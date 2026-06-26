-- Completion popup via blink.cmp.
--   • version "1.*" pulls a prebuilt Rust fuzzy-matcher binary, so no
--     make/cargo toolchain is needed at install time.
--   • No snippets source (and no friendly-snippets dep): lsp, path and buffer
--     feed the menu, plus lazydev's require-path source in lua buffers (this
--     config is lua, so module-path completion is the common case there).
--   • blink's completion capabilities are advertised to the LSP servers from
--     lua/plugins/lsp.lua, where blink is listed as a dependency of
--     mason-lspconfig so it loads before the servers are enabled (capabilities
--     are resolved at attach time, which can happen on FileType before
--     InsertEnter — hence dependency-loaded, not event-gated on InsertEnter).
return {
  "saghen/blink.cmp",
  version = "1.*",
  lazy = true,
  opts = {
    -- "enter" preset: Enter accepts, C-space opens the menu, C-n/C-p (and the
    -- arrow keys) move the selection, C-e hides. Tab is added on top so it also
    -- accepts when the menu is open and falls back to a normal Tab otherwise.
    keymap = {
      preset = "enter",
      ["<Tab>"] = { "accept", "fallback" },
    },
    appearance = { nerd_font_variant = "mono" },
    sources = {
      default = { "lsp", "path", "buffer" },
      -- lazydev (loaded on ft=lua) completes require() module paths; rank it
      -- ahead via score_offset so its entries sort above buffer words.
      per_filetype = { lua = { "lazydev", "lsp", "path", "buffer" } },
      providers = {
        lazydev = { name = "LazyDev", module = "lazydev.integrations.blink", score_offset = 100 },
      },
    },
    completion = {
      documentation = { auto_show = true, auto_show_delay_ms = 200 },
      -- Don't append "()" when accepting a function/method from the menu.
      -- Closing pairs are instead added only when typed explicitly, via
      -- mini.pairs (see lua/plugins/mini-pairs.lua).
      accept = { auto_brackets = { enabled = false } },
    },
    signature = { enabled = true },
  },
}
