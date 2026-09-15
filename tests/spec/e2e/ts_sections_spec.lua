-- `]]` / `[[` as a treesitter section motion (config.ts_sections).
--
-- Buffers are built through the API rather than `:edit` — the e2e lane cannot
-- re-edit files of an LSP-attached filetype without dragging a stale lsp.log
-- path into the next spec. Filetype is set inside nvim_buf_call so the runtime
-- ftplugins `setlocal` onto the intended buffer and not whichever one the
-- harness happens to be standing in.
local function make_buf(ft, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_call(buf, function()
    vim.bo.filetype = ft
  end)
  return buf
end

-- Target rows as 1-indexed line numbers, which is what the assertions read in.
local function target_lines(buf)
  local rows = {}
  for _, t in ipairs(require("config.ts_sections").targets(buf)) do
    rows[#rows + 1] = t.row + 1
  end
  return rows
end

describe("e2e: ts_sections", function()
  after_each(function()
    vim.cmd("silent! %bwipeout!")
  end)

  describe("function tier (locals.scm)", function()
    it("finds every C function when the brace is not in column 1", function()
      local buf = make_buf("c", {
        "#include <stdio.h>",
        "",
        "int alpha(int x) {",
        "  return x + 1;",
        "}",
        "",
        "int beta(int y) {",
        "  return y * 2;",
        "}",
        "",
        "int main(void)",
        "{",
        "  return alpha(1) + beta(2);",
        "}",
      })
      assert.are.same({ 3, 7, 11 }, target_lines(buf))
    end)

    it("targets the first non-blank column of the signature row", function()
      local buf = make_buf("c", { "int alpha(int x) {", "  return x;", "}" })
      assert.are.same({ row = 0, col = 0 }, require("config.ts_sections").targets(buf)[1])
    end)

    it("finds C++ methods nested inside a class", function()
      local buf = make_buf("cpp", {
        "class Widget {",
        "public:",
        "  void draw() {",
        "  }",
        "  int size() const {",
        "    return 0;",
        "  }",
        "};",
      })
      assert.are.same({ 3, 5 }, target_lines(buf))
    end)

    it("finds named lua functions and methods", function()
      local buf = make_buf("lua", {
        "local M = {}",
        "",
        "function M.alpha(x)",
        "  return x",
        "end",
        "",
        "function M:beta()",
        "  return self",
        "end",
        "",
        "return M",
      })
      assert.are.same({ 3, 7 }, target_lines(buf))
    end)

    it("skips anonymous callbacks in javascript", function()
      local buf = make_buf("javascript", {
        "function alpha(xs) {",
        "  return xs.map(x => x + 1);",
        "}",
        "",
        "function beta() {",
        "  return 2;",
        "}",
      })
      assert.are.same({ 1, 5 }, target_lines(buf))
    end)
  end)

  describe("structural tier (languages with no function captures)", function()
    it("descends past the wrapper node to json's top-level keys", function()
      local buf = make_buf("json", {
        "{",
        '  "name": "demo",',
        '  "version": "1.0.0",',
        '  "private": true',
        "}",
      })
      assert.are.same({ 2, 3, 4 }, target_lines(buf))
    end)

    it("reaches nested markdown headings, not just the top level", function()
      local buf = make_buf("markdown", {
        "# One",
        "",
        "text",
        "",
        "## One A",
        "",
        "more",
        "",
        "# Two",
      })
      assert.are.same({ 1, 5, 9 }, target_lines(buf))
    end)

    it("finds each terraform block", function()
      local buf = make_buf("terraform", {
        'resource "aws_instance" "web" {',
        '  ami = "ami-123"',
        "}",
        "",
        'variable "region" {',
        '  default = "us-east-1"',
        "}",
      })
      assert.are.same({ 1, 5 }, target_lines(buf))
    end)
  end)

  describe("the motion", function()
    local function cursor_line(buf, start_line, keys)
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_win_set_cursor(0, { start_line, 0 })
      vim.cmd("normal " .. keys)
      return vim.api.nvim_win_get_cursor(0)[1]
    end

    local c_lines = {
      "#include <stdio.h>",
      "",
      "int alpha(int x) {",
      "  return x + 1;",
      "}",
      "",
      "int beta(int y) {",
      "  return y * 2;",
      "}",
      "",
      "int main(void)",
      "{",
      "  return alpha(1) + beta(2);",
      "}",
    }

    it("moves ]] to the next function instead of the next column-1 brace", function()
      assert.equals(3, cursor_line(make_buf("c", c_lines), 1, "]]"))
    end)

    it("honors a count", function()
      assert.equals(7, cursor_line(make_buf("c", c_lines), 1, "2]]"))
    end)

    -- From inside main's body the previous section start is main's own
    -- signature, not the function above it. Stock [[ lands on the column-1
    -- brace at line 12 instead.
    it("moves [[ back to the previous function", function()
      assert.equals(11, cursor_line(make_buf("c", c_lines), 13, "[["))
    end)

    it("honors a count going backwards", function()
      assert.equals(7, cursor_line(make_buf("c", c_lines), 13, "2[["))
    end)

    it("runs ]] off the end to the last line", function()
      assert.equals(14, cursor_line(make_buf("c", c_lines), 11, "]]"))
    end)

    it("runs [[ off the front to the first line", function()
      assert.equals(1, cursor_line(make_buf("c", c_lines), 2, "[["))
    end)

    it("pushes the jumplist so <C-o> returns", function()
      local buf = make_buf("c", c_lines)
      assert.equals(3, cursor_line(buf, 1, "]]"))
      vim.cmd("normal! \15") -- <C-o>
      assert.equals(1, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("works as an operator motion", function()
      local buf = make_buf("c", c_lines)
      vim.api.nvim_set_current_buf(buf)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      vim.cmd("normal d]]")
      assert.equals("int beta(int y) {", vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
    end)

    -- The runtime markdown ftplugin maps ]] to its own heading search, which
    -- stays put once there is no further heading. Ours runs to EOF like every
    -- other filetype, so this asserts the override actually took.
    it("overrides the runtime markdown mapping with the same motion", function()
      local buf = make_buf("markdown", { "# One", "", "## One A", "", "# Two", "", "tail" })
      assert.equals(3, cursor_line(buf, 1, "]]"))
      assert.equals(7, cursor_line(buf, 5, "]]"))
    end)
  end)
end)
