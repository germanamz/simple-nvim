-- Lockfile-drift warning: fresh installs restore to lazy-lock.json (init.lua),
-- but an existing machine that pulls lockfile updates never re-applied them —
-- plugins silently drift from their pins (or never install at all). M.check()
-- compares each installed clone's commit against the lockfile after startup
-- and warns so drift is never silent. Extracted from init.lua so the
-- HEAD/loose-ref/packed-refs resolution ladder is unit-testable
-- (tests/spec/unit/lock_drift_spec.lua).
local M = {}

local state = require("util.state")

-- Resolve the commit a plugin clone is sitting on, via plain file reads (no
-- process spawns): detached HEAD holds the sha directly; a `ref:` HEAD is
-- resolved through the loose ref file, falling back to packed-refs.
function M._installed_commit(dir)
  local head = state.read_file(dir .. "/.git/HEAD")
  if not head then
    return nil
  end
  head = vim.trim(head)
  local ref = head:match("^ref:%s*(.+)$")
  if not ref then
    return head
  end
  local loose = state.read_file(dir .. "/.git/" .. ref)
  if loose then
    return vim.trim(loose)
  end
  for line in (state.read_file(dir .. "/.git/packed-refs") or ""):gmatch("[^\n]+") do
    local sha, name = line:match("^(%x+) (.+)$")
    if name == ref then
      return sha
    end
  end
  return nil
end

-- Compare installed commits against lazy-lock.json and warn on any drift.
function M.check()
  local raw = state.read_file(vim.fn.stdpath("config") .. "/lazy-lock.json")
  if not raw then
    return
  end
  local ok, lock = pcall(vim.json.decode, raw)
  if not ok or type(lock) ~= "table" then
    return
  end
  local drifted = {}
  for name, pin in pairs(lock) do
    local dir = vim.fn.stdpath("data") .. "/lazy/" .. name
    if M._installed_commit(dir) ~= pin.commit then
      drifted[#drifted + 1] = name
    end
  end
  if #drifted > 0 then
    table.sort(drifted)
    vim.notify(
      "Plugins out of sync with lazy-lock.json: "
        .. table.concat(drifted, ", ")
        .. " — run :Lazy restore",
      vim.log.levels.WARN
    )
  end
end

return M
