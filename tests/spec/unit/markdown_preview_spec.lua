-- Pins config.markdown_preview: the cmux-panel state machine behind `<leader>mp`.
--
-- Neovim renders nothing here. The module's entire job is a sequence of cmux CLI
-- calls plus the state it carries between them — which pane the panels tab into,
-- which surface (panel tab) each file is showing in — so these specs replace the
-- CLI with `M._run` and assert the exact argv of every invocation, in order.
-- That ordering is the contract: cmux has no "open a markdown panel into pane X"
-- primitive, so a second file is opened off the preview column, moved into it,
-- and then has focus put back — the move exists because the open cannot land the
-- panel where it belongs, and the focus exists because the move steals it.
--
-- The real `cmux` binary is never run — it would mutate the developer's live
-- terminal — so both ends are stubbed: `util.cmux.bin` (the "is this a cmux
-- session" check) and `M._run` (every invocation). `M._run` is called
-- synchronously, unlike the real path's vim.schedule hop, so a spec can assert
-- immediately after `mp.toggle()` with no waiting.
local mp = require("config.markdown_preview")

-- Which cmux CLI the module believes it has; nil is "not a cmux session".
local cmux_bin = "cmux-stub"

-- open() and close() each resolve the binary first and no-op without one, so an
-- un-stubbed detector would let the terminal the suite happens to run in decide
-- the result: green inside cmux, every one of these tests red outside it. Swap
-- the field on the shared module table (config.markdown_preview holds the table,
-- not the function). Only whether it answers is ever used — the module's run()
-- drops the binary once M._run is set, so this name reaches no argv below, let
-- alone a process.
require("util.cmux").bin = function()
  return cmux_bin
end

--- The cmux subcommand an argv is asking for. The two calls that need a JSON
--- answer carry the global `--json --id-format both` prefix; the rest lead with
--- their verb.
local function verb(args)
  if args[1] ~= "--json" then
    return args[1]
  end
  return args[4] == "markdown" and args[4] .. " " .. args[5] or args[4]
end

--- A stand-in cmux CLI, wired into `M._run`.
---
--- Records the argv of every invocation and answers from plain fields, so a
--- spec sets a failure branch up by flipping one exit code instead of scripting
--- responses. Ids are serial — the nth panel is surface `sN` in pane `pN` —
--- which mirrors the real thing: `markdown open` always splits a FRESH pane,
--- which is the whole reason the module has to move the surface afterwards.
local function fake_cmux()
  local f = {
    calls = {}, -- argv of every invocation, in order
    tree = nil, -- `cmux tree` output; nil makes discovery come back empty-handed
    open_code = 0, -- exit code for `markdown open`
    anchor_open_code = 0, -- ... when that open carries `--surface` (a stale anchor)
    move_code = 0, -- ... for `move-surface` (non-zero: the preview pane is gone)
    close_code = 0, -- ... for `close-surface` (non-zero: "Surface not found")
    source_pane = "editor", -- the pane the keypress came from
    -- What an ANCHORED open reports as its source: `--surface` makes the anchor
    -- the split source, so cmux names the preview column here, never the editor.
    -- Handing focus to it would strand the cursor exactly where move-surface
    -- left it, so this value must never turn up in a focus-pane argv.
    anchored_source = "the-preview-column",
    opened = 0,
  }

  --- The subcommand of each invocation so far, in order.
  function f.verbs()
    return vim.tbl_map(verb, f.calls)
  end

  --- Every argv of `subcommand`, in order.
  function f.of(subcommand)
    return vim.tbl_filter(function(args)
      return verb(args) == subcommand
    end, f.calls)
  end

  mp._run = function(args, on_done)
    table.insert(f.calls, args)
    local v = verb(args)
    if v == "tree" then
      return on_done(f.tree and 0 or 1, f.tree and vim.json.encode(f.tree) or "")
    elseif v == "markdown open" then
      local anchored = vim.tbl_contains(args, "--surface")
      local code = anchored and f.anchor_open_code or f.open_code
      if code ~= 0 then
        return on_done(code, "")
      end
      f.opened = f.opened + 1
      return on_done(
        0,
        vim.json.encode({
          surface_id = "s" .. f.opened,
          target_pane_id = "p" .. f.opened,
          source_pane_id = anchored and f.anchored_source or f.source_pane,
        })
      )
    elseif v == "move-surface" then
      return on_done(f.move_code, "")
    elseif v == "focus-pane" then
      return on_done(0, "")
    elseif v == "close-surface" then
      return on_done(f.close_code, "")
    end
    error("unexpected cmux call: " .. table.concat(args, " "))
  end

  return f
end

-- State keys on the absolute path and nothing here reads the file, so these need
-- not exist on disk. They are already canonical, so `_state().surfaces` can be
-- compared against them directly.
local A, B = "/tmp/nvim-markdown-preview-spec/a.md", "/tmp/nvim-markdown-preview-spec/b.md"

--- The argv of `markdown open <path>`, with `extra` appended (e.g. the anchor).
local function open_args(path, extra)
  local args = { "--json", "--id-format", "both", "markdown", "open", path, "--focus", "false" }
  return vim.list_extend(args, extra or {})
end

-- Panes as `cmux tree` reports them: a surface's `type` is all discovery has to
-- go on, since a markdown surface's JSON never names the file it renders.
local MARKDOWN_PANE = {
  id = "preview",
  surfaces = { { id = "sp1", type = "markdown" }, { id = "sp2", type = "markdown" } },
}
local MIXED_PANE = {
  id = "editor",
  surfaces = { { id = "se", type = "terminal" }, { id = "sm", type = "markdown" } },
}
local EMPTY_PANE = { id = "blank", surfaces = {} }

--- `cmux tree` output whose caller-workspace holds `panes`, beside a sibling
--- workspace that also has an all-markdown pane — the one discovery must never
--- adopt. It is a workspace this Neovim is not in, so tabbing previews into it
--- would render them onto a screen nobody is looking at; discovery filters on
--- the workspace id, not on "the first markdown pane anywhere in the tree".
local function tree_of(panes)
  return {
    caller = { workspace_id = "ws1" },
    windows = {
      {
        workspaces = {
          {
            id = "ws0",
            panes = { { id = "elsewhere", surfaces = { { id = "sx", type = "markdown" } } } },
          },
          { id = "ws1", panes = panes },
        },
      },
    },
  }
end

describe("config.markdown_preview", function()
  local f, notified, real_notify

  before_each(function()
    mp._reset()
    f = fake_cmux()
    cmux_bin = "cmux-stub"
    notified = {}
    real_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.notify = real_notify
    mp._run = nil
    mp._reset()
  end)

  describe("opening the first file", function()
    it("opens it with no anchor and adopts the pane it landed in", function()
      -- f.tree is nil, so discovery comes back with no pane to tab into and
      -- this is the plain shape: one `markdown open`, with nothing to move or
      -- re-focus after it, because the pane the panel split into becomes the
      -- preview pane.
      mp.toggle(A)

      assert.are.same({ "tree", "markdown open" }, f.verbs())
      assert.are.same(open_args(A), f.calls[2])
      assert.is_false(vim.tbl_contains(f.calls[2], "--surface"))

      local state = mp._state()
      assert.are.equal("p1", state.pane, "target_pane_id did not become the preview pane")
      assert.are.equal("s1", state.anchor, "surface_id did not become the anchor")
      assert.are.same({ [A] = "s1" }, state.surfaces)
    end)
  end)

  describe("opening a second file", function()
    it("splits off the preview pane, moves the panel in, and hands focus back", function()
      mp.toggle(A)
      f.calls = {}
      mp.toggle(B)

      assert.are.same({
        -- `--surface` is what keeps the editor still: the transient pane splits
        -- off the preview column, not off Neovim's own window.
        open_args(B, { "--surface", "s1" }),
        { "move-surface", "--surface", "s2", "--pane", "p1" },
        -- move-surface ignores `--focus false` and takes focus every time, so
        -- this call is not optional: without it the keypress leaves the cursor
        -- sitting in the preview pane.
        { "focus-pane", "--pane", "editor" },
      }, f.calls)
    end)

    it("keeps one preview pane and re-anchors on the newest tab", function()
      mp.toggle(A)
      mp.toggle(B)

      local state = mp._state()
      assert.are.equal("p1", state.pane)
      assert.are.equal("s2", state.anchor)
      assert.are.same({ [A] = "s1", [B] = "s2" }, state.surfaces)
    end)
  end)

  describe("toggling closed", function()
    it("closes the file's panel and forgets it", function()
      mp.toggle(A)
      f.calls = {}
      mp.toggle(A)

      assert.are.same({ { "close-surface", "--surface", "s1" } }, f.calls)
      assert.are.same({}, mp._state().surfaces)
    end)

    it("drops the anchor when the closed tab was the anchor, keeping the pane", function()
      -- The next open splits from the anchor, so a closed one would fail that
      -- open and cost a retry round-trip. The pane itself may still hold other
      -- tabs, so it survives.
      mp.toggle(A)
      mp.toggle(A)

      assert.is_nil(mp._state().anchor)
      assert.are.equal("p1", mp._state().pane)
    end)

    it("re-opens when cmux says the tab is already gone", function()
      -- Exit 1 is "Surface not found": the user closed that tab by hand, so the
      -- toggle was a press behind. Opening beats making them press twice to get
      -- back to where they thought they already were.
      mp.toggle(A)
      f.close_code = 1
      f.calls = {}
      mp.toggle(A)

      assert.are.same({ "close-surface", "markdown open", "move-surface", "focus-pane" }, f.verbs())
      assert.are.equal("s2", mp._state().surfaces[A], "the re-opened panel was not tracked")
    end)
  end)

  describe("a stale anchor", function()
    it("retries the open once without it and keeps the preview pane", function()
      mp.toggle(A)
      f.anchor_open_code = 1 -- the anchor tab was closed by hand
      f.calls = {}
      mp.toggle(B)

      assert.are.same({
        open_args(B, { "--surface", "s1" }),
        open_args(B),
        { "move-surface", "--surface", "s2", "--pane", "p1" },
        { "focus-pane", "--pane", "editor" },
      }, f.calls)
      -- The pane is not the thing that died — its other tabs may well be alive —
      -- so the retry still tabs into it rather than starting a second column.
      assert.are.equal("p1", mp._state().pane)
      assert.are.equal("s2", mp._state().anchor)
    end)

    it("gives up after that one retry and names the file", function()
      mp.toggle(A)
      f.open_code, f.anchor_open_code = 1, 1
      f.calls = {}
      mp.toggle(B)

      assert.are.same({ "markdown open", "markdown open" }, f.verbs())
      assert.is_nil(mp._state().surfaces[B])
      assert.are.equal(1, #notified)
      assert.is_truthy(notified[1].msg:find("b.md", 1, true))
      assert.are.equal(vim.log.levels.WARN, notified[1].level)
    end)
  end)

  describe("a dead preview pane", function()
    it("adopts the pane the panel landed in and puts no focus back", function()
      mp.toggle(A)
      f.move_code = 1 -- the preview pane is gone
      f.calls = {}
      mp.toggle(B)

      -- No focus-pane: the move failed, so nothing stole focus, and issuing one
      -- anyway would yank the cursor around for no reason.
      assert.are.same({ "markdown open", "move-surface" }, f.verbs())

      local state = mp._state()
      assert.are.equal("p2", state.pane)
      assert.are.equal("s2", state.anchor)
      assert.are.equal("s2", state.surfaces[B])
    end)
  end)

  describe("preview pane discovery", function()
    it("adopts an all-markdown pane in the caller's workspace", function()
      -- A Neovim restart tabs back into the panel column it was already using
      -- instead of splitting a second one beside it.
      f.tree = tree_of({ MIXED_PANE, EMPTY_PANE, MARKDOWN_PANE })
      mp.toggle(A)

      assert.are.equal("preview", mp._state().pane)
      assert.are.same(open_args(A, { "--surface", "sp1" }), f.calls[2])
    end)

    it("adopts no pane that is not entirely markdown panels", function()
      -- A pane with a terminal in it is somebody's editor or shell; tabbing a
      -- preview into it would bury their work. An empty pane says nothing about
      -- what it is for, so it does not qualify either — and neither does the
      -- all-markdown pane in the other workspace this fixture always carries.
      f.tree = tree_of({ MIXED_PANE, EMPTY_PANE })
      mp.toggle(A)

      assert.are.equal("p1", mp._state().pane)
      assert.is_false(vim.tbl_contains(f.calls[2], "--surface"))
    end)

    it("takes the pane to hand focus back to from the tree's caller", function()
      -- With a pane already adopted, the very first open is anchored — and an
      -- anchored open names the preview column as its source, so `tree` is the
      -- only place the caller can come from. Reading it off the open instead
      -- would focus the pane move-surface just stranded the cursor in, which is
      -- the exact bug the focus-pane call exists to prevent.
      f.tree = tree_of({ MARKDOWN_PANE })
      f.tree.caller.pane_id = "editor"
      mp.toggle(A)

      assert.are.same({ "tree", "markdown open", "move-surface", "focus-pane" }, f.verbs())
      assert.are.same({ "focus-pane", "--pane", "editor" }, f.calls[4])
    end)

    it("runs once per session, not once per open", function()
      f.tree = tree_of({ MARKDOWN_PANE })
      mp.toggle(A)
      mp.toggle(B)

      assert.are.equal(1, #f.of("tree"))
    end)
  end)

  describe("_markdown_anchor", function()
    it("returns the pane's first tab when every tab is a markdown panel", function()
      assert.are.equal("sp1", mp._markdown_anchor(MARKDOWN_PANE))
    end)

    it("rejects a pane that also hosts something else", function()
      assert.is_nil(mp._markdown_anchor(MIXED_PANE))
    end)

    it("rejects an empty pane, and one that reports no surfaces at all", function()
      assert.is_nil(mp._markdown_anchor(EMPTY_PANE))
      assert.is_nil(mp._markdown_anchor({ id = "blank" }))
    end)
  end)

  describe("_canonical", function()
    it("collapses equivalent spellings of one path to a single key", function()
      local want = mp._canonical("/tmp/notes/a.md")
      for _, spelling in ipairs({
        "/tmp/notes/./a.md",
        "/tmp/notes//a.md",
        "/tmp/notes/sub/../a.md",
        "/tmp/notes/a.md/",
      }) do
        assert.are.equal(want, mp._canonical(spelling), "not collapsed: " .. spelling)
      end
    end)

    it("collapses a symlinked ancestor for a file that does not exist yet", function()
      -- The bug this guards: fs_realpath fails outright on an unwritten path, so
      -- an earlier fix collapsed only files already on disk. A markdown buffer
      -- for a file you have not saved is exactly that case, and on macOS /tmp is
      -- a symlink to /private/tmp — so the same draft reached under the two
      -- spellings keyed two entries, and the toggle could never close the first.
      -- Resolving the deepest EXISTING ancestor and re-attaching the tail is
      -- what makes the key hold before the file exists.
      local missing = "/tmp/nvim-preview-does-not-exist-" .. vim.fn.getpid() .. ".md"
      assert.is_nil(vim.uv.fs_realpath(missing), "fixture path unexpectedly exists")
      assert.are.equal(mp._canonical(missing), mp._canonical("/private" .. missing))
    end)

    it("absolutizes a relative path and expands ~", function()
      assert.are.equal(vim.fs.normalize(vim.fn.getcwd()) .. "/a.md", mp._canonical("a.md"))
      assert.are.equal(vim.fs.normalize(vim.env.HOME) .. "/a.md", mp._canonical("~/a.md"))
    end)

    it("makes two spellings of one file toggle the same panel", function()
      -- The point of the canonical key: `<leader>mp` reaches the module from a
      -- buffer name and from an nvim-tree node, and the toggle has to be
      -- symmetric across the two.
      mp.toggle(mp._canonical("/tmp/notes/a.md"))
      f.calls = {}
      mp.toggle(mp._canonical("/tmp/notes/./a.md"))

      assert.are.same({ { "close-surface", "--surface", "s1" } }, f.calls)
    end)
  end)

  describe("an unsaved buffer", function()
    --- A modified, never-written buffer for a fresh temp path, plus the key the
    --- keymap would toggle it under.
    ---
    --- A file buffer, not a scratch one: 'modified' does not stick on
    --- `buftype=nofile`, and 'modified' is the entire subject here. 'swapfile'
    --- is off so the edit writes nothing anywhere. The path is read back OUT of
    --- the buffer because macOS hands the name back realpath'd
    --- (/private/var/...) — exactly what the keymap itself passes to toggle().
    local function draft()
      local buf = vim.api.nvim_create_buf(false, false)
      vim.bo[buf].swapfile = false
      vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".md")
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# draft" })
      return buf, mp._canonical(vim.api.nvim_buf_get_name(buf))
    end

    it("warns that the panel shows the last saved version, and writes nothing", function()
      -- cmux watches and renders the file on DISK, so an unsaved buffer previews
      -- as its last saved state. Say so; do not write the user's file for them.
      local buf, path = draft()

      mp.toggle(path)

      assert.are.equal(1, #notified)
      assert.is_truthy(notified[1].msg:find("unsaved", 1, true))
      assert.are.equal(vim.log.levels.WARN, notified[1].level)
      assert.are.equal(0, vim.fn.filereadable(path), "the buffer was written to disk")
      -- The warning is a heads-up, not a refusal: the panel still opens.
      assert.are.same({ "tree", "markdown open" }, f.verbs())

      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("says nothing for a buffer with no unsaved changes", function()
      local buf, path = draft()
      vim.bo[buf].modified = false

      mp.toggle(path)

      assert.are.same({}, notified)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe("outside a cmux session", function()
    it("says so once and calls nothing", function()
      -- The keymap stays installed (it is set from the markdown FileType
      -- autocmd, long before anyone presses it), so the no-op has to be
      -- quiet after the first press: not being in cmux is a property of the
      -- session, not of this file.
      cmux_bin = nil
      mp.toggle(A)
      mp.toggle(B)

      assert.are.same({}, f.calls)
      assert.are.same({}, mp._state().surfaces)
      assert.are.equal(1, #notified)
      assert.are.equal(vim.log.levels.WARN, notified[1].level)
    end)
  end)

  describe("toggle guards", function()
    it("ignores a nil or empty path rather than opening a panel on nothing", function()
      mp.toggle(nil)
      mp.toggle("")

      assert.are.same({}, f.calls)
    end)
  end)
end)
