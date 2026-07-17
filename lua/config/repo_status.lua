-- Branch + working-state for a single repo dir, for the nvim-tree root header
-- (superproject) and the per-submodule decorator labels. One async resolver
-- feeds both: `git status --porcelain=v2 --branch` yields branch, detached
-- state, ahead/behind, and the changed-file count in one spawn; a detached HEAD
-- gets one follow-up `git describe`. The module is nvim-tree-free — it fires a
-- `User RepoStatusChanged` event when a dir's status lands (mirroring
-- config.git_head's HeadChanged / config.review_base's ReviewBaseChanged), and
-- the tree's reload is a subscriber registered in config.nvim_tree_git.
local M = {}

-- Parse `git status --porcelain=v2 --branch` stdout lines into a status table:
--   { branch=string|nil, detached=bool, ahead=int, behind=int,
--     count=int, dirty=bool }
-- The `--branch` header lines carry branch/ahead-behind:
--   # branch.head <name>|(detached)
--   # branch.ab   +<ahead> -<behind>   (present only when an upstream is set)
-- and each changed entry is one line prefixed 1/2 (changed/renamed), u
-- (unmerged), or ? (untracked); ! (ignored) is never counted. Pure — no spawn,
-- no state. `detached_ref` is filled later by the describe follow-up, not here.
function M.parse(lines)
  local s = { branch = nil, detached = false, ahead = 0, behind = 0, count = 0, dirty = false }
  for _, l in ipairs(lines) do
    local head = l:match("^# branch%.head (.+)$")
    local ab = l:match("^# branch%.ab (.+)$")
    if head then
      if head == "(detached)" then
        s.detached = true
      else
        s.branch = head
      end
    elseif ab then
      local a, b = ab:match("^%+(%d+) %-(%d+)$")
      s.ahead = tonumber(a) or 0
      s.behind = tonumber(b) or 0
    elseif l:match("^[12u?] ") then
      s.count = s.count + 1
    end
  end
  s.dirty = s.count > 0
  return s
end

