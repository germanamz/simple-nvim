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
      -- parser-revisions.lua is the single source of truth for WHICH parsers we
      -- install and at WHAT revision: we install exactly the pinned set, so a
      -- parser can never be downloaded without a pin (the drift that once left
      -- `latex` installed, unpinned, and wired to nothing). See
      -- lua/config/ts_pinned.lua for why pinning can't be a per-call arg. tests/
      -- isn't on package.path during normal startup (only the test harness
      -- prepends it), so load by absolute path.
      local revisions = dofile(vim.fn.stdpath("config") .. "/tests/parser-revisions.lua")
      require("config.ts_pinned").apply(revisions)
      require("nvim-treesitter").install(vim.tbl_keys(revisions))

      -- Global filetype → parser registration. Downstream consumers resolve
      -- parser via this registry, not via our ad-hoc `ft_to_lang` table below.
      -- mdx has no dedicated parser, so reuse markdown.
      vim.treesitter.language.register("markdown", "mdx")
      -- jsonc has no dedicated parser; the json parser handles it.
      vim.treesitter.language.register("json", "jsonc")
      -- Go html templates (.tmpl, ft=gohtmltmpl from init.lua) reuse the html
      -- parser so tags highlight and nvim-ts-autotag can walk the tree. Go
      -- `{{ ... }}` actions fall through as plain text — fine for editing tags.
      vim.treesitter.language.register("html", "gohtmltmpl")

      -- filetype → parser language mapping (only where they differ)
      local ft_to_lang = {
        typescriptreact = "tsx",
        javascriptreact = "javascript",
        sh = "bash",
        mdx = "markdown",
        jsonc = "json",
        gohtmltmpl = "html",
        -- ft "help" is parsed by the vimdoc parser; without this, start() is
        -- called with the nonexistent "help" lang and the fold/indent wiring is
        -- silently skipped (core still TS-highlights help via its own ftplugin).
        help = "vimdoc",
      }

      local ft_pattern = {
        "markdown",
        "mdx",
        "typescript",
        "typescriptreact",
        "javascript",
        "javascriptreact",
        "python",
        "go",
        "gomod",
        "gosum",
        "gowork",
        "rust",
        "c",
        "cpp",
        "lua",
        "vim",
        "help",
        "sh",
        "bash",
        "json",
        "jsonc",
        "yaml",
        "toml",
        "html",
        "gohtmltmpl",
        "css",
      }

      vim.api.nvim_create_autocmd("FileType", {
        pattern = ft_pattern,
        callback = function(args)
          -- Large-file guard. treesitter highlight + the foldexpr's first
          -- whole-buffer parse can stall for seconds on the giant generated /
          -- vendored files a polyglot superproject is full of (bundled JS,
          -- *.pb.go, minified assets, sqlite3.c) — exactly the files you land in
          -- by accident via a grep hit or definition jump. Past the shared
          -- threshold (util.largefile), skip TS entirely (start + fold/indent
          -- wiring together, no half-wired state) and fall back to regex syntax
          -- + core indent.
          if require("util.largefile").is_large(args.buf) then
            return
          end
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
