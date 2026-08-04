-- blink.cmp source adapter. Register with:
--
--   sources = {
--     per_filetype = { sql = { "sqledit", "buffer" } },
--     providers = {
--       sqledit = { name = "sqledit", module = "sqledit.blink" },
--     },
--   }
local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

function source:enabled()
  return vim.bo.filetype == "sql"
end

function source:get_trigger_characters()
  return { "." }
end

function source:get_completions(ctx, callback)
  local sqledit = require("sqledit")
  local conn = sqledit.current()
  local function empty()
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
  end
  if not conn then
    empty()
    return
  end

  local line_before = ctx.line:sub(1, ctx.cursor[2])
  local buf_text = table.concat(vim.api.nvim_buf_get_lines(ctx.bufnr, 0, -1, false), "\n")

  local cancelled = false
  require("sqledit.completion").complete({
    conn_id = conn.id,
    line_before_cursor = line_before,
    buf_text = buf_text,
  }, function(err, items)
    if cancelled then
      return
    end
    if err then
      empty()
      return
    end
    callback({ items = items, is_incomplete_forward = false, is_incomplete_backward = false })
  end)
  return function()
    cancelled = true
  end
end

return source
