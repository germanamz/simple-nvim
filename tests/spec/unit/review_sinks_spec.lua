-- Pins the delivery layer. The real `cmux` binary is never run here -- it would
-- type into the developer's live terminal -- so both ends are stubbed:
-- util.cmux.bin (the "is this a cmux session" check) and M._run (every
-- invocation). M._run is called synchronously, unlike the real path's
-- vim.schedule hop, so a spec can assert immediately after send().
local sinks = require("config.review_sinks")

local cmux_bin = "cmux-stub"
require("util.cmux").bin = function()
  return cmux_bin
end

describe("config.review_sinks.choose", function()
  it("prefers cmux when this is a cmux session", function()
    cmux_bin = "cmux-stub"
    assert.are.equal("cmux", sinks.choose())
  end)

  it("falls back to the clipboard outside cmux", function()
    cmux_bin = nil
    assert.are.equal("clipboard", sinks.choose())
    cmux_bin = "cmux-stub"
  end)
end)

describe("config.review_sinks clipboard", function()
  it("puts the payload on the + register", function()
    local done
    sinks.send("clipboard", "hello agent", {}, function(ok)
      done = ok
    end)
    assert.is_true(done)
    assert.are.equal("hello agent", vim.fn.getreg("+"))
  end)
end)
