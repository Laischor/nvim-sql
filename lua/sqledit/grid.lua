-- Renders a query result as an aligned grid buffer.
--
-- Editing: `c` on a cell opens an input and writes the change back as
-- `UPDATE … WHERE <pk>` (parameterized, never string-concatenated).
-- A result is editable only when it came from a single-table SELECT and
-- all primary-key columns of that table are present in the result.
-- `r` re-runs the query, `q` closes the window.
local rpc = require("sqledit.rpc")

local M = {}

local state = {
  buf = nil, -- data rows
  win = nil,
  header_buf = nil, -- sticky column names, 1-line window above the data
  header_win = nil,
  status_text = nil, -- shown in the data window's winbar
  result = nil,
  meta = nil, -- {conn, adapter, prod, sql, source = {schema, table_}|nil, rerun}
  ranges = nil, -- per data row: per column {byte_start, byte_stop}
  table_columns = nil, -- columns meta of meta.source, once fetched
}

local MAX_CELL_WIDTH = 60

local function notify_err(msg)
  vim.notify("sqledit: " .. msg, vim.log.levels.ERROR)
end

local function cell_text(v)
  if v == nil or v == vim.NIL then
    return "NULL"
  end
  local t = type(v)
  if t == "table" then
    return vim.json.encode(v)
  end
  local s = tostring(v)
  s = s:gsub("[\n\r\t]", { ["\n"] = "␤", ["\r"] = "", ["\t"] = " " })
  return s
end

local function truncate(s, width)
  if vim.fn.strdisplaywidth(s) <= width then
    return s
  end
  local out = ""
  for _, ch in vim.iter(vim.fn.split(s, "\\zs")):enumerate() do
    if vim.fn.strdisplaywidth(out .. ch) > width - 1 then
      break
    end
    out = out .. ch
  end
  return out .. "…"
end

local function pad(s, width, right_align)
  local gap = width - vim.fn.strdisplaywidth(s)
  if gap <= 0 then
    return s
  end
  local fill = string.rep(" ", gap)
  if right_align then
    return fill .. s
  end
  return s .. fill
end

local function quote_ident(name)
  return '"' .. name:gsub('"', '""') .. '"'
end

local function ensure_buffers()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "hide"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].filetype = "sqledit_grid"
  vim.api.nvim_buf_set_name(state.buf, "sqledit://results")

  state.header_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.header_buf].buftype = "nofile"
  vim.bo[state.header_buf].bufhidden = "hide"
  vim.bo[state.header_buf].swapfile = false
  vim.api.nvim_buf_set_name(state.header_buf, "sqledit://header")

  for _, buf in ipairs({ state.buf, state.header_buf }) do
    vim.keymap.set("n", "q", function()
      M.close()
    end, { buffer = buf, nowait = true, desc = "sqledit: close grid" })
  end
  vim.keymap.set("n", "c", function()
    M.edit_cell()
  end, { buffer = state.buf, nowait = true, desc = "sqledit: edit cell" })
  vim.keymap.set("x", "c", function()
    M.edit_cells()
  end, { buffer = state.buf, nowait = true, desc = "sqledit: edit column for selected rows" })
  vim.keymap.set("n", "r", function()
    if state.meta and state.meta.rerun then
      state.meta.rerun()
    end
  end, { buffer = state.buf, desc = "sqledit: re-run query" })
  vim.keymap.set("n", "gd", function()
    M.fk_jump()
  end, { buffer = state.buf, nowait = true, desc = "sqledit: follow foreign key" })
  vim.keymap.set("n", "w", function()
    M.next_column()
  end, { buffer = state.buf, desc = "sqledit: next column" })
  vim.keymap.set("n", "b", function()
    M.prev_column()
  end, { buffer = state.buf, desc = "sqledit: previous column" })
  vim.keymap.set("n", "gc", function()
    M.pick_column()
  end, { buffer = state.buf, nowait = true, desc = "sqledit: jump to column" })
  vim.keymap.set("n", "F", function()
    require("sqledit").refilter()
  end, { buffer = state.buf, desc = "sqledit: edit filter clauses" })
  for key, fmt in pairs({ yc = "csv", yj = "json", yi = "insert" }) do
    vim.keymap.set({ "n", "x" }, key, function()
      M.yank(fmt)
    end, { buffer = state.buf, nowait = true, desc = "sqledit: yank rows as " .. fmt })
  end
  vim.keymap.set("n", "p", function()
    M.paste()
  end, { buffer = state.buf, nowait = true, desc = "sqledit: insert rows from register" })
  vim.keymap.set("n", "o", function()
    M.insert_row()
  end, { buffer = state.buf, nowait = true, desc = "sqledit: insert new row (form)" })
  vim.keymap.set("n", "dd", function()
    M.delete_rows()
  end, { buffer = state.buf, nowait = true, desc = "sqledit: delete row" })
  vim.keymap.set("x", "d", function()
    M.delete_rows()
  end, { buffer = state.buf, nowait = true, desc = "sqledit: delete selected rows" })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = vim.api.nvim_create_augroup("sqledit_grid_cursor", { clear = true }),
    buffer = state.buf,
    callback = function()
      M.update_winbar()
    end,
  })
