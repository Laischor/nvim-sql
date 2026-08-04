local rpc = require("sqledit.rpc")
local grid = require("sqledit.grid")

local M = {}

M.config = {
  -- Path to the sqledit backend binary. Defaults to <plugin>/bin/sqledit.
  backend = nil,
  -- Path to connections.toml. Defaults to the backend's default
  -- ($SQLEDIT_CONFIG or ~/.config/sqledit/connections.toml).
  connections_file = nil,
  -- Max rows fetched per query.
  max_rows = 500,
  -- Ask before running writes on servers marked prod = true.
  confirm_prod_writes = true,
  -- Buffer-local mapping in sqledit query buffers to run the query.
  run_key = "<localleader>r",
}

local state = {
  current = nil, -- connInfo from backend: {id, server, database, adapter, prod, readonly}
  last_sql = nil,
  query_count = 0,
}

local function notify_err(msg)
  vim.notify("sqledit: " .. msg, vim.log.levels.ERROR)
end

local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.normalize(vim.fs.dirname(src) .. "/../..")
end

local function backend_path()
  return M.config.backend or (plugin_root() .. "/bin/sqledit")
end

local function ensure_backend()
  if rpc.running() then
    return true
  end
  local err = rpc.start({ backend = backend_path(), config_file = M.config.connections_file })
  if err then
    notify_err(err)
    return false
  end
  return true
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

---Current connection info ({id, server, database, adapter, prod, readonly})
---or nil. Used by completion sources.
function M.current()
  return state.current
end

---Drop cached schema data so completion re-introspects (e.g. after DDL).
function M.refresh()
  require("sqledit.completion").refresh()
  vim.notify("sqledit: schema cache cleared")
end

---Current connection label for the statusline, e.g. "site3/analytics [PROD]".
function M.status()
  local c = state.current
  if not c then
    return ""
  end
  return c.id .. (c.prod and " [PROD]" or "")
end

local WRITE_RE = vim.regex([[\v<(insert|update|delete|drop|alter|truncate|create|grant|revoke|vacuum|reindex)>]])

local function is_write(sql)
  return WRITE_RE:match_str(sql:lower()) ~= nil
end

local function quote_ident(name)
  return '"' .. name:gsub('"', '""') .. '"'
end

---Detect a plain single-table SELECT so the grid can offer cell editing.
---Conservative: any join/group/union/distinct or a second FROM disables it.
local function detect_source(sql)
  local s = sql:lower()
  if not s:match("^%s*select%f[%W]") then
    return nil
  end
  for _, kw in ipairs({ "join", "group", "union", "distinct", "having" }) do
    if s:match("%f[%w]" .. kw .. "%f[%W]") then
      return nil
    end
  end
  local from_count = 0
  for _ in s:gmatch("%f[%w]from%f[%W]") do
    from_count = from_count + 1
  end
  if from_count ~= 1 then
    return nil
  end
  local token = sql:match("[fF][rR][oO][mM]%s+([%w_%.\"]+)")
  if not token or token:find(",", 1, true) then
    return nil
  end
  token = token:gsub('"', "")
  local schema, tbl = token:match("^([%w_]+)%.([%w_]+)$")
  if not schema then
    tbl = token:match("^[%w_]+$")
    if not tbl then
      return nil
    end
  end
  return { schema = schema, table_ = tbl }
end

---Run SQL on the current connection and show the result grid.
function M.run(sql)
  if not ensure_backend() then
    return
  end
  local c = state.current
  if not c then
    notify_err("no connection — :Sqledit connect first")
    return
  end
  sql = vim.trim(sql or "")
  if sql == "" then
    notify_err("empty query")
    return
  end
  if M.config.confirm_prod_writes and c.prod and is_write(sql) then
    local choice = vim.fn.confirm(("Write statement on PROD (%s). Run it?"):format(c.id), "&Yes\n&No", 2, "Warning")
    if choice ~= 1 then
      return
    end
  end
  state.last_sql = sql
  rpc.request("query", { id = c.id, sql = sql, max_rows = M.config.max_rows }, function(err, result)
    if err then
      notify_err(err)
      return
    end
    grid.render(result, {
      conn = c.id,
      adapter = c.adapter,
      prod = c.prod,
      sql = sql,
      source = detect_source(sql),
      rerun = function()
        M.run(sql)
      end,
    })
  end)
end

local function connect_to(server_name, database, on_done)
  rpc.request("connect", { server = server_name, database = database }, function(err, info)
    if err then
      notify_err(err)
      return
    end
    state.current = info
    vim.notify("sqledit: connected to " .. info.id .. (info.prod and " [PROD]" or ""))
    if on_done then
      on_done(info)
    end
  end)
end

