local nvim_env = require("tests.helpers.nvim_env")

describe("smoke: boot", function()
  local root

  before_each(function()
    root = nvim_env.setup_isolated_env()
  end)

  after_each(function()
    nvim_env.teardown(root)
  end)

  it("init loads with no Vim errors in :messages", function()
    local output = vim.api.nvim_exec2("messages", { output = true }).output
    for line in (output or ""):gmatch("[^\r\n]+") do
      assert.is_nil(line:match("^E%d+:"), "unexpected vim error in :messages: " .. line)
    end
  end)

  describe("config modules require cleanly", function()
    local modules = {
      "config.options",
      "config.lsp_refs",
      "config.review_base",
      "config.telescope_smart",
    }
    for _, name in ipairs(modules) do
      it("requires " .. name, function()
        package.loaded[name] = nil
        local ok, err = pcall(require, name)
        assert.is_true(ok, "failed to require " .. name .. ": " .. tostring(err))
      end)
    end
  end)

  it("no plugin reports failure", function()
    local lazy_plugin = require("lazy.core.plugin")
    local plugins = require("lazy.core.config").plugins
    local failed = {}
    for name, plugin in pairs(plugins) do
      if lazy_plugin.has_errors(plugin) then
        failed[#failed + 1] = name
      end
    end
    assert.are.same({}, failed)
  end)

  describe("globally-registered keymaps", function()
    local expected_descriptions = {
      "Find files",
      "Live grep",
      "Buffers",
      "Help tags",
      "Recent files",
      "Grep word under cursor",
      "Diagnostics",
      "Keymaps",
      "Keymaps reference",
      "Commands",
      "Fuzzy find in buffer",
      "Git changed files",
      "Review base: pick branch (auto-opens files)",
      "Review base: clear",
      "Diffview: open working tree vs index",
      "Diffview: close",
      "Diffview: repo file history",
      "Diffview: current file history",
      "Diffview: branch vs origin/main",
      "Diffview: toggle file panel",
      "Files (changed first)",
      "File explorer (current file)",
      "File explorer (cwd)",
      "All keymaps (which-key)",
    }

    local function find_normal_keymap_by_desc(desc)
      for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
        if m.desc == desc then
          return m
        end
      end
      return nil
    end

    for _, desc in ipairs(expected_descriptions) do
      it("registers keymap: " .. desc, function()
        assert.is_not_nil(
          find_normal_keymap_by_desc(desc),
          "no normal-mode keymap with desc=" .. vim.inspect(desc)
        )
      end)
    end
  end)
end)
