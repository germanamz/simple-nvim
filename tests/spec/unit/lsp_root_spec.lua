-- Pins config.lsp_root: keeping ts_ls's root_dir inside the repository that
-- contains the buffer.
--
-- lspconfig roots ts_ls at the nearest package-manager lockfile, and
-- vim.fs.root's NESTED marker groups rank "nearest lockfile anywhere up to /"
-- above "nearest .git". So one stray pnpm-lock.yaml at or above a superproject
-- root pulls every lockfile-less submodule into a single client rooted over the
-- whole tree — in a 200-submodule workspace, tsserver over everything.
--
-- The clamp pulls the root back down to the repo holding the buffer, but only
-- when that repo is itself a TypeScript project: an ungated clamp re-roots a git
-- submodule VENDORED inside a TS project (compiled by the parent's tsconfig) at
-- itself, tsserver drops the file into an inferred project, and a clean file
-- grows a false TS2307.
local lsp_root = require("config.lsp_root")

describe("config.lsp_root.clamp", function()
  it("pulls the root down to a lockfile-less submodule that owns a tsconfig", function()
    -- stray lockfile at /w captured /w/super/repoD
    assert.are.equal("/w/super/repoD", lsp_root.clamp("/w", "/w/super/repoD", true))
  end)

  it("leaves the root alone when the boundary is not a TS project", function()
    -- the vendored-submodule regression: /app/vendor/ui has no tsconfig of its
    -- own and is compiled by /app's, so re-rooting it there is what breaks it.
    assert.are.equal("/app", lsp_root.clamp("/app", "/app/vendor/ui", false))
  end)

  it("leaves a root that already sits at the repo boundary unchanged", function()
    assert.are.equal("/w/repoA", lsp_root.clamp("/w/repoA", "/w/repoA", true))
  end)

  it("never moves the root UP, only down toward the buffer", function()
    -- a package inside a repo: boundary is an ancestor of the root, not below it
    assert.are.equal(
      "/w/repoE/packages/vendor",
      lsp_root.clamp("/w/repoE/packages/vendor", "/w/repoE", true)
    )
  end)

  it("ignores a boundary that is a sibling rather than a descendant", function()
    -- "/w/ab" must not look like a child of "/w/a" on a bare prefix test
    assert.are.equal("/w/a", lsp_root.clamp("/w/a", "/w/ab", true))
  end)

  it("returns the dir unchanged when the buffer is in no repo at all", function()
    assert.are.equal("/w/x", lsp_root.clamp("/w/x", nil, true))
  end)

  it("clamps out of the filesystem root", function()
    -- getcwd() fallbacks and stray top-level lockfiles can land the root at "/";
    -- "/" .. "/" would be a bogus prefix, so this is special-cased.
    assert.are.equal("/repo", lsp_root.clamp("/", "/repo", true))
  end)

  it("tolerates a trailing slash on either argument", function()
    assert.are.equal("/w/repo", lsp_root.clamp("/w/", "/w/repo", true))
    assert.are.equal("/w/repo", lsp_root.clamp("/w", "/w/repo/", true))
  end)

  it("passes a nil dir through", function()
    assert.is_nil(lsp_root.clamp(nil, "/w/repo", true))
  end)
end)

describe("config.lsp_root.is_ts_project", function()
  local function tmp(files)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    for _, f in ipairs(files) do
      local fh = assert(io.open(root .. "/" .. f, "w"))
      fh:write("{}\n")
      fh:close()
    end
    return root
  end

  it("accepts a dir holding tsconfig.json", function()
    local d = tmp({ "tsconfig.json" })
    assert.is_true(lsp_root.is_ts_project(d))
    vim.fn.delete(d, "rf")
  end)

  it("accepts a dir holding jsconfig.json", function()
    local d = tmp({ "jsconfig.json" })
    assert.is_true(lsp_root.is_ts_project(d))
    vim.fn.delete(d, "rf")
  end)

  it("rejects a dir holding neither", function()
    local d = tmp({ "package.json" })
    assert.is_false(lsp_root.is_ts_project(d))
    vim.fn.delete(d, "rf")
  end)

  it("rejects nil", function()
    assert.is_false(lsp_root.is_ts_project(nil))
  end)
end)

describe("config.lsp_root.bound", function()
  it("never calls on_dir when the base aborts", function()
    -- lspconfig's ts_ls root_dir returns WITHOUT calling on_dir for a deno
    -- project. Wrapping must preserve that or ts_ls starts on deno files.
    local called = false
    local base = function() end -- aborts: never invokes its callback
    lsp_root.bound(base)(vim.api.nvim_get_current_buf(), function()
      called = true
    end)
    assert.is_false(called)
  end)

  it("passes a dir through when the buffer is in no repo", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local seen
    lsp_root.bound(function(_, on_dir)
      on_dir("/nonexistent/root")
    end)(buf, function(d)
      seen = d
    end)
    assert.are.equal("/nonexistent/root", seen)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("is idempotent, so re-running the plugin spec cannot stack layers", function()
    -- bound() returns a fresh closure per call, so without memoization a
    -- :Lazy reload would wrap the wrapper and run the clamp twice per resolution.
    local base = function(_, on_dir)
      on_dir("/x")
    end
    local once = lsp_root.bound(base)
    assert.are.equal(once, lsp_root.bound(base))
    assert.are.equal(once, lsp_root.bound(once))
  end)

  it("declines to wrap a function config.lsp_tsdk already wrapped", function()
    -- On a second config run the base read back from vim.lsp.config is last
    -- run's tsdk wrapper; bounding it again would stack.
    local tsdk = require("config.lsp_tsdk")
    local wrapped = tsdk.wrap_root_dir(function(_, on_dir)
      on_dir("/x")
    end)
    assert.are.equal(wrapped, lsp_root.bound(wrapped))
  end)
end)
