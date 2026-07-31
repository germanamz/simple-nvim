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

describe("config.js_tool_version.warn", function()
  local root, notices

  before_each(function()
    version._reset()
    notices = {}
    version._notify = function(msg)
      notices[#notices + 1] = msg
    end
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/src", "p")
    require("config.js_toolchain")._clear()
  end)

  after_each(function()
    version._notify = nil
    version._reset()
    vim.fn.delete(root, "rf")
    require("config.js_toolchain")._clear()
  end)

  local function project(pin)
    local f = assert(io.open(root .. "/package.json", "w"))
    f:write(('{"devDependencies":{"prettier":"%s"}}'):format(pin))
    f:close()
    local g = assert(io.open(root .. "/.prettierrc", "w"))
    g:write("{}\n")
    g:close()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, root .. "/src/a.ts")
    return bufnr
  end

  it("warns when the majors differ", function()
    version.warn(project("^2.8.8"), "prettier", "3.8.3")
    assert.are.equal(1, #notices)
    assert.is_truthy(notices[1]:find("prettier", 1, true))
    assert.is_truthy(notices[1]:find("2.8.8", 1, true))
    assert.is_truthy(notices[1]:find("3.8.3", 1, true))
  end)

  it("stays silent when the majors agree", function()
    version.warn(project("^3.0.3"), "prettier", "3.8.3")
    assert.are.equal(0, #notices)
  end)

  it("stays silent when the running version is unknown", function()
    version.warn(project("^2.8.8"), "prettier", nil)
    assert.are.equal(0, #notices)
  end)

  it("stays silent when the project pins nothing", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, root .. "/src/a.ts")
    version.warn(bufnr, "prettier", "3.8.3")
    assert.are.equal(0, #notices)
  end)

  it("warns once per root, not once per save", function()
    local bufnr = project("^2.8.8")
    version.warn(bufnr, "prettier", "3.8.3")
    version.warn(bufnr, "prettier", "3.8.3")
    version.warn(bufnr, "prettier", "3.8.3")
    assert.are.equal(1, #notices)
  end)
end)

describe("config.js_tool_version.running", function()
  before_each(function()
    version._reset()
  end)

  after_each(function()
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
    local real = vim.system
    vim.system = function(...)
      calls = calls + 1
      return real(...)
    end
    version.running("definitely-not-a-real-tool", "/tmp")
    version.running("definitely-not-a-real-tool", "/tmp")
    version.running("definitely-not-a-real-tool", "/tmp")
    vim.system = real
    assert.are.equal(1, calls)
  end)
end)
