-- GitHub Light (high-contrast) colorscheme. Replaces Neovim's built-in default
-- scheme: github_light_high_contrast gives every language rich, distinct token
-- colors (treesitter + LSP semantic tokens) out of the box, which is the whole
-- readability goal. The config is light-only — background is locked to light in
-- config.options, and the custom highlight overrides (gitsigns diff tints,
-- SmartFiles* status colors, block guides, …) re-assert themselves on the
-- ColorScheme event this fires.
return {
  "projekt0n/github-nvim-theme",
  name = "github-theme",
  -- lazy=false + the top priority so the theme paints before any other plugin
  -- loads and its single ColorScheme event lands after the eager config modules
  -- required in init.lua (their ColorScheme autocmds then re-apply on top).
  lazy = false,
  priority = 1000,
  config = function()
    -- Plain defaults: no italic/bold style overrides, no palette overrides — we
    -- adopt the variant's token colors as-is.
    require("github-theme").setup({})
    vim.cmd.colorscheme("github_light_high_contrast")
  end,
}
