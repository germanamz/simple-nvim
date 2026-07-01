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
    {
      -- .tf → ft terraform (pinned by extension in init.lua, bypassing core's
      -- detect.tf content heuristic), parsed by the terraform parser. col 0 =
      -- the `resource` keyword.
      label = "terraform",
      path = "main.tf",
      content = 'resource "aws_instance" "web" {\n  ami = "ami-123"\n}\n',
      capture_col = 0,
    },
    {
      -- .graphql → ft graphql, same-named parser. col 0 = the `type` keyword.
      label = "graphql",
      path = "schema.graphql",
      content = "type Query {\n  hello: String\n}\n",
      capture_col = 0,
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

  -- Go html templates parse with the gotmpl parser (so `{{ ... }}` actions
  -- highlight) and inject the surrounding markup back as html (so tags
  -- highlight). Assert BOTH language trees produce captures — this is the pair
  -- that a naive single-parser setup would miss.
  it("highlights gotmpl actions and injected html in a gohtmltmpl buffer", function()
    local repo = git_fixture.repo({
      commits = { { files = { ["page.tmpl"] = "<div>{{ .Name }}</div>\n" } }, message = "init" },
    })
    local canonical = vim.uv.fs_realpath(repo) or repo
    vim.fn.chdir(canonical)
    vim.cmd("edit " .. canonical .. "/page.tmpl")
    local bufnr = vim.api.nvim_get_current_buf()

    assert.are.equal("gohtmltmpl", vim.bo[bufnr].filetype)

    wait.wait_for(function()
      return vim.treesitter.highlighter.active[bufnr] ~= nil
    end, 5000, "treesitter highlighter never attached")
    -- Force a full parse so the injected html tree is materialized before we
    -- probe captures (injections parse lazily).
    vim.treesitter.get_parser(bufnr):parse(true)

    local function langs_at(col)
      local seen = {}
      for _, c in ipairs(vim.treesitter.get_captures_at_pos(bufnr, 0, col)) do
        seen[c.lang] = true
      end
      return seen
    end

    -- col 1 = the `div` tag name, highlighted by the injected html tree.
    assert.is_true(langs_at(1).html == true, "expected an injected html capture on the <div> tag")
    -- col 9 = `.Name` inside the action, highlighted by the primary gotmpl tree.
    assert.is_true(langs_at(9).gotmpl == true, "expected a gotmpl capture inside the {{ }} action")
  end)
end)
