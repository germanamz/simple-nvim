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

    it("uses gitsigns_head when set", function()
      vim.b.nvim_git_branch = ""
      vim.b.nvim_review_base = ""
      vim.b.gitsigns_head = "main"
      assert.are.equal(" main ", _G.git_branch_status())
    end)

    it("falls back to nvim_git_branch when gitsigns_head is empty", function()
      vim.b.nvim_git_branch = "feature"
      vim.b.gitsigns_head = ""
      vim.b.nvim_review_base = ""
      assert.are.equal(" feature ", _G.git_branch_status())
    end)

    it("prefers gitsigns_head over nvim_git_branch when both are set", function()
      vim.b.nvim_git_branch = "stale-branch"
      vim.b.gitsigns_head = "main"
      vim.b.nvim_review_base = ""
      assert.are.equal(" main ", _G.git_branch_status())
    end)
  end)

  describe("setup", function()
    it("refreshes the branch cache on FocusGained", function()
      require("config.statusline").setup()
      local autocmds = vim.api.nvim_get_autocmds({
        group = "nvim_statusline",
        event = "FocusGained",
      })
      assert.is_true(#autocmds > 0)
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
end)
