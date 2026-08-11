local dr = require("config.decl_rules")

-- Real Go source, laid out so every branch of rule_rows shows up:
--   • a single-line package clause and import (no rule — nothing to separate)
--   • a doc-commented type, function and METHOD (a rule above each doc block)
--   • an inline comment inside a body (never a group boundary)
local GO = {
  "package main", -- 0
  "", -- 1
  'import "fmt"', -- 2
  "", -- 3  <- rule
  "// Server serves HTTP.", -- 4
  "type Server struct {", -- 5
  "\taddr string", -- 6
  "}", -- 7
  "", -- 8  <- rule
  "// New makes a Server.", -- 9
  "func New(addr string) *Server {", -- 10
  "\treturn &Server{addr}", -- 11
  "}", -- 12
  "", -- 13 <- rule
  "// ListenAndServe blocks until done.", -- 14
  "func (s *Server) ListenAndServe() error {", -- 15
  "\t// inline note about why", -- 16
  "\tfmt.Println(s.addr)", -- 17
  "\treturn nil", -- 18
  "}", -- 19
}

describe("e2e: decl_rules", function()
  local ns = vim.api.nvim_create_namespace("decl_rules")
  local buf

  -- Buffers are built through the API rather than :edit — a Go buffer would
  -- otherwise attach the LSP stack, which this spec has no use for.
  local function open(lines, ft)
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = ft
    vim.treesitter.start(buf, ft)
    return buf
  end

  local function rule_rows_painted()
    local rows = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})) do
      rows[#rows + 1] = m[2]
    end
    table.sort(rows)
    return rows
  end

  after_each(function()
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    buf = nil
  end)

  it("finds the rule rows in real Go source", function()
    open(GO, "go")
    assert.are.same({ 3, 8, 13 }, dr.rows_for(buf))
  end)

  it("paints one extmark per rule row", function()
    open(GO, "go")
    dr.paint(buf)
    assert.are.same({ 3, 8, 13 }, rule_rows_painted())
  end)

  it("paints the rule as a full-width underline, not a virtual line", function()
    open(GO, "go")
    dr.paint(buf)
    local mark = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })[1]
    local details = mark[4]
    assert.are.equal("DeclRule", details.line_hl_group)
    assert.is_nil(details.virt_lines)
    local group = vim.api.nvim_get_hl(0, { name = "DeclRule", link = false })
    assert.is_true(group.underline)
  end)

  it("repaints from scratch rather than stacking marks", function()
    open(GO, "go")
    dr.paint(buf)
    dr.paint(buf)
    dr.paint(buf)
    assert.are.same({ 3, 8, 13 }, rule_rows_painted())
  end)

  it("repaints when the filetype changes but the text does not", function()
    -- `:set filetype=` swaps the parser without bumping changedtick, so a
    -- tick-only guard would leave the Go rules painted over a buffer treesitter
    -- is now parsing as something else.
    open(GO, "go")
    dr.paint(buf)
    assert.are.same({ 3, 8, 13 }, rule_rows_painted())

    -- Assigning filetype fires FileType, which schedules the repaint.
    vim.bo[buf].filetype = "markdown"
    vim.wait(2000, function()
      return #rule_rows_painted() == 0
    end, 20)
    assert.are.same({}, rule_rows_painted())
  end)

  it("clears its marks for an excluded filetype", function()
    open({ "# Heading", "", "Some prose.", "", "# Another", "", "More prose." }, "markdown")
    dr.paint(buf)
    assert.are.same({}, rule_rows_painted())
  end)

  it("draws nothing in a buffer treesitter never attached to", function()
    -- The highlighter check is the ONLY thing carrying the large-file guard:
    -- plugins/treesitter.lua skips starting a highlighter on oversized buffers,
    -- and without this gate rows_for would call get_parser/parse() on exactly
    -- those. So the filetype must be a real, non-excluded one — otherwise
    -- eligible() returns false at EXCLUDED_FT[""] and never reaches the check.
    open(GO, "go")
    vim.treesitter.stop(buf)
    assert.is_nil(vim.treesitter.highlighter.active[buf])
    dr.paint(buf)
    assert.are.same({}, rule_rows_painted())
  end)

  it("keeps a trailing comment out of the next declaration's group", function()
    open({
      "package main", -- 0
      "", -- 1
      "func Alpha() {", -- 2
      "\tprintln(1)", -- 3
      "} // end Alpha", -- 4  <- rule for Beta lands here, NOT on row 3
      "", -- 5
      "// Beta does things.", -- 6
      "func Beta() {", -- 7
      "\tprintln(2)", -- 8
      "}", -- 9
    }, "go")
    assert.are.same({ 1, 5 }, dr.rows_for(buf))
  end)

  describe("toggle", function()
    it("registers <leader>ur", function()
      local found
      for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
        if m.lhs == " ur" then
          found = m
        end
      end
      assert.is_not_nil(found, "<leader>ur should be mapped")
      assert.is_not_nil(found.desc)
    end)

    it("clears the rules when disabled and restores them when re-enabled", function()
      open(GO, "go")
      dr.paint(buf)
      assert.are.same({ 3, 8, 13 }, rule_rows_painted())
      assert.is_true(dr.is_enabled())

      dr.toggle()
      assert.is_false(dr.is_enabled())
      assert.are.same({}, rule_rows_painted())

      dr.toggle()
      assert.is_true(dr.is_enabled())
      assert.are.same({ 3, 8, 13 }, rule_rows_painted())
    end)
  end)

  it("works the same in a second language", function()
    -- Lua: same "named child of the root" rule, no per-language node table.
    -- `local M = {}` and the trailing `return M` are single-line statements with
    -- no doc block, so they get no rule — the same call the one-line Go imports
    -- above get. Only the two functions are separated.
    open({
      "local M = {}", -- 0
      "", -- 1  <- rule
      "-- Adds two numbers.", -- 2
      "function M.add(a, b)", -- 3
      "  return a + b", -- 4
      "end", -- 5
      "", -- 6  <- rule
      "-- Subtracts two numbers.", -- 7
      "function M.sub(a, b)", -- 8
      "  return a - b", -- 9
      "end", -- 10
      "", -- 11
      "return M", -- 12
    }, "lua")
    assert.are.same({ 1, 6 }, dr.rows_for(buf))
  end)
end)
