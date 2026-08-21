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

local function is_query_buf(buf)
  return vim.api.nvim_buf_get_name(buf):match("^sqledit://query%-") ~= nil
end

---Bind a query buffer to a connection (nil unbinds) and reflect it in the
---buffer name: sqledit://query-3@site3/analytics.
local function bind_buffer(buf, info)
  vim.b[buf].sqledit_conn = info
  local old = vim.api.nvim_buf_get_name(buf)
  local n = old:match("^sqledit://query%-(%d+)")
  if not n then
    return
  end
  local new = info and ("sqledit://query-%s@%s"):format(n, info.id) or ("sqledit://query-%s"):format(n)
  if new == old then
    return
  end
  vim.api.nvim_buf_set_name(buf, new)
  -- renaming leaves an unlisted buffer holding the old name — wipe it
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= buf and vim.api.nvim_buf_get_name(b) == old then
      vim.api.nvim_buf_delete(b, { force = true })
    end
  end
end

---Connection a buffer runs against: its own binding, else the global one.
local function effective_conn(buf)
  return vim.b[buf].sqledit_conn or state.current
end

---Make `info` the connection to use from here on: global default, plus the
---current query buffer's binding when we're in one.
local function adopt_conn(info, on_done)
  state.current = info
  if is_query_buf(0) then
    bind_buffer(vim.api.nvim_get_current_buf(), info)
  end
  vim.notify("sqledit: connected to " .. info.id .. (info.prod and " [PROD]" or ""))
  if on_done then
    on_done(info)
  end
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

local blink_registered = false

---Register the completion source with blink.cmp, if installed. No-op when
---the user already configured a "sqledit" provider manually.
local function register_blink()
  if blink_registered then
    return
  end
  local ok, blink = pcall(require, "blink.cmp")
  if not ok or type(blink.add_source_provider) ~= "function" then
    return
  end
  blink_registered = true
  if pcall(blink.add_source_provider, "sqledit", { name = "sqledit", module = "sqledit.blink" }) then
    blink.add_filetype_source("sql", "sqledit")
  end
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  -- after startup so blink's own setup has run; FileType covers lazy loading
  vim.schedule(register_blink)
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "sql",
    group = vim.api.nvim_create_augroup("sqledit_blink", { clear = true }),
    callback = register_blink,
  })
end

---For :checkhealth.
function M.blink_registered()
  return blink_registered
end

---Connection info ({id, server, database, adapter, prod, readonly}) the
---current buffer runs against — its binding, else the global one — or nil.
---Used by completion sources.
function M.current()
  return effective_conn(0)
end

---Drop cached schema data so completion re-introspects (e.g. after DDL).
function M.refresh()
  require("sqledit.completion").refresh()
  vim.notify("sqledit: schema cache cleared")
end

---Connection label for the statusline, e.g. "site3/analytics [PROD]".
---Buffer-aware: a bound query buffer shows its own connection.
function M.status()
  local c = effective_conn(0)
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

