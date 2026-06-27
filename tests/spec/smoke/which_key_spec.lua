local nvim_env = require("tests.helpers.nvim_env")

describe("smoke: which-key keybinding documentation", function()
  local root

  before_each(function()
    root = nvim_env.setup_isolated_env()
  end)

  after_each(function()
    nvim_env.teardown(root)
  end)

  -- The intended named groups for every `<leader>` (and `gs`) prefix namespace.
  -- which-key shows these as the section titles in the popup; without them the
  -- chord menu reads as a bare prefix. Pinned here so a dropped/renamed group
  -- (including the buffer-local-only `lsp`/`markdown` groups that never surface
  -- in the global keymap table) fails loudly instead of silently degrading.
  local EXPECTED_GROUPS = {
    ["<leader>b"] = "buffer",
    ["<leader>f"] = "find",
    ["<leader>g"] = "git",
    ["<leader>h"] = "hunks",
    ["<leader>k"] = "keys",
    ["<leader>l"] = "lsp",
    ["<leader>m"] = "markdown",
    ["<leader>q"] = "quit",
    ["<leader>u"] = "toggle",
    ["gs"] = "surround",
  }

  local function spec_by_lhs()
    local spec = require("plugins.which-key")[1].opts.spec
    local by_lhs = {}
    for _, entry in ipairs(spec) do
      by_lhs[entry[1]] = entry
    end
    return by_lhs
  end

  -- Every mapping the config defines under `<leader>` must carry a `desc`, or
  -- the which-key popup falls back to a raw rhs / `<Lua function>` reference.
  -- lazy.nvim registers each `keys` trigger with its desc (so the label shows
  -- before the plugin even loads) and the rest are set with explicit descs, so
  -- the whole leader namespace should be documented at startup. This is the
  -- core "all keybindings are documented" guard: add a leader map without a
  -- desc anywhere and this fails.
  it("documents every global leader mapping with a desc", function()
    local undocumented = {}
    for _, mode in ipairs({ "n", "x" }) do
      for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
        local lhs = m.lhs or ""
        -- leader == <Space>; nvim_get_keymap renders it as a literal " " prefix.
        -- `#lhs > 1` skips a lone leader (not a real binding).
        if lhs:sub(1, 1) == " " and #lhs > 1 then
          if not m.desc or m.desc == "" then
            table.insert(undocumented, mode .. " " .. vim.fn.keytrans(lhs))
          end
        end
      end
    end
    assert.are.same({}, undocumented)
  end)

  -- Every leader prefix that actually has child mappings must be declared as a
  -- named group, so the popup never shows an unlabeled chord prefix. Derived
  -- from the live global keymaps so a *new* group introduced without a label is
  -- caught (buffer-local-only groups are covered by the static check below).
  it("labels every in-use leader group prefix", function()
    local groups = spec_by_lhs()
    local unlabeled = {}
    local seen = {}
    for _, mode in ipairs({ "n", "x" }) do
      for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
        local lhs = m.lhs or ""
        -- leader + group letter + at least one more key => a `<leader>X` group.
        if lhs:sub(1, 1) == " " and #lhs >= 3 then
          local prefix = "<leader>" .. lhs:sub(2, 2)
          local entry = groups[prefix]
          if not seen[prefix] and (not entry or not entry.group or entry.group == "") then
            seen[prefix] = true
            table.insert(unlabeled, prefix)
          end
        end
      end
    end
    table.sort(unlabeled)
    assert.are.same({}, unlabeled)
  end)

  -- Pin the full set of intended group names (covers the lsp/markdown groups
  -- whose members are buffer-local and never appear in the global table above).
  it("declares a named group for every prefix namespace", function()
    local groups = spec_by_lhs()
    for prefix, label in pairs(EXPECTED_GROUPS) do
      local entry = groups[prefix] or {}
      assert.are.equal(label, entry.group, "which-key group missing/renamed for " .. prefix)
    end
  end)

  -- Neovim 0.11 ships the default `gr*` LSP keymaps without a `desc`, so
  -- which-key falls back to the raw Lua function. The plugin spec relabels them
  -- via opts.spec; assert those entries are present so the labels don't silently
  -- regress to function references.
  it("relabels the default gr* LSP keymaps via opts.spec", function()
    local by_lhs = spec_by_lhs()

    assert.are.equal("lsp", (by_lhs["gr"] or {}).group)
    assert.are.equal("Code action", (by_lhs["gra"] or {}).desc)
    assert.are.equal("Rename", (by_lhs["grn"] or {}).desc)
    assert.are.equal("References", (by_lhs["grr"] or {}).desc)
    assert.are.equal("Implementation", (by_lhs["gri"] or {}).desc)
    assert.are.equal("Type definition", (by_lhs["grt"] or {}).desc)
    assert.are.equal("Document symbols", (by_lhs["gO"] or {}).desc)
  end)

  -- The built-in matchit chords (`[%` `]%` `g%`) and the native g/z/<C-w>
  -- motions carry no `desc` on the raw keymap; which-key labels them through
  -- its bundled presets plugin. Guard that those presets stay enabled so the
  -- popup keeps documenting them instead of showing `<Plug>(Matchit…)`.
  it("keeps which-key presets enabled so built-in motions stay labeled", function()
    local presets = require("which-key.config").plugins.presets
    assert.is_true(presets.g)
    assert.is_true(presets.nav)
    assert.is_true(presets.motions)
    assert.is_true(presets.operators)
  end)
end)
