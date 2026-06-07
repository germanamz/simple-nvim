-- Pins the byte-level common-affix diff extracted from gitsigns' word-diff
-- painter. middle_span(old, new) returns the shared-prefix length and the
-- differing middle-span lengths in old and new (shared suffix is implied).
local inline_diff = require("util.inline_diff")

describe("util.inline_diff.middle_span", function()
  it("reports no difference for identical strings", function()
    local s = inline_diff.middle_span("abc", "abc")
    assert.are.equal(3, s.prefix)
    assert.are.equal(0, s.old_mid)
    assert.are.equal(0, s.new_mid)
  end)

  it("isolates a single changed character", function()
    local s = inline_diff.middle_span("abc", "axc")
    assert.are.equal(1, s.prefix)
    assert.are.equal(1, s.old_mid)
    assert.are.equal(1, s.new_mid)
  end)

  it("isolates a trailing insertion", function()
    local s = inline_diff.middle_span("abc", "abcd")
    assert.are.equal(3, s.prefix)
    assert.are.equal(0, s.old_mid)
    assert.are.equal(1, s.new_mid)
  end)

  it("isolates a trailing deletion", function()
    local s = inline_diff.middle_span("abcd", "abc")
    assert.are.equal(3, s.prefix)
    assert.are.equal(1, s.old_mid)
    assert.are.equal(0, s.new_mid)
  end)

  it("isolates an insertion between shared prefix and suffix", function()
    local s = inline_diff.middle_span("hello world", "hello brave world")
    assert.are.equal(6, s.prefix) -- "hello "
    assert.are.equal(0, s.old_mid)
    assert.are.equal(6, s.new_mid) -- "brave "
  end)

  it("handles an empty old string as a pure insertion", function()
    local s = inline_diff.middle_span("", "abc")
    assert.are.equal(0, s.prefix)
    assert.are.equal(0, s.old_mid)
    assert.are.equal(3, s.new_mid)
  end)

  it("handles an empty new string as a pure deletion", function()
    local s = inline_diff.middle_span("abc", "")
    assert.are.equal(0, s.prefix)
    assert.are.equal(3, s.old_mid)
    assert.are.equal(0, s.new_mid)
  end)
end)
