-- Disk-truth helpers for the treesitter parser cache, used by
-- scripts/ts-sync.lua.
-- (Lives under lua/config/ rather than beside the script because lua/ is the
-- only directory on the runtimepath a `luafile` script can `require` from.)
--
-- The sync script cannot trust its own install calls. nvim-treesitter's
-- install() reports success by counting completed TASKS, and a language it
-- never scheduled a task for — one norm_languages dropped because the registry
-- has no entry for it — contributes nothing to either side of `done == #tasks`,
-- so an install that quietly did nothing returns true. install_lang has a
-- second such path: with a download already in flight for the same language it
-- waits for that one and reports success, even when the in-flight download is
-- fetching a different revision than the caller asked for.
--
-- What is actually authoritative is what a parser install LEAVES ON DISK, and
-- that is two files, not one:
--
--   parser/<lang>.so           the compiled grammar, the thing buffers load
--   parser-info/<lang>.revision  the stamp, written from the revision that was
--                                really downloaded
--
-- Both have to be checked, because nvim-treesitter's own notion of "installed"
-- (config.get_installed) is neither of them: it unions the QUERIES directory
-- with the parser directory and never looks at the stamp. So each file can go
-- missing on its own while the run still reports success.
--
--   • stamp missing, .so present — `make warm` used to hard-fail with a Lua
--     traceback here. get_installed() still counts the language as installed,
--     so update()'s `missing` filter keeps it, needs_update() calls
--     get_installed_revision() on it, and nvim-treesitter's util.read_file
--     opens the stamp under an assert(). One deleted stamp took the whole
--     `make warm` down, mason step included (warm-cache.sh runs under `set -e`),
--     and nothing reinstalled the parser, so it stayed down. M.unbuilt is what
--     routes that language back through a forced install instead.
--
--   • .so missing, stamp present — exactly what `:TSUninstall` leaves behind:
--     it unlinks the parser and the queries symlink but never the stamp. Every
--     revision comparison passes, `make warm` and `make check` exit 0, and the
--     buffers for that language silently drop to regex highlighting. M.drift
--     requires the .so to exist for that reason, not only for symmetry.
local M = {}

---Read the revision stamp nvim-treesitter wrote for an installed parser.
---@param info_dir string directory holding the `<lang>.revision` stamps
---@param lang string parser name
---@return string? revision nil when the parser was never installed
function M.installed_revision(info_dir, lang)
  local fd = io.open(vim.fs.joinpath(info_dir, lang .. ".revision"), "r")
  if not fd then
    return nil
  end
  local rev = fd:read("*a")
  fd:close()
  -- nvim-treesitter writes the stamp with no trailing newline; anything that
  -- has round-tripped through an editor grows one. Trim so that difference
  -- can't report as permanent drift.
  rev = vim.trim(rev or "")
  return rev ~= "" and rev or nil
end

---Whether the compiled grammar for a language is on disk.
---@param parser_dir string directory holding the `<lang>.so` grammars
---@param lang string parser name
---@return boolean
local function is_built(parser_dir, lang)
  return vim.uv.fs_stat(vim.fs.joinpath(parser_dir, lang .. ".so")) ~= nil
end

---Pinned languages whose install is incomplete on disk — no stamp, no compiled
---grammar, or only one of the two. These cannot be repaired by update(): it
---filters to what get_installed() calls installed and then compares revisions,
---which is either a crash (no stamp to read) or a false pass (stamp matches,
---grammar gone). They have to be reinstalled with force.
---
---Deliberately says nothing about whether the revision is the RIGHT one — that
---is M.drift's job, and running it on a half-installed language would only
---report the same thing twice.
---@param languages string[] parser names to check
---@param info_dir string directory holding the `<lang>.revision` stamps
---@param parser_dir string directory holding the `<lang>.so` grammars
---@return string[] unbuilt in the order given, empty when every install is whole
function M.unbuilt(languages, info_dir, parser_dir)
  local out = {}
  for _, lang in ipairs(languages) do
    if not M.installed_revision(info_dir, lang) or not is_built(parser_dir, lang) then
      out[#out + 1] = lang
    end
  end
  return out
end

---Pinned languages nvim-treesitter's registry has no entry for at all.
---
---Upstream drops grammars (it dropped `latex`, which is why the parser cache
---still carries an unpinned one), and a pin the registry cannot satisfy is
---drift the maintainer has to resolve by hand — not a reason to fail the run
---and block every other parser. The caller warns and skips them.
---
---An entry that exists but carries no install_info.revision is a different
---animal: it is still installable, just not stamp-verifiable, so it stays in
---the set and M.drift names it.
---@param languages string[] parser names to check
---@param parsers table<string, table> nvim-treesitter's parser table
---@return string[] unregistered in the order given, empty when every pin resolves
function M.unregistered(languages, parsers)
  local out = {}
  for _, lang in ipairs(languages) do
    if not parsers[lang] then
      out[#out + 1] = lang
    end
  end
  return out
end

---Compare what each parser was asked to install against what is on disk.
---@param languages string[] parser names to check
---@param parsers table<string, table> nvim-treesitter's parser table
---@param info_dir string directory holding the `<lang>.revision` stamps
---@param parser_dir string directory holding the `<lang>.so` grammars
---@return string[] drift one human-readable line per mismatch, empty when clean
function M.drift(languages, parsers, info_dir, parser_dir)
  local out = {}
  for _, lang in ipairs(languages) do
    local entry = parsers[lang]
    local want = entry and entry.install_info and entry.install_info.revision
    local have = M.installed_revision(info_dir, lang)
    if want ~= have then
      out[#out + 1] = ("%s: want %s, got %s"):format(
        lang,
        want or "no registry entry",
        have or "not installed"
      )
    elseif not is_built(parser_dir, lang) then
      -- Revision agreed, grammar absent. Reported separately because the two
      -- read completely differently to whoever hits it: a revision mismatch
      -- means the pin moved, this means the install is gutted.
      out[#out + 1] = ("%s: stamped %s but %s/%s.so is missing"):format(
        lang,
        have,
        parser_dir,
        lang
      )
    end
  end
  return out
end

return M
