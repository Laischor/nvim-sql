-- Headless end-to-end suite. Run via `make test-e2e` (needs nvim on PATH
-- and a built bin/sqledit), or directly:
--
--   XDG_STATE_HOME=$(mktemp -d) nvim --headless --clean -u NONE -l tests/e2e.lua
--
-- Uses a throwaway sqlite database; no postgres required.
local this = vim.fs.normalize(debug.getinfo(1, "S").source:sub(2))
local root = vim.fs.normalize(vim.fs.dirname(this) .. "/..")
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local config_file = tmp .. "/connections.toml"
do
  local f = assert(io.open(config_file, "w"))
  f:write(('[[servers]]\nname = "testdb"\nadapter = "sqlite"\npath = "%s/test.db"\n'):format(tmp))
  f:write(('[[servers]]\nname = "otherdb"\nadapter = "sqlite"\npath = "%s/other.db"\n'):format(tmp))
  f:close()
end

vim.opt.runtimepath:append(root)
vim.cmd("runtime! plugin/sqledit.lua")

local failed, passed = 0, 0
local function step(name, ok, extra)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
  end
  -- stream to stderr so a hang still shows how far the suite got
  io.stderr:write(("%s %s%s\n"):format(ok and "OK " or "FAIL", name, extra and (" — " .. tostring(extra)) or ""))
end
local function finish()
  io.stderr:write(("---\n%d passed, %d failed\n"):format(passed, failed))
  vim.cmd(failed > 0 and "cquit 1" or "quitall!")
end

local sqledit = require("sqledit")
local rpc = require("sqledit.rpc")
local grid = require("sqledit.grid")
local transfer = require("sqledit.transfer")
sqledit.setup({ connections_file = config_file, backend = root .. "/bin/sqledit" })

local orig_notify = vim.notify

-- ---------------------------------------------------------------- helpers
local function await(fn, timeout)
  local done, aerr, ares = false, nil, nil
  fn(function(e, r)
    aerr, ares, done = e, r, true
  end)
  vim.wait(timeout or 5000, function()
    return done
  end)
  return done, aerr, ares
end

local function query_sync(sql)
  local _, e, r = await(function(cb)
    rpc.request("query", { id = "testdb/main", sql = sql }, cb)
  end)
  return e, r
end

local function find_buf(pattern)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match(pattern) then
      return b
    end
  end
end
local function grid_buf()
  return find_buf("sqledit://results")
end
local function grid_win()
  local b = grid_buf()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if b and vim.api.nvim_win_get_buf(w) == b then
      return w
    end
  end
end
local function grid_lines()
  local b = grid_buf()
  return b and vim.api.nvim_buf_get_lines(b, 0, -1, false) or {}
end
local function grid_text()
  return table.concat(grid_lines(), "\n")
end
local function g_winbar()
  local w = grid_win()
  return w and vim.wo[w].winbar or ""
end
local function g_header()
  local b = find_buf("sqledit://header")
  return b and vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] or ""
end
local function wait_grid(pattern)
  return vim.wait(5000, function()
    return grid_text():match(pattern) ~= nil
  end)
end
local function drain(ms)
  vim.wait(ms or 500, function()
    return false
  end, 50)
end

local err_msgs = {}
local function capture_notify()
  err_msgs = {}
  vim.notify = function(msg)
    if type(msg) == "string" then
      table.insert(err_msgs, msg)
    end
  end
end
local function last_err()
  return err_msgs[#err_msgs] or "?"
end

-- ------------------------------------------------------- backend + connect
local err = rpc.start({ backend = root .. "/bin/sqledit", config_file = config_file })
step("backend start", err == nil, err)

local done, perr, pres = await(function(cb)
  rpc.request("ping", nil, cb)
end)
step("ping", done and not perr and pres.ok == true, perr)

vim.ui.select = function(items, _, on_choice)
  on_choice(items[1], 1)
end
sqledit.connect()
vim.wait(5000, function()
  return sqledit.status() ~= ""
end)
step("connect via picker", sqledit.status() == "testdb/main", sqledit.status())

for _, ddl in ipairs({
  "CREATE TABLE pets (id integer primary key, name text not null, weight real)",
  "INSERT INTO pets (name, weight) VALUES ('rex', 12.5), ('mia', NULL)",
  "CREATE TABLE owners (id integer primary key, name text)",
  "CREATE TABLE dogs (id integer primary key, name text, owner_id int REFERENCES owners(id))",
  "INSERT INTO owners (id, name) VALUES (7, 'anna'), (8, 'ben')",
  "INSERT INTO dogs (id, name, owner_id) VALUES (1, 'waldi', 7), (2, 'strolch', 8)",
  "CREATE TABLE pets_copy (id integer primary key, name text, weight real)",
}) do
  local derr = query_sync(ddl)
  if derr then
    step("seed: " .. ddl:sub(1, 40), false, derr)
  end
end

-- ------------------------------------------------------------------- grid
sqledit.run("SELECT id, name, weight FROM pets ORDER BY id")
step("grid renders", wait_grid("rex"))
local gwin = grid_win()
step("grid status in winbar", g_winbar():match("testdb/main") ~= nil and g_winbar():match("2 row") ~= nil, g_winbar())
step("grid sticky header", g_header():match("^id") ~= nil and g_header():match("weight") ~= nil, g_header())
step("grid data row", grid_lines()[1]:match("rex") ~= nil and grid_lines()[1]:match("12%.5") ~= nil, grid_lines()[1])
step("grid NULL cell", grid_lines()[2]:match("NULL") ~= nil, grid_lines()[2])

local header_win
for _, w in ipairs(vim.api.nvim_list_wins()) do
  if vim.api.nvim_win_get_buf(w) == find_buf("sqledit://header") then
    header_win = w
  end
end
step("sticky header window (height 1)", header_win ~= nil and vim.api.nvim_win_get_height(header_win) == 1)

-- query buffer + run_buffer
sqledit.query()
step("query buffer filetype", vim.bo.filetype == "sql", vim.bo.filetype)
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "SELECT count(*) AS n", "FROM pets" })
sqledit.run_buffer()
vim.wait(5000, function()
  return g_header():match("^n") ~= nil
end)
step("run_buffer result", grid_lines()[1] ~= nil and grid_lines()[1]:match("2") ~= nil, grid_lines()[1])

