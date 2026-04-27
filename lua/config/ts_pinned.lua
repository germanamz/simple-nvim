-- nvim-treesitter parser pinning shim.
-- (Lives under lua/config/ rather than lua/plugins/ because lazy.nvim
-- auto-discovers everything in lua/plugins/ as a plugin spec.)
--
--
-- The plan documented two paths for pinning parsers:
--   primary  — pass `{ revision = ... }` to `require("nvim-treesitter").install()`
--   fallback — `git checkout <revision>` per parser repo after install
--
-- Neither matches reality at the SHA pinned in lazy-lock.json:
--   • install()'s options are { force, generate, max_jobs, summary } — no revision.
--   • parsers aren't kept as git checkouts; they're tarball-downloaded then built.
--
-- The actual mechanism: each parser's revision lives at
-- `parser_config[lang].install_info.revision` (in nvim-treesitter/parsers.lua).
-- The installer reads that field when downloading. Override it before calling
-- install() and the install pulls our pinned ref instead of the bundled one.
local M = {}

---Apply pinned revisions to nvim-treesitter's parser registry.
---@param revs table<string, string> map: parser name -> revision string
function M.apply(revs)
  local ok, parsers = pcall(require, "nvim-treesitter.parsers")
  if not ok then
    return
  end
  for name, revision in pairs(revs) do
    if parsers[name] and parsers[name].install_info then
      parsers[name].install_info.revision = revision
    end
  end
end

return M