local function pick_database(server, on_done)
  if server.adapter == "sqlite" then
    connect_to(server.name, nil, on_done)
    return
  end
  rpc.request("databases.list", { server = server.name }, function(err, res)
    if err then
      notify_err(err)
      return
    end
    local dbs = res.databases or {}
    if #dbs == 0 then
      notify_err("no databases on " .. server.name)
      return
    end
    vim.ui.select(dbs, { prompt = "Database on " .. server.name }, function(choice)
      if choice then
        connect_to(server.name, choice, on_done)
      end
    end)
  end)
end

---Pick server, then database, then connect. `on_done(info)` is optional.
function M.connect(on_done)
  if not ensure_backend() then
    return
  end
  rpc.request("connections.list", nil, function(err, res)
    if err then
      notify_err(err)
      return
    end
    local servers = res.servers or {}
    if #servers == 0 then
      notify_err("no servers configured — edit " .. (res.config_path or "connections.toml"))
      return
    end
    vim.ui.select(servers, {
      prompt = "SQL server",
      format_item = function(s)
        local tags = {}
        if s.prod then
          table.insert(tags, "PROD")
        end
        if s.readonly then
          table.insert(tags, "ro")
        end
        return ("%s  (%s%s)"):format(s.name, s.adapter, #tags > 0 and ", " .. table.concat(tags, ", ") or "")
      end,
    }, function(server)
      if server then
        pick_database(server, on_done)
      end
    end)
  end)
end

---Switch connection, then offer to re-run the last query there — same
---table, different site/env. Never runs anything silently: read-only
---queries need a confirm (with preview), writes are never offered.
function M.switch()
  local sql = state.last_sql
  M.connect(function(info)
    if not sql then
      return
    end
    if is_write(sql) then
      vim.notify(
        "sqledit: last query contains write statements — not offering a re-run on " .. info.id,
        vim.log.levels.WARN
      )
      return
    end
    local preview = vim.trim(sql:gsub("%s+", " "))
    if vim.fn.strchars(preview) > 80 then
      preview = vim.fn.strcharpart(preview, 0, 77) .. "..."
    end
    local prompt = ("Re-run last query on %s%s?\n\n  %s"):format(info.id, info.prod and " [PROD]" or "", preview)
    if vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1 then
      M.run(sql)
    end
  end)
end

---Fuzzy-pick a table/view across all schemas, then SELECT it.
function M.tables()
  if not ensure_backend() then
    return
  end
  local c = state.current
  if not c then
    -- no connection yet: connect first, then re-open the picker
    M.connect(function()
      M.tables()
    end)
    return
  end
  rpc.request("objects", { id = c.id }, function(err, res)
    if err then
      notify_err(err)
      return
    end
    local objs = res.objects or {}
    if #objs == 0 then
      notify_err("no tables/views on " .. c.id)
      return
    end
    vim.ui.select(objs, {
      prompt = "Table on " .. c.id,
      format_item = function(o)
        return ("%s.%s  [%s]"):format(o.schema, o.name, o.type)
      end,
    }, function(obj)
      if obj then
        M.run(("SELECT * FROM %s.%s LIMIT %d"):format(quote_ident(obj.schema), quote_ident(obj.name), M.config.max_rows))
      end
    end)
  end)
end

---Open a scratch SQL buffer bound to the current connection.
function M.query()
  state.query_count = state.query_count + 1
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, ("sqledit://query-%d"):format(state.query_count))
  vim.bo[buf].filetype = "sql"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.api.nvim_set_current_buf(buf)
  vim.keymap.set({ "n", "x" }, M.config.run_key, function()
    M.run_buffer()
  end, { buffer = buf, desc = "sqledit: run query" })
end

---Run the visual selection if in visual mode, else the whole buffer.
function M.run_buffer()
  local mode = vim.fn.mode()
  local lines
  if mode == "v" or mode == "V" or mode == "\22" then
    vim.cmd([[execute "normal! \<esc>"]])
    local s = vim.api.nvim_buf_get_mark(0, "<")[1]
    local e = vim.api.nvim_buf_get_mark(0, ">")[1]
    lines = vim.api.nvim_buf_get_lines(0, s - 1, e, false)
  else
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  end
  M.run(table.concat(lines, "\n"))
end

---Run an explicit line range (for :'<,'>Sqledit run).
function M.run_range(line1, line2)
  local lines = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)
  M.run(table.concat(lines, "\n"))
end

function M.disconnect()
  local c = state.current
  if not c then
    return
  end
  rpc.request("disconnect", { id = c.id }, function() end)
  state.current = nil
  vim.notify("sqledit: disconnected from " .. c.id)
end

function M.stop()
  rpc.stop()
  state.current = nil
end

return M
