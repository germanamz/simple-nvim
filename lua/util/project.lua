-- Is a directory the root of an independent project?
--
-- Two callers ask this question about the same tree with different markers, and
-- they must not drift apart: config.lsp_root uses it to decide whether a repo
-- boundary is a TypeScript project worth clamping ts_ls to, and
-- config.js_toolchain uses it to decide whether a submodule is an independent
-- JS package (and so seals off toolchain detection) or a vendored subtree that
-- should keep inheriting its parent's config.
--
-- fs_stat, not readdir: callers ask about one to three markers at a single
-- directory, so a stat per marker is cheaper than listing the whole directory.
local M = {}

--- Does `dir` contain any of `markers`?
---@param dir string|nil
---@param markers string[]
---@return boolean
function M.is_root(dir, markers)
  if not dir then
    return false
  end
  for _, marker in ipairs(markers) do
    if vim.uv.fs_stat(vim.fs.joinpath(dir, marker)) then
      return true
    end
  end
  return false
end

return M