end

---Mirror the data window's horizontal scroll into the header window.
local function sync_header_scroll()
  if
    not (state.win and vim.api.nvim_win_is_valid(state.win))
    or not (state.header_win and vim.api.nvim_win_is_valid(state.header_win))
  then
    return
  end
  local leftcol = vim.api.nvim_win_call(state.win, function()
    return vim.fn.winsaveview().leftcol
  end)
  vim.api.nvim_win_call(state.header_win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1, leftcol = leftcol })
  end)
end

function M.close()
  -- header first, so a potential last-window fallback lands in the data
  -- window; E444 (cannot close last window) turns into "show an empty
  -- buffer instead"
  for _, win in ipairs({ state.header_win, state.win }) do
    if win and vim.api.nvim_win_is_valid(win) and not pcall(vim.api.nvim_win_close, win, false) then
      vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
      for opt, value in pairs({
        wrap = vim.o.wrap,
        number = vim.o.number,
        relativenumber = vim.o.relativenumber,
        signcolumn = vim.o.signcolumn,
        cursorline = vim.o.cursorline,
        winfixheight = false,
        winbar = "",
      }) do
        vim.wo[win][opt] = value
      end
    end
  end
  state.win, state.header_win = nil, nil
end

local function ensure_windows()
  ensure_buffers()
  local data_ok = state.win and vim.api.nvim_win_is_valid(state.win)
  local header_ok = state.header_win and vim.api.nvim_win_is_valid(state.header_win)
  if data_ok and header_ok then
    return
  end
  M.close() -- drop a half-broken pair before rebuilding

  local prev = vim.api.nvim_get_current_win()
  vim.cmd("botright split")
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, state.buf)
  vim.cmd("aboveleft 1split")
  state.header_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.header_win, state.header_buf)

  for _, win in ipairs({ state.win, state.header_win }) do
    vim.wo[win].wrap = false
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
  end
  vim.wo[state.win].cursorline = true
  vim.wo[state.header_win].winfixheight = true
  vim.wo[state.header_win].winbar = ""

  local group = vim.api.nvim_create_augroup("sqledit_grid_win", { clear = true })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    pattern = tostring(state.win),
    callback = sync_header_scroll,
  })
  -- one window of the pair closes -> take the other with it
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = { tostring(state.win), tostring(state.header_win) },
    callback = function()
      vim.schedule(M.close)
    end,
    once = true,
  })
  -- the header is display-only: entering it passes the movement through
  -- (from the grid upwards, from anywhere else into the grid)
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    buffer = state.header_buf,
    callback = function()
      if vim.api.nvim_get_current_win() ~= state.header_win then
        return
      end
      local from = vim.fn.win_getid(vim.fn.winnr("#"))
      if from == state.win then
        vim.cmd("wincmd k")
        if vim.api.nvim_get_current_win() == state.header_win then
          vim.api.nvim_set_current_win(state.win) -- nothing above
        end
      else
        vim.api.nvim_set_current_win(state.win)
      end
    end,
  })
  vim.api.nvim_set_current_win(prev)
end

