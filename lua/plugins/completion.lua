-- Completion popup via blink.cmp.
--   • version "1.*" pulls a prebuilt Rust fuzzy-matcher binary, so no
--     make/cargo toolchain is needed at install time.
--   • No snippets source (and no friendly-snippets dep): only lsp, path and
--     buffer feed the menu.
--   • blink's completion capabilities are advertised to the LSP servers from
--     lua/plugins/lsp.lua, where blink is listed as a dependency so it loads
--     before the servers are enabled (capabilities are resolved at attach time,
--     which can happen on FileType before InsertEnter — hence not lazy here).
return {
  "saghen/blink.cmp",
  version = "1.*",
  opts = {
    -- "enter" preset: Enter accepts, C-space opens the menu, C-n/C-p (and the
    -- arrow keys) move the selection, C-e hides. Tab is added on top so it also
    -- accepts when the menu is open and falls back to a normal Tab otherwise.
    keymap = {
      preset = "enter",
      ["<Tab>"] = { "accept", "fallback" },
    },
    appearance = { nerd_font_variant = "mono" },
    sources = { default = { "lsp", "path", "buffer" } },
    completion = {
      documentation = { auto_show = true, auto_show_delay_ms = 200 },
    },
    signature = { enabled = true },
  },
}
