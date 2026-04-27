local M = {}

function M.resolve(mode, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, mode)) do
    if m.lhs == lhs then
      return { callback = m.callback, rhs = m.rhs, buffer = vim.api.nvim_get_current_buf() }
    end
  end
  for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
    if m.lhs == lhs then
      return { callback = m.callback, rhs = m.rhs, buffer = nil }
    end
  end
  return nil
end

return M
