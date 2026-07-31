-- Warn when the tool formatting a project is not the tool the project pins.
--
-- Third time this config has met the problem: docs/lsp-typescript-version.md is
-- ts_ls running mason's TypeScript over the package's own, and this is the same
-- shape one layer up. Mason's prettier is 3.x; a repo pinned to prettier 2.x gets
-- reformatted by a major it never chose — prettier 3 changed trailingComma to
-- "all" and reflows markdown differently — so a save produces a diff the project's
-- CI rejects. Silent until now, because the formatter ran and looked successful.
--
-- Deliberately dumb: only a clear MAJOR mismatch warns. Anything unparseable
-- (workspace:*, a git URL, a tag) is silence, not a guess — a false warning on
-- every save is worse than no warning.
local M = {}

--- Test seam: specs replace this to capture messages.
---@type fun(msg: string, level: integer)|nil
M._notify = nil

-- Slot name (config.js_toolchain's `formatter` value) -> the npm package.json
-- key to look up its pin under. prettier's and eslint's CLI name IS their
-- package name, so those two entries look like a no-op; biome's is NOT — its
-- npm package is scoped "@biomejs/biome" (js_toolchain.lua:41-42 hits this
-- same scoping in its own LINTER pkg_patterns probe, for the same reason).
-- A slot ABSENT from this map gets NO version check at all, silently: dprint
-- and oxfmt's npm package names were not verified here and are deliberately
-- left out rather than guessed — a wrong name would look up a key that never
-- matches and the check would be permanently, silently dead. Add a tool here
-- to turn its version check on.
local PACKAGES = {
  prettier = "prettier",
  eslint = "eslint",
  biome = "@biomejs/biome",
}

--- Roots already warned about, keyed by root + tool + both versions, so this
--- fires once per session rather than once per save. Still load-bearing next to
--- `settled` below: several saves can queue behind one in-flight probe, and all
--- of their callbacks fire when it lands.
local warned = {}

--- (root, tool) pairs whose verdict is final — warned, or checked and found to
--- agree. M.pinned is the only step here that is not memoized, so without this
--- an AGREEING project (the good case!) re-read and re-decoded its package.json
--- twice per save forever, since M.warn returned before recording anything.
local settled = {}

--- Probed versions, keyed by root + tool. The probe spawns a subprocess and its
--- caller runs inside BufWritePre (twice per format, since conform resolves the
--- formatter list more than once), so this must never re-run per save. `false`
--- records a failed probe so a broken binary is not retried on every write.
local probed = {}

--- Keys with a probe in flight, mapped to the callbacks waiting on it. A second
--- save before the first probe lands must queue, not spawn a second daemon.
local pending = {}

--- Drop every memo above: warnings, settled verdicts, and the probe cache
--- (including any in-flight registrations). For tests.
function M._reset()
  warned = {}
  settled = {}
  probed = {}
  pending = {}
end

--- Leading major of a semver range, or nil when there isn't an obvious one.
---@param range string|nil
---@return string|nil
function M.major(range)
  if type(range) ~= "string" then
    return nil
  end
  return range:match("^%D*(%d+)")
end

--- The range `root`'s package.json pins for `tool`, in either dependency block.
---@param root string|nil
---@param tool string
---@return string|nil
function M.pinned(root, tool)
  if not root then
    return nil
  end
  local f = io.open(vim.fs.joinpath(root, "package.json"), "r")
  if not f then
    return nil
  end
  local raw = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" then
    return nil
  end
  for _, block in ipairs({ "devDependencies", "dependencies" }) do
    local deps = data[block]
    if type(deps) == "table" and type(deps[tool]) == "string" then
      return deps[tool]
    end
  end
  return nil
end

-- Ordered fallback commands per probe tool. prettier mirrors conform's own
-- chain (lua/config/formatters.lua's `prettier = { "prettierd", "prettier",
-- stop_after_first = true }`): if prettierd is not installed, conform silently
-- drops to standalone prettier, and the probe must follow that fallback or it
-- caches a permanent `false` from prettierd's ENOENT — and never warns again
-- for a project that IS being reformatted, just by plain prettier instead of
-- the daemon. Tools absent here (including generic `--version` ones) get a
-- single-candidate list built in M.running.
local PROBE_CMDS = {
  prettier = {
    { "prettierd", "--debug-info", "probe.js" },
    { "prettier", "--version" },
  },
  eslint = { { "eslint_d", "status" } },
}

-- Both prettierd and eslint_d are wrapper daemons: their own --version prints
-- the DAEMON's version, not the library resolved for the project, so a naive
-- "first semver in the output" match reports the wrong number for both.
--   * prettierd --debug-info <file> (a file argument is required or it exits 1
--     with nothing on stdout) prints "prettierd X.X.X" ahead of the line that
--     actually matters, "prettier version: X.X.X" — the LIBRARY it resolved,
--     preferring one next to the file over its own bundled copy. Plain
--     `prettier --version` (the fallback above) has no such label, just the
--     bare number, so only fall through to a bare match when the label is
--     absent — never let the bare match win over the labeled one.
--   * eslint_d --version always prints its OWN version plus a static "bundled
--     eslint" number, neither of which is project-specific. `eslint_d status`
--     instead resolves and reports "local eslint vX.X.X" for `cwd`, falling
--     back to "bundled eslint vX.X.X" only when the project has none — the
--     number a project's own `eslint` pin should be compared against.
local EXTRACTORS = {
  prettier = function(stdout)
    return stdout:match("prettier version:%s*(%d+%.%d+%.%d+)") or stdout:match("(%d+%.%d+%.%d+)")
  end,
  eslint = function(stdout)
    return stdout:match("(%d+%.%d+%.%d+)")
  end,
}

--- Extracts the semver `stdout` reports for `tool`'s probe. A seam (not just
--- an internal local) so specs can pin the discrimination directly against
--- captured output, without spawning a real prettierd/eslint_d — the bug this
--- exists to catch (reporting a wrapper daemon's own version instead of the
--- library it resolved) is entirely in string parsing, not in process I/O.
---@param tool string
---@param stdout string
---@return string|nil
function M._extract(tool, stdout)
  local fn = EXTRACTORS[tool] or function(out)
    return out:match("(%d+%.%d+%.%d+)")
  end
  return fn(stdout)
end

--- The version of `tool` that will actually execute for a buffer in `root`.
---
--- ASYNCHRONOUS, and it has to be: the only caller runs inside BufWritePre, and
--- a blocking `:wait(2000)` froze the editor there for up to two seconds per
--- candidate command — four for prettier, which falls through prettierd to
--- plain prettier. That fires on the first save in any project pinning
--- prettier, eslint or biome, i.e. most of them. The warning is advisory, so
--- arriving a moment after the save costs nothing; a frozen editor costs a lot.
---
--- Returns nil while a probe is still running. `on_result` is how a caller
--- hears the late answer; it is never invoked for a value returned here, so a
--- caller handles each answer exactly once.
---@param tool string
---@param root string|nil
---@param on_result? fun(version: string|nil) called on the main loop when an
---   in-flight probe lands
---@return string|nil nil while unknown
function M.running(tool, root, on_result)
  local key = (root or "?") .. "\0" .. tool
  local hit = probed[key]
  if hit ~= nil then
    return hit or nil
  end
  if pending[key] then
    if on_result then
      table.insert(pending[key], on_result)
    end
    return nil
  end
  pending[key] = {}

  local function finish(found)
    probed[key] = found or false
    local waiters = pending[key]
    pending[key] = nil
    if not waiters or #waiters == 0 then
      return
    end
    -- vim.schedule because vim.system's callback runs in the fast event loop,
    -- where the notify path's vim.fn.fnamemodify is not allowed — and because
    -- when a spawn fails outright `finish` is reached synchronously, still
    -- inside BufWritePre, which is the one place nothing here may run.
    vim.schedule(function()
      for _, fn in ipairs(waiters) do
        pcall(fn, found or nil)
      end
    end)
  end

  local cmds = PROBE_CMDS[tool] or { { tool, "--version" } }
  local function step(i)
    local cmd = cmds[i]
    if not cmd then
      return finish(nil)
    end
    -- pcall: vim.system raises ENOENT synchronously for a binary that is not on
    -- PATH, which is the ordinary case this fallback chain exists for.
    --
    -- timeout is the async form of the cap the old blocking `:wait(2000)` gave
    -- us, and dropping it when this went async would have been a real leak:
    -- prettierd and eslint_d are resident daemons, so a wedged one never exits,
    -- `pending[key]` stays set forever (that root+tool can then never warn
    -- again), the child is never reaped, and one closure accumulates per save.
    -- vim.system TERMs on expiry and reports code 124, which reads here as a
    -- failed candidate: fall through to the next command, then cache false.
    local ok = pcall(vim.system, cmd, { cwd = root, text = true, timeout = 2000 }, function(out)
      local found = (out.code == 0 and out.stdout) and M._extract(tool, out.stdout) or nil
      if found then
        finish(found)
      else
        step(i + 1)
      end
    end)
    if not ok then
      step(i + 1)
    end
  end
  step(1)

  -- A probe whose every candidate failed to spawn has already settled inline;
  -- report it now rather than making the caller wait for an answer that exists.
  -- `on_result` is registered only past this point, so a caller never gets the
  -- same answer both as a return value and as a callback.
  local now = probed[key]
  if now ~= nil then
    return now or nil
  end
  if on_result then
    table.insert(pending[key], on_result)
  end
  return nil
end

--- Warn once if the project pins `tool` at a MAJOR version different from the
--- one actually resolved for `bufnr`'s project.
---
--- Ordered deliberately: `M.pinned` first (a cheap file read) — the common
--- case is an unpinned project, where nothing could ever warn — and only when
--- a pin exists does this reach `M.running`, whose probe is asynchronous. A
--- tool with no entry in PACKAGES returns before either.
---
--- Runs inside BufWritePre and therefore does the minimum there: on the first
--- save of a pinned project the running version is not known yet, so this
--- returns having only read package.json, and `verdict` fires from the probe's
--- callback a moment later with the message. One save late, never blocking.
---@param bufnr integer
---@param tool string
function M.warn(bufnr, tool)
  local pkg = PACKAGES[tool]
  if not pkg then
    return
  end
  local root = require("config.js_toolchain").resolve(bufnr).root
  local skey = (root or "?") .. "\0" .. tool
  if settled[skey] then
    return
  end
  local pin = M.pinned(root, pkg)
  if not pin then
    return
  end

  --- Compare and (maybe) notify, from whichever side the version arrives on.
  ---@param running string|nil
  local function verdict(running)
    if not running then
      return
    end
    -- Recorded before the majors are compared, so AGREEMENT is remembered too:
    -- that is the common case, and leaving it unrecorded is what made M.pinned
    -- re-read package.json on every save of every well-pinned project.
    settled[skey] = true
    local key = table.concat({ root or "?", tool, running, pin }, "\0")
    if warned[key] then
      return
    end
    warned[key] = true

    local want, got = M.major(pin), M.major(running)
    if not want or not got or want == got then
      return
    end

    local where = vim.fn.fnamemodify(root or "?", ":~:.")
    local msg = ("%s in %s runs %s; %s pins %s. Formatting here may not match its CI — install the project's own copy to use it."):format(
      tool,
      vim.fs.basename(root or "?"),
      running,
      where,
      pin
    )
    local notify = M._notify or vim.notify
    notify(msg, vim.log.levels.WARN)
  end

  verdict(M.running(tool, root, verdict))
end

return M
