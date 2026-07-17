-- Extended a/i textobjects. Adds argument (`aa`/`ia`), function-call
-- (`af`/`if`), and a custom dotted-chain object (`ao`/`io`) on top of Neovim's
-- builtins, so a whole `app.property` chain is one motion — pair it with the
-- sibling mini.surround `f` to wrap a symbol: `gsaiof` -> fooFunc(app.property).
--   • The `o` object is filetype-aware (dots everywhere, `::`/`:` for
--     rust/cpp/lua, `?.` for ts/js); the pattern lives in config.dotted_chain
--     so it can be unit-tested without loading the plugin.
--   • Loads on VeryLazy rather than mapping bare `a`/`i` as lazy-load triggers:
--     shimming operator-pending `a`/`i` is invasive for a plugin this small.
-- version = false matches mini.pairs/mini.surround — the mini.* monorepo ships
-- no semver tags, so pin to the default branch via lazy-lock.json.
return {
  "echasnovski/mini.ai",
  version = false,
  event = "VeryLazy",
  opts = {
    custom_textobjects = {
      -- Callable spec: mini.ai evaluates it at textobject time in the current
      -- buffer, so vim.bo.filetype resolves correctly with no FileType autocmd.
      o = function()
        return require("config.dotted_chain").spec(vim.bo.filetype)
      end,
    },
  },
}
