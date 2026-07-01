-- Invalidates the directory-keyed resolution caches when the repo topology
-- under a directory can change. util.git's root_cache and conform's python
-- pyproject cache both memoize "dir -> answer" on the assumption that a
-- directory's repo membership is fixed for the session — true almost always,
-- but a `git submodule add/deinit` or a `git init` flips it. Two triggers:
--   * DirChanged   — the cwd moved, so an unnamed buffer may resolve elsewhere.
--   * BufWritePost on .gitmodules — a submodule was added/removed in-editor.
-- Lazy: it only clears the caches; the next resolve re-probes. It does NOT cover
-- an external-shell `git submodule add/deinit/init` (which fires neither event)
-- — the <leader>gR git refresh clears the same caches as the manual hatch.
--
-- (config.statusline also has a DirChanged autocmd, but that one re-resolves
-- branch/base via its own async spawn and never reads root_cache, so the two
-- don't conflict; this one deliberately does no refresh fan-out, just a clear.)
local M = {}

local function clear()
  require("util.git")._clear_root_cache()
  require("config.formatters")._clear_python_cache()
  -- A submodule add/remove changes both root-partitioning and ignore answers in
  -- config.ignore_filter's oracle cache, so drop it on the same triggers. pcall:
  -- ignore_filter may not be loaded yet (nvim-tree is lazy).
  pcall(function()
    require("config.ignore_filter")._clear()
  end)
end

-- Exposed as the manual hatch (wired into <leader>gR) and for tests.
M._clear = clear

function M.setup()
  local g = vim.api.nvim_create_augroup("dir_cache_invalidation", { clear = true })
  vim.api.nvim_create_autocmd("DirChanged", { group = g, callback = clear })
  -- '.gitmodules' has no slash, so it matches the basename anywhere in the tree
  -- (same convention conform uses for 'pyproject.toml').
  vim.api.nvim_create_autocmd(
    "BufWritePost",
    { group = g, pattern = ".gitmodules", callback = clear }
  )
end

return M
