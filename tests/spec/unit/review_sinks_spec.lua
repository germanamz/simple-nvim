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

describe("config.review_sinks cmux", function()
  local calls

  --- A tree with the caller (nvim) and `others` as sibling terminal surfaces in
  --- the caller's workspace, mirroring the real layout: `nvim .` and the agent
  --- share one pane in one workspace.
  local function tree(others)
    local surfaces = {
      { id = "self", ref = "surface:1", title = "nvim .", type = "terminal" },
    }
    for _, o in ipairs(others) do
      surfaces[#surfaces + 1] = o
    end
    return vim.json.encode({
      caller = { surface_id = "self", workspace_id = "ws1" },
      windows = { { workspaces = { { id = "ws1", panes = { { surfaces = surfaces } } } } } },
    })
  end

  --- Stand-in cmux CLI: records every argv and answers `tree` with `payload`.
  local function fake(payload, code)
    calls = {}
    sinks._run = function(args, on_done)
      calls[#calls + 1] = args
      if args[#args] == "tree" then
        return on_done(code or 0, payload)
      end
      on_done(0, "")
    end
  end

  before_each(function()
    sinks._reset_surface()
  end)

  after_each(function()
    sinks._run = nil
  end)

  it("sends to the only other terminal surface, without submitting", function()
    fake(tree({ { id = "agent", ref = "surface:2", title = "claude", type = "terminal" } }))
    local ok
    sinks.send("cmux", "hello", { submit = false }, function(res)
      ok = res
    end)
    assert.is_true(ok)
    assert.are.same({ "--json", "--id-format", "both", "tree" }, calls[1])
    assert.are.same({ "send", "--surface", "surface:2", "--", "hello" }, calls[2])
    assert.are.equal(2, #calls)
  end)

  it("presses enter as a separate call when submitting", function()
    fake(tree({ { id = "agent", ref = "surface:2", title = "claude", type = "terminal" } }))
    sinks.send("cmux", "hello", { submit = true }, function() end)
    assert.are.same({ "send-key", "--surface", "surface:2", "enter" }, calls[3])
  end)

  it("ignores the caller's own surface and non-terminal surfaces", function()
    fake(tree({
      { id = "browser", ref = "surface:3", title = "docs", type = "browser" },
    }))
    local ok, err
    sinks.send("cmux", "hello", {}, function(res, e)
      ok, err = res, e
    end)
    assert.is_false(ok)
    assert.is_truthy(err:find("no agent surface", 1, true))
  end)

  it("reuses the resolved surface on the next send", function()
    fake(tree({ { id = "agent", ref = "surface:2", title = "claude", type = "terminal" } }))
    sinks.send("cmux", "one", {}, function() end)
    sinks.send("cmux", "two", {}, function() end)
    -- One tree call, two sends: the surface is resolved once per session.
    assert.are.equal(1, #vim.tbl_filter(function(a)
      return a[#a] == "tree"
    end, calls))
  end)

  it("re-resolves after a failed send", function()
    fake(tree({ { id = "agent", ref = "surface:2", title = "claude", type = "terminal" } }))
    sinks.send("cmux", "one", {}, function() end)
    -- The surface went away: the send exits non-zero.
    sinks._run = function(args, on_done)
      calls[#calls + 1] = args
      if args[#args] == "tree" then
        return on_done(
          0,
          tree({
            { id = "agent2", ref = "surface:9", title = "claude", type = "terminal" },
          })
        )
      end
      on_done(args[1] == "send" and args[3] == "surface:2" and 1 or 0, "")
    end
    local ok
    sinks.send("cmux", "two", {}, function(res)
      ok = res
    end)
    assert.is_true(ok)
    assert.are.same({ "send", "--surface", "surface:9", "--", "two" }, calls[#calls])
  end)
end)
