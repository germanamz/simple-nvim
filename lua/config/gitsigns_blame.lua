-- Blame answers "who wrote this line" — a question about the buffer's own
-- history, never about the review base. gitsigns derives both from one
-- per-buffer revision (see config.gitsigns_base), so with a base set it answered
-- the wrong question twice over:
--
--   * `git blame <base>` walks history from the base, so a line committed after
--     it is attributed to whatever the base's tip made of it — or, when the
--     content isn't in the base at all, to the `--contents` pseudo-commit.
--   * `CacheEntry:get_blame` short-circuits any line inside a hunk to "Not
--     Committed Yet" without running blame. That is right when hunks are vs the
--     index, but against a review base EVERY line you committed on your branch
--     is inside a hunk — so committed work read as uncommitted.
--
-- Both are patched below, and only for buffers whose revision came from a review
-- base (tagged `git_obj._review_base`). A `gitsigns://` buffer showing a
-- historical revision keeps stock behaviour: there, blaming from that revision
-- is the whole point. Hunks, signs and `<leader>hd` are untouched — they still
-- diff against the base.
local M = {}

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

-- Patch the two gitsigns entry points, once. Both keep their stock path for
-- every buffer that isn't sitting on a review base.
function M.setup()
  local Obj = require("gitsigns.git").Obj
  if Obj._review_base_blame_patched then
    return
  end
  Obj._review_base_blame_patched = true

  local orig_run_blame = Obj.run_blame
  Obj.run_blame = function(self, contents, lnum, revision, opts)
    if from_review_base(self) then
      revision = nil
    end
    return orig_run_blame(self, contents, lnum, revision, opts)
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
