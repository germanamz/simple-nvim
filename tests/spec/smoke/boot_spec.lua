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
    local keymap_probe = require("tests.helpers.keymap_probe")

    -- Keyed on lhs (the stable contract), not desc text: a cosmetic label edit
    -- shouldn't fail the smoke suite. desc here is documentation for the test
    -- name; we assert a desc *exists* (so a blanked label is caught) but not its
    -- exact wording — that's a which-key UX label, intentionally free to change.
    local expected = {
      { lhs = "<leader>ff", desc = "Find files" },
      { lhs = "<leader>fg", desc = "Live grep (project root)" },
      { lhs = "<leader>fb", desc = "Buffers" },
      { lhs = "<leader>fh", desc = "Help tags" },
      { lhs = "<leader>fr", desc = "Recent files (cwd)" },
      { lhs = "<leader>fs", desc = "Grep word under cursor (project root)" },
      { lhs = "<leader>fd", desc = "Diagnostics" },
      { lhs = "<leader>?", desc = "Keymaps" },
      { lhs = "<leader>fc", desc = "Commands" },
      { lhs = "<leader>f/", desc = "Fuzzy find in buffer" },
      { lhs = "<leader>gs", desc = "Changed files (worktree + vs base)" },
      { lhs = "<leader>gB", desc = "Review base: pick branch (auto-opens files)" },
      { lhs = "<leader>gX", desc = "Review base: clear" },
      { lhs = "<leader><space>", desc = "Files (changed first)" },
      { lhs = "<leader>K", desc = "All keymaps (which-key)" },
    }

    -- Expand <leader>/<space> the way nvim_get_keymap reports lhs.
    local function resolve_lhs(spec)
      local leader = vim.g.mapleader or "\\"
      return (spec:gsub("<leader>", leader):gsub("<[Ss]pace>", " "))
    end

    local function desc_of(lhs)
      for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
        if m.lhs == lhs then
          return m.desc
        end
      end
      return nil
    end

    for _, e in ipairs(expected) do
      it("registers " .. e.lhs .. " (" .. e.desc .. ")", function()
        local lhs = resolve_lhs(e.lhs)
        local m = keymap_probe.resolve("n", lhs)
        assert.is_not_nil(m, "no normal-mode keymap with lhs=" .. vim.inspect(lhs))
        assert.is_true(
          m.callback ~= nil or (m.rhs ~= nil and m.rhs ~= ""),
          e.lhs .. " resolves to neither a callback nor an rhs"
        )
        local desc = desc_of(lhs)
        assert.is_true(desc ~= nil and desc ~= "", "missing desc for " .. e.lhs)
      end)
    end
  end)
end)
