-- LSP stack: native vim.lsp.config (Neovim 0.11+) + mason.nvim for binaries.
--   • Mason installs server binaries into stdpath("data")/mason.
--   • mason-lspconfig drives ensure_installed.
--   • vim.lsp.config(name, {...}) registers each server; vim.lsp.enable(name)
--     activates it. The server's `filetypes` list gates attach per buffer, so
--     a server only starts when a matching filetype is opened.
local servers = {
  ts_ls         = { filetypes = { "typescript", "typescriptreact", "javascript", "javascriptreact" } },
  pyright       = { filetypes = { "python" } },
  gopls         = { filetypes = { "go", "gomod" } },
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
  marksman      = { filetypes = { "markdown" } },
  -- mdx_analyzer wraps tsserver, needs typescript lib. Falls back to
  -- mason's bundled typescript when the workspace has no node_modules.
  mdx_analyzer  = {
    filetypes = { "mdx" },
    init_options = {
      typescript = {
        tsdk = vim.fn.stdpath("data") .. "/mason/packages/typescript-language-server/node_modules/typescript/lib",
      },
    },
  },
}

-- Buffer-local LSP keymaps. `gd` overrides netrw's `gd` only where LSP attaches.
-- `]d` / `[d` come free from Neovim 0.11 defaults, so only the non-default
-- mappings are declared here.
--
-- TypeScript note: plain `textDocument/definition` on an imported symbol lands
-- on the import binding, not the real source. ts_ls exposes a custom command
-- `_typescript.goToSourceDefinition` that follows imports through to the
-- defining file; we prefer it for ts_ls buffers and fall back to the standard
-- definition if it returns nothing.
local function ts_goto_source_definition(client, bufnr)
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  client:request("workspace/executeCommand", {
    command = "_typescript.goToSourceDefinition",
    arguments = { params.textDocument.uri, params.position },
  }, function(err, result)
    if err or not result or vim.tbl_isempty(result) then
      vim.lsp.buf.definition()
      return
    end
    vim.lsp.util.show_document(result[1], client.offset_encoding, { focus = true })
  end, bufnr)
end

vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    local function map(lhs, rhs, desc)
      vim.keymap.set("n", lhs, rhs, { buffer = args.buf, silent = true, desc = desc })
    end

    if client and client.name == "ts_ls" then
      map("gd", function() ts_goto_source_definition(client, args.buf) end, "Goto source definition (ts_ls)")
    else
      map("gd", vim.lsp.buf.definition, "Goto definition")
    end
    map("<leader>e", vim.diagnostic.open_float, "Show diagnostic float")

    local lsp_refs = require("config.lsp_refs")
    map("]r", lsp_refs.next, "Next LSP reference")
    map("[r", lsp_refs.prev, "Prev LSP reference")
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
    -- nvim-lspconfig ships default `lsp/<name>.lua` files (including `cmd`)
    -- that vim.lsp.config merges with our per-server overrides. Without it,
    -- `vim.lsp.config("gopls", {...})` errors out because `cmd` is nil.
    "neovim/nvim-lspconfig",
    lazy = false,
  },
  {
    "mason-org/mason-lspconfig.nvim",
    lazy = false,
    dependencies = { "mason-org/mason.nvim", "neovim/nvim-lspconfig" },
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
