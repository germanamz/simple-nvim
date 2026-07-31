-- Pins js_toolchain.gate_root_dir. biome and oxlint each resolve their own root
-- (lspconfig/lsp/oxlint.lua runs an unbounded upward find; lspconfig/lsp/biome.lua
-- its own vim.fs.root), so neither respects our repo boundary or our linter
-- priority order. Left ungated, a superproject .oxlintrc.json attaches oxlint
-- inside an independent submodule, and a repo we resolved as biome can still get
-- oxlint alongside.
local toolchain = require("config.js_toolchain")

describe("config.js_toolchain.gate_root_dir", function()
  local root

  before_each(function()
    toolchain._clear()
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/src", "p")
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
    toolchain._clear()
  end)

  local function write(relpath, contents)
    local path = root .. "/" .. relpath
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "w"))
    f:write(contents)
    f:close()
  end

  local function buf()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, root .. "/src/a.ts")
    return bufnr
  end

  -- A stand-in for lspconfig's own resolver: records that it ran and answers.
  local function base(dir)
    local calls = { n = 0 }
    return calls, function(_, on_dir)
      calls.n = calls.n + 1
      on_dir(dir)
    end
  end

  it("calls through when detection names that tool as the linter", function()
    write("biome.json", "{}\n")
    local calls, fn = base(root)
    local got
    toolchain.gate_root_dir(fn, "biome")(buf(), function(dir)
      got = dir
    end)
    assert.are.equal(1, calls.n)
    assert.are.equal(root, got)
  end)

  it("never calls on_dir when detection names a different linter", function()
    write("eslint.config.mjs", "export default [];\n")
    local calls, fn = base(root)
    local called = false
    toolchain.gate_root_dir(fn, "biome")(buf(), function()
      called = true
    end)
    assert.are.equal(0, calls.n)
    assert.is_false(called)
  end)

  it("never calls on_dir when nothing is configured", function()
    local calls, fn = base(root)
    local called = false
    toolchain.gate_root_dir(fn, "oxlint")(buf(), function()
      called = true
    end)
    assert.are.equal(0, calls.n)
    assert.is_false(called)
  end)

  -- A throw here would propagate into lspconfig's resolution.
  it("declines rather than raising when resolution fails", function()
    local fn = function()
      error("resolver blew up")
    end
    write("biome.json", "{}\n")
    local called = false
    local ok = pcall(toolchain.gate_root_dir(fn, "biome"), buf(), function()
      called = true
    end)
    assert.is_true(ok)
    assert.is_false(called)
  end)
end)
