local M = {}

function M.setup_isolated_env()
  local root = vim.fn.tempname() .. "-nvim-test"
  vim.fn.mkdir(root, "p")
  for _, sub in ipairs({ "home", "config", "data", "state", "cache" }) do
    vim.fn.mkdir(root .. "/" .. sub, "p")
  end
  vim.fn.mkdir(root .. "/data/nvim", "p")
  local host_lazy = vim.fn.expand("~/.local/share/nvim/lazy")
  local link_path = root .. "/data/nvim/lazy"
  if vim.uv.fs_lstat(link_path) then
    vim.fn.delete(link_path, "rf")
  end
  local ok, err = vim.uv.fs_symlink(host_lazy, link_path)
  if not ok then
    error("failed to symlink lazy cache: " .. tostring(err))
  end

  vim.env.HOME = root .. "/home"
  vim.env.XDG_CONFIG_HOME = root .. "/config"
  vim.env.XDG_DATA_HOME = root .. "/data"
  vim.env.XDG_STATE_HOME = root .. "/state"
  vim.env.XDG_CACHE_HOME = root .. "/cache"
  vim.env.NVIM_BOOTSTRAP = "0"
  vim.env.TZ = "UTC"
  return root
end

function M.teardown(root)
  if root and vim.fn.isdirectory(root) == 1 then
    vim.fn.delete(root, "rf")
  end
end

return M
