local M = {}

function M.check()
  local health = vim.health
  health.start("sqledit")

  local sqledit = require("sqledit")
  local backend = sqledit.config.backend
  if not backend then
    local src = debug.getinfo(require("sqledit.rpc").start, "S").source:sub(2)
    backend = vim.fs.normalize(vim.fs.dirname(src) .. "/../..") .. "/bin/sqledit"
  end

  if vim.fn.executable(backend) == 1 then
    local version = vim.fn.system({ backend, "-version" }):gsub("%s+$", "")
    health.ok(("backend found: %s (v%s)"):format(backend, version))
  else
    health.error("backend not found: " .. backend, "run `make build` in the plugin directory")
  end

  local has_blink = pcall(require, "blink.cmp")
  if not has_blink then
    health.info("blink.cmp not installed — completion source inactive")
  elseif sqledit.blink_registered() then
    health.ok("completion source registered with blink.cmp")
  else
    health.warn(
      "blink.cmp found but source not registered yet",
      "open a sql buffer once, or check for a conflicting manual provider config"
    )
  end

  local cfg = sqledit.config.connections_file
    or vim.env.SQLEDIT_CONFIG
    or vim.fs.normalize((vim.env.XDG_CONFIG_HOME or "~/.config") .. "/sqledit/connections.toml")
  if vim.uv.fs_stat(cfg) then
    health.ok("connections file: " .. cfg)
  else
    health.warn("no connections file at " .. cfg, "create it — see README for the format")
  end
end

return M
