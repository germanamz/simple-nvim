-- Completion popup via blink.cmp.
--   • version "1.*" pulls a prebuilt Rust fuzzy-matcher binary, so no
--     make/cargo toolchain is needed at install time.
--   • Snippets are enabled for the typed/markup filetypes via blink's built-in
--     "snippets" source backed by friendly-snippets — go/python/ts/js/tsx/jsx
--     and markdown/mdx all benefit from boilerplate expansion. lua stays
--     snippet-free on purpose: this config is itself lua and lazydev's
--     require-path source is the common case there, not text snippets.
--   • blink's completion capabilities are advertised to the LSP servers from
--     lua/plugins/lsp.lua, where blink is listed as a dependency of
--     mason-lspconfig so it loads before the servers are enabled (capabilities
--     are resolved at attach time, which can happen on FileType before
--     InsertEnter — hence dependency-loaded, not event-gated on InsertEnter).
return {
  "saghen/blink.cmp",
  version = "1.*",
  lazy = true,
  -- friendly-snippets supplies the VS Code-style snippet collections that
  -- blink's built-in "snippets" source reads (needs :Lazy sync to fetch).
  dependencies = { "rafamadriz/friendly-snippets" },
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
      -- ahead via score_offset so its entries sort above buffer words. lua keeps
      -- no "snippets" source — see the header for why.
      per_filetype = {
        lua = { "lazydev", "lsp", "path", "buffer" },
        -- Prepend "snippets" for the typed/markup fts so friendly-snippets
        -- expansions sort first, ahead of lsp/path/buffer matches.
        go = { "snippets", "lsp", "path", "buffer" },
        python = { "snippets", "lsp", "path", "buffer" },
        typescript = { "snippets", "lsp", "path", "buffer" },
        typescriptreact = { "snippets", "lsp", "path", "buffer" },
        javascript = { "snippets", "lsp", "path", "buffer" },
        javascriptreact = { "snippets", "lsp", "path", "buffer" },
        markdown = { "snippets", "lsp", "path", "buffer" },
        mdx = { "snippets", "lsp", "path", "buffer" },
      },
      providers = {
        lazydev = { name = "LazyDev", module = "lazydev.integrations.blink", score_offset = 100 },
      },
    },
    completion = {
      documentation = {
        auto_show = true,
        auto_show_delay_ms = 200,
        window = { border = "rounded" },
      },
      -- Don't append "()" when accepting a function/method from the menu.
      -- Closing pairs are instead added only when typed explicitly, via
      -- mini.pairs (see lua/plugins/mini-pairs.lua).
      accept = { auto_brackets = { enabled = false } },
      -- Inline ghost text previews the top candidate at the cursor before you
      -- commit, and rounded borders keep the float legible on themes with weak
      -- float backgrounds (the menu/doc/signature popups otherwise bleed in).
      ghost_text = { enabled = true },
      menu = { border = "rounded" },
    },
    signature = { enabled = true, window = { border = "rounded" } },
  },
}
