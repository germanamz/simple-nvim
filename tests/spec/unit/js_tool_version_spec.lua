-- Pins config.js_tool_version: warn when the tool that formats a project is not
-- the tool the project pins. Same defect class as docs/lsp-typescript-version.md
-- one layer up — mason's global prettier 3.x silently reformatting a repo pinned
-- to prettier 2.x produces diffs the project's CI rejects.
local version = require("config.js_tool_version")

describe("config.js_tool_version.major", function()
  it("reads the major out of common range syntaxes", function()
    assert.are.equal("3", version.major("^3.4.2"))
    assert.are.equal("2", version.major("~2.8.8"))
    assert.are.equal("3", version.major("3.8.3"))
    assert.are.equal("2", version.major(">=2.0.0"))
    assert.are.equal("3", version.major("3.x"))
  end)

  it("is nil for anything it cannot parse", function()
    assert.is_nil(version.major(nil))
    assert.is_nil(version.major("workspace:*"))
    assert.is_nil(version.major("*"))
    assert.is_nil(version.major("github:foo/bar"))
  end)
end)

describe("config.js_tool_version.pinned", function()
  local root

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  local function pkg(contents)
    local f = assert(io.open(root .. "/package.json", "w"))
    f:write(contents)
    f:close()
  end

  it("finds a devDependency pin", function()
    pkg('{"devDependencies":{"prettier":"^2.8.8"}}')
    assert.are.equal("^2.8.8", version.pinned(root, "prettier"))
  end)

  it("finds a dependency pin", function()
    pkg('{"dependencies":{"prettier":"3.1.0"}}')
    assert.are.equal("3.1.0", version.pinned(root, "prettier"))
  end)

  it("is nil when the tool is not pinned", function()
    pkg('{"devDependencies":{"typescript":"^5"}}')
    assert.is_nil(version.pinned(root, "prettier"))
  end)

  it("is nil with no package.json and does not raise", function()
    assert.is_nil(version.pinned(root, "prettier"))
  end)

  it("is nil on malformed json and does not raise", function()
    pkg("{ not json")
    assert.is_nil(version.pinned(root, "prettier"))
  end)

  it("is nil for a nil root", function()
    assert.is_nil(version.pinned(nil, "prettier"))
  end)
end)

-- config.js_tool_version._extract: the string-parsing half of the version
-- probe, seamed out specifically so it can be pinned against captured
-- prettierd/eslint_d output without spawning a real daemon. The prettier case
-- is a genuine discrimination test, not just a pin: prettierd's --debug-info
-- prints its OWN version ("prettierd 0.28.0") ahead of the line that actually
-- matters ("prettier version: 3.9.0"), and a naive first-semver-in-the-output
-- match — which is what this module shipped with initially — silently reports
-- the daemon's version instead of the library's. See the deliberate-revert
-- proof in task-7-report.md for evidence this test actually catches that.
describe("config.js_tool_version._extract", function()
  it("prefers prettierd's labeled library version over its own leading version number", function()
    assert.are.equal(
      "3.9.0",
      version._extract("prettier", "prettierd 0.28.0\nprettier version: 3.9.0\n  Loaded from: /x")
    )
  end)

  it("falls back to a bare semver for plain prettier --version output", function()
    assert.are.equal("3.8.3", version._extract("prettier", "3.8.3\n"))
  end)

  it("reads eslint_d status's resolved local-eslint version", function()
    assert.are.equal(
      "9.39.2",
      version._extract("eslint", "eslint_d: Not running - local eslint v9.39.2")
    )
  end)

  it("reads eslint_d status's bundled-eslint fallback the same way", function()
    assert.are.equal(
      "10.8.0",
      version._extract("eslint", "eslint_d: Not running - bundled eslint v10.8.0")
    )
  end)
end)

