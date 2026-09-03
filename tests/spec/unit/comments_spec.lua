-- Pins config.comments: the formatoptions policy that makes Enter continue a
-- comment in every code buffer, the Enter-on-a-fresh-leader rule that ends one,
-- the comment-block finder behind `gqc`, and the formatexpr wrapper that lets
-- `gq` reflow comment-only ranges instead of handing them to conform.
--
-- The unit lane runs the runtime ftplugins (a bare `vim.bo.filetype = "go"`
-- gives the buffer go.vim's `comments`/`formatoptions`) and can parse go and
-- lua, so both the treesitter path and the ftplugin-driven policy are testable
-- here without the full config.
local comments = require("config.comments")

local function keys(s)
  return vim.api.nvim_replace_termcodes(s, true, false, true)
end

local function feed(s)
  vim.api.nvim_feedkeys(keys(s), "mx", false)
end

local function scratch(ft, lines)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft
  return buf
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function has(fo, flag)
  return fo:find(flag, 1, true) ~= nil
end

describe("config.comments", function()
  after_each(function()
    vim.cmd("silent! %bwipeout!")
  end)

  describe("is_fresh_leader", function()
    it("matches the leader Neovim just inserted: leader plus trailing space", function()
      assert.is_true(comments.is_fresh_leader("// ", "//"))
      assert.is_true(comments.is_fresh_leader("\t// ", "//"))
      assert.is_true(comments.is_fresh_leader("  # ", "#"))
    end)

    it("matches a doc-style leader made of the same characters", function()
      -- lua's `---` and rust's `///` are the `--` / `//` leader repeated
      assert.is_true(comments.is_fresh_leader("--- ", "--"))
      assert.is_true(comments.is_fresh_leader("/// ", "//"))
    end)

    it("rejects a bare leader, which is a paragraph separator", function()
      assert.is_false(comments.is_fresh_leader("//", "//"))
      assert.is_false(comments.is_fresh_leader("\t//", "//"))
      assert.is_false(comments.is_fresh_leader("--", "--"))
    end)

    it("rejects a leader followed by text", function()
      assert.is_false(comments.is_fresh_leader("// x ", "//"))
      assert.is_false(comments.is_fresh_leader("//go:build ", "//"))
      assert.is_false(comments.is_fresh_leader("//! ", "//"))
    end)

    it("rejects lines that do not start with the leader", function()
      assert.is_false(comments.is_fresh_leader("x ", "//"))
      assert.is_false(comments.is_fresh_leader("   ", "//"))
      assert.is_false(comments.is_fresh_leader("", "//"))
      assert.is_false(comments.is_fresh_leader("# ", "//"))
    end)
  end)

  describe("is_bare_leader", function()
    it("matches a leader with nothing after it", function()
      assert.is_true(comments.is_bare_leader("//", "//"))
      assert.is_true(comments.is_bare_leader("\t///", "//"))
      assert.is_true(comments.is_bare_leader("  #", "#"))
    end)

    it("rejects a fresh leader, text, and other lines", function()
      assert.is_false(comments.is_bare_leader("// ", "//"))
      assert.is_false(comments.is_bare_leader("// x", "//"))
      assert.is_false(comments.is_bare_leader("//!", "//"))
      assert.is_false(comments.is_bare_leader("#!", "#"))
      assert.is_false(comments.is_bare_leader("", "//"))
      assert.is_false(comments.is_bare_leader("x", "//"))
    end)
  end)

  describe("apply", function()
    it("adds r and drops t and o for a go buffer", function()
      local buf = scratch("go", {})
      -- the runtime's go.vim leaves the buffer at `cqj`: no r, no o
      assert.are.equal("cqj", vim.bo[buf].formatoptions)
      comments.apply(buf)
      local fo = vim.bo[buf].formatoptions
      assert.is_true(has(fo, "r"), "r missing from " .. fo)
      assert.is_true(has(fo, "q"), "q missing from " .. fo)
      assert.is_true(has(fo, "j"), "j missing from " .. fo)
      assert.is_true(has(fo, "l"), "l missing from " .. fo)
      assert.is_true(has(fo, "n"), "n missing from " .. fo)
      assert.is_false(has(fo, "t"), "t present in " .. fo)
      assert.is_false(has(fo, "o"), "o present in " .. fo)
    end)

    it("drops o from a lua buffer whose ftplugin adds croql", function()
      local buf = scratch("lua", {})
      assert.is_true(has(vim.bo[buf].formatoptions, "o"))
      comments.apply(buf)
      local fo = vim.bo[buf].formatoptions
      assert.is_true(has(fo, "r"))
      assert.is_false(has(fo, "o"), "o present in " .. fo)
    end)

    it("stops python code from auto-wrapping while continuing # comments", function()
      local buf = scratch("python", {})
      -- python has no ftplugin formatoptions of its own: Neovim's default tcqj
      assert.is_true(has(vim.bo[buf].formatoptions, "t"))
      comments.apply(buf)
      local fo = vim.bo[buf].formatoptions
      assert.is_false(has(fo, "t"), "t present in " .. fo)
      assert.is_true(has(fo, "r"))
    end)

    it("is idempotent", function()
      local buf = scratch("go", {})
      comments.apply(buf)
      local once = vim.bo[buf].formatoptions
      comments.apply(buf)
      assert.are.equal(once, vim.bo[buf].formatoptions)
    end)

    it("leaves markdown alone", function()
      local buf = scratch("markdown", {})
      local before = vim.bo[buf].formatoptions
      comments.apply(buf)
      assert.are.equal(before, vim.bo[buf].formatoptions)
      assert.is_false(has(vim.bo[buf].formatoptions, "r"))
    end)

    it("leaves gitcommit alone: its ftplugin wants prose wrapping", function()
      local buf = scratch("gitcommit", {})
      local before = vim.bo[buf].formatoptions
      comments.apply(buf)
      assert.are.equal(before, vim.bo[buf].formatoptions)
      assert.is_true(has(vim.bo[buf].formatoptions, "t"))
    end)

    it("leaves non-file buffers alone", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = "nofile"
      vim.bo[buf].filetype = "go"
      comments.apply(buf)
      assert.are.equal("cqj", vim.bo[buf].formatoptions)
    end)

    it("does not set textwidth: only a project's editorconfig does", function()
      local buf = scratch("go", {})
      comments.apply(buf)
      assert.are.equal(0, vim.bo[buf].textwidth)
    end)

    it("keeps a textwidth the ftplugin set", function()
      local buf = scratch("rust", {})
      assert.are.equal(100, vim.bo[buf].textwidth)
      comments.apply(buf)
      assert.are.equal(100, vim.bo[buf].textwidth)
    end)

    it("teaches formatlistpat gofmt-style bullets", function()
      local buf = scratch("go", {})
      comments.apply(buf)
      assert.is_not_nil(vim.bo[buf].formatlistpat:find("[-*+]", 1, true))
    end)
  end)

  describe("block", function()
    it("returns the run of line comments around the row, 0-indexed inclusive", function()
      local buf = scratch("lua", {
        "local a = 1", -- 0
        "", -- 1
        "-- one", -- 2
        "-- two", -- 3
        "--", -- 4
        "-- three", -- 5
        "local function f() end", -- 6
      })
      assert.are.same({ 2, 5 }, comments.block(buf, 2))
      assert.are.same({ 2, 5 }, comments.block(buf, 4))
      assert.are.same({ 2, 5 }, comments.block(buf, 5))
    end)

    it("returns nil off a comment", function()
      local buf = scratch("lua", { "local a = 1", "", "-- one", "local b = 2" })
      assert.is_nil(comments.block(buf, 0))
      assert.is_nil(comments.block(buf, 1))
      assert.is_nil(comments.block(buf, 3))
    end)

    it("excludes a trailing comment from the run", function()
      local buf = scratch("lua", {
        "-- doc", -- 0
        "local x = 1 -- trailing", -- 1
        "-- other", -- 2
      })
      assert.are.same({ 0, 0 }, comments.block(buf, 0))
      assert.is_nil(comments.block(buf, 1))
      assert.are.same({ 2, 2 }, comments.block(buf, 2))
    end)

    it("splits at a leader change", function()
      local buf = scratch("lua", {
        "-- plain", -- 0
        "--- doc", -- 1
        "--- more", -- 2
      })
      assert.are.same({ 0, 0 }, comments.block(buf, 0))
      assert.are.same({ 1, 2 }, comments.block(buf, 1))
    end)

    it("treats a directive as a boundary and never as a block", function()
      local buf = scratch("go", {
        "//go:build linux", -- 0
        "", -- 1
        "// Package x does things.", -- 2
        "//", -- 3
        "// More.", -- 4
        "//go:generate stringer", -- 5
        "package x", -- 6
      })
      assert.is_nil(comments.block(buf, 0))
      assert.are.same({ 2, 4 }, comments.block(buf, 2))
      assert.are.same({ 2, 4 }, comments.block(buf, 4))
      assert.is_nil(comments.block(buf, 5))
    end)

    it("keeps lua annotations out of the prose block", function()
      local buf = scratch("lua", {
        "--- Summary.", -- 0
        "---@param x number", -- 1
        "--- Trailing prose.", -- 2
      })
      assert.are.same({ 0, 0 }, comments.block(buf, 0))
      assert.is_nil(comments.block(buf, 1))
      assert.are.same({ 2, 2 }, comments.block(buf, 2))
    end)

    it("returns a block comment's whole span", function()
      local buf = scratch("lua", { "--[[ a", "b", "c ]]", "local x = 1" })
      assert.are.same({ 0, 2 }, comments.block(buf, 1))
      assert.is_nil(comments.block(buf, 3))
    end)

    it("falls back to commentstring when there is no parser", function()
      local buf = scratch("nosuchlang", { "# a", "# b", "x = 1", "# c" })
      vim.bo[buf].commentstring = "# %s"
      assert.are.same({ 0, 1 }, comments.block(buf, 0))
      assert.is_nil(comments.block(buf, 2))
      assert.are.same({ 3, 3 }, comments.block(buf, 3))
    end)
  end)

  describe("reflow", function()
    local LONG =
      "-- ListenAndServe blocks until the server is done and then returns the first error it saw"

    it("rewraps the block under the cursor at textwidth and leaves the code alone", function()
      local buf = scratch("lua", { LONG, "-- Second line.", "local function f() end" })
      vim.bo[buf].textwidth = 30
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      comments.reflow()
      local got = lines(buf)
      assert.are.equal("local function f() end", got[#got])
      local text = {}
      for i = 1, #got - 1 do
        assert.is_true(#got[i] <= 30, "line too long: " .. got[i])
        assert.are.equal("-- ", got[i]:sub(1, 3))
        text[#text + 1] = got[i]:sub(4)
      end
      assert.are.equal(LONG:sub(4) .. " Second line.", table.concat(text, " "))
    end)

    it("wraps at 79 columns when textwidth is 0, whatever the window width", function()
      local buf = scratch(
        "lua",
        { LONG .. " while serving requests, plus enough words to pass eighty columns." }
      )
      local columns = vim.o.columns
      vim.o.columns = 40
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      comments.reflow()
      vim.o.columns = columns
      local got = lines(buf)
      assert.is_true(#got >= 2)
      local longest = 0
      for _, l in ipairs(got) do
        longest = math.max(longest, #l)
        assert.is_true(#l <= 79, "line too long: " .. l)
      end
      -- not the 39 a 40-column window would give
      assert.is_true(longest > 39, "wrapped at the window width: " .. longest)
      assert.are.equal(0, vim.bo[buf].textwidth)
    end)

    it("keeps gofmt-style bullets separate", function()
      local buf = scratch("lua", {
        "--   - first bullet with enough words to need wrapping",
        "--   - second bullet",
      })
      comments.apply(buf)
      vim.bo[buf].textwidth = 30
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      comments.reflow()
      local got = lines(buf)
      assert.are.equal("--   - first bullet with", got[1])
      assert.are.equal("--   - second bullet", got[#got])
    end)

    it("does nothing off a comment", function()
      local buf = scratch("lua", { "local x = 1", LONG })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      comments.reflow()
      assert.are.same({ "local x = 1", LONG }, lines(buf))
    end)
  end)

  describe("cr", function()
    before_each(function()
      vim.keymap.set("i", "<CR>", function()
        return comments.cr()
      end, { expr = true, replace_keycodes = false })
    end)

    after_each(function()
      pcall(vim.keymap.del, "i", "<CR>")
    end)

    it("continues the comment leader on Enter", function()
      local buf = scratch("go", { "// Doc." })
      comments.apply(buf)
      feed("A<CR>more<Esc>")
      assert.are.same({ "// Doc.", "// more" }, lines(buf))
    end)

    it("turns the fresh leader into a code line on a second Enter", function()
      local buf = scratch("go", { "// Doc." })
      comments.apply(buf)
      feed("A<CR><CR>x<Esc>")
      assert.are.same({ "// Doc.", "x" }, lines(buf))
    end)

    it("keeps the indent of the line it clears", function()
      local buf = scratch("go", { "func f() {", "\t// Doc.", "}" })
      comments.apply(buf)
      feed("2GA<CR><CR>x<Esc>")
      assert.are.same({ "func f() {", "\t// Doc.", "\tx", "}" }, lines(buf))
    end)

    it("continues after a bare leader (the paragraph separator) with a fresh one", function()
      -- Neovim alone would give a bare `//` again; the space makes the new line
      -- the same fresh leader every other Enter produces.
      local buf = scratch("go", { "// Doc.", "//" })
      comments.apply(buf)
      feed("2GA<CR>x<Esc>")
      assert.are.same({ "// Doc.", "//", "// x" }, lines(buf))
    end)

    it("does the same for a python `#`, whose comments entry has the b flag", function()
      local buf = scratch("python", { "# Doc.", "#" })
      comments.apply(buf)
      feed("2GA<CR>x<Esc>")
      assert.are.same({ "# Doc.", "#", "# x" }, lines(buf))
    end)

    it("ends the comment after a separator followed by a second Enter", function()
      -- Two insert sessions on purpose. Fed as one burst, insert mode batches
      -- the space the first <CR> returns with a peek that resolves the second
      -- <CR>'s expr mapping BEFORE the space is in the buffer, so it sees a
      -- bare leader again. Typed keys never queue that way (PTY-verified);
      -- macros and pasted key bursts do, and get an extra `// ` line there.
      local buf = scratch("go", { "// Doc.", "//" })
      comments.apply(buf)
      feed("2GA<CR><Esc>")
      assert.are.same({ "// Doc.", "//", "// " }, lines(buf))
      feed("A<CR>x<Esc>")
      assert.are.same({ "// Doc.", "//", "x" }, lines(buf))
    end)

    it("is a plain newline off a comment", function()
      local buf = scratch("go", { "x := 1" })
      comments.apply(buf)
      feed("A<CR>y<Esc>")
      assert.are.same({ "x := 1", "y" }, lines(buf))
    end)

    it("is a plain newline when r is off", function()
      local buf = scratch("go", { "// " })
      vim.bo[buf].formatoptions = "cqj"
      feed("A<CR>x<Esc>")
      local got = lines(buf)
      assert.are.equal(2, #got)
      assert.are.equal("x", got[2])
    end)
  end)

  describe("formatexpr", function()
    local FEX = "v:lua.require'config.comments'.formatexpr()"
    local called

    before_each(function()
      called = false
      package.loaded["conform"] = {
        formatexpr = function()
          called = true
          return 0
        end,
      }
    end)

    after_each(function()
      package.loaded["conform"] = nil
    end)

    it("reflows a comment-only range with the internal formatter", function()
      local buf = scratch("lua", { "-- aaaa bbbb cccc dddd", "local x = 1" })
      vim.bo[buf].formatexpr = FEX
      vim.bo[buf].textwidth = 12
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd("normal! gqq")
      assert.are.same({ "-- aaaa bbbb", "-- cccc dddd", "local x = 1" }, lines(buf))
      assert.is_false(called)
    end)

    it("hands a code range to conform", function()
      local buf = scratch("lua", { "local x = 1" })
      vim.bo[buf].formatexpr = FEX
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd("normal! gqq")
      assert.is_true(called)
      assert.are.same({ "local x = 1" }, lines(buf))
    end)

    it("hands a mixed range to conform", function()
      local buf = scratch("lua", { "-- aaaa bbbb cccc dddd", "local x = 1" })
      vim.bo[buf].formatexpr = FEX
      vim.bo[buf].textwidth = 12
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd("normal! gqj")
      assert.is_true(called)
      assert.are.same({ "-- aaaa bbbb cccc dddd", "local x = 1" }, lines(buf))
    end)
  end)
end)
