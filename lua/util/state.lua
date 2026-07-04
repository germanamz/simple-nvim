-- Small-state persistence shared by config.ai (persisted model), config
-- .ai_models (library cache), config.review_base (review-base store) and
-- config.lock_drift (plain-file git reads): the guarded whole-file read and
-- the atomic tmp+rename write live here once. Each caller keeps its own
-- decode/validate/default semantics at the call site.
local M = {}

-- Slurp `path` as a string, or nil when it can't be opened.
function M.read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local raw = f:read("*a")
  f:close()
  return raw
end

-- Atomic-ish write: mkdir -p the parent (a stdpath dir may not exist yet on a
-- fresh install or under the test harness's XDG swap), write a per-writer
-- unique tmp (pid + hrtime, so two concurrent writers can never tear the same
-- tmp out from under each other's rename), then rename over `path`. Returns
-- true on success, false when the tmp can't be opened or the rename fails
-- (os.rename reports failure via nil-plus-message, it does not raise) — a
-- caller with a cache write-through must gate on this so its cache never
-- outruns disk (see review_base.write_state); the others treat a failed write
-- as a silent no-op, matching the hand-rolled writers this replaces.
function M.write_atomic(path, contents)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local tmp = string.format("%s.%d.%d.tmp", path, vim.fn.getpid(), vim.uv.hrtime())
  local f = io.open(tmp, "w")
  if not f then
    return false
  end
  f:write(contents)
  f:close()
  return os.rename(tmp, path) ~= nil
end

return M
