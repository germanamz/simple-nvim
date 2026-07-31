-- ESLint diagnostics, on save.
--
-- Why not a language server: vscode-eslint is Node and starts one process per
-- project root. In a superproject with hundreds of submodules, touching files
-- across them accumulates a process per repo — the cost profile
-- docs/lsp-typescript-version.md and lua/config/lsp_reap.lua already exist to
-- fight. eslint_d is a single shared daemon that caches an ESLint instance per
-- project internally, so the whole workspace costs one process. The trade is that
-- diagnostics land on save rather than as you type, and ESLint's "fix all" code
-- action is unavailable — <leader>F does the equivalent, because eslint_d is also
-- the formatter for eslint-only projects (lua/config/formatters.lua).
--
-- biome and oxlint are NOT here: both are Rust language servers registered in
-- lua/plugins/lsp.lua, where they cost almost nothing per root.
return {
  "mfussenegger/nvim-lint",
  event = { "BufReadPre", "BufNewFile" },
  config = function()
    local lint = require("lint")

    -- nvim-lint's builtin resolves eslint_d from PATH only, which in this setup is
    -- always mason's global copy. conform's builtins prefer the project's own
    -- node_modules/.bin (conform.util.from_node_modules), and the linter must
    -- agree with the formatter about which ESLint is authoritative.
    --
    -- Buffer 0 rather than a threaded bufnr because nvim-lint gives `cmd` no
    -- argument and evaluates it against the buffer try_lint picked, which is
    -- always the current one (lint.lua's `api.nvim_get_current_buf()`). The
    -- callback below makes its own buffer the current one before calling in, so
    -- the two cannot disagree about which project's node_modules to search.
    lint.linters.eslint_d.cmd = function()
      local found = vim.fs.find("node_modules/.bin/eslint_d", {
        upward = true,
        path = vim.fs.dirname(vim.api.nvim_buf_get_name(0)),
      })[1]
      if found and vim.fn.executable(found) == 1 then
        return found
      end
      return "eslint_d"
    end

    -- No linters_by_ft: which linter applies is a property of the PROJECT, not the
    -- filetype, so the decision is made per buffer at save time from
    -- config.js_toolchain. A biome repo never reaches try_lint at all.
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = vim.api.nvim_create_augroup("nvim_lint_js", { clear = true }),
      pattern = { "*.js", "*.jsx", "*.mjs", "*.cjs", "*.ts", "*.tsx", "*.mts", "*.cts" },
      callback = function(args)
        local bufnr = args.buf
        -- Same guard conform's format-on-save uses: a multi-MB generated bundle
        -- would stall the daemon and paint thousands of diagnostics.
        if require("util.largefile").is_large(bufnr) then
          return
        end
        if require("config.js_toolchain").resolve(bufnr).linter ~= "eslint" then
          return
        end

        -- eslint_d caches one ESLint instance per cwd, and flat-config lookup
        -- starts at cwd — so cwd decides which project's rules the pass runs
        -- under. nvim-lint defaults it to the EDITOR's cwd (lint.lua's
        -- `opts.cwd or linter.cwd or vim.fn.getcwd()`), while conform's eslint_d
        -- builtin uses the nearest package.json above the FILE
        -- (conform/formatters/eslint_d.lua's `util.root_file`). With a
        -- superproject open and the buffer in a submodule those are different
        -- projects, and the disagreement is silent: eslint_d answers "Could not
        -- find config file", nvim-lint's parser turns that into {}, and the
        -- buffer gets zero diagnostics that look exactly like a clean file. The
        -- `cmd` override above already fixed this for the binary; this fixes the
        -- other half.
        --
        -- Resolved from the buffer's NAME, not `vim.fs.root(bufnr, ...)`: given
        -- a bufnr, vim.fs.root discards the name and answers uv.cwd() for any
        -- buffer whose buftype is not "" (vim/fs.lua), reintroducing the editor
        -- cwd for exactly the buffers we are keeping it out of. The path form is
        -- also what conform reaches through (its root_file takes ctx.dirname).
        -- nil is a supported cwd — nvim-lint falls back to vim.fn.getcwd() the
        -- way it always did — so an unnamed buffer needs no special handling.
        local name = vim.api.nvim_buf_get_name(bufnr)
        local cwd = nil
        if name ~= "" then
          -- The fallback covers an eslint.config.* with no package.json beside
          -- it: the buffer's own directory is still nearer the project than
          -- wherever the editor happens to be cd'd.
          cwd = vim.fs.root(name, "package.json") or vim.fs.dirname(name)
        end

        -- try_lint takes no bufnr: it lints, and attaches diagnostics to,
        -- nvim_get_current_buf() (lint.lua). BufWritePost usually fires for the
        -- current buffer but not always (`:bufdo w`, a plugin writing a
        -- background buffer), and there we would gate on the saved file's
        -- project and then paint its diagnostics onto whatever is focused.
        -- nvim_buf_call makes the gated buffer the one nvim-lint sees.
        vim.api.nvim_buf_call(bufnr, function()
          require("lint").try_lint("eslint_d", { cwd = cwd })
        end)
      end,
    })
  end,
}
