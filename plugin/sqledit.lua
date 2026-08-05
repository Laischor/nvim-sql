if vim.g.loaded_sqledit then
  return
end
vim.g.loaded_sqledit = true

local subcommands = { "connect", "switch", "tables", "filter", "query", "run", "history", "refresh", "disconnect" }

vim.api.nvim_create_user_command("Sqledit", function(cmd)
  local sqledit = require("sqledit")
  local sub = cmd.fargs[1] or "connect"
  if sub == "connect" then
    sqledit.connect()
  elseif sub == "switch" then
    sqledit.switch()
  elseif sub == "tables" then
    sqledit.tables()
  elseif sub == "filter" then
    sqledit.filter()
  elseif sub == "query" then
    sqledit.query()
  elseif sub == "run" then
    if cmd.range > 0 then
      sqledit.run_range(cmd.line1, cmd.line2)
    elseif #cmd.fargs > 1 then
      sqledit.run(table.concat(vim.list_slice(cmd.fargs, 2), " "))
    else
      sqledit.run_buffer()
    end
  elseif sub == "history" then
    sqledit.history()
  elseif sub == "refresh" then
    sqledit.refresh()
  elseif sub == "disconnect" then
    sqledit.disconnect()
  else
    vim.notify("sqledit: unknown subcommand " .. sub, vim.log.levels.ERROR)
  end
end, {
  nargs = "*",
  range = true,
  complete = function(arglead, cmdline)
    if cmdline:match("^%s*Sqledit%s+%S+%s") then
      return {}
    end
    return vim.tbl_filter(function(s)
      return vim.startswith(s, arglead)
    end, subcommands)
  end,
  desc = "sqledit: SQL client",
})
