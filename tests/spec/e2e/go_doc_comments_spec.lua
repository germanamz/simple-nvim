-- Guards after/queries/go/highlights.scm: upstream's doc-comment patterns skip
-- `method_declaration`, so without the extension every method's doc block fell
-- back to plain @comment and rendered a tier louder than a function's.
local GO = {
  "// Package main is the doc.", -- 0
  "package main", -- 1
  "", -- 2
  "// Server serves HTTP.", -- 3
  "type Server struct {", -- 4
  "\taddr string", -- 5
  "}", -- 6
  "", -- 7
  "// New makes a Server.", -- 8
  "func New(addr string) *Server {", -- 9
  "\treturn &Server{addr}", -- 10
  "}", -- 11
  "", -- 12
  "// ListenAndServe blocks until done.", -- 13
  "func (s *Server) ListenAndServe() error {", -- 14
  "\t// inline note about why", -- 15
  "\treturn nil", -- 16
  "}", -- 17
  "", -- 18
  "// free-standing note, attached to nothing", -- 19
}

describe("e2e: go doc comments", function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, GO)
    vim.bo[buf].filetype = "go"
    vim.treesitter.start(buf, "go")
  end)

  after_each(function()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    buf = nil
  end)

  -- Walks the resolved `highlights` query directly. get_captures_at_pos reports
  -- nothing for a buffer that is parsed but never displayed, which every buffer
  -- in a headless spec is.
  local function captures_on(row)
    local parser = vim.treesitter.get_parser(buf, "go")
    parser:parse(true)
    local query = vim.treesitter.query.get("go", "highlights")
    local found = {}
    for id, node in query:iter_captures(parser:trees()[1]:root(), buf, row, row + 1) do
      local s, _, e = node:range()
      if row >= s and row <= e then
        found[query.captures[id]] = true
      end
    end
    return found
  end

  it("captures the doc comment above a METHOD as documentation", function()
    -- The whole point of the extension: this row is the one upstream misses.
    assert.is_true(captures_on(13)["comment.documentation"])
  end)

  it("still captures the upstream cases", function()
    assert.is_true(captures_on(0)["comment.documentation"], "package doc")
    assert.is_true(captures_on(3)["comment.documentation"], "doc above a type")
    assert.is_true(captures_on(8)["comment.documentation"], "doc above a function")
  end)

  it("leaves an inline comment in the ordinary tier", function()
    local caps = captures_on(15)
    assert.is_true(caps["comment"])
    assert.is_not_true(caps["comment.documentation"])
  end)

  it("leaves a comment attached to no declaration in the ordinary tier", function()
    local caps = captures_on(19)
    assert.is_true(caps["comment"])
    assert.is_not_true(caps["comment.documentation"])
  end)

  it("separates declaration names from call sites", function()
    -- config.syntax_emphasis bolds the first set and leaves the second alone;
    -- if these captures ever merge upstream, the bolding silently spreads.
    assert.is_true(captures_on(9)["function"], "func New is a declaration")
    assert.is_true(captures_on(14)["function.method"], "ListenAndServe is a method decl")
    assert.is_true(captures_on(4)["type.definition"], "type Server is a definition")
  end)
end)