---Run SQL and show the result grid. `conn` pins the connection; without it
---the current buffer's binding is used, falling back to the global one.
function M.run(sql, conn)
  if not ensure_backend() then
    return
  end
  local c = conn or effective_conn(0)
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
    require("sqledit.history").add(c.id, sql)
    grid.render(result, {
      conn = c.id,
      adapter = c.adapter,
      prod = c.prod,
      sql = sql,
      source = detect_source(sql),
      rerun = function()
        M.run(sql, c)
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
    adopt_conn(info, on_done)
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

---Pick a connection. Already-open connections come first and are adopted
---directly (no database picker); configured servers follow and go through
---the server → database flow. `on_done(info)` is optional.
function M.connect(on_done)
  if not ensure_backend() then
    return
  end
  rpc.request("connections.active", nil, function(aerr, ares)
    local active = (not aerr and ares.connections) or {}
    rpc.request("connections.list", nil, function(err, res)
      if err then
        notify_err(err)
        return
      end
      local servers = res.servers or {}
      if #servers == 0 and #active == 0 then
        notify_err("no servers configured — edit " .. (res.config_path or "connections.toml"))
        return
      end
      local items = {}
      for _, c in ipairs(active) do
        table.insert(items, { conn = c })
      end
      for _, s in ipairs(servers) do
        table.insert(items, { server = s })
      end
      vim.ui.select(items, {
        prompt = "SQL server",
        format_item = function(it)
          local tags = {}
          if it.conn then
            table.insert(tags, "open")
          end
          local s = it.conn or it.server
          if s.prod then
            table.insert(tags, "PROD")
          end
          if s.readonly then
            table.insert(tags, "ro")
          end
          if it.conn then
            return ("%s  (%s)"):format(it.conn.id, table.concat(tags, ", "))
          end
          return ("%s  (%s%s)"):format(s.name, s.adapter, #tags > 0 and ", " .. table.concat(tags, ", ") or "")
        end,
      }, function(it)
        if not it then
          return
        end
        if it.conn then
          adopt_conn(it.conn, on_done)
        else
          pick_database(it.server, on_done)
        end
      end)
    end)
  end)
end

---Adopt an already-open connection (a connInfo) as the one to use from
---here on — global default plus the current query buffer's binding. Used
---by the tree view.
function M.use_connection(info)
  adopt_conn(info)
end

---Toggle the tree sidebar (servers → databases → schemas → tables → columns).
function M.tree()
  if not ensure_backend() then
    return
  end
  require("sqledit.tree").toggle()
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

---Ask for optional WHERE / ORDER BY clauses (prefilled from `defaults`),
---then hand back suffix + the raw clauses.
local function input_clauses(defaults, cb)
  vim.ui.input({ prompt = "WHERE (empty: none): ", default = defaults.where }, function(where)
    if where == nil then -- cancelled
      return
    end
    vim.ui.input({ prompt = "ORDER BY (empty: none): ", default = defaults.order }, function(order)
      if order == nil then
        return
      end
      where, order = vim.trim(where), vim.trim(order)
      local suffix = ""
      if where ~= "" then
        suffix = suffix .. " WHERE " .. where
      end
      if order ~= "" then
        suffix = suffix .. " ORDER BY " .. order
      end
      cb(suffix, where, order)
    end)
  end)
end

---Fuzzy-pick a table/view across all schemas, then SELECT it.
---opts.clauses: also prompt for WHERE / ORDER BY.
function M.tables(opts)
  opts = opts or {}
  if not ensure_backend() then
    return
  end
  local c = effective_conn(0)
  if not c then
    -- no connection yet: connect first, then re-open the picker
    M.connect(function()
      M.tables(opts)
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
      if not obj then
        return
      end
      local base = ("SELECT * FROM %s.%s"):format(quote_ident(obj.schema), quote_ident(obj.name))
      if not opts.clauses then
        M.run(("%s LIMIT %d"):format(base, M.config.max_rows), c)
        return
      end
      input_clauses({}, function(suffix, where, order)
        state.last_filter = { base = base, where = where, order = order, conn = c }
        M.run(("%s%s LIMIT %d"):format(base, suffix, M.config.max_rows), c)
      end)
    end)
  end)
end

---Like tables(), but asks for WHERE / ORDER BY before running.
function M.filter()
  M.tables({ clauses = true })
end

---Re-edit the clauses of the last :Sqledit filter (prefilled) and re-run
---on the same table.
function M.refilter()
  local f = state.last_filter
  if not f then
    notify_err("no previous filter — :Sqledit filter first")
    return
  end
  input_clauses({ where = f.where, order = f.order }, function(suffix, where, order)
    state.last_filter = { base = f.base, where = where, order = order, conn = f.conn }
    M.run(("%s%s LIMIT %d"):format(f.base, suffix, M.config.max_rows), f.conn)
  end)
end

---Open a scratch SQL buffer, optionally prefilled. The buffer is bound to
---the connection in effect here (a bound buffer passes its binding on);
---the binding shows in the buffer name and survives later switches.
function M.query(initial)
  state.query_count = state.query_count + 1
  local conn = effective_conn(0)
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, ("sqledit://query-%d"):format(state.query_count))
  if conn then
    bind_buffer(buf, conn)
  end
  vim.bo[buf].filetype = "sql"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  if initial then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(initial, "\n", { plain = true }))
  end
  -- never swallow a grid/header window: hop to the previous window, or
  -- make a new split when everything visible belongs to sqledit
  if vim.api.nvim_buf_get_name(0):match("^sqledit://") then
    vim.cmd("wincmd p")
    if vim.api.nvim_buf_get_name(0):match("^sqledit://") then
      vim.cmd("topleft split")
    end
  end
  vim.api.nvim_set_current_buf(buf)
  vim.keymap.set({ "n", "x" }, M.config.run_key, function()
    M.run_buffer()
  end, { buffer = buf, desc = "sqledit: run query" })
end

---Pick a query from this connection's history; opens it in a query
---buffer (never runs it directly).
function M.history()
  local c = effective_conn(0)
  if not c then
    notify_err("no connection — :Sqledit connect first")
    return
  end
  local entries = require("sqledit.history").get(c.id)
  if #entries == 0 then
    vim.notify("sqledit: no history for " .. c.id)
    return
  end
  vim.ui.select(entries, {
    prompt = "Query history for " .. c.id,
    format_item = function(e)
      local flat = e.sql:gsub("%s+", " ")
      if vim.fn.strchars(flat) > 80 then
        flat = vim.fn.strcharpart(flat, 0, 77) .. "..."
      end
      return os.date("%Y-%m-%d %H:%M", e.ts) .. "  " .. flat
    end,
  }, function(entry)
    if entry then
      M.query(entry.sql)
    end
  end)
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

---Disconnect the connection in effect for the current buffer. Clears the
---global default when it matches and unbinds every buffer bound to it.
function M.disconnect()
  local c = effective_conn(0)
  if not c then
    return
  end
  rpc.request("disconnect", { id = c.id }, function() end)
  if state.current and state.current.id == c.id then
    state.current = nil
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local bc = vim.b[buf].sqledit_conn
    if bc and bc.id == c.id then
      bind_buffer(buf, nil)
    end
  end
  vim.notify("sqledit: disconnected from " .. c.id)
end

function M.stop()
  rpc.stop()
  state.current = nil
end

return M
