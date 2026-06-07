-- Pins the markdown <leader>w rewrap planner extracted from options.lua. The
-- pure plan_actions walks a line range and classifies it into prose chunks and
-- fenced-code blocks (skipping table rows), which the rewrap orchestrator then
-- applies. Previously buried in a keymap callback with no coverage.
local rewrap = require("config.markdown_rewrap")

describe("config.markdown_rewrap", function()
  describe("parse_fence", function()
    it("recognizes a backtick fence with a language", function()
      local indent, fc, lang = rewrap._parse_fence("```lua")
      assert.are.equal("", indent)
      assert.are.equal("```", fc)
      assert.are.equal("lua", lang)
    end)

    it("recognizes an indented tilde fence", function()
      local indent, fc, lang = rewrap._parse_fence("  ~~~python")
      assert.are.equal("  ", indent)
      assert.are.equal("~~~", fc)
      assert.are.equal("python", lang)
    end)

    it("returns nil for a non-fence line", function()
      assert.is_nil(rewrap._parse_fence("plain text"))
    end)
  end)

  describe("plan_actions", function()
    it("treats a contiguous block as a single prose action", function()
      local a = rewrap.plan_actions({ "hello", "world" }, 1, 2)
      assert.are.same({ { kind = "prose", from = 1, to = 2 } }, a)
    end)

    it("isolates a fenced code block between prose chunks", function()
      local a = rewrap.plan_actions({ "text", "```lua", "code", "```", "more" }, 1, 5)
      assert.are.equal(3, #a)
      assert.are.same({ kind = "prose", from = 1, to = 1 }, a[1])
      assert.are.equal("code", a[2].kind)
      assert.are.equal(3, a[2].from)
      assert.are.equal(3, a[2].to)
      assert.are.equal("lua", a[2].lang)
      assert.are.same({ kind = "prose", from = 5, to = 5 }, a[3])
    end)

    it("excludes table rows from prose ranges", function()
      local a = rewrap.plan_actions({ "para", "| a | b |", "more" }, 1, 3)
      assert.are.same({
        { kind = "prose", from = 1, to = 1 },
        { kind = "prose", from = 3, to = 3 },
      }, a)
    end)

    it("preserves the indent on an indented code block", function()
      local a = rewrap.plan_actions({ "  ```python", "  code", "  ```" }, 1, 3)
      assert.are.equal(1, #a)
      assert.are.equal("code", a[1].kind)
      assert.are.equal(2, a[1].from)
      assert.are.equal(2, a[1].to)
      assert.are.equal("python", a[1].lang)
      assert.are.equal("  ", a[1].indent)
    end)

    it("formats an unterminated fence at EOF best-effort", function()
      local a = rewrap.plan_actions({ "```lua", "code" }, 1, 2)
      assert.are.equal(1, #a)
      assert.are.equal("code", a[1].kind)
      assert.are.equal(2, a[1].from)
      assert.are.equal(2, a[1].to)
    end)

    it("offsets line numbers by the start line", function()
      local a = rewrap.plan_actions({ "x", "y" }, 5, 6)
      assert.are.same({ { kind = "prose", from = 5, to = 6 } }, a)
    end)
  end)
end)