local function redraw()
  local result, meta = state.result, state.meta
  local cols = result.columns or {}
  local rows = result.rows or {}

  local widths, numeric = {}, {}
  for i, col in ipairs(cols) do
    widths[i] = vim.fn.strdisplaywidth(col.name)
    numeric[i] = true
  end
  local cells = {}
  for r, row in ipairs(rows) do
    cells[r] = {}
    for i = 1, #cols do
      local v = row[i]
      if v ~= nil and v ~= vim.NIL and type(v) ~= "number" then
        numeric[i] = false
      end
      local s = truncate(cell_text(v), MAX_CELL_WIDTH)
      cells[r][i] = s
      local w = vim.fn.strdisplaywidth(s)
      if w > widths[i] then
        widths[i] = w
      end
    end
  end

  local header = {}
  for i, col in ipairs(cols) do
    header[i] = pad(col.name, widths[i], false)
  end
  state.status_text = ("%s%s  •  %d row(s)%s  •  %dms%s"):format(
    meta.conn,
    meta.prod and "  [PROD]" or "",
    result.row_count or #rows,
    result.more and " (truncated, raise max_rows)" or "",
    result.duration_ms or 0,
    meta.source and "  •  c:edit gd:fk r:rerun" or ""
  )

  local lines = {}
  state.ranges = {}
  for r = 1, #rows do
    local line, ranges = "", {}
    for i = 1, #cols do
      if i > 1 then
        line = line .. " │ "
      end
      local start = #line + 1
      line = line .. pad(cells[r][i], widths[i], numeric[i])
      ranges[i] = { start, #line }
    end
    state.ranges[r] = ranges
    table.insert(lines, line)
  end

  ensure_windows()
  vim.bo[state.header_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.header_buf, 0, -1, false, { table.concat(header, " │ ") })
  vim.bo[state.header_buf].modifiable = false
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  local ns = vim.api.nvim_create_namespace("sqledit_grid")
  vim.api.nvim_buf_clear_namespace(state.header_buf, ns, 0, -1)
  vim.hl.range(state.header_buf, ns, "Title", { 0, 0 }, { 0, -1 })

  local height = math.min(#lines + 1, math.max(10, math.floor(vim.o.lines * 0.4)))
  vim.api.nvim_win_set_height(state.win, height)
  vim.api.nvim_win_set_height(state.header_win, 1)
  sync_header_scroll()
  M.update_winbar()
end

---@param result table backend query result
---@param meta {conn: string, adapter: string, prod: boolean, sql: string, source: table|nil, rerun: function|nil}
function M.render(result, meta)
  state.result = result
  state.meta = meta
  state.table_columns = nil
  redraw()
  if #(result.rows or {}) > 0 then
    vim.api.nvim_win_set_cursor(state.win, { 1, 0 })
  end
end

---Column index for a 1-based byte position, from the (shared) column
---alignment of the first data row. nil without rows.
local function column_at(byte_col)
  local ranges = state.ranges and state.ranges[1]
  if not ranges then
    return nil
  end
  for i, range in ipairs(ranges) do
    if byte_col <= range[2] or i == #ranges then
      return i
    end
  end
end

local function goto_column(i)
  local ranges = state.ranges and state.ranges[1]
  if not ranges or not ranges[i] then
    return
  end
  local pos = vim.api.nvim_win_get_cursor(state.win)
  vim.api.nvim_win_set_cursor(state.win, { pos[1], ranges[i][1] - 1 })
  M.update_winbar()
end

---Current column index under the cursor (also for the header lines).
function M.current_column()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return nil
  end
  return column_at(vim.api.nvim_win_get_cursor(state.win)[2] + 1)
end

function M.next_column()
  local i = M.current_column()
  if i then
    goto_column(math.min(i + 1, #state.result.columns))
  end
end

function M.prev_column()
  local i = M.current_column()
  if i then
    goto_column(math.max(i - 1, 1))
  end
end

---Fuzzy-pick a column and jump to it — for wide tables.
function M.pick_column()
  if not state.result then
    return
  end
  local cols = state.result.columns
  vim.ui.select(cols, {
    prompt = "Column",
    format_item = function(c)
      return c.name .. "  (" .. (c.type or "") .. ")"
    end,
  }, function(_, idx)
    if idx then
      goto_column(idx)
    end
  end)
end

---Winbar carries the status line plus, in wide tables, where you are:
---column n/total, name, type.
function M.update_winbar()
  if not (state.win and vim.api.nvim_win_is_valid(state.win) and state.result) then
    return
  end
  local text = state.status_text or ""
  local i = M.current_column()
  if i then
    local col = state.result.columns[i]
    text = ("col %d/%d: %s (%s)  •  %s"):format(i, #state.result.columns, col.name, col.type or "?", text)
  end
  vim.wo[state.win].winbar = text:gsub("%%", "%%%%")
end

---Cell under the cursor in the grid window, or nil.
local function cell_at_cursor()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return nil
  end
  local pos = vim.api.nvim_win_get_cursor(state.win)
  local row = pos[1]
  if row < 1 or row > #state.result.rows then
    return nil
  end
  local byte_col = pos[2] + 1
  for i, range in ipairs(state.ranges[row]) do
    if byte_col <= range[2] or i == #state.ranges[row] then
      return row, i
    end
  end
end

local function get_table_columns(cb)
  if state.table_columns then
    cb(state.table_columns)
    return
  end
  local src = state.meta.source
  if not src.schema then
    -- unqualified table in the query: resolve its schema first
    rpc.request("objects", { id = state.meta.conn }, function(err, res)
      if err then
        notify_err(err)
        return
      end
      local lname = src.table_:lower()
      for _, o in ipairs(res.objects or {}) do
        if o.name:lower() == lname then
          src.schema = o.schema
          src.table_ = o.name
          get_table_columns(cb)
          return
        end
      end
      notify_err(("table %q not found in schema — not editable"):format(src.table_))
    end)
    return
  end
  rpc.request("columns", { id = state.meta.conn, schema = src.schema, table = src.table_ }, function(err, res)
    if err then
      notify_err(err)
      return
    end
    state.table_columns = res.columns or {}
    cb(state.table_columns)
  end)
end

---Input prefill / param serialization: cells edit as text, literal NULL
---means SQL NULL.
local function to_input(v)
  if v == nil or v == vim.NIL then
    return "NULL"
  end
  if type(v) == "table" then
    return vim.json.encode(v)
  end
  return tostring(v)
end

local function placeholder(n)
  return state.meta.adapter == "postgres" and ("$" .. n) or "?"
end

---One pk-condition group per row, OR-joined — handles composite pks and
---NULL pk values without row-value syntax. Appends pk values to params.
---Returns the groups, or nil + error message.
local function build_pk_where(table_cols, rows, params)
  local src = state.meta.source
  local result = state.result
  local pks = vim.tbl_filter(function(c)
    return c.pk
  end, table_cols)
  if #pks == 0 then
    return nil, ("%s.%s has no primary key — read-only"):format(src.schema, src.table_)
  end
  local col_index = {}
  for i, c in ipairs(result.columns) do
    col_index[c.name] = i
  end
  local groups = {}
  for _, row in ipairs(rows) do
    local conds = {}
    for _, pk in ipairs(pks) do
      local i = col_index[pk.name]
      if not i then
        return nil, ("primary key column %q not in result — select it to edit"):format(pk.name)
      end
      local v = result.rows[row][i]
      if v == nil or v == vim.NIL then
        table.insert(conds, quote_ident(pk.name) .. " IS NULL")
      else
        table.insert(params, tostring(v))
        table.insert(conds, quote_ident(pk.name) .. " = " .. placeholder(#params))
      end
    end
    table.insert(groups, "(" .. table.concat(conds, " AND ") .. ")")
  end
  return groups
end

---Write `input` into column `col` of the given row indices via one
---parameterized UPDATE. Input semantics: "NULL" = SQL NULL, '' = empty
---string, empty input = no change.
local function apply_update(rows, col, input)
  local src = state.meta.source
  local result = state.result
  local table_cols = state.table_columns

  if input == "" then
    vim.notify("sqledit: no change (NULL for null, '' for empty string)")
    return
  end
  local new_value
  if input == "NULL" then
    new_value = vim.NIL
  elseif input == "''" then
    new_value = ""
  else
    new_value = input
  end

  local params = { new_value }
  local groups, gerr = build_pk_where(table_cols, rows, params)
  if not groups then
    notify_err(gerr)
    return
  end

  local col_name = result.columns[col].name
  local sql = ("UPDATE %s.%s SET %s = %s WHERE %s"):format(
    quote_ident(src.schema),
    quote_ident(src.table_),
    quote_ident(col_name),
    placeholder(1),
    table.concat(groups, " OR ")
  )

  -- multi-row edits always confirm; single-row only on prod
  if #rows > 1 or state.meta.prod then
    local preview = sql
    if #preview > 200 then
      preview = preview:sub(1, 197) .. "..."
    end
    local prompt = ("Update %d row(s) on %s%s?\n\n  %s.%s = %s\n\n  %s"):format(
      #rows,
      state.meta.conn,
      state.meta.prod and " [PROD]" or "",
      src.table_,
      col_name,
      input,
      preview
    )
    if vim.fn.confirm(prompt, "&Yes\n&No", 2, state.meta.prod and "Warning" or "Question") ~= 1 then
      return
    end
  end

  rpc.request("query", { id = state.meta.conn, sql = sql, params = params }, function(err, res)
    if err then
      notify_err(err)
      return
    end
    local affected = res.rows_affected or 0
    if affected ~= #rows then
      notify_err(("expected %d row(s), %d affected — press r to reload"):format(#rows, affected))
      return
    end
    for _, row in ipairs(rows) do
      -- keep numbers numeric so alignment survives the local update
      local stored = new_value
      if stored ~= vim.NIL and tonumber(stored) ~= nil and type(result.rows[row][col]) == "number" then
        stored = tonumber(stored)
      end
      result.rows[row][col] = stored
    end
    local cursor = vim.api.nvim_win_get_cursor(state.win)
    redraw()
    vim.api.nvim_win_set_cursor(state.win, cursor)
    vim.notify(("sqledit: updated %d row(s) in %s.%s.%s"):format(#rows, src.schema, src.table_, col_name))
  end)
end

---SQL literal for a cell value in an equality comparison. Values come
---from the database itself; strings are quoted with '' doubling.
local function sql_literal(v)
  if type(v) == "number" then
    return tostring(v)
  end
  return "'" .. tostring(v):gsub("'", "''") .. "'"
end

---Follow the foreign key of the cell under the cursor: opens the
---referenced row in the grid (read-only SELECT).
function M.fk_jump()
  if not (state.result and state.meta) then
    return
  end
  if not state.meta.source then
    notify_err("result not editable (needs a plain single-table SELECT)")
    return
  end
  local row, col = cell_at_cursor()
  if not row then
    notify_err("no cell under cursor")
    return
  end
  get_table_columns(function(table_cols)
    local col_name = state.result.columns[col].name
    local fk
    for _, c in ipairs(table_cols) do
      if c.name == col_name then
        fk = c.fk
        break
      end
    end
    if not fk or fk == vim.NIL then
      notify_err(("no foreign key on %q"):format(col_name))
      return
    end
    local value = state.result.rows[row][col]
    if value == nil or value == vim.NIL then
      notify_err(col_name .. " is NULL — nothing to follow")
      return
    end
    if type(value) == "table" then
      notify_err("cannot follow a structured value")
      return
    end
    local sql = ("SELECT * FROM %s.%s WHERE %s = %s"):format(
      quote_ident(fk.schema),
      quote_ident(fk.table),
      quote_ident(fk.column),
      sql_literal(value)
    )
    require("sqledit").run(sql)
  end)
end

---Shared entry for single- and multi-row edits: validates the column,
---prefills the input (common value across rows, empty when mixed).
local function start_edit(rows, col)
  get_table_columns(function(table_cols)
    local col_name = state.result.columns[col].name
    local known = false
    for _, c in ipairs(table_cols) do
      if c.name == col_name then
        known = true
        break
      end
    end
    if not known then
      notify_err(("%q is not a column of %s.%s (computed/aliased?)"):format(
        col_name, state.meta.source.schema, state.meta.source.table_))
      return
    end
    -- NULL prefills empty (no need to delete "NULL" before typing);
    -- setting NULL is done by typing the literal NULL
    local function prefill_text(v)
      if v == nil or v == vim.NIL then
        return ""
      end
      return to_input(v)
    end
    local prefill = prefill_text(state.result.rows[rows[1]][col])
    for _, row in ipairs(rows) do
      if prefill_text(state.result.rows[row][col]) ~= prefill then
        prefill = ""
        break
      end
    end
    local prompt = #rows > 1 and ("%s.%s (%d rows) = "):format(state.meta.source.table_, col_name, #rows)
      or ("%s.%s = "):format(state.meta.source.table_, col_name)
    vim.ui.input({ prompt = prompt, default = prefill }, function(input)
      if input == nil then -- cancelled
        return
      end
      apply_update(rows, col, input)
    end)
  end)
end

local function editable_or_complain()
  if not (state.result and state.meta) then
    return false
  end
  if not state.meta.source then
    notify_err("result not editable (needs a plain single-table SELECT)")
    return false
  end
  return true
end

---Row indices for the current action: visual selection when active
---(leaves visual mode), else the cursor row.
local function selected_rows()
  local total = #state.result.rows
  if total == 0 then
    return nil
  end
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    vim.cmd([[execute "normal! \<esc>"]])
    local first = vim.api.nvim_buf_get_mark(state.buf, "<")[1]
    local last = vim.api.nvim_buf_get_mark(state.buf, ">")[1]
    first, last = math.max(1, math.min(first, last)), math.min(total, math.max(first, last))
    local rows = {}
    for r = first, last do
      table.insert(rows, r)
    end
    return rows
  end
  local pos = vim.api.nvim_win_get_cursor(state.win)
  if pos[1] > total then
    return nil
  end
  return { pos[1] }
end

---Yank rows as csv/json/insert into the unnamed register and, when
---available, the system clipboard.
function M.yank(fmt)
  if not state.result then
    return
  end
  local rows_idx = selected_rows()
  if not rows_idx then
    notify_err("no rows to yank")
    return
  end
  local transfer = require("sqledit.transfer")
  local cols = {}
  for i, c in ipairs(state.result.columns) do
    cols[i] = c.name
  end
  local rows = {}
  for _, r in ipairs(rows_idx) do
    table.insert(rows, state.result.rows[r])
  end
  local function finish(text)
    vim.fn.setreg('"', text)
    pcall(vim.fn.setreg, "+", text)
    vim.notify(("sqledit: yanked %d row(s) as %s"):format(#rows, fmt))
  end
  if fmt == "csv" then
    finish(transfer.to_csv(cols, rows))
  elseif fmt == "json" then
    finish(transfer.to_json(cols, rows))
  else
    local src = state.meta.source
    if not src then
      notify_err("INSERT yank needs a single-table SELECT (source table unknown)")
      return
    end
    -- resolves the schema of an unqualified table as a side effect
    get_table_columns(function()
      finish(transfer.to_insert(src.schema, src.table_, cols, rows))
    end)
  end
end

---Insert rows from the register (CSV or JSON, auto-detected) into the
---grid's source table on the CURRENT connection, then re-run the query.
function M.paste()
  if not editable_or_complain() then
    return
  end
  local text = ""
  local ok, clip = pcall(vim.fn.getreg, "+")
  if ok and clip ~= "" then
    text = clip
  else
    text = vim.fn.getreg('"')
  end
  local transfer = require("sqledit.transfer")
  local cols, rows = transfer.parse(text)
  if not cols then
    notify_err("paste: " .. rows)
    return
  end
  get_table_columns(function(table_cols)
    -- match by exact name, falling back to case-insensitive (postgres
    -- folds unquoted identifiers; external CSV headers vary)
    local known, known_ci = {}, {}
    for _, c in ipairs(table_cols) do
      known[c.name] = c.name
      known_ci[c.name:lower()] = c.name
    end
    local keep, dropped = {}, {}
    for i, name in ipairs(cols) do
      local target = known[name] or known_ci[name:lower()]
      if target then
        table.insert(keep, { idx = i, name = target })
      else
        table.insert(dropped, name)
      end
    end
    if #keep == 0 then
      local table_names = vim.tbl_map(function(c)
        return c.name
      end, table_cols)
      notify_err(("paste: no matching columns on %s\n  payload: %s\n  table:   %s"):format(
        state.meta.source.table_,
        table.concat(cols, ", "),
        table.concat(table_names, ", ")
      ))
      return
    end

    local src = state.meta.source
    local pk_names = {}
    for _, c in ipairs(table_cols) do
      if c.pk then
        for _, k in ipairs(keep) do
          if k.name == c.name then
            table.insert(pk_names, c.name)
          end
        end
      end
    end

    local col_names = vim.tbl_map(function(k)
      return k.name
    end, keep)
    local prompt = ("Insert %d row(s) into %s.%s on %s%s?\n\n  columns: %s%s"):format(
      #rows,
      src.schema,
      src.table_,
      state.meta.conn,
      state.meta.prod and " [PROD]" or "",
      table.concat(col_names, ", "),
      #dropped > 0 and ("\n  ignored (not on table): " .. table.concat(dropped, ", ")) or ""
    )
    local style = state.meta.prod and "Warning" or "Question"
    if #pk_names > 0 then
      -- pasted pk values usually collide — offer to let the db assign them
      prompt = prompt .. "\n  primary key in payload: " .. table.concat(pk_names, ", ")
      local choice = vim.fn.confirm(prompt, "&Insert as-is\n&Without pk\n&Cancel", 2, style)
      if choice ~= 1 and choice ~= 2 then
        return
      end
      if choice == 2 then
        keep = vim.tbl_filter(function(k)
          return not vim.tbl_contains(pk_names, k.name)
        end, keep)
        if #keep == 0 then
          notify_err("paste: payload only contains primary key columns")
          return
        end
      end
    elseif vim.fn.confirm(prompt, "&Yes\n&No", 2, style) ~= 1 then
      return
    end

    local params, tuples, names = {}, {}, {}
    for i, k in ipairs(keep) do
      names[i] = quote_ident(k.name)
    end
    for _, row in ipairs(rows) do
      local vals = {}
      for i, k in ipairs(keep) do
        local v = row[k.idx]
        if v == nil or v == vim.NIL then
          table.insert(params, vim.NIL)
        elseif type(v) == "table" then
          table.insert(params, vim.json.encode(v))
        else
          table.insert(params, tostring(v))
        end
        vals[i] = placeholder(#params)
      end
      table.insert(tuples, "(" .. table.concat(vals, ", ") .. ")")
    end
    local sql = ("INSERT INTO %s.%s (%s) VALUES %s"):format(
      quote_ident(src.schema),
      quote_ident(src.table_),
      table.concat(names, ", "),
      table.concat(tuples, ", ")
    )

    rpc.request("query", { id = state.meta.conn, sql = sql, params = params }, function(err, res)
      if err then
        notify_err(err)
        return
      end
      vim.notify(("sqledit: inserted %d row(s) into %s.%s"):format(res.rows_affected or 0, src.schema, src.table_))
      if state.meta.rerun then
        state.meta.rerun()
      end
    end)
  end)
end

---Delete the selected rows (or the cursor row) — always confirmed.
function M.delete_rows()
  if not editable_or_complain() then
    return
  end
  local rows = selected_rows()
  if not rows then
    notify_err("no rows selected")
    return
  end
  get_table_columns(function(table_cols)
    local src = state.meta.source
    local result = state.result
    local params = {}
    local groups, gerr = build_pk_where(table_cols, rows, params)
    if not groups then
      notify_err(gerr)
      return
    end
    local sql = ("DELETE FROM %s.%s WHERE %s"):format(
      quote_ident(src.schema),
      quote_ident(src.table_),
      table.concat(groups, " OR ")
    )
    local preview = sql
    if #preview > 200 then
      preview = preview:sub(1, 197) .. "..."
    end
    local prompt = ("Delete %d row(s) from %s.%s on %s%s?\n\n  %s"):format(
      #rows,
      src.schema,
      src.table_,
      state.meta.conn,
      state.meta.prod and " [PROD]" or "",
      preview
    )
    if vim.fn.confirm(prompt, "&Delete\n&Cancel", 2, "Warning") ~= 1 then
      return
    end
    rpc.request("query", { id = state.meta.conn, sql = sql, params = params }, function(err, res)
      if err then
        notify_err(err)
        return
      end
      local affected = res.rows_affected or 0
      if affected ~= #rows then
        notify_err(("expected %d row(s), %d affected — press r to reload"):format(#rows, affected))
        return
      end
      table.sort(rows, function(a, b)
        return a > b
      end)
      for _, r in ipairs(rows) do
        table.remove(result.rows, r)
      end
      result.row_count = #result.rows
      local cursor = vim.api.nvim_win_get_cursor(state.win)
      redraw()
      if #result.rows > 0 then
        vim.api.nvim_win_set_cursor(state.win, { math.min(cursor[1], #result.rows), cursor[2] })
      end
      vim.notify(("sqledit: deleted %d row(s) from %s.%s"):format(#rows, src.schema, src.table_))
    end)
  end)
end

---Open a one-line-per-column form in a float; :w runs the INSERT.
---Empty value = column omitted (DB default / serial pk), literal NULL
---= SQL NULL.
function M.insert_row()
  if not editable_or_complain() then
    return
  end
  get_table_columns(function(table_cols)
    local src = state.meta.source
    local buf = vim.api.nvim_create_buf(false, false)
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "sqledit_insert"
    vim.api.nvim_buf_set_name(buf, ("sqledit://insert/%s.%s"):format(src.schema, src.table_))

    local lines = {}
    for _, c in ipairs(table_cols) do
      table.insert(lines, c.name .. " = ")
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modified = false

    local ns = vim.api.nvim_create_namespace("sqledit_insert_form")
    for i, c in ipairs(table_cols) do
      local hints = { c.type }
      if c.pk then
        table.insert(hints, "pk")
      end
      if c.not_null then
        table.insert(hints, "not null")
      end
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        virt_text = { { "  " .. table.concat(hints, " · "), "Comment" } },
        virt_text_pos = "eol",
      })
    end

    local width = math.min(vim.o.columns - 4, 70)
    local height = math.min(#lines, vim.o.lines - 6)
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      row = math.floor((vim.o.lines - height) / 2) - 1,
      col = math.floor((vim.o.columns - width) / 2),
      width = width,
      height = height,
      border = "rounded",
      title = (" INSERT INTO %s.%s — :w runs it, empty = default, NULL = null "):format(src.schema, src.table_),
      title_pos = "center",
    })
    vim.wo[win].number = false
    vim.wo[win].signcolumn = "no"
    vim.keymap.set("n", "q", "<cmd>bwipeout!<cr>", { buffer = buf, nowait = true })

    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = buf,
      callback = function()
        local names, vals, params = {}, {}, {}
        for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
          local name, value = line:match("^%s*([%w_]+)%s*=%s*(.*)$")
          if name and vim.trim(value) ~= "" then
            value = vim.trim(value)
            table.insert(names, quote_ident(name))
            if value == "NULL" then
              table.insert(params, vim.NIL)
            else
              table.insert(params, value)
            end
            table.insert(vals, placeholder(#params))
          end
        end
        if #names == 0 then
          notify_err("insert: all fields empty")
          return
        end
        local sql = ("INSERT INTO %s.%s (%s) VALUES (%s)"):format(
          quote_ident(src.schema),
          quote_ident(src.table_),
          table.concat(names, ", "),
          table.concat(vals, ", ")
        )
        if state.meta.prod then
          local prompt = ("Insert into %s.%s on PROD (%s)?\n\n  %s"):format(
            src.schema, src.table_, state.meta.conn, sql)
          if vim.fn.confirm(prompt, "&Yes\n&No", 2, "Warning") ~= 1 then
            return
          end
        end
        rpc.request("query", { id = state.meta.conn, sql = sql, params = params }, function(qerr)
          if qerr then
            notify_err(qerr)
            return
          end
          vim.bo[buf].modified = false
          if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
          end
          vim.notify(("sqledit: inserted 1 row into %s.%s"):format(src.schema, src.table_))
          if state.meta.rerun then
            state.meta.rerun()
          end
        end)
      end,
    })
  end)
end

---Edit the cell under the cursor.
function M.edit_cell()
  if not editable_or_complain() then
    return
  end
  local row, col = cell_at_cursor()
  if not row then
    notify_err("no cell under cursor")
    return
  end
  start_edit({ row }, col)
end

---Edit one column across the visually selected rows (one UPDATE).
function M.edit_cells()
  if not editable_or_complain() then
    return
  end
  local rows = selected_rows()
  local col = M.current_column()
  if not rows or not col then
    notify_err("no rows selected")
    return
  end
  start_edit(rows, col)
end

return M
