-- Completion core: schema-aware suggestions fed from backend introspection.
-- Editor-agnostic — blink.cmp (and future nvim-cmp) adapters wrap M.complete().
--
-- Context detection is deliberately parser-free:
--   after FROM/JOIN/INTO/UPDATE/TABLE  -> tables + schemas
--   after "<qualifier>."               -> columns (alias/table) or tables (schema)
--   otherwise                          -> keywords + tables + schemas
--                                         + columns of tables referenced in the buffer
local rpc = require("sqledit.rpc")

local M = {}

-- conn_id -> { objects = [...], columns = { ["schema.table"] = [...] } }
local cache = {}

---Drop cached schema data (all connections, or one).
function M.refresh(conn_id)
  if conn_id then
    cache[conn_id] = nil
  else
    cache = {}
  end
end

local function get_objects(conn_id, cb)
  local c = cache[conn_id]
  if c and c.objects then
    cb(nil, c.objects)
    return
  end
  rpc.request("objects", { id = conn_id }, function(err, res)
    if err then
      cb(err, nil)
      return
    end
    cache[conn_id] = cache[conn_id] or { columns = {} }
    cache[conn_id].objects = res.objects or {}
    cb(nil, cache[conn_id].objects)
  end)
end

local function get_columns(conn_id, schema, table_, cb)
  local key = schema .. "." .. table_
  local c = cache[conn_id]
  if c and c.columns[key] then
    cb(nil, c.columns[key])
    return
  end
  rpc.request("columns", { id = conn_id, schema = schema, table = table_ }, function(err, res)
    if err then
      cb(err, nil)
      return
    end
    cache[conn_id] = cache[conn_id] or { columns = {} }
    cache[conn_id].columns[key] = res.columns or {}
    cb(nil, cache[conn_id].columns[key])
  end)
end

-- words that can follow a table reference but are never an alias
local STOP_WORDS = {
  where = true, on = true, group = true, order = true, limit = true, offset = true,
  left = true, right = true, inner = true, outer = true, cross = true, full = true,
  join = true, union = true, having = true, set = true, using = true, select = true,
  values = true, returning = true, natural = true, ["and"] = true, ["or"] = true,
}

---Scan the buffer for `FROM/JOIN/UPDATE/INTO <table> [AS] <alias>`.
---Returns alias(lower) -> table token (possibly "schema.table", original case)
---and the list of distinct table tokens referenced.
---Quoted identifiers are not supported here.
local function scan_tables(text)
  local map = {}
  local tables, seen = {}, {}
  local lower = text:lower()
  for _, kw in ipairs({ "from", "join", "update", "into" }) do
    local init = 1
    while true do
      local s, e = lower:find("%f[%w]" .. kw .. "%f[%W]", init)
      if not s then
        break
      end
      local ts, te, pos1, _, pos2 = lower:find("^%s+()([%w_]+%.?[%w_]*)()", e + 1)
      if ts then
        local token = text:sub(pos1, pos2 - 1)
        if not seen[token:lower()] then
          seen[token:lower()] = true
          table.insert(tables, token)
        end
        local as, ae, alias = lower:find("^%s+([%w_]+)", te + 1)
        if alias == "as" then
          as, ae, alias = lower:find("^%s+([%w_]+)", ae + 1)
        end
        if alias and not STOP_WORDS[alias] then
          map[alias] = token
        end
        init = te + 1
      else
        init = e + 1
      end
    end
  end
  return map, tables
end

local function split_qualified(token)
  local schema, tbl = token:match("^([%w_]+)%.([%w_]+)$")
  if schema then
    return schema, tbl
  end
  return nil, token
end

local function find_object(objects, name)
  local lname = name:lower()
  for _, o in ipairs(objects) do
    if o.name:lower() == lname then
      return o
    end
  end
end

---Decide what to complete based on the text before the cursor.
local function detect(line_before_cursor, buf_text, objects)
  -- strip the word currently being typed
  local prefix = line_before_cursor:gsub("[%w_]*$", "")

  local qualifier = prefix:match("([%w_]+)%.$")
  if qualifier then
    local aliases = scan_tables(buf_text)
    local target = aliases[qualifier:lower()]
    if target then
      local schema, tbl = split_qualified(target)
      if not schema then
        local o = find_object(objects, tbl)
        schema = o and o.schema
        tbl = o and o.name or tbl
      end
      if schema then
        return { kind = "columns", schema = schema, table_ = tbl }
      end
    end
    local o = find_object(objects, qualifier)
    if o then
      return { kind = "columns", schema = o.schema, table_ = o.name }
    end
    local lq = qualifier:lower()
    for _, obj in ipairs(objects) do
      if obj.schema:lower() == lq then
        return { kind = "tables", schema = obj.schema }
      end
    end
    return { kind = "none" } -- unknown qualifier: stay quiet, don't spam keywords
  end

  local kw = prefix:match("([%w_]+)%s+$")
  kw = kw and kw:lower()
  if kw == "from" or kw == "join" or kw == "into" or kw == "update" or kw == "table" then
    return { kind = "tables" }
  end
  return { kind = "general" }
