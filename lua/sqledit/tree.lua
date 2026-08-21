-- Tree sidebar: servers → databases → schemas → tables → columns.
-- Secondary browsing next to the fuzzy pickers, built for fast keyboard
-- navigation: l/h drill and climb, <CR> on a table opens its data in the
-- grid (the cursor stays in the tree). Children load lazily and are
-- cached; R refetches a node's subtree.
local rpc = require("sqledit.rpc")

local M = {}

local state = {
  buf = nil,
  win = nil,
  roots = nil, -- server nodes; expansion state lives in the nodes
  nodes = {}, -- line (1-based) -> node, rebuilt on every redraw
}

local ns = vim.api.nvim_create_namespace("sqledit_tree")

local function notify_err(msg)
  vim.notify("sqledit: " .. msg, vim.log.levels.ERROR)
end

-- ------------------------------------------------------------------ nodes
-- node = {kind, parent, expanded, loaded, loading, children, ...kind fields}
-- conn (a connInfo) sits on the node that owns the connection: database
-- nodes for postgres, server nodes for sqlite.

local function conn_of(node)
  while node do
    if node.conn then
      return node.conn
    end
    node = node.parent
  end
end

---Group an `objects` response into schema nodes with table children.
local function schema_nodes(parent, objects)
  local by_schema, order = {}, {}
  for _, o in ipairs(objects) do
    local s = by_schema[o.schema]
    if not s then
      s = { kind = "schema", name = o.schema, parent = parent, loaded = true, children = {} }
      by_schema[o.schema] = s
      table.insert(order, s)
    end
    table.insert(s.children, {
      kind = "table",
      schema = o.schema,
      name = o.name,
      type = o.type,
      parent = s,
    })
  end
  -- a lone schema (sqlite "main", plain public-only postgres) is noise:
  -- skip the level and hang its tables directly under the parent
  if #order == 1 then
    for _, t in ipairs(order[1].children) do
      t.parent = parent
    end
    return order[1].children
  end
  return order
end

---Connect (idempotent on the backend) and list objects.
local function load_objects(node, server, database, cb)
  rpc.request("connect", { server = server, database = database }, function(err, info)
    if err then
      cb(err)
      return
    end
    node.conn = info
    rpc.request("objects", { id = info.id }, function(oerr, res)
      if oerr then
        cb(oerr)
        return
      end
      cb(nil, schema_nodes(node, res.objects or {}))
    end)
  end)
end

local function load_children(node, cb)
  if node.kind == "server" then
    if node.server.adapter == "sqlite" then
      load_objects(node, node.server.name, nil, cb)
      return
    end
    rpc.request("databases.list", { server = node.server.name }, function(err, res)
      if err then
        cb(err)
        return
      end
      local children = {}
      for _, name in ipairs(res.databases or {}) do
        table.insert(children, { kind = "database", server = node.server.name, database = name, parent = node })
      end
      cb(nil, children)
    end)
  elseif node.kind == "database" then
    load_objects(node, node.server, node.database, cb)
  elseif node.kind == "table" then
    local conn = conn_of(node)
    rpc.request("columns", { id = conn.id, schema = node.schema, table = node.name }, function(err, res)
      if err then
        cb(err)
        return
      end
      local children = {}
      for _, col in ipairs(res.columns or {}) do
        table.insert(children, { kind = "column", col = col, parent = node })
      end
      cb(nil, children)
    end)
  else -- schema children are preloaded, columns are leaves
    cb(nil, node.children or {})
  end
end

-- ----------------------------------------------------------------- render
local HL = { server = "Directory", database = "Directory", schema = "Type", table_ = nil, column = "Comment" }

local function node_label(node)
  if node.kind == "server" then
    local tags = {}
    if node.server.prod then
      table.insert(tags, "PROD")
    end
    if node.server.readonly then
      table.insert(tags, "ro")
    end
    local suffix = #tags > 0 and (", " .. table.concat(tags, ", ")) or ""
    return ("%s  (%s%s)"):format(node.server.name, node.server.adapter, suffix)
  elseif node.kind == "database" then
    return node.database
  elseif node.kind == "schema" then
    return node.name
  elseif node.kind == "table" then
    return node.name .. (node.type ~= "table" and ("  [" .. node.type .. "]") or "")
  else
    local c = node.col
    local marks = {}
    if c.pk then
      table.insert(marks, "pk")
    end
    if c.not_null then
      table.insert(marks, "nn")
    end
    if c.fk then
      table.insert(marks, "fk")
    end
    local suffix = #marks > 0 and ("  [" .. table.concat(marks, ",") .. "]") or ""
    return ("%s  %s%s"):format(c.name, c.type or "", suffix)
  end
end

local function flatten(nodes, depth, lines, map)
  for _, node in ipairs(nodes) do
    node.depth = depth
    local arrow = "  "
    if node.kind ~= "column" then
      arrow = node.loading and "… " or (node.expanded and "▾ " or "▸ ")
    end
    table.insert(lines, string.rep("  ", depth) .. arrow .. node_label(node))
    table.insert(map, node)
    if node.expanded and node.children then
      flatten(node.children, depth + 1, lines, map)
    end
  end
end