-- ------------------------------------------------------------------ switch
local confirm_prompts = {}
vim.fn.confirm = function(prompt)
  table.insert(confirm_prompts, prompt)
  return 1
end
sqledit.switch()
vim.wait(5000, function()
  return #confirm_prompts > 0
end)
step("switch asks confirm with preview", #confirm_prompts == 1 and confirm_prompts[1]:match("SELECT") ~= nil, confirm_prompts[1])

local warned = false
vim.notify = function(msg, ...)
  if type(msg) == "string" and msg:match("not offering") then
    warned = true
  end
  orig_notify(msg, ...)
end
sqledit.run("UPDATE pets SET weight = weight WHERE 1 = 0")
drain(300)
sqledit.switch()
vim.wait(5000, function()
  return warned
end)
step("switch refuses write re-run", warned and #confirm_prompts == 1)
vim.notify = orig_notify

-- -------------------------------------------------------------- completion
local completion = require("sqledit.completion")
local function complete_sync(line, buf_text)
  local _, cerr, items = await(function(cb)
    completion.complete({ conn_id = "testdb/main", line_before_cursor = line, buf_text = buf_text or line }, cb)
  end)
  return cerr, items or {}
end
local function labels(items)
  local out = {}
  for _, it in ipairs(items) do
    out[it.label] = it
  end
  return out
end

local cerr, items = complete_sync("select * from ")
local l = labels(items)
step("completion: tables after FROM", cerr == nil and l.pets ~= nil and l.main ~= nil, cerr)
cerr, items = complete_sync("select p.", "select p.\nfrom pets p")
l = labels(items)
step("completion: columns via alias", cerr == nil and l.id ~= nil and l.weight ~= nil, cerr)
step("completion: pk marker", l.id ~= nil and l.id.detail:match("pk") ~= nil, l.id and l.id.detail)
cerr, items = complete_sync("select pets.")
step("completion: columns via table name", labels(items).name ~= nil)
cerr, items = complete_sync("select * from main.")
l = labels(items)
step("completion: schema qualifier", l.pets ~= nil and l.id == nil)
cerr, items = complete_sync("select o.", "select o. from main.pets as o")
step("completion: AS alias + qualified", labels(items).weight ~= nil)
cerr, items = complete_sync("")
l = labels(items)
step("completion: general keywords + tables", l.select ~= nil and l.pets ~= nil)
cerr, items = complete_sync("select x.")
step("completion: unknown qualifier quiet", cerr == nil and #items == 0, tostring(#items))
cerr, items = complete_sync("select ", "select \nfrom pets")
l = labels(items)
step("completion: bare columns from FROM table", cerr == nil and l.weight ~= nil and l.id ~= nil, cerr)
step("completion: bare column detail names table", l.weight ~= nil and l.weight.detail:match("pets") ~= nil, l.weight and l.weight.detail)
cerr, items = complete_sync("update pets set ")
l = labels(items)
step("completion: bare columns after UPDATE", cerr == nil and l.weight ~= nil, cerr)
cerr, items = complete_sync("select ")
l = labels(items)
step("completion: no table in buffer, no columns", cerr == nil and l.weight == nil and l.select ~= nil)

-- --------------------------------------------------------------- cell edit
sqledit.run("SELECT id, name, weight FROM pets ORDER BY id")
wait_grid("rex")
gwin = grid_win()
vim.api.nvim_set_current_win(gwin)
local line1 = grid_lines()[1]
vim.api.nvim_win_set_cursor(gwin, { 1, line1:find("rex") - 1 })

local input_default, next_input = nil, "bruno"
vim.ui.input = function(opts, on_confirm)
  input_default = opts.default
  on_confirm(next_input)
end
grid.edit_cell()
step("edit: grid updated", wait_grid("bruno"))
step("edit: input prefilled", input_default == "rex", input_default)
local qerr, qres = query_sync("SELECT name FROM pets WHERE id = 1")
step("edit: persisted", qerr == nil and qres.rows[1][1] == "bruno", qerr)

vim.api.nvim_win_set_cursor(gwin, { 1, #line1 - 2 })
next_input = "NULL"
grid.edit_cell()
drain(500)
qerr, qres = query_sync("SELECT weight FROM pets WHERE id = 1")
step("edit: NULL literal", qerr == nil and qres.rows[1][1] == vim.NIL, vim.inspect(qres and qres.rows))

-- NULL cell prefills empty
input_default = "?"
next_input = nil -- cancel
grid.edit_cell()
drain(300)
step("edit: NULL prefills empty", input_default == "", input_default)

-- '' sets an empty string
next_input = "''"
grid.edit_cell()
drain(500)
qerr, qres = query_sync("SELECT weight FROM pets WHERE id = 1")
step("edit: '' means empty string", qerr == nil and qres.rows[1][1] == "", vim.inspect(qres and qres.rows))

-- empty input changes nothing
capture_notify()
next_input = ""
grid.edit_cell()
vim.wait(3000, function()
  return last_err():match("no change") ~= nil
end)
qerr, qres = query_sync("SELECT weight FROM pets WHERE id = 1")
step("edit: empty input is a no-op", last_err():match("no change") ~= nil and qres.rows[1][1] == "", last_err())
vim.notify = orig_notify
query_sync("UPDATE pets SET weight = NULL WHERE id = 1")

capture_notify()
sqledit.run("SELECT count(*) AS n FROM pets")
vim.wait(3000, function()
  return g_header():match("^n") ~= nil
end)
vim.api.nvim_win_set_cursor(gwin, { 1, 0 })
next_input = "9"
grid.edit_cell()
vim.wait(3000, function()
  return last_err():match("not a column") ~= nil
end)
step("edit: computed column refused", last_err():match("not a column") ~= nil, last_err())

capture_notify()
sqledit.run("SELECT name FROM pets ORDER BY id")
vim.wait(3000, function()
  return grid_lines()[1] ~= nil and grid_lines()[1]:match("bruno") ~= nil
end)
vim.api.nvim_win_set_cursor(gwin, { 1, 0 })
grid.edit_cell()
vim.wait(3000, function()
  return last_err():match("not in result") ~= nil
end)
step("edit: missing pk refused", last_err():match("not in result") ~= nil, last_err())

capture_notify()
sqledit.run("SELECT p.id FROM pets p JOIN pets q ON q.id = p.id")
vim.wait(3000, function()
  return g_header():match("^id") ~= nil
end)
vim.api.nvim_win_set_cursor(gwin, { 1, 0 })
grid.edit_cell()
vim.wait(3000, function()
  return last_err():match("not editable") ~= nil
end)
step("edit: join refused", last_err():match("not editable") ~= nil, last_err())
vim.notify = orig_notify

-- ---------------------------------------------------------------- fk jump
sqledit.run("SELECT id, name, owner_id FROM dogs ORDER BY id")
step("fk: dogs grid", wait_grid("waldi"))
local dline = grid_lines()[1]
vim.api.nvim_win_set_cursor(gwin, { 1, #dline - 1 })
grid.fk_jump()
step("fk: jumped to referenced row", wait_grid("anna"))
step("fk: exactly one row", g_winbar():match("1 row") ~= nil and grid_text():match("ben") == nil, g_winbar())

capture_notify()
sqledit.run("SELECT id, name, owner_id FROM dogs ORDER BY id")
wait_grid("waldi")
vim.api.nvim_win_set_cursor(gwin, { 1, 0 })
grid.fk_jump()
vim.wait(3000, function()
  return last_err():match("no foreign key") ~= nil
end)
step("fk: non-fk column refused", last_err():match("no foreign key") ~= nil, last_err())
vim.notify = orig_notify

-- ---------------------------------------------------------------- history
local history = require("sqledit.history")
local entries = history.get("testdb/main")
step("history: recorded", #entries > 3, tostring(#entries))
step("history: newest first", entries[1].sql:match("FROM dogs") ~= nil, entries[1].sql)
local before_count = #entries
sqledit.run("SELECT id, name, owner_id FROM dogs ORDER BY id")
drain(500)
step("history: dedup", #history.get("testdb/main") == before_count)
sqledit.history()
vim.wait(2000, function()
  return vim.bo.filetype == "sql" and vim.api.nvim_buf_get_name(0):match("sqledit://query") ~= nil
end)
local qlines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
step("history: opens prefilled query buffer", qlines:match("FROM dogs") ~= nil, qlines:sub(1, 50))

-- --------------------------------------------------------------- column nav
vim.api.nvim_set_current_win(gwin)
vim.api.nvim_win_set_cursor(gwin, { 1, 0 })
step("nav: col 1", grid.current_column() == 1, tostring(grid.current_column()))
grid.next_column()
step("nav: w", grid.current_column() == 2, tostring(grid.current_column()))
grid.next_column()
grid.next_column()
step("nav: clamps at last", grid.current_column() == 3, tostring(grid.current_column()))
grid.prev_column()
step("nav: b", grid.current_column() == 2, tostring(grid.current_column()))
step("nav: winbar column info", g_winbar():match("col 2/3: name") ~= nil, g_winbar())
vim.ui.select = function(items, _, on_choice)
  on_choice(items[3], 3)
end
grid.pick_column()
step("nav: gc picker", grid.current_column() == 3, tostring(grid.current_column()))

-- header window is unfocusable: movement passes through it
vim.api.nvim_set_current_win(gwin)
vim.cmd("wincmd k") -- up from the grid: skip header, land above
step("sticky: C-w k skips header upward", vim.api.nvim_get_current_win() ~= header_win, tostring(vim.api.nvim_get_current_win()))
local above_win = vim.api.nvim_get_current_win()
if above_win ~= gwin then
  vim.cmd("wincmd j") -- down from above: skip header, land in the grid
  step("sticky: C-w j skips header into grid", vim.api.nvim_get_current_win() == gwin, tostring(vim.api.nvim_get_current_win()))
else
  step("sticky: C-w j skips header into grid", true, "no window above grid in this layout")
end
vim.api.nvim_set_current_win(gwin)

-- horizontal scroll sync
vim.api.nvim_win_call(gwin, function()
  vim.cmd("normal! 5zl")
end)
vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(gwin) }) -- headless never redraws
local hleft = vim.api.nvim_win_call(header_win, function()
  return vim.fn.winsaveview().leftcol
end)
step("sticky: horizontal sync", hleft == 5, tostring(hleft))
vim.api.nvim_win_call(gwin, function()
  vim.cmd("normal! 5zh")
end)

-- ------------------------------------------------------------ multi-row edit
sqledit.run("SELECT id, name, weight FROM pets ORDER BY id")
wait_grid("bruno")
vim.api.nvim_set_current_win(gwin)
line1 = grid_lines()[1]
vim.api.nvim_win_set_cursor(gwin, { 1, line1:find("bruno") - 1 })
vim.cmd("normal! Vj")
confirm_prompts = {}
next_input = "same"
input_default = nil
grid.edit_cells()
vim.wait(5000, function()
  local e, r = query_sync("SELECT count(*) FROM pets WHERE name = 'same'")
  return r and r.rows[1][1] == 2
end)
qerr, qres = query_sync("SELECT count(*) FROM pets WHERE name = 'same'")
step("multiedit: both rows in db", qres and qres.rows[1][1] == 2, vim.inspect(qres and qres.rows))
step("multiedit: mixed prefill empty", input_default == "", input_default)
step("multiedit: confirm has row count", confirm_prompts[1] ~= nil and confirm_prompts[1]:match("2 row") ~= nil, confirm_prompts[1])

vim.api.nvim_win_set_cursor(gwin, { 1, line1:find("bruno") - 1 })
vim.cmd("normal! Vj")
next_input = nil -- cancel
input_default = nil
grid.edit_cells()
drain(300)
step("multiedit: common value prefilled", input_default == "same", input_default)

-- --------------------------------------------------------------- column copy
-- "=column" copies another column's value row by row (SET a = b)
query_sync("UPDATE pets SET name = 'cn1', weight = 1.5 WHERE id = 1")
query_sync("UPDATE pets SET name = 'cn2', weight = 2.5 WHERE id = 2")
sqledit.run("SELECT id, name, weight FROM pets ORDER BY id")
wait_grid("cn1")
vim.api.nvim_set_current_win(gwin)
line1 = grid_lines()[1]
vim.api.nvim_win_set_cursor(gwin, { 1, line1:find("cn1") - 1 })
vim.cmd("normal! Vj")
confirm_prompts = {}
next_input = "=weight"
grid.edit_cells()
vim.wait(5000, function()
  local e, r = query_sync("SELECT name FROM pets ORDER BY id")
  return r and r.rows[1][1] == "1.5" and r.rows[2][1] == "2.5"
end)
qerr, qres = query_sync("SELECT name FROM pets ORDER BY id")
step(
  "colcopy: per-row values in db",
  qres and qres.rows[1][1] == "1.5" and qres.rows[2][1] == "2.5",
  vim.inspect(qres and qres.rows)
)
step("colcopy: confirm names the copy", confirm_prompts[1] ~= nil and confirm_prompts[1]:match("column copy") ~= nil, confirm_prompts[1])
step("colcopy: grid mirrors locally", grid_lines()[1]:match("1%.5.*1%.5") ~= nil, grid_lines()[1])

-- unknown source column refused
capture_notify()
vim.api.nvim_win_set_cursor(gwin, { 1, 0 })
vim.cmd("normal! Vj")
next_input = "=nosuch"
grid.edit_cells()
vim.wait(3000, function()
  return last_err():match("no column") ~= nil
end)
step("colcopy: unknown source refused", last_err():match('no column "nosuch"') ~= nil, last_err())
vim.notify = orig_notify

-- source column not in the result: update persists, grid refetches
query_sync("UPDATE pets SET name = 'zz' WHERE id IN (1, 2)")
sqledit.run("SELECT id, name FROM pets ORDER BY id")
wait_grid("zz")
vim.api.nvim_set_current_win(gwin)
line1 = grid_lines()[1]
vim.api.nvim_win_set_cursor(gwin, { 1, line1:find("zz") - 1 })
vim.cmd("normal! Vj")
next_input = "=weight"
grid.edit_cells()
vim.wait(5000, function()
  return grid_text():match("1%.5") ~= nil
end)
step("colcopy: source outside result reruns", grid_text():match("1%.5") ~= nil, grid_text():sub(1, 60))
qerr, qres = query_sync("SELECT name FROM pets WHERE id = 1")
step("colcopy: persisted without source in result", qres and qres.rows[1][1] == "1.5", vim.inspect(qres and qres.rows))

-- -------------------------------------------------------------- yank/paste
query_sync("UPDATE pets SET name = 'rex', weight = 12.5 WHERE id = 1")
query_sync("UPDATE pets SET name = 'mi,a', weight = NULL WHERE id = 2")
sqledit.run("SELECT id, name, weight FROM pets ORDER BY id")
wait_grid("rex")
vim.api.nvim_set_current_win(gwin)
vim.api.nvim_win_set_cursor(gwin, { 1, 0 })
vim.cmd("normal! Vj")
grid.yank("csv")
local reg = vim.fn.getreg('"')
step("yank: csv header", reg:match("^id,name,weight\n") ~= nil, reg:sub(1, 30))
step("yank: csv quoting + NULL", reg:match('2,"mi,a",\n') ~= nil, reg)

vim.api.nvim_win_set_cursor(gwin, { 1, 0 })
grid.yank("json")
local jok, jdec = pcall(vim.json.decode, vim.fn.getreg('"'))
step("yank: json row with types", jok and #jdec == 1 and jdec[1].name == "rex" and jdec[1].weight == 12.5, vim.fn.getreg('"'))

grid.yank("insert")
vim.wait(3000, function()
  return vim.fn.getreg('"'):match("INSERT") ~= nil
end)
step("yank: insert statement", vim.fn.getreg('"'):match('INSERT INTO "main"%."pets"') ~= nil, vim.fn.getreg('"'):sub(1, 50))

vim.api.nvim_win_set_cursor(gwin, { 1, 0 })
vim.cmd("normal! Vj")
grid.yank("json")

sqledit.run("SELECT id, name, weight FROM pets_copy")
vim.wait(3000, function()
  return g_winbar():match("0 row") ~= nil
end)
confirm_prompts = {}
grid.paste()
vim.wait(5000, function()
  local e, r = query_sync("SELECT count(*) FROM pets_copy")
  return r and r.rows[1][1] == 2
end)
qerr, qres = query_sync("SELECT name, weight FROM pets_copy ORDER BY id")
step("paste: rows inserted", qerr == nil and #qres.rows == 2, vim.inspect(qres and qres.rows))
step("paste: confirmed with count+table", confirm_prompts[1] ~= nil and confirm_prompts[1]:match("2 row") ~= nil and confirm_prompts[1]:match("pets_copy") ~= nil, confirm_prompts[1])
step("paste: comma value survived", qres.rows[2][1] == "mi,a", vim.inspect(qres.rows))
step("paste: NULL survived", qres.rows[2][2] == vim.NIL, vim.inspect(qres.rows[2]))
step("paste: grid refreshed", wait_grid("rex"))

-- paste diagnostics
local pc, pr = transfer.parse('INSERT INTO "main"."pets" (a) VALUES (1);')
step("transfer: INSERT payload rejected with hint", pc == nil and tostring(pr):match("query buffer") ~= nil, tostring(pr))

vim.fn.setreg('"', "ID,Name,WEIGHT\n9,harald,1.5\n")
pcall(vim.fn.setreg, "+", "ID,Name,WEIGHT\n9,harald,1.5\n")
grid.paste()
vim.wait(5000, function()
  local e, r = query_sync("SELECT name FROM pets_copy WHERE id = 9")
  return r and #r.rows == 1
end)
qerr, qres = query_sync("SELECT name FROM pets_copy WHERE id = 9")
step("paste: case-insensitive header", qres ~= nil and #qres.rows == 1 and qres.rows[1][1] == "harald", vim.inspect(qres and qres.rows))

vim.fn.setreg('"', "foo,bar\n1,2\n")
pcall(vim.fn.setreg, "+", "foo,bar\n1,2\n")
capture_notify()
grid.paste()
vim.wait(3000, function()
  return last_err():match("payload") ~= nil
end)
step(
  "paste: mismatch diagnostic lists both sides",
  last_err():match("foo, bar") ~= nil and last_err():match("id, name, weight") ~= nil,
  last_err()
)
vim.notify = orig_notify

-- csv NULL-vs-empty roundtrip
local tc, tr = transfer.parse('a,b\n"",hello\n,"wo""rld"\n')
step("transfer: quoted empty = empty string", tc ~= nil and tr[1][1] == "" and tr[1][2] == "hello", vim.inspect(tr))
step("transfer: unquoted empty = NULL, escaped quote", tr[2][1] == vim.NIL and tr[2][2] == 'wo"rld', vim.inspect(tr))

-- paste with pk collision: "Without pk" choice lets the db assign ids
vim.fn.setreg('"', '[{"id":1,"name":"clone1","weight":1},{"id":2,"name":"clone2","weight":2}]')
pcall(vim.fn.setreg, "+", '[{"id":1,"name":"clone1","weight":1},{"id":2,"name":"clone2","weight":2}]')
confirm_prompts = {}
vim.fn.confirm = function(prompt)
  table.insert(confirm_prompts, prompt)
  return 2 -- "Without pk"
end
grid.paste()
vim.wait(5000, function()
  local e, r = query_sync("SELECT count(*) FROM pets_copy WHERE name LIKE 'clone%'")
  return r and r.rows[1][1] == 2
end)
qerr, qres = query_sync("SELECT count(*) FROM pets_copy WHERE name LIKE 'clone%'")
step("paste: pk skipped on request", qres ~= nil and qres.rows[1][1] == 2, vim.inspect(qres and qres.rows))
step("paste: pk warning in prompt", confirm_prompts[1] ~= nil and confirm_prompts[1]:match("primary key in payload: id") ~= nil, confirm_prompts[1])
vim.fn.confirm = function(prompt)
  table.insert(confirm_prompts, prompt)
  return 1
end

-- insert form: o opens a float, :w runs the INSERT
sqledit.run("SELECT id, name, weight FROM pets_copy ORDER BY id")
vim.wait(3000, function()
  return g_winbar():match("row") ~= nil
end)
vim.api.nvim_set_current_win(grid_win())
grid.insert_row()
local form_buf
vim.wait(3000, function()
  form_buf = find_buf("sqledit://insert/main%.pets_copy")
  return form_buf ~= nil
end)
step("form: opens with one line per column", form_buf ~= nil and vim.api.nvim_buf_line_count(form_buf) == 3)
-- lines hold only values; column labels are virtual text (can't be mangled)
local form_marks = vim.api.nvim_buf_get_extmarks(
  form_buf,
  vim.api.nvim_create_namespace("sqledit_insert_form"),
  0,
  -1,
  { details = true }
)
local label_texts = {}
for _, m in ipairs(form_marks) do
  local vt = m[4].virt_text
  if vt and m[4].virt_text_pos == "inline" then
    table.insert(label_texts, vim.trim(vt[1][1]))
  end
end
step("form: virtual labels", vim.deep_equal(label_texts, { "id", "name", "weight" }), vim.inspect(label_texts))
step("form: cursor on first non-pk field", vim.api.nvim_win_get_cursor(0)[1] == 2, tostring(vim.api.nvim_win_get_cursor(0)[1]))
vim.api.nvim_buf_set_lines(form_buf, 0, -1, false, { "", "formy", "NULL" })
vim.api.nvim_buf_call(form_buf, function()
  vim.cmd("write")
end)
vim.wait(5000, function()
  local e, r = query_sync("SELECT weight FROM pets_copy WHERE name = 'formy'")
  return r and #r.rows == 1
end)
qerr, qres = query_sync("SELECT weight FROM pets_copy WHERE name = 'formy'")
step("form: row inserted, empty pk omitted", qres ~= nil and #qres.rows == 1, vim.inspect(qres and qres.rows))
step("form: NULL literal", qres ~= nil and qres.rows[1][1] == vim.NIL, vim.inspect(qres and qres.rows))
step("form: closed after insert", not vim.api.nvim_buf_is_valid(form_buf))

-- delete rows (dd / visual d) — always confirmed
sqledit.run("SELECT id, name, weight FROM pets_copy ORDER BY id")
vim.wait(3000, function()
  return grid_text():match("formy") ~= nil
end)
qerr, qres = query_sync("SELECT count(*) FROM pets_copy")
local before_del = qres.rows[1][1]
vim.api.nvim_set_current_win(grid_win())
vim.api.nvim_win_set_cursor(grid_win(), { 1, 0 })
confirm_prompts = {}
grid.delete_rows()
vim.wait(5000, function()
  local e, r = query_sync("SELECT count(*) FROM pets_copy")
  return r and r.rows[1][1] == before_del - 1
end)
qerr, qres = query_sync("SELECT count(*) FROM pets_copy")
step("delete: single row via dd", qres.rows[1][1] == before_del - 1, tostring(qres.rows[1][1]))
step("delete: always confirmed", confirm_prompts[1] ~= nil and confirm_prompts[1]:match("Delete 1 row") ~= nil, confirm_prompts[1])
step("delete: grid shrunk locally", #grid_lines() == before_del - 1, tostring(#grid_lines()))

vim.api.nvim_win_set_cursor(grid_win(), { 1, 0 })
vim.cmd("normal! Vj")
confirm_prompts = {}
grid.delete_rows()
vim.wait(5000, function()
  local e, r = query_sync("SELECT count(*) FROM pets_copy")
  return r and r.rows[1][1] == before_del - 3
end)
qerr, qres = query_sync("SELECT count(*) FROM pets_copy")
step("delete: visual selection", qres.rows[1][1] == before_del - 3, tostring(qres.rows[1][1]))
step("delete: confirm has count", confirm_prompts[1] ~= nil and confirm_prompts[1]:match("Delete 2 row") ~= nil, confirm_prompts[1])

-- cancel keeps everything
vim.fn.confirm = function(prompt)
  table.insert(confirm_prompts, prompt)
  return 2
end
vim.api.nvim_win_set_cursor(grid_win(), { 1, 0 })
grid.delete_rows()
drain(500)
qerr, qres = query_sync("SELECT count(*) FROM pets_copy")
step("delete: cancel is a no-op", qres.rows[1][1] == before_del - 3, tostring(qres.rows[1][1]))
vim.fn.confirm = function(prompt)
  table.insert(confirm_prompts, prompt)
  return 1
end

-- ---------------------------------------------------------- filter/refilter
vim.ui.select = function(items, _, on_choice)
  for i, o in ipairs(items) do
    if o.name == "dogs" then
      on_choice(o, i)
      return
    end
  end
end
local inputs = { "owner_id = 7", "id desc" }
local input_defaults = {}
vim.ui.input = function(opts, on_confirm)
  table.insert(input_defaults, opts.default or "")
  on_confirm(table.remove(inputs, 1))
end
sqledit.filter()
vim.wait(3000, function()
  return grid_text():match("waldi") ~= nil and grid_text():match("strolch") == nil
end)
step("filter: where applied", grid_text():match("waldi") ~= nil and grid_text():match("strolch") == nil, grid_text():sub(1, 60))
local fentries
vim.wait(3000, function()
  fentries = history.get("testdb/main")
  return fentries[1].sql:match("WHERE owner_id = 7") ~= nil
end)
step("filter: full sql in history", fentries[1].sql:match("ORDER BY id desc") ~= nil, fentries[1].sql)

input_defaults = {}
inputs = { "owner_id = 8", "" }
sqledit.refilter()
vim.wait(3000, function()
  return grid_text():match("strolch") ~= nil and grid_text():match("waldi") == nil
end)
step("refilter: new where applied", grid_text():match("strolch") ~= nil, grid_text():sub(1, 60))
step("refilter: prefill carries clauses", input_defaults[1] == "owner_id = 7", table.concat(input_defaults, "|"))

-- ------------------------------------------------- per-buffer connections
-- a query buffer is born bound to the connection in effect; the name shows it
sqledit.query()
local qbuf = vim.api.nvim_get_current_buf()
step("bind: query buffer bound", vim.b[qbuf].sqledit_conn.id == "testdb/main", vim.inspect(vim.b[qbuf].sqledit_conn))
step(
  "bind: name carries connection",
  vim.api.nvim_buf_get_name(qbuf):match("sqledit://query%-%d+@testdb/main$") ~= nil,
  vim.api.nvim_buf_get_name(qbuf)
)

-- switching inside a query buffer rebinds it (and renames)
vim.ui.select = function(items, _, on_choice)
  for i, it in ipairs(items) do
    if it.server and it.server.name == "otherdb" then
      on_choice(it, i)
      return
    end
  end
end
sqledit.connect()
vim.wait(3000, function()
  return sqledit.status() == "otherdb/main"
end)
step("bind: switch rebinds current query buffer", vim.b[qbuf].sqledit_conn.id == "otherdb/main", vim.inspect(vim.b[qbuf].sqledit_conn))
step("bind: rename on rebind", vim.api.nvim_buf_get_name(qbuf):match("@otherdb/main$") ~= nil, vim.api.nvim_buf_get_name(qbuf))

-- open connections come first in the picker; picking one skips the db prompt
local seen_items
local select_calls = 0
vim.ui.select = function(items, _, on_choice)
  select_calls = select_calls + 1
  seen_items = items
  for i, it in ipairs(items) do
    if it.conn and it.conn.id == "testdb/main" then
      on_choice(it, i)
      return
    end
  end
end
vim.cmd("new") -- plain buffer: only the global default moves
sqledit.connect()
vim.wait(3000, function()
  return sqledit.status() == "testdb/main"
end)
step("fast: open connections listed first", seen_items[1].conn ~= nil and seen_items[2].conn ~= nil, vim.inspect(seen_items[1]))
step("fast: single picker, no db prompt", select_calls == 1, tostring(select_calls))
step("fast: global switched", sqledit.status() == "testdb/main", sqledit.status())

-- the bound buffer keeps its connection and runs against it
step("bind: survives global switch", vim.b[qbuf].sqledit_conn.id == "otherdb/main", vim.inspect(vim.b[qbuf].sqledit_conn))
vim.api.nvim_set_current_buf(qbuf)
step("bind: statusline is buffer-aware", sqledit.status() == "otherdb/main", sqledit.status())
vim.api.nvim_buf_set_lines(qbuf, 0, -1, false, { "SELECT 42" })
sqledit.run_buffer()
local oentries
vim.wait(3000, function()
  oentries = history.get("otherdb/main")
  return #oentries > 0
end)
step("bind: run uses buffer connection", oentries[1] and oentries[1].sql == "SELECT 42", oentries[1] and oentries[1].sql)

-- disconnect clears matching bindings and restores the plain name
vim.api.nvim_set_current_buf(qbuf)
sqledit.disconnect()
drain(500)
step("bind: disconnect unbinds buffer", vim.b[qbuf].sqledit_conn == nil, vim.inspect(vim.b[qbuf].sqledit_conn))
step(
  "bind: name restored on unbind",
  vim.api.nvim_buf_get_name(qbuf):match("sqledit://query%-%d+$") ~= nil,
  vim.api.nvim_buf_get_name(qbuf)
)
step("bind: global default untouched", sqledit.status() == "testdb/main", sqledit.status())

-- --------------------------------------------------------- cross-table copy
-- yank a cell block in one table (ctrl+v y), paste it onto a block in
-- another table (ctrl+v p) — per-row UPDATEs in one transaction
query_sync("UPDATE pets SET name = 'rex', weight = 12.5 WHERE id = 1")
query_sync("UPDATE pets SET name = 'mi,a', weight = NULL WHERE id = 2")
query_sync("DELETE FROM pets_copy")
query_sync("INSERT INTO pets_copy (id, name, weight) VALUES (10, 'aaa', 1), (11, 'bbb', 2)")

sqledit.run("SELECT id, name, weight FROM pets ORDER BY id")
wait_grid("rex")
vim.api.nvim_set_current_win(gwin)
line1 = grid_lines()[1]
vim.api.nvim_win_set_cursor(gwin, { 1, line1:find("rex") - 1 })
vim.cmd([[execute "normal! \<C-v>"]])
vim.api.nvim_win_set_cursor(gwin, { 2, #grid_lines()[2] - 1 })
grid.yank_cells()
step("cellyank: tsv in register", vim.fn.getreg('"') == "rex\t12.5\nmi,a\tNULL", vim.inspect(vim.fn.getreg('"')))

sqledit.run("SELECT id, name, weight FROM pets_copy ORDER BY id")
wait_grid("aaa")
vim.api.nvim_set_current_win(gwin)
line1 = grid_lines()[1]
confirm_prompts = {}
vim.api.nvim_win_set_cursor(gwin, { 1, line1:find("aaa") - 1 })
vim.cmd([[execute "normal! \<C-v>"]])
vim.api.nvim_win_set_cursor(gwin, { 2, #grid_lines()[2] - 1 })
grid.paste_cells()
vim.wait(5000, function()
  local e, r = query_sync("SELECT name FROM pets_copy WHERE id = 10")
  return r and r.rows[1][1] == "rex"
end)
qerr, qres = query_sync("SELECT name, weight FROM pets_copy ORDER BY id")
step(
  "cellpaste: values landed per row",
  qres and qres.rows[1][1] == "rex" and qres.rows[1][2] == 12.5 and qres.rows[2][1] == "mi,a" and qres.rows[2][2] == vim.NIL,
  vim.inspect(qres and qres.rows)
)
step(
  "cellpaste: confirm shows shape + origin",
  confirm_prompts[1] ~= nil and confirm_prompts[1]:match("2 row%(s%) × 2 column%(s%)") ~= nil and confirm_prompts[1]:match("yanked off pets on testdb/main") ~= nil,
  confirm_prompts[1]
)
step("cellpaste: grid mirrors locally", grid_text():match("rex") ~= nil and grid_text():match("aaa") == nil, grid_text():sub(1, 80))

-- shape mismatch refused (one target row for a two-row block)
capture_notify()
vim.api.nvim_win_set_cursor(gwin, { 1, line1:find("│") + 2 })
vim.cmd([[execute "normal! \<C-v>"]])
vim.api.nvim_win_set_cursor(gwin, { 1, #grid_lines()[1] - 1 })
grid.paste_cells()
vim.wait(3000, function()
  return last_err():match("mismatch") ~= nil
end)
step("cellpaste: shape mismatch refused", last_err():match("row count mismatch: yanked 2, selected 1") ~= nil, last_err())
vim.notify = orig_notify

-- ------------------------------------------------------------------- tree
local tree = require("sqledit.tree")
local function tree_lines()
  return vim.api.nvim_buf_get_lines(tree.state().buf, 0, -1, false)
end
local function tree_line(pat)
  for i, l in ipairs(tree_lines()) do
    if l:match(pat) then
      return i, l
    end
  end
end

sqledit.tree()
vim.wait(3000, function()
  return #tree.state().nodes == 2
end)
local twin = vim.api.nvim_get_current_win()
step("tree: opens with both servers", #tree.state().nodes == 2, tostring(#tree.state().nodes))
step("tree: buffer name", vim.api.nvim_buf_get_name(0) == "sqledit://tree", vim.api.nvim_buf_get_name(0))
step("tree: server label has adapter", tree_line("testdb%s+%(sqlite%)") ~= nil, tree_lines()[1])

-- drill into the sqlite server: database level and lone schema are skipped,
-- tables hang directly under the server
vim.api.nvim_win_set_cursor(twin, { tree_line("testdb"), 0 })
tree.drill()
vim.wait(3000, function()
  return tree_line("dogs") ~= nil
end)
step("tree: tables under sqlite server", tree_line("pets") ~= nil and tree_line("dogs") ~= nil, vim.inspect(tree_lines()))
local _, dogs_line = tree_line("▸ dogs")
step("tree: no schema level for lone schema", dogs_line ~= nil and dogs_line:match("^  ▸") ~= nil, dogs_line)

-- drill into a table: columns with pk/fk markers
vim.api.nvim_win_set_cursor(twin, { tree_line("▸ dogs"), 0 })
tree.drill()
vim.wait(3000, function()
  return tree_line("owner_id") ~= nil
end)
local _, pk_line = tree_line("^%s+id%s")
local _, fk_line = tree_line("owner_id")
step("tree: pk marker", pk_line ~= nil and pk_line:match("%[pk%]") ~= nil, pk_line)
step("tree: fk marker", fk_line ~= nil and fk_line:match("%[fk%]") ~= nil, fk_line)

-- l on an expanded node steps into the first child
vim.api.nvim_win_set_cursor(twin, { tree_line("▾ dogs"), 0 })
tree.drill()
step("tree: drill steps into child", vim.api.nvim_win_get_cursor(twin)[1] == tree_line("▾ dogs") + 1, tostring(vim.api.nvim_win_get_cursor(twin)[1]))

-- h climbs to the parent, h again collapses it
tree.climb()
step("tree: climb to parent", vim.api.nvim_win_get_cursor(twin)[1] == tree_line("▾ dogs"), tostring(vim.api.nvim_win_get_cursor(twin)[1]))
tree.climb()
step("tree: climb collapses", tree_line("owner_id") == nil, vim.inspect(tree_lines()))

-- <CR> on a table opens its data in the grid; the cursor stays in the tree
vim.api.nvim_win_set_cursor(twin, { tree_line("▸ pets$") or tree_line("▸ pets"), 0 })
tree.activate()
vim.wait(3000, function()
  return grid_text():match("rex") ~= nil
end)
step("tree: enter opens table data", grid_text():match("rex") ~= nil, grid_text():sub(1, 60))
step("tree: cursor stays in tree", vim.api.nvim_get_current_win() == twin, tostring(vim.api.nvim_get_current_win()))

-- toggle closes, reopening keeps the expansion state
sqledit.tree()
step("tree: toggle closes", not vim.api.nvim_win_is_valid(twin))
sqledit.tree()
step("tree: expansion survives reopen", tree_line("▾ testdb") ~= nil and tree_line("dogs") ~= nil, vim.inspect(tree_lines()))
tree.close()

-- q when the grid pair holds the only windows: no E444, empty buffer stays
vim.wait(2000, function()
  return grid_win() ~= nil
end)
vim.api.nvim_set_current_win(grid_win())
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
  if not (name:match("^sqledit://results") or name:match("^sqledit://header")) then
    pcall(vim.api.nvim_win_close, w, true)
  end
end
step("close: only grid pair left", #vim.api.nvim_tabpage_list_wins(0) == 2, tostring(#vim.api.nvim_tabpage_list_wins(0)))
local close_ok, close_err = pcall(grid.close)
step("close: no E444 on last window", close_ok, close_err)
local remaining = vim.api.nvim_tabpage_list_wins(0)
local rem_buf = vim.api.nvim_win_get_buf(remaining[1])
step("close: one empty buffer remains", #remaining == 1 and vim.api.nvim_buf_get_name(rem_buf) == "" and vim.api.nvim_buf_line_count(rem_buf) == 1, vim.api.nvim_buf_get_name(rem_buf))

finish()
