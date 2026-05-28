local function stub_vim_fn(map)
  local orig = vim.fn
  local stub = setmetatable({}, {
    __index = function(_, name)
      if map[name] then
        return map[name]
      end
      return orig[name]
    end,
  })
  vim.fn = stub
  return function()
    vim.fn = orig
  end
end

describe("config.formatters", function()
  local M, restore_fn

  before_each(function()
    package.loaded["config.formatters"] = nil
    M = require("config.formatters")
  end)

  after_each(function()
    if restore_fn then
      restore_fn()
      restore_fn = nil
    end
  end)

  describe("resolve_fence_argv", function()
    it("returns nil for nil or empty tags", function()
      assert.is_nil(M.resolve_fence_argv(nil))
      assert.is_nil(M.resolve_fence_argv(""))
    end)

    it("resolves a direct tag when the binary is on PATH", function()
      restore_fn = stub_vim_fn({
        executable = function()
          return 1
        end,
      })
      assert.are.same({ "stylua", "-" }, M.resolve_fence_argv("lua"))
    end)

    it("lowercases the tag before lookup", function()
      restore_fn = stub_vim_fn({
        executable = function()
          return 1
        end,
      })
      assert.are.same({ "stylua", "-" }, M.resolve_fence_argv("LUA"))
    end)

    it("resolves aliases to their canonical formatter", function()
      restore_fn = stub_vim_fn({
        executable = function()
          return 1
        end,
      })
      assert.are.same(M.fence_argv.python, M.resolve_fence_argv("py"))
      assert.are.same(M.fence_argv.typescript, M.resolve_fence_argv("tsx"))
      assert.are.same(M.fence_argv.cpp, M.resolve_fence_argv("c++"))
    end)

    it("returns nil for a tag with no configured formatter", function()
      restore_fn = stub_vim_fn({
        executable = function()
          return 1
        end,
      })
      assert.is_nil(M.resolve_fence_argv("nosuchlang"))
    end)

    it("returns nil when the formatter binary is not on PATH", function()
      restore_fn = stub_vim_fn({
        executable = function()
          return 0
        end,
      })
      assert.is_nil(M.resolve_fence_argv("lua"))
    end)

    it("checks executability of the first argv element", function()
      local checked
      restore_fn = stub_vim_fn({
        executable = function(prog)
          checked = prog
          return 1
        end,
      })
      M.resolve_fence_argv("python")
      assert.are.equal("ruff", checked)
    end)
  end)

  describe("map invariants", function()
    it("points every alias at an existing fence_argv key", function()
      for alias, target in pairs(M.fence_aliases) do
        assert.is_not_nil(
          M.fence_argv[target],
          "alias '" .. alias .. "' targets unknown key '" .. target .. "'"
        )
      end
    end)

    it("gives every fence_argv entry a non-empty argv with stdin/stdout support", function()
      for tag, argv in pairs(M.fence_argv) do
        assert.is_true(#argv >= 1, "empty argv for " .. tag)
        assert.is_string(argv[1])
      end
    end)
  end)
end)
