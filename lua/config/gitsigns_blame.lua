-- Blame answers "who wrote this line". Two things made gitsigns answer "who
-- last touched this file" instead, and both are patched here.
--
-- The first is universal: `git blame` stops at the commit that put a line in
-- THIS file, so a file created by lifting code out of another one credits the
-- extraction for every line it moved. M.setup makes every blame path follow
-- copies (see FOLLOW_COPIES).
--
-- The second only bites with a review base. gitsigns derives blame and the diff
-- from one per-buffer revision (see config.gitsigns_base), so with a base set it
-- answered the wrong question twice over:
--
--   * `git blame <base>` walks history from the base, so a line committed after
--     it is attributed to whatever the base's tip made of it — or, when the
--     content isn't in the base at all, to the `--contents` pseudo-commit.
--   * `CacheEntry:get_blame` short-circuits any line inside a hunk to "Not
--     Committed Yet" without running blame. That is right when hunks are vs the
--     index, but against a review base EVERY line you committed on your branch
--     is inside a hunk — so committed work read as uncommitted.
--
-- Both of those are patched only for buffers whose revision came from a review
-- base (tagged `git_obj._review_base`). A `gitsigns://` buffer showing a
-- historical revision keeps stock behaviour: there, blaming from that revision
-- is the whole point. Hunks, signs and `<leader>hd` are untouched — they still
-- diff against the base.
local M = {}

-- Follow lines back through moves and copies. `-C` searches the other files a
-- commit touched; the second `-C` also searches the parent commit's files, and
-- that is the one a file CREATED by the move needs — the usual shape of "this
-- helper was extracted into its own file". A third `-C` would search every
-- commit in history, which is unbounded and fixes nothing this doesn't.
--
-- Measured on a 435-line file whose whole content arrived in one extraction
-- commit (the worst case: git actually has a parent tree to search) it took
-- blame from 0.16s to 0.55s; where there is nothing to find it costs ~0.03s.
-- Blame is async, debounced, and cached per buffer, so that is off the hot path.
local FOLLOW_COPIES = { "-C", "-C" }

-- Every blame path — the eol label, `<leader>hb`, the blame window — shares one
-- per-buffer cache (`CacheEntry.blame`) that is NOT keyed by opts, so whichever
-- path runs first decides the flags the whole buffer's blame was computed with.
-- Injecting here instead of in `current_line_blame_opts.extra_opts` keeps them
-- on one answer. The caller's table is copied rather than extended in place:
-- `current_line_blame_opts` is gitsigns' shared config table, and appending to
-- it would grow the flag list on every blame.
local function follow_copies(opts)
  local extra = {}
  if opts and opts.extra_opts then
    vim.list_extend(extra, opts.extra_opts)
  end
  vim.list_extend(extra, FOLLOW_COPIES)
  local out = vim.tbl_extend("force", {}, opts or {})
  out.extra_opts = extra
  return out
end

-- True when this object's revision is the review base we applied, rather than a
-- revision the buffer genuinely represents. The equality check keeps the tag
-- honest if the revision moves some other way (a manual `:Gitsigns change_base`).
local function from_review_base(git_obj)
  if not git_obj or git_obj._review_base == nil then
    return false
  end
  return git_obj.revision == git_obj._review_base
end

-- CacheEntry:get_blame with the hunk short-circuit removed: entry caching and
-- invalidation stay gitsigns' (self.blame, cleared by CacheEntry:invalidate and
-- realigned by on_lines), so this only decides WHEN to run blame, never how the
-- result is stored. `wait_for_hunks` is skipped too — hunks are what we're
-- deliberately not consulting.
local function blame_ignoring_base(self, lnum, opts)
  local blame = self.blame
  local first = type(lnum) == "table" and lnum[1] or lnum
  local last = type(lnum) == "table" and lnum[2] or lnum

  local valid = true
  if lnum then
    for l = first, last do
      valid = self:blame_valid(l)
      if not valid then
        break
      end
    end
  else
    valid = self:blame_valid(nil)
  end

  if not blame or not valid then
    blame = blame or { entries = {} }
    -- Runs `git blame` with the revision dropped by the Obj patch below.
    local entries, commits, full = self:run_blame(lnum, opts)
    self.commits = vim.tbl_extend("force", self.commits or {}, commits)
    if lnum and not full then
      for l = first, last do
        blame.entries[l] = entries[l]
      end
    else
      blame.entries = entries
    end
    self.blame = blame
  end

  return blame.entries[lnum]
end

-- Patch the two gitsigns entry points, once. Copy-following applies to every
-- buffer; dropping the revision keeps its stock path for every buffer that
-- isn't sitting on a review base.
function M.setup()
  local Obj = require("gitsigns.git").Obj
  if Obj._blame_patched then
    return
  end
  Obj._blame_patched = true

  local orig_run_blame = Obj.run_blame
  Obj.run_blame = function(self, contents, lnum, revision, opts)
    if from_review_base(self) then
      revision = nil
    end
    return orig_run_blame(self, contents, lnum, revision, follow_copies(opts))
  end

  local CacheEntry = require("gitsigns.cache").CacheEntry
  local orig_get_blame = CacheEntry.get_blame
  CacheEntry.get_blame = function(self, lnum, opts)
    if not from_review_base(self.git_obj) then
      return orig_get_blame(self, lnum, opts)
    end
    return blame_ignoring_base(self, lnum, opts)
  end
end

return M
