-- Lua LSP setup for editing this config: lazydev feeds lua_ls type
-- definitions for the Neovim runtime and for plugin modules on demand, as
-- files actually require() them. Replaces the old approach of stuffing the
-- entire runtime (nvim_get_runtime_file("", true)) into workspace.library,
-- which made lua_ls index every installed plugin on attach — slow to attach
-- and memory-hungry.
return {
  "folke/lazydev.nvim",
  ft = "lua",
  opts = {
    library = {
      -- vim.uv typings, loaded only when a file mentions vim.uv.
      { path = "${3rd}/luv/library", words = { "vim%.uv" } },
    },
  },
}
