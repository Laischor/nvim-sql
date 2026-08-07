-- Serialize grid rows to CSV/JSON/INSERT and parse CSV/JSON back —
-- the transport for copying rows between connections via registers.
--
-- NULL round-trips: CSV writes NULL as an unquoted empty field and an
-- empty string as "", the parser keeps them apart. JSON uses null.
local M = {}

local function is_null(v)
  return v == nil or v == vim.NIL
end

local function cell_string(v)
  if type(v) == "table" then
    return vim.json.encode(v)
  end
  return tostring(v)
end

local function csv_field(v)
  if is_null(v) then
    return ""
  end
  local s = cell_string(v)
  if s == "" or s:find('[",\r\n]') then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return s
end

---@param cols string[] column names
---@param rows any[][] cell values (vim.NIL for NULL)
function M.to_csv(cols, rows)
  local lines = { table.concat(vim.tbl_map(csv_field, cols), ",") }
  for _, row in ipairs(rows) do
    local fields = {}
    for i = 1, #cols do
      fields[i] = csv_field(row[i])
    end
    table.insert(lines, table.concat(fields, ","))
  end
  return table.concat(lines, "\n") .. "\n"
end

function M.to_json(cols, rows)
  local objs = {}
  for _, row in ipairs(rows) do
    local obj = {}
    for i, name in ipairs(cols) do
      local v = row[i]
      obj[name] = is_null(v) and vim.NIL or v
    end
    table.insert(objs, obj)
  end
  return vim.json.encode(objs)
end

local function sql_literal(v)
  if is_null(v) then
    return "NULL"
  end
  if type(v) == "number" then
    return tostring(v)
  end
  return "'" .. cell_string(v):gsub("'", "''") .. "'"
end

local function quote_ident(name)
  return '"' .. name:gsub('"', '""') .. '"'
end

---Rows as a ready-to-run INSERT statement (for pasting outside sqledit).
function M.to_insert(schema, table_, cols, rows)
  local names = {}
  for i, name in ipairs(cols) do
    names[i] = quote_ident(name)
  end
  local tuples = {}
  for _, row in ipairs(rows) do
    local vals = {}
    for i = 1, #cols do
      vals[i] = sql_literal(row[i])
    end
    table.insert(tuples, "(" .. table.concat(vals, ", ") .. ")")
  end
  return ("INSERT INTO %s.%s (%s) VALUES\n  %s;\n"):format(
    quote_ident(schema),
    quote_ident(table_),
    table.concat(names, ", "),
    table.concat(tuples, ",\n  ")
  )
end

-- RFC 4180-ish CSV parser; returns rows of {value, quoted} pairs.
local function parse_csv_raw(text)
  local rows, row = {}, {}
  local field, quoted, in_quotes = {}, false, false
  local i, n = 1, #text
  local function end_field()
    table.insert(row, { value = table.concat(field), quoted = quoted })
    field, quoted = {}, false
  end
  local function end_row()
    end_field()
    table.insert(rows, row)
    row = {}
  end
  while i <= n do
    local ch = text:sub(i, i)
    if in_quotes then
      if ch == '"' then
        if text:sub(i + 1, i + 1) == '"' then
          table.insert(field, '"')
          i = i + 1
        else
          in_quotes = false
        end
      else
        table.insert(field, ch)
      end
    elseif ch == '"' and #field == 0 then
      in_quotes, quoted = true, true
    elseif ch == "," then
      end_field()
    elseif ch == "\r" then -- swallow, \n handles the row break
    elseif ch == "\n" then
      end_row()
    else
      table.insert(field, ch)
    end
    i = i + 1
  end
  if #field > 0 or #row > 0 then
    end_row()
  end
  return rows
end

local function parse_csv(text)
  local raw = parse_csv_raw(text)
  if #raw < 2 then
    return nil, "CSV needs a header line and at least one data row"
  end
  local cols = {}
  for _, f in ipairs(raw[1]) do
    table.insert(cols, f.value)
  end
  local rows = {}
  for r = 2, #raw do
    local row = {}
    for i = 1, #cols do
      local f = raw[r][i]
      if f == nil or (f.value == "" and not f.quoted) then
        row[i] = vim.NIL -- unquoted empty field = NULL
      else
        row[i] = f.value
      end
    end
    table.insert(rows, row)
  end
  return cols, rows
end

local function parse_json(text)
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok or type(decoded) ~= "table" then
    return nil, "not valid JSON"
  end
  if decoded[1] == nil and next(decoded) ~= nil then
    decoded = { decoded } -- single object
  end
  if #decoded == 0 then
    return nil, "empty JSON array"
  end
  local cols = {}
  for name in pairs(decoded[1]) do
    table.insert(cols, name)
  end
  table.sort(cols)
  local rows = {}
  for _, obj in ipairs(decoded) do
    if type(obj) ~= "table" then
      return nil, "expected an array of objects"
    end
    local row = {}
    for i, name in ipairs(cols) do
      local v = obj[name]
      row[i] = (v == nil or v == vim.NIL) and vim.NIL or v
    end
    table.insert(rows, row)
  end
  return cols, rows
end

---Auto-detect CSV or JSON. Returns (cols, rows) or (nil, err).
function M.parse(text)
  text = vim.trim(text or "")
  if text == "" then
    return nil, "register is empty"
  end
  if text:sub(1, 1) == "[" or text:sub(1, 1) == "{" then
    return parse_json(text)
  end
  if text:upper():match("^INSERT%f[%W]") then
    return nil, "register holds an INSERT statement (yi) — run it in a query buffer; grid paste needs CSV (yc) or JSON (yj)"
  end
  local cols, rows = parse_csv(text)
  if not cols then
    return nil, rows
  end
  for i, name in ipairs(cols) do
    cols[i] = vim.trim(name)
  end
  return cols, rows
end

return M
