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
  buf = nil,
  win = nil,
  result = nil,
  meta = nil, -- {conn, adapter, prod, sql, source = {schema, table_}|nil, rerun}
  ranges = nil, -- per data row: per column {byte_start, byte_stop}
  table_columns = nil, -- columns meta of meta.source, once fetched
}

local MAX_CELL_WIDTH = 60
local HEADER_LINES = 3 -- status, header, rule

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

local function ensure_window()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      return
    end
  else
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.buf].buftype = "nofile"
    vim.bo[state.buf].bufhidden = "hide"
    vim.bo[state.buf].swapfile = false
    vim.bo[state.buf].filetype = "sqledit_grid"
    vim.api.nvim_buf_set_name(state.buf, "sqledit://results")
    vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = state.buf, nowait = true })
    vim.keymap.set("n", "c", function()
      M.edit_cell()
    end, { buffer = state.buf, nowait = true, desc = "sqledit: edit cell" })
    vim.keymap.set("n", "r", function()
      if state.meta and state.meta.rerun then
        state.meta.rerun()
      end
    end, { buffer = state.buf, desc = "sqledit: re-run query" })
    vim.keymap.set("n", "gd", function()
      M.fk_jump()
    end, { buffer = state.buf, nowait = true, desc = "sqledit: follow foreign key" })
  end
  local prev = vim.api.nvim_get_current_win()
  vim.cmd("botright split")
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, state.buf)
  vim.wo[state.win].wrap = false
  vim.wo[state.win].number = false
  vim.wo[state.win].relativenumber = false
  vim.wo[state.win].signcolumn = "no"
  vim.wo[state.win].cursorline = true
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

  local lines = {}
  local header, rule = {}, {}
  for i, col in ipairs(cols) do
    header[i] = pad(col.name, widths[i], false)
    rule[i] = string.rep("─", widths[i])
  end
  local status = ("%s%s  •  %d row(s)%s  •  %dms%s"):format(
    meta.conn,
    meta.prod and "  [PROD]" or "",
    result.row_count or #rows,
    result.more and " (truncated, raise max_rows)" or "",
    result.duration_ms or 0,
    meta.source and "  •  c:edit gd:fk r:rerun" or ""
  )
  table.insert(lines, status)
  table.insert(lines, table.concat(header, " │ "))
  table.insert(lines, table.concat(rule, "─┼─"))

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

  ensure_window()
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  local ns = vim.api.nvim_create_namespace("sqledit_grid")
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  vim.hl.range(state.buf, ns, meta.prod and "ErrorMsg" or "Comment", { 0, 0 }, { 0, -1 })
  vim.hl.range(state.buf, ns, "Title", { 1, 0 }, { 1, -1 })

  local height = math.min(#lines + 1, math.max(10, math.floor(vim.o.lines * 0.4)))
  vim.api.nvim_win_set_height(state.win, height)
end

---@param result table backend query result
---@param meta {conn: string, adapter: string, prod: boolean, sql: string, source: table|nil, rerun: function|nil}
function M.render(result, meta)
  state.result = result
  state.meta = meta
  state.table_columns = nil
  redraw()
  if #(result.rows or {}) > 0 then
    vim.api.nvim_win_set_cursor(state.win, { HEADER_LINES + 1, 0 })
  end
end

---Cell under the cursor in the grid window, or nil.
local function cell_at_cursor()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return nil
  end
  local pos = vim.api.nvim_win_get_cursor(state.win)
  local row = pos[1] - HEADER_LINES
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

local function apply_update(row, col, input)
  local src = state.meta.source
  local result = state.result
  local table_cols = state.table_columns

  local pks = vim.tbl_filter(function(c)
    return c.pk
  end, table_cols)
  if #pks == 0 then
    notify_err(("%s.%s has no primary key — read-only"):format(src.schema, src.table_))
    return
  end

  -- map pk columns to their values in this result row
  local col_index = {}
  for i, c in ipairs(result.columns) do
    col_index[c.name] = i
  end
  local where, params = {}, {}
  local new_value = input == "NULL" and vim.NIL or input
  table.insert(params, new_value)
  local placeholder = function(n)
    return state.meta.adapter == "postgres" and ("$" .. n) or "?"
  end
  for _, pk in ipairs(pks) do
    local i = col_index[pk.name]
    if not i then
      notify_err(("primary key column %q not in result — select it to edit"):format(pk.name))
      return
    end
    local v = result.rows[row][i]
    if v == nil or v == vim.NIL then
      table.insert(where, quote_ident(pk.name) .. " IS NULL")
    else
      table.insert(params, tostring(v))
      table.insert(where, quote_ident(pk.name) .. " = " .. placeholder(#params))
    end
  end

  local col_name = result.columns[col].name
  local sql = ("UPDATE %s.%s SET %s = %s WHERE %s"):format(
    quote_ident(src.schema),
    quote_ident(src.table_),
    quote_ident(col_name),
    placeholder(1),
    table.concat(where, " AND ")
  )

  if state.meta.prod then
    local prompt = ("Run on PROD (%s)?\n\n  %s\n  values: %s"):format(
      state.meta.conn,
      sql,
      vim.inspect(params):gsub("%s+", " ")
    )
    if vim.fn.confirm(prompt, "&Yes\n&No", 2, "Warning") ~= 1 then
      return
    end
  end

  rpc.request("query", { id = state.meta.conn, sql = sql, params = params }, function(err, res)
    if err then
      notify_err(err)
      return
    end
    local affected = res.rows_affected or 0
    if affected ~= 1 then
      notify_err(("expected 1 row, %d affected — press r to reload"):format(affected))
      return
    end
    -- keep numbers numeric so alignment survives the local update
    local stored = new_value
    if stored ~= vim.NIL and tonumber(stored) ~= nil and type(result.rows[row][col]) == "number" then
      stored = tonumber(stored)
    end
    result.rows[row][col] = stored
    local cursor = vim.api.nvim_win_get_cursor(state.win)
    redraw()
    vim.api.nvim_win_set_cursor(state.win, cursor)
    vim.notify(("sqledit: updated %s.%s.%s"):format(src.schema, src.table_, col_name))
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

---Edit the cell under the cursor.
function M.edit_cell()
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
    local current = state.result.rows[row][col]
    vim.ui.input({
      prompt = ("%s.%s = "):format(state.meta.source.table_, col_name),
      default = to_input(current),
    }, function(input)
      if input == nil then -- cancelled
        return
      end
      apply_update(row, col, input)
    end)
  end)
end

return M
