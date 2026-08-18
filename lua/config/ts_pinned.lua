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
--
-- IMPORTANT: restarting nvim is still not enough to re-pin an ALREADY-INSTALLED
-- parser. install() early-returns for one without ever consulting the revision,
-- so editing a pin in parser-revisions.lua and reopening the editor leaves the
-- old parser in place. Run `make warm`: scripts/ts-sync.lua awaits install()
-- and then update(), and update() compares install_info.revision — our pin,
-- because M.setup's autocmd re-applies it during update()'s own reload —
-- against the installed parser-info/<lang>.revision stamp, rebuilding the ones
-- that differ. An interactive `:TSUpdate` now does the same thing for the same
-- reason. `make update` does NOT go the other way: it runs the very same sync,
-- overrides and all, so it re-snapshots these pins rather than advancing them.
-- Moving a parser onto whatever revision a newer nvim-treesitter bundles is a
-- hand edit in parser-revisions.lua, because the grammar and its queries —
-- symlinked live out of the plugin checkout, not taken from the pinned tarball,
-- and patched in queries/ for some languages — have to move together, and
-- nothing verifies that pairing yet. See scripts/update-pins.sh.
local M = {}

---Apply pinned revisions to nvim-treesitter's parser registry, first
---registering any out-of-tree parser the registry has no entry for.
---
---`out_of_tree` names grammars nvim-treesitter does not ship (today: fga, the
---OpenFGA DSL). Each value is the install_info minus its revision — the
---revision comes from `revs`, like every other parser's, so parser-revisions.lua
---stays the single source of truth for what gets installed and at what ref: an
---out-of-tree url with no pin registers nothing. Should upstream later add the
---same language, its bundled entry wins (url, tier, maintainers) and only the
---revision is overridden, exactly as for the parsers it always shipped.
---
---No `tier` is set on the entries created here. install() normalizes its
---language list with `unsupported = true`, which drops tier-4 entries — a nil
---tier passes. The only other reader is get_available(tier), used when a tier
---NAME (`stable`, `unstable`, …) is passed as a language: an untiered entry is
---simply left out of `:TSInstall stable` and friends, which is fine because
---this config only ever installs by explicit parser name.
---@param revs table<string, string> map: parser name -> revision string
---@param out_of_tree? table<string, { url: string }> parsers to register when absent
function M.apply(revs, out_of_tree)
  local ok, parsers = pcall(require, "nvim-treesitter.parsers")
  if not ok then
    return
  end
  for name, info in pairs(out_of_tree or {}) do
    if not parsers[name] and revs[name] then
      parsers[name] = { install_info = vim.tbl_extend("force", info, { revision = revs[name] }) }
    end
  end
  for name, revision in pairs(revs) do
    if parsers[name] and parsers[name].install_info then
      parsers[name].install_info.revision = revision
    end
  end
end

---Re-apply the pins every time nvim-treesitter rebuilds its parser table.
---
---`install()` calls `reload_parsers()` as its first statement, which nils
---`package.loaded["nvim-treesitter.parsers"]`, re-requires a fresh table and
---rebinds its module-local to it — so an `apply()` call made *before*
---install() writes into a table the installer then throws away, and the
---bundled revisions are what actually get installed. reload_parsers fires
---`User TSUpdate` immediately afterwards for precisely this reason (its own
---comment: "Reload the parser table and user modifications"), and that event
---is the only seam whose writes the installer sees.
---
---Also fires for `:TSUpdate` / `:TSInstall`, so the pins hold for those too.
---Out-of-tree parsers ride the same event for the same reason: the reloaded
---table has no entry for them, so they have to be re-registered each time.
---@param revs table<string, string> map: parser name -> revision string
---@param out_of_tree? table<string, { url: string }> see M.apply
function M.setup(revs, out_of_tree)
  vim.api.nvim_create_autocmd("User", {
    pattern = "TSUpdate",
    group = vim.api.nvim_create_augroup("ts_pinned", { clear = true }),
    callback = function()
      M.apply(revs, out_of_tree)
    end,
  })
end

return M
