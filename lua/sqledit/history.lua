-- Per-connection query history, persisted as JSON in stdpath("state").
-- Successful queries only; duplicates float to the top instead of piling up.
local M = {}

local MAX_PER_CONN = 200

local data = nil -- conn_id -> array of {sql, ts}, newest last

local function file_path()
  return vim.fn.stdpath("state") .. "/sqledit/history.json"
end

local function load()
  if data then
    return
  end
  data = {}
  local f = io.open(file_path(), "r")
  if not f then
    return
  end
  local content = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.json.decode, content)
  if ok and type(decoded) == "table" then
    data = decoded
  end
end

local function save()
  local dir = vim.fs.dirname(file_path())
  vim.fn.mkdir(dir, "p")
  local f, err = io.open(file_path(), "w")
  if not f then
    vim.notify("sqledit: cannot write history: " .. (err or "?"), vim.log.levels.WARN)
    return
  end
  f:write(vim.json.encode(data))
  f:close()
end

---Record a successfully executed query.
function M.add(conn_id, sql)
  load()
  local list = data[conn_id] or {}
  for i = #list, 1, -1 do
    if list[i].sql == sql then
      table.remove(list, i)
    end
  end
  table.insert(list, { sql = sql, ts = os.time() })
  if #list > MAX_PER_CONN then
    table.remove(list, 1)
  end
  data[conn_id] = list
  save()
end

---History for one connection, newest first.
function M.get(conn_id)
  load()
  local list = data[conn_id] or {}
  local out = {}
  for i = #list, 1, -1 do
    table.insert(out, list[i])
  end
  return out
end

return M