local function redraw()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  local keep = state.win
    and vim.api.nvim_win_is_valid(state.win)
    and state.nodes[vim.api.nvim_win_get_cursor(state.win)[1]]

  local lines, map = {}, {}
  flatten(state.roots or {}, 0, lines, map)
  if #lines == 0 then
    lines = { "(no servers configured)" }
  end
  state.nodes = map

  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for i, node in ipairs(map) do
    local group = HL[node.kind == "table" and "table_" or node.kind]
    if group then
      vim.hl.range(state.buf, ns, group, { i - 1, 0 }, { i - 1, -1 })
    end
    if node.kind == "server" and node.server.prod then
      local s = lines[i]:find("PROD", 1, true)
      if s then
        vim.hl.range(state.buf, ns, "WarningMsg", { i - 1, s - 1 }, { i - 1, s + 3 })
      end
    end
  end

  -- keep the cursor on the node it was on, even when lines shifted
  if keep and state.win and vim.api.nvim_win_is_valid(state.win) then
    for i, node in ipairs(map) do
      if node == keep then
        vim.api.nvim_win_set_cursor(state.win, { i, 0 })
        break
      end
    end
  end
end

-- ------------------------------------------------------------- navigation
local function node_at_cursor()
  return state.nodes[vim.api.nvim_win_get_cursor(0)[1]]
end

local function line_of(node)
  for i, n in ipairs(state.nodes) do
    if n == node then
      return i
    end
  end
end

local function expand(node, on_done)
  if node.kind == "column" or node.expanded or node.loading then
    return
  end
  if node.loaded then
    node.expanded = true
    redraw()
    if on_done then
      on_done()
    end
    return
  end
  node.loading = true
  redraw()
  load_children(node, function(err, children)
    node.loading = false
    if err then
      redraw()
      notify_err(err)
      return
    end
    node.children = children
    node.loaded = true
    node.expanded = true
    redraw()
    if on_done then
      on_done()
    end
  end)
end

local function collapse(node)
  node.expanded = false
  redraw()
end

---SELECT the table into the grid; the cursor stays in the tree.
local function open_table(node)
  local sqledit = require("sqledit")
  local sql = ('SELECT * FROM "%s"."%s" LIMIT %d'):format(
    node.schema:gsub('"', '""'),
    node.name:gsub('"', '""'),
    sqledit.config.max_rows
  )
  sqledit.run(sql, conn_of(node))
end

---<CR>: open a table's data, toggle everything else. `node` defaults to
---the cursor node (same for the other actions below).
function M.activate(node)
  node = node or node_at_cursor()
  if not node then
    return
  end
  if node.kind == "table" then
    open_table(node)
  elseif node.kind ~= "column" then
    if node.expanded then
      collapse(node)
    else
      expand(node)
    end
  end
end

---l: expand a collapsed node; step into an expanded one.
function M.drill(node)
  node = node or node_at_cursor()
  if not node or node.kind == "column" then
    return
  end
  if node.expanded and node.children and #node.children > 0 then
    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_win_get_cursor(0)[1] + 1, 0 })
  else
    expand(node)
  end
end

---h: collapse an expanded node; climb to the parent otherwise.
function M.climb(node)
  node = node or node_at_cursor()
  if not node then
    return
  end
  if node.expanded then
    collapse(node)
    return
  end
  local parent_line = node.parent and line_of(node.parent)
  if parent_line then
    vim.api.nvim_win_set_cursor(0, { parent_line, 0 })
  end
end

---R: drop the node's cached subtree and refetch (columns of a column's
---table, otherwise the node itself).
function M.refresh(node)
  node = node or node_at_cursor()
  if not node then
    return
  end
  if node.kind == "column" then
    node = node.parent
  end
  if node.kind == "schema" then -- schemas come from the database's objects
    node = node.parent
  end
  local was_expanded = node.expanded
  node.children, node.loaded, node.expanded = nil, false, false
  if was_expanded then
    expand(node)
  else
    redraw()
  end
end

---c: make this node's connection the global default (query buffers opened
---from here on run against it).
function M.use_connection(node)
  node = node or node_at_cursor()
  if not node then
    return
  end
  local conn = conn_of(node)
  if not conn then
    notify_err("expand the node first — nothing connected here yet")
    return
  end
  require("sqledit").use_connection(conn)
end

-- ----------------------------------------------------------------- window
local function ensure_buffer()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "hide"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].filetype = "sqledit_tree"
  vim.api.nvim_buf_set_name(state.buf, "sqledit://tree")

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, function()
      fn()
    end, { buffer = state.buf, nowait = true, desc = "sqledit tree: " .. desc })
  end
  map("<CR>", M.activate, "open table / toggle")
  map("o", M.activate, "open table / toggle")
  map("l", M.drill, "expand / step in")
  map("<Right>", M.drill, "expand / step in")
  map("h", M.climb, "collapse / to parent")
  map("<Left>", M.climb, "collapse / to parent")
  map("R", M.refresh, "refetch subtree")
  map("c", M.use_connection, "use this connection")
  map("q", M.close, "close tree")
end

local function load_roots()
  rpc.request("connections.list", nil, function(err, res)
    if err then
      notify_err(err)
      return
    end
    state.roots = {}
    for _, server in ipairs(res.servers or {}) do
      table.insert(state.roots, { kind = "server", server = server })
    end
    redraw()
  end)
end

function M.open()
  ensure_buffer()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
    return
  end
  vim.cmd("topleft 34vsplit")
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, state.buf)
  vim.wo[state.win].wrap = false
  vim.wo[state.win].number = false
  vim.wo[state.win].relativenumber = false
  vim.wo[state.win].signcolumn = "no"
  vim.wo[state.win].cursorline = true
  vim.wo[state.win].winfixwidth = true
  if state.roots then
    redraw() -- reopening keeps the previous expansion state
  else
    load_roots()
  end
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
end

function M.toggle()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.close()
  else
    M.open()
  end
end

---For tests.
function M.state()
  return state
end

return M
