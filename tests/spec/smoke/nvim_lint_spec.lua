-- Pins the nvim-lint wiring: eslint_d must run on save ONLY where
-- config.js_toolchain resolves the linter slot to eslint, so a biome or oxlint
-- repo never spawns an ESLint pass.
describe("nvim-lint wiring", function()
  it("loads the plugin", function()
    assert.is_true(pcall(require, "lint"))
  end)

  -- Asserting only that `cmd` is a function is satisfied by `return "eslint_d"`
  -- — i.e. by deleting the local-first resolution the override exists for. Call
  -- it and check which binary comes back.
  describe("eslint_d command resolution", function()
    local dir

    before_each(function()
      dir = vim.fn.tempname()
      vim.fn.mkdir(dir .. "/src", "p")
    end)

    after_each(function()
      vim.fn.delete(dir, "rf")
    end)

    -- `cmd` takes no argument: nvim-lint evaluates it against the current
    -- buffer, so the buffer has to actually be current for the call.
    local function cmd_for(relpath)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, dir .. "/" .. relpath)
      local got
      vim.api.nvim_buf_call(buf, function()
        got = require("lint").linters.eslint_d.cmd()
      end)
      vim.api.nvim_buf_delete(buf, { force = true })
      return got
    end

    it("is a function, not a fixed string", function()
      assert.is_function(require("lint").linters.eslint_d.cmd)
    end)

    it("prefers the project's own node_modules/.bin/eslint_d", function()
      vim.fn.mkdir(dir .. "/node_modules/.bin", "p")
      local bin = dir .. "/node_modules/.bin/eslint_d"
      local f = assert(io.open(bin, "w"))
      f:write("#!/bin/sh\nexit 0\n")
      f:close()
      vim.fn.setfperm(bin, "rwxr-xr-x")
      assert.are.equal(vim.fn.resolve(bin), vim.fn.resolve(cmd_for("src/a.ts")))
    end)

    it("falls back to eslint_d on PATH when the project has none", function()
      assert.are.equal("eslint_d", cmd_for("src/a.ts"))
    end)
  end)

  it("creates the BufWritePost autocmd", function()
    local autocmds = vim.api.nvim_get_autocmds({
      group = "nvim_lint_js",
      event = "BufWritePost",
    })
    assert.is_true(#autocmds > 0, "expected a BufWritePost autocmd in nvim_lint_js")
  end)

  -- The three tests above never run the autocmd's callback, so they cannot
  -- catch the one thing this task exists to enforce: eslint_d must NOT fire
  -- outside an eslint-linted project. Fire the real callback with
  -- config.js_toolchain.resolve and lint.try_lint stubbed (same
  -- swap-and-restore shape as lsp_fs_sync_spec's vim.lsp.get_clients stub) so
  -- neither a real project fixture nor a real eslint_d process is needed.
  describe("gate: eslint_d runs only when js_toolchain resolves the eslint linter", function()
    local dir
    local buf
    local orig_resolve
    local orig_try_lint
    local try_lint_calls

    before_each(function()
      dir = vim.fn.tempname()
      vim.fn.mkdir(dir .. "/pkg/src", "p")
      buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, dir .. "/pkg/src/a.ts")
      orig_resolve = require("config.js_toolchain").resolve
      orig_try_lint = require("lint").try_lint
      try_lint_calls = {}
      -- `buf` records which buffer nvim-lint would have linted: try_lint takes
      -- no bufnr and reads nvim_get_current_buf() itself.
      require("lint").try_lint = function(name, opts)
        table.insert(try_lint_calls, { name, opts, buf = vim.api.nvim_get_current_buf() })
      end
    end)

    after_each(function()
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      vim.fn.delete(dir, "rf")
      require("config.js_toolchain").resolve = orig_resolve
      require("lint").try_lint = orig_try_lint
    end)

    it("does not lint when the resolved linter is not eslint", function()
      require("config.js_toolchain").resolve = function()
        return { linter = "biome" }
      end
      vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
      assert.are.equal(0, #try_lint_calls)
    end)

    it("lints with eslint_d when the resolved linter is eslint", function()
      require("config.js_toolchain").resolve = function()
        return { linter = "eslint" }
      end
      vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
      assert.are.equal(1, #try_lint_calls)
      assert.are.equal("eslint_d", try_lint_calls[1][1])
    end)

    -- nvim-lint defaults cwd to the EDITOR's cwd, while conform's eslint_d
    -- builtin uses the nearest package.json above the FILE. Left disagreeing,
    -- a superproject cwd with the buffer in a submodule makes eslint_d resolve
    -- a different project's flat config — and nvim-lint reports the resulting
    -- "Could not find config file" as zero diagnostics, indistinguishable from
    -- a clean file.
    --
    -- `buf` is a scratch buffer, and that is load-bearing: vim.fs.root given a
    -- BUFNR discards the buffer name and answers uv.cwd() for any buftype that
    -- is not "" (vim/fs.lua), so the bufnr form of this lookup fails here in
    -- exactly the way it would fail in the editor for the wrong buffer kinds.
    it("runs eslint_d from the buffer's nearest package.json, not the editor's cwd", function()
      local f = assert(io.open(dir .. "/pkg/package.json", "w"))
      f:write('{"name":"pkg"}\n')
      f:close()
      require("config.js_toolchain").resolve = function()
        return { linter = "eslint" }
      end
      vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
      assert.are.equal(1, #try_lint_calls)
      assert.are.equal(vim.fn.resolve(dir .. "/pkg"), vim.fn.resolve(try_lint_calls[1][2].cwd))
    end)

    it("falls back to the buffer's own directory when there is no package.json", function()
      require("config.js_toolchain").resolve = function()
        return { linter = "eslint" }
      end
      vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
      assert.are.equal(1, #try_lint_calls)
      assert.are.equal(vim.fn.resolve(dir .. "/pkg/src"), vim.fn.resolve(try_lint_calls[1][2].cwd))
    end)

    -- try_lint takes no bufnr and lints nvim_get_current_buf(), so a
    -- BufWritePost raised for a buffer that is not the focused one would gate
    -- on one project and paint another buffer's diagnostics.
    it("lints the buffer the write was for, not whatever is focused", function()
      require("config.js_toolchain").resolve = function()
        return { linter = "eslint" }
      end
      local previous = vim.api.nvim_get_current_buf()
      local other = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(other)
      local ok, err = pcall(vim.api.nvim_exec_autocmds, "BufWritePost", { buffer = buf })
      vim.api.nvim_set_current_buf(previous)
      vim.api.nvim_buf_delete(other, { force = true })
      assert.is_true(ok, tostring(err))
      assert.are.equal(1, #try_lint_calls)
      assert.are.equal(buf, try_lint_calls[1].buf)
    end)
  end)

  -- lua/config/file_reload.lua re-reads buffers whose file changed on disk, and
  -- a reload fires no BufWritePost -- so without a second edge the last save's
  -- diagnostics survive the rewrite. They do not merely go stale: vim.diagnostic
  -- keeps its display extmarks across a reload and Neovim re-anchors them, so an
  -- eslint sign from the pre-fix text ends up sitting on an unrelated line of the
  -- corrected file. That is why the eraser is tested here alongside the trigger.
  describe("external reload edge and the namespace eraser", function()
    local dir
    local buf
    local ns
    local orig_resolve
    local orig_try_lint
    local orig_is_large
    local try_lint_calls

    before_each(function()
      dir = vim.fn.tempname()
      vim.fn.mkdir(dir .. "/pkg/src", "p")
      buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, dir .. "/pkg/src/a.ts")
      ns = require("lint").get_namespace("eslint_d")
      orig_resolve = require("config.js_toolchain").resolve
      orig_try_lint = require("lint").try_lint
      orig_is_large = require("util.largefile").is_large
      try_lint_calls = {}
      require("lint").try_lint = function(name, opts)
        table.insert(try_lint_calls, { name, opts, buf = vim.api.nvim_get_current_buf() })
      end
      -- The default for this block: an eslint project. The gate tests override it.
      require("config.js_toolchain").resolve = function()
        return { linter = "eslint" }
      end
    end)

    after_each(function()
      vim.diagnostic.reset(ns, buf)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      vim.fn.delete(dir, "rf")
      require("config.js_toolchain").resolve = orig_resolve
      require("lint").try_lint = orig_try_lint
      require("util.largefile").is_large = orig_is_large
    end)

    -- Stands in for the previous pass's output. Line 0 because a scratch buffer
    -- has exactly one line and vim.diagnostic drops marks past the end.
    local function paint(target)
      vim.diagnostic.set(ns, target, {
        { lnum = 0, col = 0, message = "stale", severity = vim.diagnostic.severity.ERROR },
      })
      assert.are.equal(1, #vim.diagnostic.get(target, { namespace = ns }), "fixture did not paint")
    end

    local function painted(target)
      return #vim.diagnostic.get(target, { namespace = ns })
    end

    -- Exactly what config.file_reload publishes from FileChangedShellPost.
    local function reloaded(target)
      vim.api.nvim_exec_autocmds("User", {
        pattern = "FileReloaded",
        data = { buf = target },
        modeline = false,
      })
    end

    it("registers on User FileReloaded", function()
      local autocmds = vim.api.nvim_get_autocmds({
        group = "nvim_lint_js",
        event = "User",
        pattern = "FileReloaded",
      })
      assert.is_true(#autocmds > 0, "expected a User FileReloaded autocmd in nvim_lint_js")
    end)

    it("re-lints the reloaded buffer, not whatever is focused", function()
      local previous = vim.api.nvim_get_current_buf()
      local other = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(other)
      local ok, err = pcall(reloaded, buf)
      vim.api.nvim_set_current_buf(previous)
      vim.api.nvim_buf_delete(other, { force = true })
      assert.is_true(ok, tostring(err))
      assert.are.equal(1, #try_lint_calls)
      assert.are.equal("eslint_d", try_lint_calls[1][1])
      assert.are.equal(buf, try_lint_calls[1].buf)
    end)

    -- try_lint is asynchronous: it spawns eslint_d and returns. Leaving the
    -- previous pass painted until the daemon answers is the whole symptom, so
    -- the reload edge has to erase before it re-runs, not after.
    it("erases the previous pass before the async re-lint can answer", function()
      paint(buf)
      reloaded(buf)
      assert.are.equal(1, #try_lint_calls, "expected the re-lint to still run")
      assert.are.equal(0, painted(buf), "stale diagnostics survived the reload")
    end)

    -- A `User` autocmd matches on the event name, so every reloaded buffer
    -- reaches this callback -- and js_toolchain.resolve answers from the
    -- DIRECTORY, never the filetype. A markdown file in an eslint repo would
    -- otherwise be handed to eslint_d.
    it("ignores a reloaded buffer that is not JavaScript or TypeScript", function()
      local md = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(md, dir .. "/pkg/README.md")
      reloaded(md)
      vim.api.nvim_buf_delete(md, { force = true })
      assert.are.equal(0, #try_lint_calls)
    end)

    -- The two gates below used to be bare `return`s. A buffer that stops
    -- qualifying keeps whatever the last qualifying pass painted, forever:
    -- nothing in this config calls vim.diagnostic.reset, and the store is
    -- dropped only on BufWipeout.
    it("erases the paint when the buffer grew past the largefile bound", function()
      require("util.largefile").is_large = function()
        return true
      end
      paint(buf)
      vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
      assert.are.equal(0, #try_lint_calls)
      assert.are.equal(0, painted(buf), "a now-huge buffer kept its eslint diagnostics")
    end)

    it("erases the paint when the project stopped resolving to eslint", function()
      require("config.js_toolchain").resolve = function()
        return { linter = "biome" }
      end
      paint(buf)
      vim.api.nvim_exec_autocmds("BufWritePost", { buffer = buf })
      assert.are.equal(0, #try_lint_calls)
      assert.are.equal(0, painted(buf), "a no-longer-eslint project kept its eslint diagnostics")
    end)
  end)
end)