describe("config.js_tool_version.warn", function()
  local root, notices, real_running

  before_each(function()
    version._reset()
    notices = {}
    version._notify = function(msg)
      notices[#notices + 1] = msg
    end
    real_running = version.running
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/src", "p")
    require("config.js_toolchain")._clear()
  end)

  after_each(function()
    version._notify = nil
    version.running = real_running
    version._reset()
    vim.fn.delete(root, "rf")
    require("config.js_toolchain")._clear()
  end)

  local function project(deps)
    local f = assert(io.open(root .. "/package.json", "w"))
    f:write(('{"devDependencies":%s}'):format(deps))
    f:close()
    local g = assert(io.open(root .. "/.prettierrc", "w"))
    g:write("{}\n")
    g:close()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, root .. "/src/a.ts")
    return bufnr
  end

  local function pinning(pin)
    return project(('{"prettier":"%s"}'):format(pin))
  end

  local function unpinned_buf()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, root .. "/src/a.ts")
    return bufnr
  end

  it("warns when the majors differ", function()
    version.running = function()
      return "3.8.3"
    end
    version.warn(pinning("^2.8.8"), "prettier")
    assert.are.equal(1, #notices)
    assert.is_truthy(notices[1]:find("prettier", 1, true))
    assert.is_truthy(notices[1]:find("2.8.8", 1, true))
    assert.is_truthy(notices[1]:find("3.8.3", 1, true))
  end)

  it("stays silent when the majors agree", function()
    version.running = function()
      return "3.8.3"
    end
    version.warn(pinning("^3.0.3"), "prettier")
    assert.are.equal(0, #notices)
  end)

  it("stays silent when the running version is unknown", function()
    version.running = function()
      return nil
    end
    version.warn(pinning("^2.8.8"), "prettier")
    assert.are.equal(0, #notices)
  end)

  it("stays silent when the project pins nothing, and never probes", function()
    local probes = 0
    version.running = function(...)
      probes = probes + 1
      return "3.8.3"
    end
    version.warn(unpinned_buf(), "prettier")
    assert.are.equal(0, #notices)
    assert.are.equal(0, probes)
  end)

  it("warns once per root, not once per save", function()
    version.running = function()
      return "3.8.3"
    end
    local bufnr = pinning("^2.8.8")
    version.warn(bufnr, "prettier")
    version.warn(bufnr, "prettier")
    version.warn(bufnr, "prettier")
    assert.are.equal(1, #notices)
  end)

  it("looks up biome's scoped npm package, not the bare slot name", function()
    version.running = function()
      return "2.5.5"
    end
    local bufnr = project('{"@biomejs/biome":"^1.9.0"}')
    version.warn(bufnr, "biome")
    assert.are.equal(1, #notices)
    assert.is_truthy(notices[1]:find("biome", 1, true))
    assert.is_truthy(notices[1]:find("1.9.0", 1, true))
  end)

  it("skips tools with no known npm package name (dprint, oxfmt), without probing", function()
    local probes = 0
    version.running = function(...)
      probes = probes + 1
      return "1.0.0"
    end
    local bufnr = pinning("^2.8.8") -- pins prettier, irrelevant to dprint/oxfmt
    version.warn(bufnr, "dprint")
    version.warn(bufnr, "oxfmt")
    assert.are.equal(0, #notices)
    assert.are.equal(0, probes)
  end)
end)

describe("config.js_tool_version.running", function()
  local real_system

  before_each(function()
    version._reset()
    real_system = vim.system
  end)

  after_each(function()
    vim.system = real_system
    version._reset()
  end)

  it("returns a semver for a tool that is on PATH", function()
    if vim.fn.executable("prettierd") ~= 1 then
      pending("prettierd not on PATH")
      return
    end
    assert.is_truthy(version.running("prettier", nil):match("^%d+%.%d+%.%d+$"))
  end)

  it("is nil for a tool that does not exist, without raising", function()
    assert.is_nil(version.running("definitely-not-a-real-tool", nil))
  end)

  it("probes a given root and tool only once", function()
    local calls = 0
    vim.system = function(...)
      calls = calls + 1
      return real_system(...)
    end
    version.running("definitely-not-a-real-tool", "/tmp")
    version.running("definitely-not-a-real-tool", "/tmp")
    version.running("definitely-not-a-real-tool", "/tmp")
    assert.are.equal(1, calls)
  end)

  it("_reset drops the probe cache, so a later call probes again", function()
    local calls = 0
    vim.system = function(...)
      calls = calls + 1
      return real_system(...)
    end
    version.running("definitely-not-a-real-tool", "/tmp")
    version._reset()
    version.running("definitely-not-a-real-tool", "/tmp")
    assert.are.equal(2, calls)
  end)

  it("falls back to plain prettier when prettierd fails", function()
    vim.system = function(cmd)
      if cmd[1] == "prettierd" then
        return {
          wait = function()
            return { code = 1, stdout = "" }
          end,
        }
      end
      return {
        wait = function()
          return { code = 0, stdout = "3.8.3\n" }
        end,
      }
    end
    assert.are.equal("3.8.3", version.running("prettier", "/tmp"))
  end)
end)
