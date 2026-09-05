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
  -- Restored here rather than at the end of the body that changed it: an
  -- assertion that throws would otherwise leave util.cmux.bin answering nil for
  -- the rest of the process, and every cmux example below would fail with "not
  -- a cmux session", burying the one real failure.
  after_each(function()
    cmux_bin = "cmux-stub"
  end)

  it("prefers cmux when this is a cmux session", function()
    assert.are.equal("cmux", sinks.choose())
  end)

  it("falls back to the clipboard outside cmux", function()
    cmux_bin = nil
    assert.are.equal("clipboard", sinks.choose())
  end)
end)

describe("config.review_sinks clipboard", function()
  -- `+` is the developer's real system clipboard, so the register write is
  -- recorded rather than performed. The sink's contract is "hand the payload to
  -- setreg('+')"; asserting it back through the OS would clobber whatever they
  -- had copied and go red on any box without a clipboard provider.
  local real_setreg, wrote

  before_each(function()
    wrote = {}
    real_setreg = vim.fn.setreg
    vim.fn.setreg = function(reg, value)
      wrote[#wrote + 1] = { reg, value }
    end
  end)

  after_each(function()
    vim.fn.setreg = real_setreg
  end)

  it("puts the payload on the + register", function()
    local done
    sinks.send("clipboard", "hello agent", {}, function(ok)
      done = ok
    end)
    assert.is_true(done)
    assert.are.same({ { "+", "hello agent" } }, wrote)
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

  --- Answer the surface picker with the `pick`th candidate (nil cancels) for
  --- the duration of `fn`, the way with_input does for vim.ui.input in
  --- review_comments_spec. Returns what the picker was offered and how often it
  --- was opened, so a spec can tell "asked once and cached" from "asked twice".
  local function with_select(pick, fn)
    local real = vim.ui.select
    local seen = { count = 0 }
    vim.ui.select = function(items, opts, cb)
      seen.count = seen.count + 1
      seen.offered = vim.tbl_map(opts.format_item, items)
      cb(pick and items[pick] or nil)
    end
    local ok, err = pcall(fn)
    vim.ui.select = real
    if not ok then
      error(err)
    end
    return seen
  end

  --- The text argument of the nth recorded `send`.
  local function sent_text(n)
    return calls[n][5]
  end

  --- Nothing in the payload may reach the agent's terminal as a keystroke:
  --- `cmux send` turns a real newline, a real carriage return and the
  --- two-character escapes \n and \r into Enter, and \t (real or escaped) into
  --- Tab. An Enter submits the draft <leader>as exists to leave unsent.
  local function assert_no_keystrokes(text)
    assert.is_truthy(text:match("^[^\n\r\t]*$"))
    assert.is_nil(text:find("\\[nrt]"))
  end

  before_each(function()
    sinks._reset_surface()
  end)

  after_each(function()
    sinks._run = nil
  end)

  local function agent()
    return { { id = "agent", ref = "surface:2", title = "claude", type = "terminal" } }
  end

  it("sends to the only other terminal surface, without submitting", function()
    fake(tree(agent()))
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
    fake(tree(agent()))
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

  it("asks which of several surfaces to use, then remembers the answer", function()
    fake(tree({
      { id = "agent", ref = "surface:2", title = "claude", type = "terminal" },
      { id = "shell", ref = "surface:3", title = "zsh", type = "terminal" },
    }))
    local ok
    local picker = with_select(2, function()
      sinks.send("cmux", "one", {}, function(res)
        ok = res
      end)
      sinks.send("cmux", "two", {}, function() end)
    end)
    assert.is_true(ok)
    assert.are.same({ "claude", "zsh" }, picker.offered)
    assert.are.equal(1, picker.count)
    assert.are.same({ "send", "--surface", "surface:3", "--", "one" }, calls[2])
    assert.are.same({ "send", "--surface", "surface:3", "--", "two" }, calls[3])
  end)

  it("reports a cancelled picker and sends nothing", function()
    fake(tree({
      { id = "agent", ref = "surface:2", title = "claude", type = "terminal" },
      { id = "shell", ref = "surface:3", title = "zsh", type = "terminal" },
    }))
    local ok, err
    with_select(nil, function()
      sinks.send("cmux", "hello", {}, function(res, e)
        ok, err = res, e
      end)
    end)
    assert.is_false(ok)
    assert.are.equal("cancelled", err)
    assert.are.equal(1, #calls)
  end)

  it("reuses the resolved surface on the next send", function()
    fake(tree(agent()))
    sinks.send("cmux", "one", {}, function() end)
    sinks.send("cmux", "two", {}, function() end)
    -- One tree call, two sends: the surface is resolved once per session.
    assert.are.equal(1, #vim.tbl_filter(function(a)
      return a[#a] == "tree"
    end, calls))
  end)

  it("re-resolves after a failed send", function()
    fake(tree(agent()))
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

  it("keeps a comment's literal backslash-n from firing an Enter", function()
    fake(tree(agent()))
    local payload = [[1. @lua/config/init.lua#L3   strip the trailing \n here]]
    sinks.send("cmux", payload, {}, function() end)
    local sent = sent_text(2)
    assert_no_keystrokes(sent)
    -- Readable on the other end: only invisible separators were added, so
    -- dropping them gives the comment back verbatim.
    assert.are.equal(payload, (sent:gsub("\226\128\139", "")))
  end)

  it("flattens a multi-comment batch onto one line", function()
    fake(tree(agent()))
    -- The shape review_comments.format emits: a header, then a blank line and
    -- an indented block per comment. Every one of those newlines is an Enter to
    -- `cmux send`, so a two-comment batch would submit itself in six pieces.
    local batch = table.concat({
      "Review comments (2):",
      "",
      "1. @lua/config/init.lua#L3",
      [[   strip the trailing \n here]],
      "",
      "2. @lua/config/other.lua#L9-11",
      "   this regex\tneeds a tab",
    }, "\n")
    sinks.send("cmux", batch, {}, function() end)
    local sent = sent_text(2)
    assert_no_keystrokes(sent)
    for _, part in ipairs({
      "Review comments (2):",
      "@lua/config/init.lua#L3",
      "strip the trailing",
      "@lua/config/other.lua#L9-11",
      "needs a tab",
    }) do
      assert.is_truthy(sent:find(part, 1, true))
    end
  end)
end)
