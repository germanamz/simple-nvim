local M = {}

local DEFAULT_TIMEOUT = 1500
local INTERVAL = 20

function M.wait_for(predicate, timeout, message)
  timeout = timeout or DEFAULT_TIMEOUT
  message = message or "predicate did not become true"
  local ok = vim.wait(timeout, predicate, INTERVAL)
  if not ok then
    error("wait_for timed out after " .. timeout .. "ms: " .. message, 2)
  end
end

function M.wait_for_buffer(opts)
  M.wait_for(function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == opts.filetype then
        return true
      end
    end
    return false
  end, opts.timeout, "buffer with filetype=" .. tostring(opts.filetype) .. " never appeared")
end

function M.wait_for_event(pattern, timeout)
  local fired = false
  local id = vim.api.nvim_create_autocmd("User", {
    pattern = pattern,
    once = true,
    callback = function()
      fired = true
    end,
  })
  M.wait_for(function()
    return fired
  end, timeout, "event " .. pattern .. " never fired")
  pcall(vim.api.nvim_del_autocmd, id)
end

return M
