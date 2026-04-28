local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")
local git_fixture = require("tests.helpers.git_fixture")

describe("e2e: treesitter", function()
  local root, prev_cwd

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
  end)

  after_each(function()
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  local cases = {
    {
      label = "lua",
      path = "sample.lua",
      content = "local x = 1\n",
      capture_col = 6,
    },
    {
      label = "typescript",
      path = "sample.ts",
      content = "const x: number = 1;\n",
      capture_col = 6,
    },
  }

  for _, case in ipairs(cases) do
    it("attaches highlighter and sets foldexpr for " .. case.label, function()
      local repo = git_fixture.repo({
        commits = { { files = { [case.path] = case.content } }, message = "init" },
      })
      local canonical = vim.uv.fs_realpath(repo) or repo
      vim.fn.chdir(canonical)
      vim.cmd("edit " .. canonical .. "/" .. case.path)
      local bufnr = vim.api.nvim_get_current_buf()

      wait.wait_for(function()
        return vim.treesitter.highlighter.active[bufnr] ~= nil
      end, 5000, "treesitter highlighter never attached")

      assert.is_not_nil(
        vim.treesitter.highlighter.active[bufnr],
        "treesitter highlighter not active"
      )

      local captures = vim.treesitter.get_captures_at_pos(bufnr, 0, case.capture_col)
      assert.is_true(
        #captures >= 1,
        "expected ≥1 capture at row 0 col " .. case.capture_col .. ", got " .. #captures
      )

      assert.are.equal(
        "v:lua.vim.treesitter.foldexpr()",
        vim.wo.foldexpr,
        "foldexpr not set to treesitter foldexpr"
      )
    end)
  end
end)
