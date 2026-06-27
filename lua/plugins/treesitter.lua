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

      -- Global filetype → parser registration: the single source of truth for
      -- which parser a filetype resolves to. The FileType handler below starts
      -- TS with NO explicit lang and lets core resolve through this registry, so
      -- there is no second ad-hoc mapping table to drift out of sync. Core
      -- already self-resolves an unregistered ft to a same-named parser and
      -- knows help→vimdoc, so we only register the fts whose parser differs AND
      -- that core doesn't already know.
      -- mdx has no dedicated parser, so reuse markdown.
      vim.treesitter.language.register("markdown", "mdx")
      -- jsonc has no dedicated parser; the json parser handles it.
      vim.treesitter.language.register("json", "jsonc")
      -- Go html templates (.tmpl, ft=gohtmltmpl from init.lua) reuse the html
      -- parser so tags highlight and nvim-ts-autotag can walk the tree. Go
      -- `{{ ... }}` actions fall through as plain text — fine for editing tags.
      vim.treesitter.language.register("html", "gohtmltmpl")
      -- React fts and `sh` aren't core-registered (their parsers are tsx /
      -- javascript / bash); without these, start() would resolve a nonexistent
      -- same-named parser and the fold/indent wiring would be silently skipped.
      vim.treesitter.language.register("tsx", "typescriptreact")
      vim.treesitter.language.register("javascript", "javascriptreact")
      vim.treesitter.language.register("bash", "sh")
      -- The parser is named git_config; the filetype Neovim sets is gitconfig.
      vim.treesitter.language.register("git_config", "gitconfig")

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
        "gitconfig",
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
          -- start() with no explicit lang lets core resolve the parser through
          -- the registry above. Skip the redundant start for fts $VIMRUNTIME
          -- ftplugins already highlight (lua/markdown/help): if a highlighter is
          -- already active, treat TS as started and just layer our fold/indent
          -- wiring on top instead of re-doing core's bookkeeping. Relies on the
          -- semi-internal highlighter.active field and on this autocmd running
          -- after core's filetypeplugin autocmd — true under default startup
          -- ordering. Folds still get wired everywhere.
          local ok = vim.treesitter.highlighter.active[args.buf] ~= nil
            or pcall(vim.treesitter.start, args.buf)
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
      -- auto:1 instead of a fixed "1" so fold-less buffers (non-TS, large-file
      -- skipped, plain text) don't reserve a permanent blank gutter; TS buffers
      -- still get a 1-col gutter showing fold structure.
      vim.opt.foldcolumn = "auto:1"
    end,
  },
}