end

-- LSP CompletionItemKind
local KIND = { Field = 5, Class = 7, Module = 9, Keyword = 14 }

local KEYWORDS = {
  "select", "from", "where", "join", "left", "right", "inner", "outer", "cross", "on",
  "group by", "order by", "having", "limit", "offset", "distinct", "as", "and", "or",
  "not", "null", "like", "ilike", "in", "exists", "between", "is", "case", "when",
  "then", "else", "end", "union", "all", "insert into", "values", "update", "set",
  "delete from", "returning", "with", "count", "sum", "avg", "min", "max", "coalesce",
}

local function add_tables(items, objects, schema)
  for _, o in ipairs(objects) do
    if not schema or o.schema == schema then
      table.insert(items, {
        label = o.name,
        kind = KIND.Class,
        detail = o.schema .. " · " .. o.type,
      })
    end
  end
end

local function add_schemas(items, objects)
  local seen = {}
  for _, o in ipairs(objects) do
    if not seen[o.schema] then
      seen[o.schema] = true
      table.insert(items, { label = o.schema, kind = KIND.Module, detail = "schema" })
    end
  end
end

local function column_items(cols, items, src)
  items = items or {}
  for _, c in ipairs(cols) do
    local marks = {}
    if c.pk then
      table.insert(marks, "pk")
    end
    if c.not_null then
      table.insert(marks, "not null")
    end
    table.insert(items, {
      label = c.name,
      kind = KIND.Field,
      detail = (src and src .. " · " or "")
        .. c.type
        .. (#marks > 0 and "  [" .. table.concat(marks, ", ") .. "]" or ""),
    })
  end
  return items
end

---Resolve a table token from the buffer to a known schema+table, or nil.
local function resolve_table(objects, token)
  local schema, tbl = split_qualified(token)
  if schema then
    local ls, lt = schema:lower(), tbl:lower()
    for _, o in ipairs(objects) do
      if o.schema:lower() == ls and o.name:lower() == lt then
        return o.schema, o.name
      end
    end
    return nil
  end
  local o = find_object(objects, tbl)
  if o then
    return o.schema, o.name
  end
end

---Fetch columns of every table referenced in the buffer and append them
---to items (label detail carries the source table). Errors per table are
---ignored — completion still returns the rest.
local function add_referenced_columns(conn_id, buf_text, objects, items, done)
  local _, tokens = scan_tables(buf_text)
  local targets = {}
  for _, token in ipairs(tokens) do
    local schema, tbl = resolve_table(objects, token)
    if schema then
      table.insert(targets, { schema = schema, tbl = tbl })
    end
  end
  if #targets == 0 then
    done()
    return
  end
  local pending = #targets
  for _, t in ipairs(targets) do
    get_columns(conn_id, t.schema, t.tbl, function(cerr, cols)
      if not cerr then
        column_items(cols, items, t.tbl)
      end
      pending = pending - 1
      if pending == 0 then
        done()
      end
    end)
  end
end

---@param opts {conn_id: string, line_before_cursor: string, buf_text: string}
---@param cb fun(err: string|nil, items: table[]|nil)
function M.complete(opts, cb)
  get_objects(opts.conn_id, function(err, objects)
    if err then
      cb(err, nil)
      return
    end
    local ctx = detect(opts.line_before_cursor, opts.buf_text, objects)

    if ctx.kind == "columns" then
      get_columns(opts.conn_id, ctx.schema, ctx.table_, function(cerr, cols)
        if cerr then
          cb(cerr, nil)
          return
        end
        cb(nil, column_items(cols))
      end)
      return
    end

    local items = {}
    if ctx.kind == "tables" then
      add_tables(items, objects, ctx.schema)
      if not ctx.schema then
        add_schemas(items, objects)
      end
    elseif ctx.kind == "general" then
      add_referenced_columns(opts.conn_id, opts.buf_text, objects, items, function()
        for _, kw in ipairs(KEYWORDS) do
          table.insert(items, { label = kw, kind = KIND.Keyword })
        end
        add_tables(items, objects, nil)
        add_schemas(items, objects)
        cb(nil, items)
      end)
      return
    end
    cb(nil, items)
  end)
end

return M
