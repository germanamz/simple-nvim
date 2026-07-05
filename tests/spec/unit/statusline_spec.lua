describe("config.statusline", function()
  local buf

  before_each(function()
    package.loaded["config.statusline"] = nil
    require("config.statusline")
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
  end)

  after_each(function()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  describe("git_branch_status", function()
    it("returns an empty string when neither head nor base is set", function()
      vim.b.nvim_git_branch = ""
      vim.b.nvim_review_base = ""
      vim.b.gitsigns_head = ""
      assert.are.equal("", _G.git_branch_status())
    end)

    it("shows head and base joined with an arrow when both are set", function()
      vim.b.nvim_git_branch = "feature"
      vim.b.nvim_review_base = "origin/main"
      assert.are.equal(" feature ↗ origin/main ", _G.git_branch_status())
    end)

    it("shows only the head when no base is set", function()
      vim.b.nvim_git_branch = "feature"
      vim.b.nvim_review_base = ""
      assert.are.equal(" feature ", _G.git_branch_status())
    end)

    it("shows only the base when no head is set", function()
      vim.b.nvim_git_branch = ""
      vim.b.nvim_review_base = "origin/main"
      assert.are.equal(" ↗ origin/main ", _G.git_branch_status())
    end)

    it("falls back to gitsigns_head when nvim_git_branch is empty", function()
      vim.b.nvim_git_branch = ""
      vim.b.nvim_review_base = ""
      vim.b.gitsigns_head = "main"
      assert.are.equal(" main ", _G.git_branch_status())
    end)

    it("prefers nvim_git_branch over gitsigns_head when both are set", function()
      vim.b.nvim_git_branch = "feature"
      vim.b.gitsigns_head = "stale"
      vim.b.nvim_review_base = ""
      assert.are.equal(" feature ", _G.git_branch_status())
    end)
  end)

  describe("setup", function()
    it("refreshes the branch cache on HeadChanged", function()
      require("config.statusline").setup()
      local autocmds = vim.api.nvim_get_autocmds({
        group = "nvim_statusline",
        event = "User",
        pattern = "HeadChanged",
      })
      assert.is_true(#autocmds > 0)
    end)

    it("refreshes the branch cache on FocusGained", function()
      require("config.statusline").setup()
      local autocmds = vim.api.nvim_get_autocmds({
        group = "nvim_statusline",
        event = "FocusGained",
      })
      assert.is_true(#autocmds > 0)
    end)
  end)

  describe("refresh_all", function()
    it("exposes a public manual-refresh entry point", function()
      -- Backs the <leader>gR keymap and the FocusGained git refresh; the keymap
      -- breaks silently if this stops being a callable public function.
      assert.is_function(require("config.statusline").refresh_all)
    end)
  end)

  describe("plugin-owned stubs", function()
    it("defines no-op lsp_refs_status and gitsigns_hunks_status", function()
      assert.is_function(_G.lsp_refs_status)
      assert.is_function(_G.gitsigns_hunks_status)
      assert.are.equal("", _G.lsp_refs_status())
      assert.are.equal("", _G.gitsigns_hunks_status())
    end)
  end)

  -- Behavioral lock for the data.root event scoping (plan stage P4). The
  -- scoping decision runs through git.buf_in_root, so spying on it captures
  -- exactly which root the handler forwards — synchronously, with no async
  -- refresh to race. This catches the wiring trap directly: a callback that
  -- passed the autocmd args table (or nil) instead of data.root would call
  -- buf_in_root with the wrong value, or the nil sweep would call it at all.
  describe("event fan-out scoping", function()
    local nvim_env = require("helpers.nvim_env")
    local git_fixture = require("helpers.git_fixture")
    local env_root, git, sp, roots_seen, orig_buf_in_root, opened

    before_each(function()
      env_root = nvim_env.setup_isolated_env()
      package.loaded["util.git"] = nil
      package.loaded["config.git_head"] = nil
      package.loaded["config.statusline"] = nil
      git = require("util.git")
      require("config.statusline").setup()
      sp = git_fixture.superproject({ children = { "childA", "childB" } })
      -- Record every root the scoping predicate is asked about. statusline holds
      -- the util.git table (not the function), so replacing the field is seen by
      -- refresh_all_buffers' call site.
      roots_seen = {}
      orig_buf_in_root = git.buf_in_root
      git.buf_in_root = function(buf, root)
        roots_seen[#roots_seen + 1] = root
        return orig_buf_in_root(buf, root)
      end
      opened = {}
    end)

    after_each(function()
      git.buf_in_root = orig_buf_in_root
      require("config.git_head")._stop_all()
      for _, b in ipairs(opened) do
        if vim.api.nvim_buf_is_valid(b) then
          vim.api.nvim_buf_delete(b, { force = true })
        end
      end
      nvim_env.teardown(env_root)
    end)

    local function open(file)
      local b = vim.fn.bufadd(file)
      vim.fn.bufload(b)
      opened[#opened + 1] = b
      return b
    end

    it("scopes the HeadChanged handler to data.root, not the autocmd args", function()
      local rootA = git.root(sp.children.childA)
      open(sp.children.childA .. "/childA.txt")
      open(sp.children.childB .. "/childB.txt")
      -- exec_autocmds runs the handler synchronously, so the predicate calls it
      -- makes are all captured before this returns — no async watcher in play yet.
      vim.api.nvim_exec_autocmds("User", {
        pattern = "HeadChanged",
        modeline = false,
        data = { root = rootA, branch = "main" },
      })
      assert.is_true(#roots_seen > 0) -- the handler scoped rather than full-swept
      for _, root in ipairs(roots_seen) do
        assert.are.equal(rootA, root) -- forwarded data.root verbatim
      end
    end)

    it("does not scope the nil sweep (refresh_all reaches every root)", function()
      open(sp.children.childA .. "/childA.txt")
      open(sp.children.childB .. "/childB.txt")
      require("config.statusline").refresh_all()
      -- root == nil short-circuits buf_in_root, so a correct full sweep never
      -- consults it. The wiring trap (passing a truthy args table as root) would
      -- instead call it for every buffer and scope the sweep to nothing.
      assert.are.equal(0, #roots_seen)
    end)
  end)

  -- Behavioral lock for the cross-instance staleness fix: another nvim/tool can
  -- change git state while this instance is unfocused, and only the FocusGained
  -- sweep can repair a NON-CURRENT buffer whose branch is already cached (the
  -- BufEnter gate never re-resolves a non-nil nvim_git_branch). refresh() calls
  -- path.buf_start_dir(buf) synchronously per swept buffer, so replacing that
  -- field on the shared util.path table captures exactly which buffers the
  -- handler reached — the same spy idiom as the buf_in_root scoping tests.
  describe("FocusGained sweep", function()
    local nvim_env = require("helpers.nvim_env")
    local git_fixture = require("helpers.git_fixture")
    local wait = require("helpers.wait")
    local path = require("util.path")
    local env_root, repo, other, refreshed, orig_buf_start_dir

    before_each(function()
      env_root = nvim_env.setup_isolated_env()
      require("config.statusline").setup()
      -- A distinctive branch name: refresh()'s async callback checks only buffer
      -- validity, so a stale callback from an earlier test can land on a recycled
      -- buffer number — but it can only ever write "" or another repo's branch,
      -- never this one.
      repo = git_fixture.repo({
        base_branch = "focus-swept",
        commits = { { files = { ["other.txt"] = "other\n" }, message = "init" } },
      })
      other = vim.fn.bufadd(repo .. "/other.txt")
      -- Mark the buffer already-resolved with a value no longer matching git
      -- reality BEFORE loading it: bufload fires a BufEnter here, and a nil
      -- branch would let the BufEnter gate resolve the buffer outside the
      -- sweep. With it set, only the FocusGained sweep may overwrite it.
      vim.b[other].nvim_git_branch = "outdated"
      vim.b[other].nvim_review_base = ""
      vim.fn.bufload(other)
      refreshed = {}
      orig_buf_start_dir = path.buf_start_dir
      path.buf_start_dir = function(b)
        refreshed[b] = true
        return orig_buf_start_dir(b)
      end
    end)

    after_each(function()
      path.buf_start_dir = orig_buf_start_dir
      require("config.git_head")._stop_all()
      if other and vim.api.nvim_buf_is_valid(other) then
        vim.api.nvim_buf_delete(other, { force = true })
      end
      vim.fn.delete(repo, "rf")
      nvim_env.teardown(env_root)
    end)

    it("re-resolves a non-current already-resolved buffer", function()
      assert.are_not.equal(other, vim.api.nvim_get_current_buf())
      vim.api.nvim_exec_autocmds("FocusGained", { modeline = false })
      assert.is_true(refreshed[other])
      assert.is_true(refreshed[vim.api.nvim_get_current_buf()])
    end)

    it("overwrites the stale cached branch once the async resolve lands", function()
      vim.api.nvim_exec_autocmds("FocusGained", { modeline = false })
      wait.wait_for(function()
        return vim.b[other].nvim_git_branch == "focus-swept"
      end, nil, "non-current buffer's branch cache was never re-resolved")
    end)
  end)
end)
