local nvim_env = require("tests.helpers.nvim_env")

-- The full-config half of config.comments (unit rules live in
-- tests/spec/unit/comments_spec.lua): the FileType policy reaching real
-- buffers, the insert <CR> path through blink's buffer-local map and its
-- fallback, `gqc`, and the formatexpr wrapper with conform actually loaded —
-- conform is lazy (BufReadPre/BufNewFile), so an API-built buffer has an
-- EMPTY formatexpr until it is force-loaded, and a `gq` test that skips that
-- passes for the wrong reason.
describe("e2e: comment continuation and reflow", function()
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

  local function feed(s)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(s, true, false, true), "mx", false)
  end

  -- A real (listed, buftype "") buffer built through the API: go is an LSP
  -- filetype and :edit on one is banned in this lane.
  local function buffer(ft, lines)
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = ft
    return buf
  end

  local function lines(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  it("gives go and python buffers Enter continuation without o/O or t", function()
    for _, ft in ipairs({ "go", "python" }) do
      local buf = buffer(ft, {})
      local fo = vim.bo[buf].formatoptions
      assert.is_not_nil(fo:find("r", 1, true), ft .. ": r missing from " .. fo)
      assert.is_nil(fo:find("o", 1, true), ft .. ": o present in " .. fo)
      assert.is_nil(fo:find("t", 1, true), ft .. ": t present in " .. fo)
      assert.are.equal(0, vim.bo[buf].textwidth)
    end
  end)

  it("continues a // doc comment on Enter through the live <CR> map", function()
    local buf = buffer("go", { "// Doc." })
    feed("A<CR>more<Esc>")
    assert.are.same({ "// Doc.", "// more" }, lines(buf))
  end)

  it("ends the comment when Enter lands on the fresh leader", function()
    local buf = buffer("go", { "// Doc." })
    feed("A<CR><CR>x<Esc>")
    assert.are.same({ "// Doc.", "x" }, lines(buf))
  end)

  it("gqc reflows the doc comment under the cursor and leaves the func alone", function()
    local buf = buffer("go", {
      "// ListenAndServe blocks until the server is done and then returns the first error it saw",
      "func (s *Server) ListenAndServe() error {",
      "\treturn nil",
      "}",
    })
    vim.bo[buf].textwidth = 40
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    feed("gqc")
    local got = lines(buf)
    assert.are.equal("}", got[#got])
    assert.are.equal("\treturn nil", got[#got - 1])
    assert.are.equal("func (s *Server) ListenAndServe() error {", got[#got - 2])
    assert.is_true(#got > 4, "comment was not wrapped")
    for i = 1, #got - 3 do
      assert.is_true(#got[i] <= 40, "line too long: " .. got[i])
      assert.are.equal("// ", got[i]:sub(1, 3))
    end
  end)

  describe("with conform loaded", function()
    before_each(function()
      require("lazy").load({ plugins = { "conform.nvim" } })
    end)

    it("owns formatexpr and wraps conform's", function()
      assert.are.equal("v:lua.require'config.comments'.formatexpr()", vim.o.formatexpr)
    end)

    it("reflows a comment-only gq range with the internal formatter", function()
      local buf = buffer("lua", { "-- aaaa bbbb cccc dddd", "local x = 1" })
      vim.bo[buf].textwidth = 12
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd("normal! gqq")
      assert.are.same({ "-- aaaa bbbb", "-- cccc dddd", "local x = 1" }, lines(buf))
    end)

    it("still hands a code range to conform", function()
      if vim.fn.executable("stylua") ~= 1 then
        pending("stylua not on PATH")
        return
      end
      local buf = buffer("lua", { "local x={1,2}" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd("normal! gqq")
      assert.are.same({ "local x = { 1, 2 }" }, lines(buf))
    end)
  end)
end)
