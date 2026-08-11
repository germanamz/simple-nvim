local dr = require("config.decl_rules")

describe("config.decl_rules", function()
  describe("is_comment", function()
    it("matches the common grammar spellings", function()
      assert.is_true(dr.is_comment("comment"))
      assert.is_true(dr.is_comment("line_comment"))
      assert.is_true(dr.is_comment("block_comment"))
    end)

    it("does not match declaration node types", function()
      assert.is_false(dr.is_comment("function_declaration"))
      assert.is_false(dr.is_comment("method_declaration"))
      assert.is_false(dr.is_comment("type_declaration"))
    end)
  end)

  describe("rule_rows", function()
    it("rules the line above a multi-line declaration", function()
      -- 0: package foo
      -- 1: (blank)
      -- 2..4: func A() { … }
      local rows = dr.rule_rows({
        { type = "package_clause", s = 0, e = 0 },
        { type = "function_declaration", s = 2, e = 4 },
      })
      assert.are.same({ 1 }, rows)
    end)

    it("starts the group at the doc comment, not the declaration", function()
      -- 0: package foo
      -- 1: (blank)
      -- 2: // A does a thing.
      -- 3..4: func A() { … }
      local rows = dr.rule_rows({
        { type = "package_clause", s = 0, e = 0 },
        { type = "comment", s = 2, e = 2 },
        { type = "function_declaration", s = 3, e = 4 },
      })
      assert.are.same({ 1 }, rows)
    end)

    it("absorbs a multi-line doc comment run into the group", function()
      -- 2,3,4 are three consecutive `//` lines above the func on 5
      local rows = dr.rule_rows({
        { type = "package_clause", s = 0, e = 0 },
        { type = "comment", s = 2, e = 2 },
        { type = "comment", s = 3, e = 3 },
        { type = "comment", s = 4, e = 4 },
        { type = "function_declaration", s = 5, e = 7 },
      })
      assert.are.same({ 1 }, rows)
    end)

    it("leaves a comment separated by a blank line outside the group", function()
      -- 0: // free-standing note
      -- 1: (blank)
      -- 2: // B docs
      -- 3..4: func B() { … }
      -- The rule belongs on the blank line 1, not above the free-standing note.
      local rows = dr.rule_rows({
        { type = "comment", s = 0, e = 0 },
        { type = "comment", s = 2, e = 2 },
        { type = "function_declaration", s = 3, e = 4 },
      })
      assert.are.same({ 1 }, rows)
    end)

    it("skips single-line declarations that carry no doc comment", function()
      -- a run of one-line imports would otherwise be ruled to death
      local rows = dr.rule_rows({
        { type = "package_clause", s = 0, e = 0 },
        { type = "import_declaration", s = 2, e = 2 },
        { type = "import_declaration", s = 3, e = 3 },
        { type = "import_declaration", s = 4, e = 4 },
      })
      assert.are.same({}, rows)
    end)

    it("rules a single-line declaration that does carry a doc comment", function()
      local rows = dr.rule_rows({
        { type = "package_clause", s = 0, e = 0 },
        { type = "comment", s = 2, e = 2 },
        { type = "const_declaration", s = 3, e = 3 },
      })
      assert.are.same({ 1 }, rows)
    end)

    it("draws nothing above a declaration group that starts at row 0", function()
      assert.are.same({}, dr.rule_rows({ { type = "function_declaration", s = 0, e = 3 } }))
      assert.are.same(
        {},
        dr.rule_rows({
          { type = "comment", s = 0, e = 0 },
          { type = "function_declaration", s = 1, e = 3 },
        })
      )
    end)

    it("returns each row once, sorted", function()
      -- two declarations whose groups both start on row 3 can't happen in real
      -- source, but dedup + sort are what keep the extmark loop total.
      local rows = dr.rule_rows({
        { type = "function_declaration", s = 6, e = 8 },
        { type = "function_declaration", s = 3, e = 4 },
        { type = "function_declaration", s = 3, e = 5 },
      })
      assert.are.same({ 2, 5 }, rows)
    end)

    -- A trailing comment (`} // end Alpha`) parses as a root-level sibling whose
    -- start row is one the previous node already occupies. Treating it as the
    -- head of the NEXT declaration's doc run dragged the group start backwards
    -- into the previous function's body.
    it("does not let a trailing comment seed the next declaration's group", function()
      -- 0..2: func Alpha() { … } // end Alpha   (comment trails the `}` on row 2)
      -- 3: // Beta docs
      -- 4..6: func Beta() { … }
      local rows = dr.rule_rows({
        { type = "function_declaration", s = 0, e = 2 },
        { type = "comment", s = 2, e = 2 },
        { type = "comment", s = 3, e = 3 },
        { type = "function_declaration", s = 4, e = 6 },
      })
      -- Beta's group starts at its own doc comment on row 3, so the rule lands
      -- on row 2 (the `}` line) — never on row 1, inside Alpha's body.
      assert.are.same({ 2 }, rows)
    end)

    it("does not let a trailing comment fake a doc block for a one-liner", function()
      -- 2: const MaxRetries = 3 // per attempt
      -- 3: const Timeout = 5
      -- Neither is multi-line and neither has a doc block, so neither is ruled.
      local rows = dr.rule_rows({
        { type = "package_clause", s = 0, e = 0 },
        { type = "const_declaration", s = 2, e = 2 },
        { type = "comment", s = 2, e = 2 },
        { type = "const_declaration", s = 3, e = 3 },
      })
      assert.are.same({}, rows)
    end)

    it("still groups a doc comment that follows a trailing comment", function()
      -- The trailing comment on row 2 is dropped, but the real doc run on rows
      -- 4-5 (after a blank line) still forms the group.
      local rows = dr.rule_rows({
        { type = "function_declaration", s = 0, e = 2 },
        { type = "comment", s = 2, e = 2 },
        { type = "comment", s = 4, e = 4 },
        { type = "comment", s = 5, e = 5 },
        { type = "function_declaration", s = 6, e = 8 },
      })
      assert.are.same({ 3 }, rows)
    end)

    it("handles a file of nothing but comments", function()
      assert.are.same(
        {},
        dr.rule_rows({
          { type = "comment", s = 0, e = 0 },
          { type = "comment", s = 1, e = 1 },
        })
      )
    end)
  end)
end)
