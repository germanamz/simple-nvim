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
    -- arrow keys) move the selection, C-e hides. Tab is AI-first: if minuet has
    -- an inline suggestion painted it accepts that (and stops); otherwise it
    -- accepts the blink menu selection, else falls back to a literal Tab. The
    -- function runs in blink's insert-mode keymap runner, where a truthy return
    -- means "handled, stop here" and nil/false falls through to the next entry
    -- ("accept" then "fallback") — see saghen/blink.cmp keymap/apply.lua.
    keymap = {
      preset = "enter",
      ["<Tab>"] = {
        -- pcall the require + call so this map is safe before minuet lazy-loads
        -- (it is event=InsertEnter): with no minuet there is no suggestion, so we
        -- return nil and fall through. is_visible()/accept() are minuet's
        -- confirmed virtual-text API (minuet-ai.nvim virtualtext.lua action.*).
        function()
          local ok, vt = pcall(require, "minuet.virtualtext")
          if not ok then
            return
          end
          local visible_ok, visible = pcall(vt.action.is_visible)
          if visible_ok and visible then
            pcall(vt.action.accept)
            return true
          end
        end,
        "accept",
        "fallback",
      },
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
      -- Inline ghost text is OFF here because the AI layer owns the inline
      -- preview while AI completions are enabled (the default) — minuet virtual
      -- text, see lua/plugins/minuet.lua + lua/config/ai.lua. Toggling AI off via
      -- <leader>ua flips this leaf back to true at runtime (config.ai.apply
      -- mutates blink.cmp.config completion.ghost_text.enabled, which blink's
      -- renderer reads live) so blink's own LSP ghost text returns.
      ghost_text = { enabled = false },
      menu = { border = "rounded" },
    },
    signature = { enabled = true, window = { border = "rounded" } },
  },
}
