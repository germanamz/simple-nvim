local nvim_env = require("tests.helpers.nvim_env")
local keymap_probe = require("tests.helpers.keymap_probe")

-- Wiring for the format-on-save toggle: the :FormatDisable / :FormatDisable! /
-- :FormatEnable commands and the <leader>uf keymap that conform.lua registers.
-- These are pure flag manipulation (vim.g / vim.b `disable_autoformat`), so no
-- formatter binary is needed — the end-to-end "a disabled save leaves bytes
-- untouched" proof lives in the e2e format_on_save_spec. conform's keymap and
-- commands are created in its `config` function (not a lazy `keys`/`cmd` stub),
-- so the plugin must be force-loaded before they exist.
describe("smoke: format-on-save toggle (conform.nvim)", function()
  local root

  local function reset_flags()
    vim.g.disable_autoformat = false
    vim.b.disable_autoformat = false
  end

  before_each(function()
    root = nvim_env.setup_isolated_env()
    require("lazy").load({ plugins = { "conform.nvim" } })
    reset_flags()
  end)

  after_each(function()
    reset_flags() -- vim.g persists across `it`s in this nvim; don't leak
    nvim_env.teardown(root)
  end)

  it("registers the :FormatDisable and :FormatEnable commands", function()
    assert.are.equal(2, vim.fn.exists(":FormatDisable"))
    assert.are.equal(2, vim.fn.exists(":FormatEnable"))
  end)

  it(":FormatDisable sets the global flag", function()
    vim.cmd("FormatDisable")
    assert.is_true(vim.g.disable_autoformat)
  end)

  it(":FormatDisable! scopes to the current buffer and leaves the global flag off", function()
    vim.cmd("FormatDisable!")
    assert.is_true(vim.b.disable_autoformat)
    assert.is_false(vim.g.disable_autoformat)
  end)

  it(":FormatEnable clears both the global and buffer flags", function()
    vim.g.disable_autoformat = true
    vim.b.disable_autoformat = true
    vim.cmd("FormatEnable")
    assert.is_false(vim.g.disable_autoformat)
    assert.is_false(vim.b.disable_autoformat)
  end)

  describe("<leader>uf keymap", function()
    local function leader_lhs(spec)
      local leader = vim.g.mapleader or "\\"
      return (spec:gsub("<leader>", leader))
    end

    local function uf_map()
      return keymap_probe.resolve("n", leader_lhs("<leader>uf"))
    end

    it("is registered with a callback and a description", function()
      local m = uf_map()
      assert.is_not_nil(m, "no <leader>uf normal-mode keymap")
      assert.is_not_nil(m.callback, "<leader>uf has no callback")
      local desc
      for _, k in ipairs(vim.api.nvim_get_keymap("n")) do
        if k.lhs == leader_lhs("<leader>uf") then
          desc = k.desc
        end
      end
      assert.is_true(desc ~= nil and desc ~= "", "missing desc for <leader>uf")
    end)

    it("toggles the global flag on and back off", function()
      local m = uf_map()
      m.callback()
      assert.is_true(vim.g.disable_autoformat)
      m.callback()
      assert.is_false(vim.g.disable_autoformat)
    end)

    it("clears a stray per-buffer disable when re-enabling globally", function()
      local m = uf_map()
      vim.b.disable_autoformat = true -- a lingering :FormatDisable! on this buffer
      m.callback() -- disable globally; buffer flag left as-is
      assert.is_true(vim.g.disable_autoformat)
      assert.is_true(vim.b.disable_autoformat)
      m.callback() -- re-enable globally; must also drop the buffer flag
      assert.is_false(vim.g.disable_autoformat)
      assert.is_false(vim.b.disable_autoformat)
    end)
  end)
end)
