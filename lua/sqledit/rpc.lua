-- Manages the sqledit backend process and speaks newline-delimited
-- JSON-RPC 2.0 with it over stdin/stdout.
local M = {}

local state = {
  job = nil,
  next_id = 0,
  pending = {}, -- id -> callback(err, result)
  buf = "",
}

local function dispatch_line(line)
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" then
    vim.notify("sqledit: bad message from backend: " .. line, vim.log.levels.ERROR)
    return
  end
  local cb = msg.id and state.pending[msg.id]
  if not cb then
    return
  end
  state.pending[msg.id] = nil
  if msg.error then
    cb(msg.error.message or "unknown backend error", nil)
  else
    cb(nil, msg.result)
  end
end

local function on_stdout(_, data)
  -- jobstart chunk semantics: concatenating with "\n" restores the raw stream
  state.buf = state.buf .. table.concat(data, "\n")
  while true do
    local nl = state.buf:find("\n", 1, true)
    if not nl then
      break
    end
    local line = state.buf:sub(1, nl - 1)
    state.buf = state.buf:sub(nl + 1)
    if line ~= "" then
      dispatch_line(line)
    end
  end
end

local function fail_all_pending(reason)
  local pending = state.pending
  state.pending = {}
  for _, cb in pairs(pending) do
    cb(reason, nil)
  end
end

---@param opts {backend: string, config_file: string|nil}
---@return string|nil error
function M.start(opts)
  if state.job then
    return nil
  end
  if vim.fn.executable(opts.backend) ~= 1 then
    return ("backend not found: %s (run `make build` in the plugin directory)"):format(opts.backend)
  end
  local cmd = { opts.backend }
  if opts.config_file and opts.config_file ~= "" then
    vim.list_extend(cmd, { "-config", opts.config_file })
  end
  local stderr = {}
  state.buf = ""
  state.job = vim.fn.jobstart(cmd, {
    on_stdout = on_stdout,
    on_stderr = function(_, data)
      for _, l in ipairs(data) do
        if l ~= "" then
          table.insert(stderr, l)
        end
      end
    end,
    on_exit = function(_, code)
      state.job = nil
      local reason = "backend exited with code " .. code
      if #stderr > 0 then
        reason = reason .. ": " .. table.concat(stderr, " ")
      end
      fail_all_pending(reason)
      if code ~= 0 then
        vim.notify("sqledit: " .. reason, vim.log.levels.ERROR)
      end
    end,
  })
  if state.job <= 0 then
    state.job = nil
    return "failed to start backend: " .. opts.backend
  end
  return nil
end

function M.running()
  return state.job ~= nil
end

function M.stop()
  if state.job then
    vim.fn.jobstop(state.job)
    state.job = nil
    fail_all_pending("backend stopped")
  end
end

---Send a request. The callback receives (err, result).
function M.request(method, params, cb)
  if not state.job then
    cb("backend not running (call setup / :Sqledit connect first)", nil)
    return
  end
  state.next_id = state.next_id + 1
  local id = state.next_id
  state.pending[id] = cb
  local payload = vim.json.encode({
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params or vim.empty_dict(),
  })
  vim.fn.chansend(state.job, payload .. "\n")
end

return M
