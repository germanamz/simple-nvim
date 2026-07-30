-- Pins config.telescope_grep: the grep scopes behind <leader>fg (repo toplevel)
-- and <leader>fG (one directory, asked for through vim.ui.input).
--
-- The value of the folder-scoped picker is that it lands on a REAL directory
-- whatever the caller points at — a tree node that is a file, a typed path with
-- a ~, a relative path, a path that does not exist — so these specs are mostly
-- about that normalization, plus the scope showing up in the prompt title (the
-- only thing distinguishing this picker from the project-wide one on screen).
local grep = require("config.telescope_grep")

-- Captures the live_grep opts instead of opening a picker. telescope.builtin is
-- required lazily inside M.grep, so seeding package.loaded is enough — no real
-- telescope needed in the plenary-only harness.
local function stub_builtin()
  local calls = {}
  package.loaded["telescope.builtin"] = {
    live_grep = function(opts)
      table.insert(calls, opts)
    end,
  }
  return calls
end

--- Answer the next vim.ui.input with `answer` (nil simulates <Esc>), and record
--- the opts it was asked with so the seeded default can be asserted.
local function stub_input(answer)
  local seen = {}
  vim.ui.input = function(opts, on_confirm)
    table.insert(seen, opts)
    on_confirm(answer)
  end
  return seen
end

