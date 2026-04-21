-- nvim-treesitter `main` branch — new API for Neovim 0.11+
-- Differences vs master:
--   • no `configs.setup({...})` — you call `vim.treesitter.start()` per buffer
--   • parsers installed via `require("nvim-treesitter").install({...})`
--   • no `highlight`/`indent` modules; indent handled by nvim core
return {
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    lazy = false,
    build = ":TSUpdate",
    config = function()
      local parsers = {
        "markdown", "markdown_inline",
        "typescript", "tsx", "javascript", "jsdoc",
        "python",
        "go", "gomod", "gosum", "gowork",
        "rust",
        "lua", "luadoc", "vim", "vimdoc", "query",
        "bash", "json", "yaml", "toml",
        "html", "css", "regex", "diff", "git_config",
      }

      require("nvim-treesitter").install(parsers)

      -- Global filetype → parser registration. Downstream plugins
      -- (render-markdown, etc.) resolve parser via this registry, not via
      -- our ad-hoc `ft_to_lang` table below. mdx has no dedicated parser,
      -- so reuse markdown.
      vim.treesitter.language.register("markdown", "mdx")
      -- jsonc has no dedicated parser; the json parser handles it.
      vim.treesitter.language.register("json", "jsonc")

      -- filetype → parser language mapping (only where they differ)
      local ft_to_lang = {
        typescriptreact = "tsx",
        javascriptreact = "javascript",
        sh              = "bash",
        mdx             = "markdown",
        jsonc           = "json",
      }

      local ft_pattern = {
        "markdown", "mdx",
        "typescript", "typescriptreact", "javascript", "javascriptreact",
        "python",
        "go", "gomod", "gosum", "gowork",
        "rust",
        "lua", "vim", "help",
        "sh", "bash", "json", "jsonc", "yaml", "toml",
        "html", "css",
      }

      vim.api.nvim_create_autocmd("FileType", {
        pattern = ft_pattern,
        callback = function(args)
          local ft = vim.bo[args.buf].filetype
          local lang = ft_to_lang[ft] or ft
          local ok = pcall(vim.treesitter.start, args.buf, lang)
          if ok then
            vim.wo.foldmethod = "expr"
            vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"
            vim.bo[args.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
          end
        end,
      })

      -- fold defaults — start fully unfolded
      vim.opt.foldenable = true
      vim.opt.foldlevel = 99
      vim.opt.foldlevelstart = 99
      vim.opt.foldcolumn = "1"
    end,
  },
}
