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
    {
      -- .fga → ft fga (pinned by extension in init.lua), parsed by the
      -- out-of-tree fga parser config.ts_pinned registers (matoous/
      -- tree-sitter-fga is not in nvim-treesitter's registry). col 0 = the
      -- `model` keyword.
      label = "fga",
      path = "model.fga",
      content = "model\n  schema 1.1\n\ntype user\n",
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

  -- OpenFGA models: the queries are vendored in queries/fga/ (upstream's use a
  -- predicate core Neovim has no handler for), so exercise each of them —
  -- highlights, indents, folds — against a representative model rather than
  -- trusting the parser alone.
  describe("fga (OpenFGA)", function()
    local MODEL = {
      "model", -- 0
      "  schema 1.1", -- 1
      "", -- 2
      "type user", -- 3
      "", -- 4
      "type group", -- 5
      "  relations", -- 6
      "    define member: [user]", -- 7
      "", -- 8
      "# folders nest", -- 9
      "type folder", -- 10
      "  relations", -- 11
      "    define parent: [folder]", -- 12
      "    define viewer: [user, user:*, group#member with non_expired] or viewer from parent", -- 13
      "", -- 14
      "condition non_expired(current_time: timestamp, grant_time: timestamp) {", -- 15
      "  current_time < grant_time && grant_time.getFullYear() > 2000", -- 16
      "}", -- 17
    }

    local bufnr

    local function open_model()
      local repo = git_fixture.repo({
        commits = {
          { files = { ["model.fga"] = table.concat(MODEL, "\n") .. "\n" } },
          message = "init",
        },
      })
      local canonical = vim.uv.fs_realpath(repo) or repo
      vim.fn.chdir(canonical)
      vim.cmd("edit " .. canonical .. "/model.fga")
      bufnr = vim.api.nvim_get_current_buf()
      wait.wait_for(function()
        return vim.treesitter.highlighter.active[bufnr] ~= nil
      end, 5000, "treesitter highlighter never attached to the fga buffer")
      vim.treesitter.get_parser(bufnr):parse(true)
    end

    local function captures_at(row, col)
      local names = {}
      for _, c in ipairs(vim.treesitter.get_captures_at_pos(bufnr, row, col)) do
        names[c.capture] = true
      end
      return names
    end

    it("parses the whole model without error nodes", function()
      open_model()
      assert.is_false(
        vim.treesitter.get_parser(bufnr):parse(true)[1]:root():has_error(),
        "grammar produced ERROR nodes for a valid model"
      )
    end)

    it("highlights keywords, types, relations, refs, conditions and comments", function()
      open_model()
      assert.is_true(captures_at(0, 0)["keyword"] == true, "`model` should be @keyword")
      assert.is_true(captures_at(5, 0)["keyword.type"] == true, "`type` should be @keyword.type")
      assert.is_true(captures_at(5, 5)["type"] == true, "type name should be @type")
      assert.is_true(captures_at(7, 4)["keyword"] == true, "`define` should be @keyword")
      assert.is_true(captures_at(7, 11)["property"] == true, "relation name should be @property")
      assert.is_true(captures_at(7, 20)["type"] == true, "`[user]` restriction should be @type")
      -- line 13: `    define viewer: [user, user:*, group#member with non_expired] or viewer from parent`
      assert.is_true(captures_at(13, 34)["type"] == true, "`group#member` ref should be @type")
      assert.is_true(
        captures_at(13, 47)["keyword.operator"] == true,
        "`with` should be @keyword.operator"
      )
      assert.is_true(
        captures_at(13, 52)["function.call"] == true,
        "condition reference should be @function.call"
      )
      assert.is_true(
        captures_at(13, 65)["keyword.operator"] == true,
        "`or` should be @keyword.operator"
      )
      assert.is_true(
        captures_at(13, 75)["keyword.operator"] == true,
        "`from` should be @keyword.operator"
      )
      assert.is_true(captures_at(9, 0)["comment"] == true, "`# …` should be @comment")
      assert.is_true(
        captures_at(15, 0)["keyword.function"] == true,
        "`condition` should be @keyword.function"
      )
      assert.is_true(captures_at(15, 10)["function"] == true, "condition name should be @function")
      assert.is_true(
        captures_at(15, 22)["variable.parameter"] == true,
        "condition param should be @variable.parameter"
      )
      assert.is_true(
        captures_at(15, 36)["type.builtin"] == true,
        "`timestamp` should be @type.builtin"
      )
      assert.is_true(captures_at(16, 15)["operator"] == true, "CEL `<` should be @operator")
      -- `grant_time.getFullYear()`: the call pattern and the generic
      -- @variable pattern both match the identifier; the LAST capture is the
      -- one the highlighter paints, so it has to be the call.
      local call = vim.treesitter.get_captures_at_pos(bufnr, 16, 42)
      assert.are.equal(
        "function.call",
        call[#call].capture,
        "CEL call should paint as @function.call"
      )
    end)

    it("indents relations under type, define under relations, and CEL under condition", function()
      open_model()
      vim.api.nvim_set_current_buf(bufnr)
      local indent = require("nvim-treesitter.indent").get_indent
      -- 1-indexed lines
      assert.are.equal(0, indent(6), "`type group` should sit at column 0")
      assert.are.equal(2, indent(7), "`relations` should be indented under its type")
      assert.are.equal(4, indent(8), "`define` should be indented under relations")
      assert.are.equal(4, indent(14), "a second `define` keeps the relations indent")
      assert.are.equal(2, indent(17), "a CEL line is indented inside the condition body")
      assert.are.equal(0, indent(18), "the closing `}` returns to column 0")
    end)

    -- What `o` / <CR> compute: the blank line's indent comes from the last node
    -- of the line above. Built through the API rather than a git fixture; the
    -- interesting rows are the empty ones.
    it("indents a new blank line from the structure above it", function()
      -- A file without the `model` / `schema` header is one ERROR node, and
      -- (ERROR) @indent.auto hands every line back to autoindent (-1); the
      -- header keeps this a valid model so the structure rules are what's
      -- measured.
      local lines = {
        "model", -- 1
        "  schema 1.1", -- 2
        "type user", -- 3
        "", -- 4  after a relation-less type: stay at 0 for the next `type`
        "type folder", -- 5
        "  relations", -- 6
        "", -- 7  after relations: the first define goes to 4
        "    define parent: [folder]", -- 8
        "", -- 9  after a define: the next define stays at 4
        "condition c(x: int) {", -- 10
        "", -- 11 inside the body
        "  x > 1", -- 12
        "}", -- 13
        "", -- 14 after the body: back to 0
      }
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = "fga"
      vim.bo[buf].shiftwidth = 2
      vim.api.nvim_set_current_buf(buf)
      vim.treesitter.start(buf, "fga")
      vim.treesitter.get_parser(buf):parse(true)
      local indent = require("nvim-treesitter.indent").get_indent
      assert.are.equal(0, indent(4))
      assert.are.equal(4, indent(7))
      assert.are.equal(4, indent(9))
      assert.are.equal(2, indent(11))
      assert.are.equal(0, indent(14))
    end)

    -- Mid-typing: `relations` with no define yet is an ERROR node *beside*
    -- the type declaration, not inside it. Kept in its own buffer because an
    -- ERROR anywhere makes nvim-treesitter treat every top-level node as
    -- "in error" (parent:has_error() is transitive), which shifts the
    -- error-free expectations above.
    it("indents the first define under a bare `relations` while it is still being typed", function()
      local lines = { "model", "  schema 1.1", "type doc", "  relations", "" }
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = "fga"
      vim.bo[buf].shiftwidth = 2
      vim.api.nvim_set_current_buf(buf)
      vim.treesitter.start(buf, "fga")
      vim.treesitter.get_parser(buf):parse(true)
      assert.are.equal(4, require("nvim-treesitter.indent").get_indent(5))
    end)

    -- A `#` comment after the LAST define of a relations block is a trailing
    -- extra that tree-sitter hangs off source_file, so nvim-treesitter's
    -- indentexpr would put it — and the line opened under it — at column 0.
    -- config.fga_indent hands comment lines and the line after one back to
    -- autoindent; that is what the buffer's indentexpr points at.
    it("keeps a trailing comment, and the line after it, at the block's indent", function()
      open_model()
      vim.api.nvim_set_current_buf(bufnr)
      assert.are.equal("v:lua.require'config.fga_indent'.indentexpr()", vim.bo[bufnr].indentexpr)
      vim.api.nvim_buf_set_lines(bufnr, 14, 14, false, { "    # trailing note", "" })
      vim.treesitter.get_parser(bufnr):parse(true)
      local function indentexpr(lnum)
        vim.v.lnum = lnum
        return vim.fn.eval(vim.bo[bufnr].indentexpr)
      end
      -- -1 = keep the current indent / autoindent from the previous line
      assert.are.equal(-1, indentexpr(15), "the comment line itself")
      assert.are.equal(-1, indentexpr(16), "the blank line opened under it")
      -- everything else still goes through treesitter
      assert.are.equal(4, indentexpr(14), "`define viewer` above the comment")
    end)

    it("folds a type declaration and a condition, not a lone `type user`", function()
      open_model()
      vim.api.nvim_set_current_buf(bufnr)
      -- foldexpr(lnum) reads its argument (v:lnum is only the fallback when
      -- called from 'foldexpr' with no args), so pass the line directly.
      local function level(lnum)
        return vim.treesitter.foldexpr(lnum)
      end
      assert.are.equal(">1", level(6), "`type group` opens a fold")
      assert.are.equal(">1", level(16), "`condition …` opens a fold")
      assert.are.equal("0", level(4), "`type user` (one line) is not a fold")
    end)
  end)

  it("treats fga.mod (the module manifest) as an fga buffer", function()
    local repo = git_fixture.repo({
      commits = {
        { files = { ["fga.mod"] = "schema: '1.2'\ncontents:\n  - core.fga\n" } },
        message = "init",
      },
    })
    local canonical = vim.uv.fs_realpath(repo) or repo
    vim.fn.chdir(canonical)
    vim.cmd("edit " .. canonical .. "/fga.mod")
    local bufnr = vim.api.nvim_get_current_buf()
    assert.are.equal("fga", vim.bo[bufnr].filetype)
    wait.wait_for(function()
      return vim.treesitter.highlighter.active[bufnr] ~= nil
    end, 5000, "treesitter highlighter never attached to fga.mod")
    assert.is_false(vim.treesitter.get_parser(bufnr):parse(true)[1]:root():has_error())
    -- the `- file` entries indent under `contents:`
    vim.api.nvim_set_current_buf(bufnr)
    local indent = require("nvim-treesitter.indent").get_indent
    assert.are.equal(2, indent(3), "`- core.fga` sits under contents:")
    vim.api.nvim_buf_set_lines(bufnr, 3, 3, false, { "" })
    vim.treesitter.get_parser(bufnr):parse(true)
    assert.are.equal(2, indent(4), "a new entry line lands under contents:")
  end)
end)
