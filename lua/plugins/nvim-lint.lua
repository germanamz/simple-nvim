-- ESLint diagnostics: on save, and again when the file is rewritten under you.
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
--
-- Zig is not here either, for a different reason: nvim-lint DOES ship a `zig`
-- linter (`zig ast-check`), and zls runs that same check internally and
-- publishes the result, so wiring it would put two identical diagnostics on
-- every line. Adding it later needs a filename guard, not a filetype one —
-- Neovim maps .zon to ft=zig and `ast-check` rejects a build.zig.zon outright
-- ("file cannot be a tuple"). See docs/zig.md.
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

    -- Extensions rather than Neovim filetypes because both consumers below want
    -- filenames: BufWritePost matches globs, and the reload edge has to do the
    -- match itself — a `User` autocmd's pattern is the EVENT name, so every
    -- reloaded buffer arrives there whatever it holds, and js_toolchain.resolve
    -- answers from the buffer's DIRECTORY and would happily hand a README.md
    -- sitting in an eslint repo to eslint_d. One list feeds both edges so they
    -- cannot drift apart; every entry is a plain `*.ext` glob, which is why an
    -- extension compare is exactly equivalent to the pattern match.
    local EXTENSIONS = { "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts" }

    local globs = vim.tbl_map(function(ext)
      return "*." .. ext
    end, EXTENSIONS)

    local function lintable(bufnr)
      local ext = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":e")
      return vim.tbl_contains(EXTENSIONS, ext)
    end

    -- The only vim.diagnostic.reset in this config, and it has to exist: eslint
    -- paint otherwise outlives every reason for it. The store is dropped only on
    -- BufWipeout, and the display extmarks SURVIVE a reload because Neovim
    -- re-anchors them to the new lines — so a sign from the pre-fix text does not
    -- vanish when the file is rewritten underneath the buffer, it slides onto an
    -- unrelated line, which is worse than a stale sign because it reads as a
    -- fresh one. Every path that ends without a new pass erases the old one.
    --
    -- get_namespace is nvim-lint's own accessor (lint.lua) rather than a
    -- hand-rolled nvim_create_namespace("eslint_d"): its namespace table is keyed
    -- on `linter.name`, which try_lint fills in from the requested name, and
    -- reproducing that key here would be a guess that stays correct only by luck.
    local function drop_diagnostics(bufnr)
      vim.diagnostic.reset(require("lint").get_namespace("eslint_d"), bufnr)
    end

    --- Run — or deliberately decline to run — eslint_d over `bufnr`.
    ---
    --- `stale` says the buffer's TEXT changed with no pass of ours behind it, so
    --- the previous result describes lines that no longer exist. It erases before
    --- re-running rather than letting try_lint overwrite: the pass is
    --- asynchronous (nvim-lint spawns the daemon and returns), so the old marks
    --- would otherwise sit there mis-anchored for as long as eslint_d takes to
    --- answer — and forever if this buffer's project turns out not to answer at
    --- all.
    ---@param bufnr integer
    ---@param stale boolean
    local function lint_buf(bufnr, stale)
      -- Same guard conform's format-on-save uses: a multi-MB generated bundle
      -- would stall the daemon and paint thousands of diagnostics. Erasing
      -- instead of returning bare because a buffer only just over the bound is
      -- still carrying the diagnostics from when it was under it.
      if require("util.largefile").is_large(bufnr) then
        drop_diagnostics(bufnr)
        return
      end
      -- Same reasoning when a project switches to biome or oxlint, or its eslint
      -- config is deleted: the abandoned ESLint result would stay painted
      -- underneath whatever the new tool reports.
      if require("config.js_toolchain").resolve(bufnr).linter ~= "eslint" then
        drop_diagnostics(bufnr)
        return
      end
      if stale then
        drop_diagnostics(bufnr)
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
      -- nvim_get_current_buf() (lint.lua). Neither edge can promise the buffer
      -- it was raised for is the focused one — BufWritePost fires for a
      -- background buffer under `:bufdo w`, and a reload sweep is mostly about
      -- HIDDEN buffers by construction — and there we would gate on one file's
      -- project and then paint its diagnostics onto whatever is on screen.
      -- nvim_buf_call makes the gated buffer the one nvim-lint sees.
      vim.api.nvim_buf_call(bufnr, function()
        require("lint").try_lint("eslint_d", { cwd = cwd })
      end)
    end

    local group = vim.api.nvim_create_augroup("nvim_lint_js", { clear = true })

    -- No linters_by_ft: which linter applies is a property of the PROJECT, not the
    -- filetype, so the decision is made per buffer at save time from
    -- config.js_toolchain. A biome repo never reaches try_lint at all.
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = group,
      pattern = globs,
      callback = function(args)
        lint_buf(args.buf, false)
      end,
    })

    -- The second edge: an agent, a CLI formatter or a `git checkout` rewrote the
    -- file and lua/config/file_reload.lua re-read it. A reload fires
    -- BufReadPre/BufReadPost/FileType/FileChangedShellPost and NO BufWritePost
    -- (measured), so before this the buffer showed the corrected text carrying
    -- the diagnostics of the text it replaced.
    --
    -- Hooked on file_reload's own event rather than on a reload edge guessed at
    -- here, because FileChangedShellPost is the only one that fires solely after
    -- a reload really happened — a conflict or a deletion stops at
    -- FileChangedShell — and file_reload already owns that distinction.
    --
    -- Deliberately NOT BufReadPost, which would catch reloads too: that also
    -- lints every JS file the moment it is opened, so every grep hit and every
    -- definition jump costs a daemon pass. Diagnostics land on save here.
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "FileReloaded",
      callback = function(args)
        local bufnr = args.data and args.data.buf
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) and lintable(bufnr) then
          lint_buf(bufnr, true)
        end
      end,
    })
  end,
}
