-- config.ignore_filter replaces nvim-tree's builtin git-ignore filter (which,
-- in a superproject, spawns a synchronous `git status --ignored` per submodule
-- and trips a never-reset kill switch). Pins the pure decision logic the
-- synchronous filter and the async oracle rely on: the static heavy-dir set, the
-- partition-by-toplevel that keeps `git check-ignore` from crossing a submodule
-- boundary, and the NUL-delimited output parse. Also pins drain()'s mid-batch
-- invalidation guards: both async stages compare the batch's captured cache
-- table against the live one by IDENTITY, so an M._clear() landing mid-flight
-- drops the batch's stale verdicts and skips the util.git root-memo prime.
--
-- And the edges that trigger that clear, which used to be an in-editor write
-- and nothing else: a .gitignore rewritten by a branch switch or an agent
-- reaches this module only as a re-read (BufReadPost / config.file_reload's
-- User FileReloaded), and until it did, the memo kept hiding files the new
-- rules no longer ignore.

describe("config.ignore_filter", function()
  local M

  before_each(function()
    package.loaded["config.ignore_filter"] = nil
    M = require("config.ignore_filter")
  end)

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, "ignore_filter")
  end)

  describe("_is_static", function()
    it("matches a curated heavy-dir basename at any depth", function()
      assert.is_true(M._is_static("/a/b/node_modules"))
      assert.is_true(M._is_static("/x/.venv"))
      assert.is_true(M._is_static("/deep/nested/__pycache__"))
      assert.is_true(M._is_static("/p/.terraform"))
    end)

    it("does NOT match ambiguous names that are sometimes tracked", function()
      -- These must fall through to the oracle so a tracked dir of that name
      -- (git's real, index-aware answer) stays visible.
      assert.is_false(M._is_static("/p/target"))
      assert.is_false(M._is_static("/p/build"))
      assert.is_false(M._is_static("/p/dist"))
      assert.is_false(M._is_static("/p/bin"))
      assert.is_false(M._is_static("/p/vendor"))
      assert.is_false(M._is_static("/p/.idea"))
      assert.is_false(M._is_static("/p/Pods"))
    end)

    it("returns false for an ordinary path", function()
      assert.is_false(M._is_static("/p/src/main.rs"))
      assert.is_false(M._is_static("/p/README.md"))
    end)
  end)

  describe("is_ignored (synchronous predicate)", function()
    it("hides a static heavy dir immediately, with no enqueue/git", function()
      assert.is_true(M.is_ignored("/repo/node_modules"))
    end)

    it("fails open (shows) on a first, unknown non-static path", function()
      -- The oracle resolves it asynchronously; the synchronous answer must not
      -- block, so an unresolved path is shown until the batch lands.
      assert.is_false(M.is_ignored("/repo/some/unknown/dir"))
    end)
  end)

  describe("_partition", function()
    it("groups paths by their containing directory's toplevel", function()
      -- root_fn stub: dirname -> toplevel. Mirrors util.git.root resolving a
      -- path inside a submodule to that submodule's own toplevel.
      local function root_fn(dir)
        if dir:find("^/super/subA") then
          return "/super/subA"
        elseif dir:find("^/super") then
          return "/super"
        end
        return nil
      end

      local by_top, unrooted = M._partition({
        "/super/subA/target", -- inside submodule subA
        "/super/subA/x/y", -- deeper inside subA
        "/super/pkg/build", -- superproject
        "/elsewhere/thing", -- outside any work tree
      }, root_fn)

      assert.are.same({ "/super/subA/target", "/super/subA/x/y" }, by_top["/super/subA"])
      assert.are.same({ "/super/pkg/build" }, by_top["/super"])
      assert.are.same({ "/elsewhere/thing" }, unrooted)
    end)

    it("returns empty tables when nothing resolves to a repo", function()
      local by_top, unrooted = M._partition({ "/no/repo/here" }, function()
        return nil
      end)
      assert.are.same({}, by_top)
      assert.are.same({ "/no/repo/here" }, unrooted)
    end)
  end)

  describe("_parse_check_ignore", function()
    it("splits the NUL-delimited ignored subset into a lookup set", function()
      local hit = M._parse_check_ignore("/r/target\0/r/sub/build\0")
      assert.is_true(hit["/r/target"])
      assert.is_true(hit["/r/sub/build"])
      assert.is_nil(hit["/r/src"])
    end)

    it("returns an empty set for empty/nil output (rc 1 or error)", function()
      assert.are.same({}, M._parse_check_ignore(""))
      assert.are.same({}, M._parse_check_ignore(nil))
    end)
  end)

  describe("drain (mid-batch invalidation guards)", function()
    local git
    local sys_calls, scheduled, prime_calls
    local orig_system, orig_schedule, orig_prime

    -- Run scheduled callbacks until quiescent; new work queued by a callback
    -- (a pool worker spawning the next stage) runs in the same flush.
    local function flush()
      while #scheduled > 0 do
        local fns = scheduled
        scheduled = {}
        for _, fn in ipairs(fns) do
          fn()
        end
      end
    end

    before_each(function()
      git = require("util.git")
      git._clear_root_cache()
      sys_calls, scheduled, prime_calls = {}, {}, {}
      orig_system, orig_schedule, orig_prime = vim.system, vim.schedule, git._prime_root
      -- Capture async work instead of running it, so the test can interleave
      -- M._clear() between stage 1 (rev-parse) and stage 2 (check-ignore).
      vim.system = function(cmd, opts, on_exit)
        sys_calls[#sys_calls + 1] = { cmd = cmd, opts = opts, on_exit = on_exit }
      end
      vim.schedule = function(fn)
        scheduled[#scheduled + 1] = fn
      end
      git._prime_root = function(dir, top)
        prime_calls[#prime_calls + 1] = { dir = dir, top = top }
      end
    end)

    after_each(function()
      vim.system, vim.schedule, git._prime_root = orig_system, orig_schedule, orig_prime
      git._clear_root_cache()
    end)

    it("resolves a batch through both stages while the cache stays live", function()
      assert.is_false(M.is_ignored("/repo/a"))
      flush()
      assert.are.equal(1, #sys_calls)
      assert.are.same({ "git", "-C", "/repo", "rev-parse", "--show-toplevel" }, sys_calls[1].cmd)

      sys_calls[1].on_exit({ code = 0, stdout = "/repo\n" })
      flush()
      assert.are.same({ { dir = "/repo", top = "/repo" } }, prime_calls)
      assert.are.equal(2, #sys_calls)
      assert.are.same(
        { "git", "--no-optional-locks", "-C", "/repo", "check-ignore", "-z", "--stdin" },
        sys_calls[2].cmd
      )

      sys_calls[2].on_exit({ code = 0, stdout = "/repo/a\0" })
      flush()
      assert.is_true(M.is_ignored("/repo/a"))
    end)

    it("drops stage-2 verdicts when M._clear() lands before check-ignore resolves", function()
      assert.is_false(M.is_ignored("/repo/a"))
      flush()
      sys_calls[1].on_exit({ code = 0, stdout = "/repo\n" })
      flush()
      assert.are.equal(2, #sys_calls)

      M._clear() -- .gitignore write mid-flight: mints a fresh cache table

      sys_calls[2].on_exit({ code = 0, stdout = "/repo/a\0" }) -- stale "ignored" verdict
      flush()

      -- The fresh cache must stay unpolluted: still fail-open (shown), not the
      -- stale hide computed against the old rules.
      assert.is_false(M.is_ignored("/repo/a"))
    end)

    it("skips the root-memo prime and stage 2 when M._clear() lands during stage 1", function()
      assert.is_false(M.is_ignored("/repo/a"))
      flush()
      assert.are.equal(1, #sys_calls)

      M._clear() -- topology change lands before rev-parse resolves

      sys_calls[1].on_exit({ code = 0, stdout = "/repo\n" })
      flush()

      -- A pre-clear toplevel must not warm util.git's memo, and the batch's
      -- check-ignore must never spawn.
      assert.are.same({}, prime_calls)
      assert.are.equal(1, #sys_calls)
    end)
  end)

  describe("_is_ignore_file", function()
    it("matches the files whose contents ARE the ignore rules", function()
      assert.is_true(M._is_ignore_file("/repo/.gitignore"))
      assert.is_true(M._is_ignore_file("/repo/pkg/deep/.gitignore"))
      assert.is_true(M._is_ignore_file("/repo/.git/info/exclude"))
    end)

    it("does not match names that merely look like them", function()
      assert.is_false(M._is_ignore_file("/repo/gitignore"))
      assert.is_false(M._is_ignore_file("/repo/.gitignore.bak"))
      assert.is_false(M._is_ignore_file("/repo/excludes.txt"))
      assert.is_false(M._is_ignore_file("/repo/src/main.rs"))
    end)
  end)

  -- The invalidation edges. BufWritePost alone only ever fires for an
  -- IN-EDITOR write, so a .gitignore rewritten by an agent, a codegen run or a
  -- branch switch changed nothing here: memoized verdicts outlived the rules
  -- that produced them until a DirChanged or <leader>gR happened to land. The
  -- symptom -- a file that refuses to appear in the tree under a stale grey
  -- NvimTreeGitIgnored row -- reads exactly like a git/LSP staleness bug even
  -- though no git or LSP state is involved.
  describe("invalidation edges", function()
    local git
    local sys_calls, scheduled
    local orig_system, orig_schedule

    local function flush()
      while #scheduled > 0 do
        local fns = scheduled
        scheduled = {}
        for _, fn in ipairs(fns) do
          fn()
        end
      end
    end

    -- Drive one path through both async stages so it lands in the cache as a
    -- CONFIRMED hide. A live verdict is the only thing a clear is observable
    -- through: is_ignored() answers true from the memo, and fail-open false
    -- once the memo is gone.
    local function memoize_hidden(abs, top)
      assert.is_false(M.is_ignored(abs))
      flush()
      sys_calls[1].on_exit({ code = 0, stdout = top .. "\n" })
      flush()
      sys_calls[2].on_exit({ code = 0, stdout = abs .. "\0" })
      flush()
      assert.is_true(M.is_ignored(abs), "precondition: the oracle verdict never memoized")
    end

    -- What config.file_reload publishes once 'autoread' has re-read a file that
    -- changed underneath the editor: a bufnr, not a path, so the consumer has
    -- to ask the filename question itself.
    local function publish_reload(basename)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. "/" .. basename)
      vim.api.nvim_exec_autocmds("User", {
        pattern = "FileReloaded",
        data = { buf = buf },
        modeline = false,
      })
      vim.api.nvim_buf_delete(buf, { force = true })
    end

    before_each(function()
      git = require("util.git")
      git._clear_root_cache()
      sys_calls, scheduled = {}, {}
      orig_system, orig_schedule = vim.system, vim.schedule
      vim.system = function(cmd, opts, on_exit)
        sys_calls[#sys_calls + 1] = { cmd = cmd, opts = opts, on_exit = on_exit }
      end
      vim.schedule = function(fn)
        scheduled[#scheduled + 1] = fn
      end
      M.setup()
    end)

    after_each(function()
      vim.system, vim.schedule = orig_system, orig_schedule
      git._clear_root_cache()
    end)

    it("registers BufWritePost AND BufReadPost on the .gitignore/exclude patterns", function()
      -- BufReadPost is the edge a `:e!` (the disk copy after a conflict) and a
      -- checktime reload both fire; without it only in-editor writes invalidate.
      for _, event in ipairs({ "BufWritePost", "BufReadPost" }) do
        local patterns = {}
        for _, au in ipairs(vim.api.nvim_get_autocmds({ group = "ignore_filter", event = event })) do
          patterns[au.pattern] = true
        end
        assert.is_true(patterns[".gitignore"], "no " .. event .. " autocmd for .gitignore")
        assert.is_true(patterns["exclude"], "no " .. event .. " autocmd for exclude")
      end
    end)

    it("re-resolves a memoized verdict when an external .gitignore reload lands", function()
      memoize_hidden("/repo/a", "/repo")
      publish_reload(".gitignore")
      -- Back to unknown: the path fails open and re-enqueues, so the next
      -- oracle round trip answers under the new rules.
      assert.is_false(M.is_ignored("/repo/a"))
    end)

    it("re-resolves when the reloaded file is a .git/info/exclude", function()
      memoize_hidden("/repo/a", "/repo")
      publish_reload("exclude")
      assert.is_false(M.is_ignored("/repo/a"))
    end)

    it("keeps verdicts when the reloaded buffer is an ordinary file", function()
      -- The common case by far: every other reloaded buffer must not throw away
      -- a tree's worth of oracle answers.
      memoize_hidden("/repo/a", "/repo")
      publish_reload("main.rs")
      assert.is_true(M.is_ignored("/repo/a"))
    end)

    it("clears unconditionally on User FileRefreshForced", function()
      memoize_hidden("/repo/a", "/repo")
      vim.api.nvim_exec_autocmds("User", { pattern = "FileRefreshForced", modeline = false })
      assert.is_false(M.is_ignored("/repo/a"))
    end)
  end)
end)
