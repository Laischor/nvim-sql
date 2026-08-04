-- Renders a query result as an aligned, read-only grid buffer.
local M = {}

local state = {
  buf = nil,
  win = nil,
}

local MAX_CELL_WIDTH = 60

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

---@param result table backend query result
---@param meta {conn: string, prod: boolean}
function M.render(result, meta)
  local cols = result.columns or {}
  local rows = result.rows or {}

  -- statement without result set (UPDATE, DDL, …)
  if #cols == 0 then
    local msg = ("%s: OK — %d row(s) affected, %dms"):format(meta.conn, result.rows_affected or 0, result.duration_ms or 0)
    vim.notify("sqledit: " .. msg, vim.log.levels.INFO)
    return
  end

  -- stringify + column widths + numeric detection
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
  local status = ("%s%s  •  %d row(s)%s  •  %dms"):format(
    meta.conn,
    meta.prod and "  [PROD]" or "",
    result.row_count or #rows,
    result.more and " (truncated, raise max_rows)" or "",
    result.duration_ms or 0
  )
  table.insert(lines, status)
  table.insert(lines, table.concat(header, " │ "))
  table.insert(lines, table.concat(rule, "─┼─"))
  for r = 1, #rows do
    local parts = {}
    for i = 1, #cols do
      parts[i] = pad(cells[r][i], widths[i], numeric[i])
    end
    table.insert(lines, table.concat(parts, " │ "))
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
  -- park the cursor on the first data row
  if #rows > 0 then
    vim.api.nvim_win_set_cursor(state.win, { 4, 0 })
  end
end

return M