describe("config.telescope_grep", function()
  local tmp, real_input, real_notify, notified

  before_each(function()
    tmp = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(tmp .. "/pkg/src", "p")
    vim.fn.writefile({ "x" }, tmp .. "/pkg/src/a.lua")
    real_input = vim.ui.input
    real_notify = vim.notify
    notified = {}
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.ui.input = real_input
    vim.notify = real_notify
    package.loaded["telescope.builtin"] = nil
    package.loaded["nvim-tree.api"] = nil
    vim.fn.delete(tmp, "rf")
  end)

  describe("grep", function()
    it("scopes the picker to the directory and names it in the title", function()
      local calls = stub_builtin()
      grep.grep(tmp .. "/pkg/src")
      assert.are.equal(1, #calls)
      assert.are.equal(tmp .. "/pkg/src/", calls[1].cwd)
      -- Outside a repo the root is the cwd, so the scope is not under it and
      -- util.path.relative keeps it absolute — the title still ends in the path.
      assert.is_truthy(calls[1].prompt_title:match("^Live Grep %(.*pkg/src%)$"))
    end)

    it("greps a file's parent folder, so a file path is not a dead end", function()
      local calls = stub_builtin()
      grep.grep(tmp .. "/pkg/src/a.lua")
      assert.are.equal(tmp .. "/pkg/src", calls[1].cwd)
      assert.is_truthy(calls[1].prompt_title:match("pkg/src%)$"))
    end)

    it("warns and opens nothing when the path does not exist", function()
      local calls = stub_builtin()
      assert.is_nil(grep.grep(tmp .. "/nope"))
      assert.are.equal(0, #calls)
      assert.are.equal(1, #notified)
      assert.are.equal(vim.log.levels.WARN, notified[1].level)
      -- No trailing slash in the message: :p adds one, which reads as if the
      -- user had typed it.
      assert.is_truthy(notified[1].msg:match("nope$"))
    end)

    it("expands ~ and resolves a relative path against the cwd", function()
      local calls = stub_builtin()
      local cwd = vim.fn.getcwd()
      vim.cmd.lcd(tmp .. "/pkg")
      local ok = pcall(grep.grep, "src")
      vim.cmd.lcd(cwd)
      assert.is_true(ok)
      assert.are.equal(tmp .. "/pkg/src/", calls[1].cwd)

      grep.grep("~")
      assert.are.equal(vim.fn.expand("~") .. "/", calls[2].cwd)
    end)

    it("shows the basename when the scope is the repo root itself", function()
      local calls = stub_builtin()
      local root = grep.root()
      grep.grep(root)
      assert.are.equal(
        "Live Grep (" .. vim.fn.fnamemodify(root, ":t") .. ")",
        calls[1].prompt_title
      )
    end)

    it("ignores an empty target", function()
      local calls = stub_builtin()
      assert.is_nil(grep.grep(""))
      assert.is_nil(grep.grep(nil))
      assert.are.equal(0, #calls)
      assert.are.equal(0, #notified)
    end)
  end)

  describe("seed", function()
    it("uses the focused buffer's own folder outside the tree", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, tmp .. "/pkg/src/a.lua")
      vim.api.nvim_set_current_buf(buf)
      assert.are.equal(tmp .. "/pkg/src", grep.seed())
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("falls back to the cwd for an unnamed buffer", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
      assert.are.equal(vim.fn.getcwd(), grep.seed())
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    describe("in the tree", function()
      local buf

      before_each(function()
        buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(buf)
        vim.bo[buf].filetype = "NvimTree"
      end)

      after_each(function()
        vim.api.nvim_buf_delete(buf, { force = true })
      end)

      --- nvim-tree hands out field-only clones of its nodes, so a table with
      --- just absolute_path is a faithful stand-in — and deliberately carries no
      --- `type`, pinning that the module probes the filesystem instead.
      local function stub_node(path)
        package.loaded["nvim-tree.api"] = {
          tree = {
            get_node_under_cursor = function()
              return path and { absolute_path = path } or nil
            end,
          },
        }
      end

      it("uses a directory node as-is", function()
        stub_node(tmp .. "/pkg/src")
        assert.are.equal(tmp .. "/pkg/src", grep.seed())
      end)

      it("uses a file node's parent folder", function()
        stub_node(tmp .. "/pkg/src/a.lua")
        assert.are.equal(tmp .. "/pkg/src", grep.seed())
      end)

      it("falls back to the buffer ladder when no node is under the cursor", function()
        stub_node(nil)
        assert.are.equal(vim.fn.getcwd(), grep.seed())
      end)
    end)
  end)

  describe("prompt", function()
    it("seeds the input with the folder plus a trailing slash", function()
      stub_builtin()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, tmp .. "/pkg/src/a.lua")
      vim.api.nvim_set_current_buf(buf)
      local seen = stub_input(nil)
      grep.prompt()
      assert.are.equal(1, #seen)
      assert.are.equal(tmp .. "/pkg/src/", seen[1].default)
      -- Completion is what makes the seed editable rather than take-it-or-leave-it.
      assert.are.equal("dir", seen[1].completion)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("shortens the seed to a cwd-relative path, matching dir completion", function()
      stub_builtin()
      local cwd = vim.fn.getcwd()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, tmp .. "/pkg/src/a.lua")
      vim.api.nvim_set_current_buf(buf)
      vim.cmd.lcd(tmp)
      local seen = stub_input(nil)
      pcall(grep.prompt)
      vim.cmd.lcd(cwd)
      assert.are.equal("pkg/src/", seen[1].default)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("shows the cwd itself as './', not the absolute path", function()
      stub_builtin()
      -- ":." has no relative form for the cwd, so without the special case this
      -- would be a full absolute path — the seed an unnamed buffer produces.
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
      local seen = stub_input(nil)
      grep.prompt()
      assert.are.equal("./", seen[1].default)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("greps the answer", function()
      local calls = stub_builtin()
      stub_input(tmp .. "/pkg")
      grep.prompt()
      assert.are.equal(tmp .. "/pkg/", calls[1].cwd)
    end)

    it("opens nothing when cancelled or cleared", function()
      local calls = stub_builtin()
      stub_input(nil)
      grep.prompt()
      stub_input("")
      grep.prompt()
      stub_input("   ")
      grep.prompt()
      assert.are.equal(0, #calls)
      assert.are.equal(0, #notified)
    end)

    it("trims surrounding whitespace off the answer", function()
      local calls = stub_builtin()
      stub_input("  " .. tmp .. "/pkg  ")
      grep.prompt()
      assert.are.equal(tmp .. "/pkg/", calls[1].cwd)
    end)
  end)

  describe("root", function()
    it("returns the repo toplevel, or the cwd outside a repo", function()
      local git_fixture = require("helpers.git_fixture")
      local repo = git_fixture.repo({
        commits = { { files = { ["a.lua"] = "1\n" }, message = "init" } },
      })
      local cwd = vim.fn.getcwd()
      require("util.git")._clear_root_cache()
      vim.cmd.lcd(repo)
      local in_repo = grep.root()
      vim.cmd.lcd(tmp)
      require("util.git")._clear_root_cache()
      local outside = grep.root()
      vim.cmd.lcd(cwd)
      require("util.git")._clear_root_cache()
      assert.are.equal(vim.fn.resolve(repo), vim.fn.resolve(in_repo))
      assert.are.equal(tmp, vim.fn.resolve(outside))
    end)
  end)
end)
