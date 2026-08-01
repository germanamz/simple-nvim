-- Per-buffer review base for gitsigns.
--
-- gitsigns keeps ONE base (`config.base`) that every attached buffer inherits,
-- but a review base belongs to a single repo root (see config.review_base). In a
-- superproject, pushing one root's base globally leaked it into buffers living
-- in sibling submodules — and gitsigns feeds that base to `git blame <revision>`
-- as well as to the diff. A submodule checked out behind its own branch tip
-- (the normal state: the superproject pins a commit, the branch moves on) then
-- blamed every line on whatever commit last touched it on that ref — a squash or
-- merge commit, i.e. "the latest committer" — instead of the commit that wrote
-- the line.
--
-- So the global base is never set. Each attached buffer carries the base of its
-- OWN root, and a base change re-bases only that root's buffers.
local M = {}

local git = require("util.git")
local review_base = require("config.review_base")

-- A buffer's current revision lives in gitsigns' cache entry, which is also the
-- "fully attached" signal: b:gitsigns_status is set earlier in attach, before
-- the entry exists, so it can't stand in for this.
local function entry(bufnr)
  local ok, cache = pcall(require, "gitsigns.cache")
  if not ok then
    return nil
  end
  return cache.cache[bufnr]
end

-- Point one buffer at `ref` (nil = back to the index). change_base's per-buffer
-- form acts on the CURRENT buffer, so borrow it for the call — that is what
-- keeps the ref off the global base every other buffer reads.
function M.set(bufnr, ref)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local e = entry(bufnr)
  -- Unattached buffers (untracked / new-vs-base) hold no base at all, and an
  -- unchanged base would cost a pointless re-diff of the whole buffer.
  if not e or e.git_obj.revision == ref then
    return
  end
  vim.api.nvim_buf_call(bufnr, function()
    require("gitsigns").change_base(ref, false)
  end)
  -- Tag what this revision MEANS, so config.gitsigns_blame can tell a review
  -- base apart from a revision the buffer genuinely represents (a `gitsigns://`
  -- historical buffer) and blame past the former. Set straight after the call —
  -- change_base is async, and the tag records the ref we asked for, which the
  -- reader only trusts once git_obj.revision has actually caught up to it.
  e.git_obj._review_base = ref
end

-- gitsigns calls on_attach BEFORE it registers the buffer's cache entry, so the
-- base can only land on a later tick. Poll briefly instead of assuming a fixed
-- number of ticks; a slow attach must not silently drop the base.
local RETRY_MS = 25
local MAX_TRIES = 20

-- Attach path: give the buffer the base of its own root. A root with no base
-- needs no action — a fresh attach already tracks the index, because the global
-- base is left unset.
function M.apply(bufnr, tries)
  local root = git.buf_root(bufnr)
  local ref = root and review_base.get(root) or nil
  if not ref then
    return
  end
  if entry(bufnr) then
    M.set(bufnr, ref)
    return
  end
  tries = (tries or 0) + 1
  if tries > MAX_TRIES or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.defer_fn(function()
    M.apply(bufnr, tries)
  end, RETRY_MS)
end

-- A root's base moved (ReviewBaseChanged): re-base that root's buffers, and
-- nothing else. EXACT root equality via git.buf_in_root, so a superproject's
-- change never reaches the submodule buffers sitting under it on disk.
function M.rebase_root(root, ref)
  if not root then
    return
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and git.buf_in_root(buf, root) then
      M.set(buf, ref)
    end
  end
end

return M
