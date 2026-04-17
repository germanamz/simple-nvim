-- LSP stack: native vim.lsp.config (Neovim 0.11+) + mason.nvim for binaries.
--   • Mason installs server binaries into stdpath("data")/mason.
--   • mason-lspconfig drives ensure_installed.
--   • vim.lsp.config(name, {...}) registers each server; vim.lsp.enable(name)
--     activates it. The server's `filetypes` list gates attach per buffer, so
--     a server only starts when a matching filetype is opened.
local servers = {
  ts_ls         = { filetypes = { "typescript", "typescriptreact", "javascript", "javascriptreact" } },
  pyright       = { filetypes = { "python" } },
  gopls         = { filetypes = { "go", "gomod", "gosum", "gowork" } },
  rust_analyzer = { filetypes = { "rust" } },
  lua_ls        = {
    filetypes = { "lua" },
    settings = {
      Lua = {
        runtime     = { version = "LuaJIT" },
        diagnostics = { globals = { "vim" } },
        workspace   = {
          library = vim.api.nvim_get_runtime_file("", true),
          checkThirdParty = false,
        },
        telemetry = { enable = false },
      },
    },
  },
  bashls   = { filetypes = { "sh", "bash" } },
  jsonls   = { filetypes = { "json", "jsonc" } },
  yamlls   = { filetypes = { "yaml" } },
  taplo    = { filetypes = { "toml" } },
  html     = { filetypes = { "html" } },
  cssls    = { filetypes = { "css", "scss", "less" } },
  marksman = { filetypes = { "markdown" } },
}

-- Buffer-local LSP keymaps. `gd` overrides netrw's `gd` only where LSP attaches.
-- `]d` / `[d` come free from Neovim 0.11 defaults, so only the non-default
-- mappings are declared here.
vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(args)
    local opts = { buffer = args.buf, silent = true }
    vim.keymap.set("n", "gd",        vim.lsp.buf.definition,    opts)
    vim.keymap.set("n", "<leader>e", vim.diagnostic.open_float, opts)
  end,
})

return {
  {
    "mason-org/mason.nvim",
    lazy = false,
    build = ":MasonUpdate",
    config = function()
      require("mason").setup()
    end,
  },
  {
    "mason-org/mason-lspconfig.nvim",
    lazy = false,
    dependencies = { "mason-org/mason.nvim" },
    config = function()
      local server_names = vim.tbl_keys(servers)

      require("mason-lspconfig").setup({
        ensure_installed = server_names,
        automatic_installation = false,
      })

      for name, cfg in pairs(servers) do
        vim.lsp.config(name, cfg)
        vim.lsp.enable(name)
      end
    end,
  },
}