-- Status table -> highlighted segments { {str=, hl={group}}, … }, in render
-- order (branch|detached, dirty+count, ahead, behind). Each part after the
-- lead carries its own leading space, so a plain concatenation of the `str`s is
-- the spaced label. Returns {} when neither a branch nor a detached ref is
-- known (unborn / outside a repo) — the caller then renders nothing.
function M.segments(status)
  local segs = {}
  if status.detached then
    local ref = status.detached_ref
    local text = (ref and ref ~= "") and (ref .. " (detached)") or "(detached)"
    segs[#segs + 1] = { str = text, hl = { "SmartFilesDetached" } }
  elseif status.branch and status.branch ~= "" then
    segs[#segs + 1] = { str = status.branch, hl = { "SmartFilesBranch" } }
  else
    return {}
  end
  if status.dirty and status.count > 0 then
    segs[#segs + 1] = { str = " ✎" .. status.count, hl = { "SmartFilesModified" } }
  end
  if status.ahead and status.ahead > 0 then
    segs[#segs + 1] = { str = " ↑" .. status.ahead, hl = { "SmartFilesAhead" } }
  end
  if status.behind and status.behind > 0 then
    segs[#segs + 1] = { str = " ↓" .. status.behind, hl = { "SmartFilesBehind" } }
  end
  return segs
end

-- Status table -> plain (colourless) label string; the flatten of segments()'s
-- strings. Consumed by the monochrome root_folder_label line.
function M.plain(status)
  local acc = {}
  for _, seg in ipairs(M.segments(status)) do
    acc[#acc + 1] = seg.str
  end
  return table.concat(acc)
end

-- ===================== highlight groups =====================

-- The label groups reused/added for the segments above. Defined with
-- default=true (a colorscheme may override) and re-applied on ColorScheme by the
-- decorator builder, matching git_status_codes.define_highlights. The dirty
-- flag reuses SmartFilesModified so a dirty repo and a modified file read alike;
-- the branch/detached/ahead/behind groups are new (GitHub-light fg tokens).
function M.define_highlights()
  require("config.git_status_codes").define_highlights() -- ensure SmartFilesModified exists
  vim.api.nvim_set_hl(
    0,
    "SmartFilesBranch",
    { fg = require("config.palette").muted, default = true }
  )
  vim.api.nvim_set_hl(0, "SmartFilesDetached", { fg = "#bc4c00", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesAhead", { fg = "#1a7f37", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesBehind", { fg = "#cf222e", bold = true, default = true })
end

-- ===================== async resolve + per-dir cache =====================

-- Bounds the resolve spawn; matches statusline.refresh_dir's 10s ceiling — a
-- whole-repo status over a large tree may be slow, and killing a legitimate one
-- would blank the label. A hung/failed spawn degrades to a cache miss.
local GIT_TIMEOUT_MS = 10000

-- Uniform for root AND submodules: --ignore-submodules=all so each repo's count
-- reflects ITS OWN tracked files (nested submodules render on their own rows),
-- and --porcelain=v2 --branch yields branch, detached, ahead/behind, and the
-- changed entries in one spawn.
local STATUS_ARGS =
  { "status", "--porcelain=v2", "--branch", "--untracked-files=all", "--ignore-submodules=all" }

local git = require("util.git")

-- dir -> { status = <table>, state = <index key> } (never a pending marker;
-- get() must stay clean). `state` is util.git.index_key at resolve time — the
-- cheap, spawn-free change key that lets revalidate() keep an unchanged entry on
-- FocusGained instead of nuking and re-resolving every visible submodule.
local cache = {}
-- Per-dir single-flight, mirroring nvim_tree_git.refresh_labels: `pending` marks
-- an in-flight resolve; a request arriving mid-flight sets `trailing`, collapsing
-- a burst to at most 1 running + 1 queued rerun that re-reads current inputs.
local pending, trailing = {}, {}

-- The real spawn. Assigned to M._resolve (a swappable seam so tests can drive
-- completion by hand). One `git status --porcelain=v2 --branch`, then — only on
-- a detached HEAD — one `git describe --tags --always` for a readable ref.
-- Parsing is vim.schedule'd onto the main loop (vim.system's on_exit runs in a
-- fast context), so `cb` always fires on the main loop. cb(nil) on any failure.
-- Returns true when the first spawn started (so request() can clear its guard if
-- it didn't).
local function default_resolve(dir, cb)
  local ok = pcall(
    vim.system,
    vim.list_extend({ "git", "-C", dir }, STATUS_ARGS),
    { text = true, timeout = GIT_TIMEOUT_MS },
    function(out)
      local code, stdout = out.code, out.stdout
      vim.schedule(function()
        if code ~= 0 then
          return cb(nil)
        end
        local status = M.parse(vim.split(stdout or "", "\n", { trimempty = true }))
        if not status.detached then
          return cb(status)
        end
        local ok2 = pcall(
          vim.system,
          { "git", "-C", dir, "describe", "--tags", "--always" },
          { text = true, timeout = GIT_TIMEOUT_MS },
          function(d)
            local dcode, dout = d.code, d.stdout
            vim.schedule(function()
              if dcode == 0 then
                local ref = vim.trim(dout or "")
                status.detached_ref = ref ~= "" and ref or nil
              end
              cb(status)
            end)
          end
        )
        if not ok2 then
          cb(status) -- no ref; still render "(detached)"
        end
      end)
    end
  )
  if not ok then
    vim.schedule(function()
      cb(nil)
    end)
    return false
  end
  return true
end
M._resolve = default_resolve

-- Cached status for `dir`, or nil when unresolved/failed. Never spawns.
function M.get(dir)
  local entry = cache[dir]
  return entry and entry.status or nil
end

-- Schedule a resolve for `dir` (single-flight). On a successful resolve it
-- caches the status and fires `User RepoStatusChanged { dir }`; a failed resolve
-- caches nothing and fires nothing (so the tree does not reload → re-request →
-- respawn in a loop). Fire-on-success also means an unchanged re-resolve after
-- invalidate_all still repaints, which is what a focus refresh wants.
function M.request(dir)
  if pending[dir] then
    trailing[dir] = true
    return
  end
  pending[dir] = true
  local started = M._resolve(dir, function(status)
    pending[dir] = nil
    if status then
      -- Capture the cheap index key alongside the status so a later revalidate()
      -- can tell "nothing changed" (keep) from "restaged/committed/checked out"
      -- (drop and re-resolve) without a spawn.
      cache[dir] = { status = status, state = git.index_key(dir) }
      vim.api.nvim_exec_autocmds("User", { pattern = "RepoStatusChanged", data = { dir = dir } })
    end
    if trailing[dir] then
      trailing[dir] = nil
      M.request(dir)
    end
  end)
  if not started then
    pending[dir] = nil
  end
end

-- Monochrome label for the root_folder_label line: the plain status, or "" on a
-- cold cache (scheduling a resolve so the header repaints once it lands).
function M.label_plain(dir)
  local s = M.get(dir)
  if not s then
    M.request(dir)
    return ""
  end
  return M.plain(s)
end

-- Drop every cached status so the next render re-resolves. The hard flush, for
-- the manual <leader>gR hatch and the definitive HeadChanged / ReviewBaseChanged
-- signals; only visible consumers re-request, so non-visible submodules simply
-- fall out of cache — "only when visible" holds on refresh, not just first paint.
function M.invalidate_all()
  cache = {}
end

-- The cheap FocusGained lever: drop only entries whose git index moved since they
-- were resolved (stage / commit / checkout — see util.git.index_key), keeping the
-- rest. Returning to nvim over a 200-submodule superproject with nothing changed
-- then re-resolves ZERO submodules, instead of invalidate_all's re-resolve-every-
-- visible-row storm. A bare external worktree edit is the documented gap (its
-- index key does not move); <leader>gR force-flushes for that case.
function M.revalidate()
  for dir, entry in pairs(cache) do
    if git.index_key(dir) ~= entry.state then
      cache[dir] = nil
    end
  end
end

-- Test seam: clear all state and restore the real resolver.
function M._reset()
  cache, pending, trailing = {}, {}, {}
  M._resolve = default_resolve
end

return M
