-- Pins config.dotted_chain: the per-filetype character class and the composed
-- pattern that backs the mini.ai `o` (dotted-chain) textobject. See
-- docs/dotted-chain-textobject-design.md.
--
-- The module is pure (no Neovim state, no plugin). To assert selection
-- behaviour without loading mini.ai, `select` below emulates the one piece of
-- mini.ai that matters for these patterns: it collects every match of the
-- outer pattern, keeps the NARROWEST span covering the cursor (mini/ai.lua:1884
-- "Covering candidate is better than covering current if it is narrower"), then
-- applies the extraction pattern to derive the `a`/`i` spans.
--
-- This emulates only mini.ai's `cover` search (a cursor sitting ON its chain).
-- mini.ai's real default is `cover_or_next`, so when the cursor is off every
-- chain (whitespace, or a chain's trailing separator) the plugin reaches
-- FORWARD to the next chain — behaviour this single-line, cover-only helper
-- structurally cannot model. The sibling smoke spec drives the real plugin and
-- pins that forward-reach, the leading-separator strip, and multi-line chains;
-- keep the two in sync when either changes.
local dotted_chain = require("config.dotted_chain")

-- Emulate MiniAi span selection for the given filetype's spec.
-- Returns the `a` (around) and `i` (inner) selected substrings for a cursor at
-- 1-based byte column `col`.
local function select(ft, line, col)
  local s = dotted_chain.spec(ft)
  local outer, extract = s[1], s[2]

  local best
  local init = 1
  while init <= #line do
    local from, to = line:find(outer, init)
    if not from then
      break
    end
    if from <= col and col <= to then
      if not best or (to - from) < (best.to - best.from) then
        best = { from = from, to = to }
      end
    end
    -- mini.ai advances the search start to from+1 (a callable pattern must
    -- therefore never return a match starting before init, or this loops).
    init = from + 1
  end
  if not best then
    return nil
  end

  local matched = line:sub(best.from, best.to)
  local p1, p2, p3, p4 = matched:match(extract)
  assert(p1, "extraction pattern did not match " .. matched)
  return matched:sub(p1, p4 - 1), matched:sub(p2, p3 - 1)
end

-- Select with the cursor on the first byte of `on` (first occurrence).
local function select_on(ft, line, on)
  local at = assert(line:find(on, 1, true), "substring not in line: " .. on)
  return select(ft, line, at)
end

describe("config.dotted_chain", function()
  describe("class", function()
    it("uses the base word/underscore/dot class for filetypes with no extras", function()
      assert.are.equal("%w_%.", dotted_chain.class("go"))
      assert.are.equal("%w_%.", dotted_chain.class("python"))
      assert.are.equal("%w_%.", dotted_chain.class("bash"))
      assert.are.equal("%w_%.", dotted_chain.class("unknown-ft"))
      assert.are.equal("%w_%.", dotted_chain.class(""))
    end)

    it("adds a colon for lua, rust, and cpp", function()
      assert.are.equal("%w_%.:", dotted_chain.class("lua"))
      assert.are.equal("%w_%.:", dotted_chain.class("rust"))
      assert.are.equal("%w_%.:", dotted_chain.class("cpp"))
    end)

    it("adds an escaped question mark for the ts/js filetypes", function()
      assert.are.equal("%w_%.%?", dotted_chain.class("typescript"))
      assert.are.equal("%w_%.%?", dotted_chain.class("typescriptreact"))
      assert.are.equal("%w_%.%?", dotted_chain.class("javascript"))
      assert.are.equal("%w_%.%?", dotted_chain.class("javascriptreact"))
    end)
  end)

  describe("spec selection", function()
    it("selects the whole dotted chain with the cursor on any segment", function()
      local line = 'someFunc("another arg", app.property)'
      assert.are.equal("app.property", (select_on("go", line, "app")))
      assert.are.equal("app.property", (select_on("go", line, "property")))
    end)

    it("selects the full chain identically for `a` and `i`", function()
      local a, i = select_on("go", "x = app.property", "property")
      assert.are.equal("app.property", a)
      assert.are.equal("app.property", i)
    end)

    it("strips a leading separator (method-chain continuation lines)", function()
      assert.are.equal("filter", (select_on("javascript", "  .filter(Boolean)", "filter")))
    end)

    it("ends the chain on a word char, not a trailing dot", function()
      assert.are.equal("app", (select_on("lua", "-- see app.", "app")))
    end)

    it("keeps colon-joined chains together for lua and rust", function()
      assert.are.equal("obj:method", (select_on("lua", "obj:method(1)", "method")))
      assert.are.equal(
        "config.foo",
        (select_on("lua", "local M = require('config.foo')", "config"))
      )
      assert.are.equal(
        "std::vec::Vec::new",
        (select_on("rust", "let v = std::vec::Vec::new()", "vec"))
      )
      assert.are.equal("std::string", (select_on("cpp", "std::string s", "string")))
    end)

    it("keeps optional-chaining `?.` together for ts/js", function()
      assert.are.equal(
        "app?.property",
        (select_on("typescript", "const y = app?.property", "property"))
      )
      assert.are.equal(
        "props?.user?.name",
        (select_on("typescriptreact", "props?.user?.name", "user"))
      )
      assert.are.equal("app.fn", (select_on("typescript", "app.fn?.()", "fn")))
    end)

    it("does not swallow subtraction, since no class contains a dash", function()
      assert.are.equal("i", (select_on("go", "arr[i-1]", "i")))
      assert.are.equal("n", (select_on("c", "n-1", "n")))
    end)

    it("leaves a spaced ternary untouched", function()
      assert.are.equal("b", (select_on("typescript", "const y = a ? b : c", "b")))
    end)

    it("selects a bare identifier with no separators", function()
      assert.are.equal("VAR", (select_on("bash", "echo $VAR", "VAR")))
      assert.are.equal("x", (select_on("rust", "let x: i32 = 5", "x")))
    end)

    it("stops the chain at `?.[`, keeping only the identifier (ts index access)", function()
      assert.are.equal("arr", (select_on("typescript", "const z = arr?.[0]", "arr")))
    end)

    it("does not cross a channel operator (go `<-` is not a chain char)", function()
      assert.are.equal("v", (select_on("go", "ch <- v", "v")))
    end)

    -- Accepted imprecisions from docs/dotted-chain-textobject-design.md, pinned
    -- so a future change to the character class must consciously update them
    -- rather than silently widening or narrowing what `o` grabs.
    describe("accepted imprecisions (pinned so they cannot silently worsen)", function()
      it("swallows an UNSPACED ternary (formatters space these, so rare)", function()
        assert.are.equal("a?b", (select_on("typescript", "const y = a?b:c", "a")))
      end)

      it("swallows an UNSPACED rust type annotation", function()
        assert.are.equal("x:i32", (select_on("rust", "let x:i32 = 5", "x")))
      end)

      it("treats a dotted number as a chain", function()
        assert.are.equal("3.14", (select_on("go", "x = 3.14", "3")))
      end)

      it("strips a leading-dot float to its mantissa", function()
        assert.are.equal("5", (select_on("go", "x = .5", "5")))
      end)
    end)
  end)
end)
