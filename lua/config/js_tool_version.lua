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

--- Roots already warned about, keyed by root + tool + both versions, so this
--- fires once per session rather than once per save.
local warned = {}

--- Probed versions, keyed by root + tool. The probe spawns a subprocess and its
--- caller runs inside BufWritePre (twice per format, since conform resolves the
--- formatter list more than once), so this must never re-run per save. `false`
--- records a failed probe so a broken binary is not retried on every write.
local probed = {}

--- Drop the warned set and the probe cache. For tests.
function M._reset()
  warned = {}
  probed = {}
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

--- Warn once if `running` and the project's pin disagree on the major version.
---@param bufnr integer
---@param tool string
---@param running string|nil version actually executing, nil when unknown
function M.warn(bufnr, tool, running)
  if not running then
    return
  end
  local root = require("config.js_toolchain").resolve(bufnr).root
  local pin = M.pinned(root, tool)
  local want, got = M.major(pin), M.major(running)
  if not want or not got or want == got then
    return
  end

  local key = table.concat({ root or "?", tool, running, pin }, "\0")
  if warned[key] then
    return
  end
  warned[key] = true

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

-- Both prettierd and eslint_d are wrapper daemons: their own --version prints
-- the DAEMON's version, not the library resolved for the project, so a naive
-- "first semver in the output" match reports the wrong number for both.
--   * prettierd --debug-info <file> (a file argument is required or it exits 1
--     with nothing on stdout) prints "prettierd X.X.X" ahead of the line that
--     actually matters, "prettier version: X.X.X" — the LIBRARY it resolved,
--     preferring one next to the file over its own bundled copy.
--   * eslint_d --version always prints its OWN version plus a static "bundled
--     eslint" number, neither of which is project-specific. `eslint_d status`
--     instead resolves and reports "local eslint vX.X.X" for `cwd`, falling
--     back to "bundled eslint vX.X.X" only when the project has none — the
--     number a project's own `eslint` pin should be compared against.
local PROBES = {
  prettier = {
    cmd = { "prettierd", "--debug-info", "probe.js" },
    extract = function(out)
      return out:match("prettier version:%s*(%d+%.%d+%.%d+)")
    end,
  },
  eslint = {
    cmd = { "eslint_d", "status" },
    extract = function(out)
      return out:match("(%d+%.%d+%.%d+)")
    end,
  },
}

--- The version of `tool` that will actually execute for a buffer in `root`.
---@param tool string
---@param root string|nil
---@return string|nil
function M.running(tool, root)
  local key = (root or "?") .. "\0" .. tool
  local hit = probed[key]
  if hit ~= nil then
    return hit or nil
  end

  local probe = PROBES[tool]
    or {
      cmd = { tool, "--version" },
      extract = function(out)
        return out:match("(%d+%.%d+%.%d+)")
      end,
    }

  local ok, out = pcall(function()
    return vim.system(probe.cmd, { cwd = root, text = true }):wait(2000)
  end)
  local found = ok and out.code == 0 and out.stdout and probe.extract(out.stdout)

  probed[key] = found or false
  return found or nil
end

return M
