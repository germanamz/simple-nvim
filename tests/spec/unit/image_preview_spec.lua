-- Pins config.image_preview: the cmux calls behind opening an image from the tree.
--
-- cmux's `open` can only tab a file into an existing pane, and left to itself it
-- picks Neovim's own, where the image would cover the editor. So an image tabs
-- into a pane beside Neovim when one is already open, and only when Neovim is
-- alone in its workspace is the image opened hidden in Neovim's pane and split
-- off into a pane of its own. These specs replace the CLI with `M._run` and
-- assert the exact argv of every invocation, in order.
--
-- The real `cmux` binary is never run -- it would mutate the developer's live
-- terminal -- so both ends are stubbed: `util.cmux.bin` (the "is this a cmux
-- session" check) and `M._run` (every invocation). `M._run` is called
-- synchronously, unlike the real path's vim.schedule hop, so a spec can assert
-- immediately after `ip.open()` with no waiting.
local ip = require("config.image_preview")

-- Which cmux CLI the module believes it has; nil is "not a cmux session".
local cmux_bin = "cmux-stub"
require("util.cmux").bin = function()
  return cmux_bin
end

--- The cmux subcommand an argv is asking for, past the `--json --id-format both`
--- prefix the calls that need an answer carry.
local function verb(args)
  return args[1] == "--json" and args[4] or args[1]
end

--- A pane as `cmux list-panes` reports it: which surfaces it holds and how big
--- it is on screen.
local function pane(id, surface_ids, width, height)
  return { id = id, surface_ids = surface_ids, pixel_frame = { width = width, height = height } }
end

-- Neovim's own pane, holding the surface CMUX_SURFACE_ID names.
local EDITOR = pane("editor", { "nvim-surface" }, 1000, 1000)

--- A stand-in cmux CLI, wired into `M._run`. Records every argv and answers the
--- way cmux 0.64 does: `list-panes` lists the workspace's panes, `open` reports
--- the new tab under `opened[1].payload`, and `split-off` reports the pane it
--- made. Ids are serial: the nth tab is `sN`, the nth split `pN`.
local function fake_cmux()
  local f = {
    calls = {},
    panes = { EDITOR }, -- what `list-panes` reports
    list_code = 0, -- exit code for `list-panes`
    open_code = 0, -- ... for an `open` into Neovim's pane
    dead = {}, -- pane id -> true: an `open --pane` into it fails ("Pane not found")
    split_code = 0, -- ... for `split-off`
    tabs = 0,
    splits = 0,
  }

  function f.verbs()
    return vim.tbl_map(verb, f.calls)
  end

  ip._run = function(args, on_done)
    table.insert(f.calls, args)
    local v = verb(args)
    if v == "list-panes" then
      if f.list_code ~= 0 then
        return on_done(f.list_code, "", "")
      end
      return on_done(0, vim.json.encode({ panes = f.panes }), "")
    elseif v == "open" then
      local into = vim.tbl_contains(args, "--pane") and args[vim.fn.index(args, "--pane") + 2]
      local code = into and (f.dead[into] and 1 or 0) or f.open_code
      if code ~= 0 then
        return on_done(code, "", "Error: not_found: Pane not found")
      end
      f.tabs = f.tabs + 1
      local payload = { surface_id = "s" .. f.tabs, pane_id = into or "editor" }
      return on_done(0, vim.json.encode({ opened = { { kind = "file", payload = payload } } }), "")
    elseif v == "split-off" then
      if f.split_code ~= 0 then
        return on_done(f.split_code, "", "Error: split failed")
      end
      f.splits = f.splits + 1
      return on_done(0, vim.json.encode({ pane_id = "p" .. f.splits, surface_id = args[6] }), "")
    elseif v == "close-surface" then
      return on_done(0, "", "")
    end
    error("unexpected cmux call: " .. table.concat(args, " "))
  end

  return f
end

-- Nothing here reads the files, so they need not exist; fs_realpath leaves a
-- missing path alone, so the argv carries them verbatim.
local A, B = "/nonexistent/image-preview-spec/a.png", "/nonexistent/image-preview-spec/b.jpg"

--- The argv that lists the panes of Neovim's workspace.
local LIST_PANES =
  { "--json", "--id-format", "both", "list-panes", "--workspace", "nvim-workspace" }

--- The argv that opens `path` hidden in Neovim's own pane.
local function open_here(path)
  return { "--json", "--id-format", "both", "open", path, "--no-focus", "--surface", "nvim-surface" }
end

--- The argv that opens `path` into `pane_id`.
local function open_into(path, pane_id)
  return { "--json", "--id-format", "both", "open", path, "--pane", pane_id, "--no-focus" }
end

--- The argv that splits tab `id` off to the right.
local function split_off(id)
  return {
    "--json",
    "--id-format",
    "both",
    "split-off",
    "--surface",
    id,
    "right",
    "--focus",
    "false",
  }
end

describe("config.image_preview", function()
  local real_surface, real_workspace, real_ui_open, real_notify, notes

  before_each(function()
    ip._reset()
    cmux_bin = "cmux-stub"
    real_surface, real_workspace = vim.env.CMUX_SURFACE_ID, vim.env.CMUX_WORKSPACE_ID
    vim.env.CMUX_SURFACE_ID, vim.env.CMUX_WORKSPACE_ID = "nvim-surface", "nvim-workspace"
    real_ui_open = vim.ui.open
    real_notify = vim.notify
    notes = {}
    vim.notify = function(msg, level)
      table.insert(notes, { msg = msg, level = level })
    end
  end)

  after_each(function()
    ip._run = nil
    vim.notify = real_notify
    vim.env.CMUX_SURFACE_ID, vim.env.CMUX_WORKSPACE_ID = real_surface, real_workspace
    vim.ui.open = real_ui_open
  end)

  describe("is_image", function()
    it("knows raster images by extension, in any case", function()
      assert.is_true(ip.is_image("/x/shot.png"))
      assert.is_true(ip.is_image("/x/PHOTO.JPG"))
      assert.is_true(ip.is_image("/x/anim.gif"))
      assert.is_true(ip.is_image("/x/pic.webp"))
    end)

    it("leaves text files alone, SVG included", function()
      -- SVG is markup you may well want to edit, so <CR> keeps opening it.
      assert.is_false(ip.is_image("/x/logo.svg"))
      assert.is_false(ip.is_image("/x/main.lua"))
      assert.is_false(ip.is_image("/x/Makefile"))
      assert.is_false(ip.is_image("/x/png"))
      assert.is_false(ip.is_image(nil))
    end)
  end)

  it("splits a pane off for the first image when Neovim is alone", function()
    local f = fake_cmux()
    ip.open(A)
    assert.are.same({ LIST_PANES, open_here(A), split_off("s1") }, f.calls)
    assert.are.equal("p1", ip._state().pane)
    assert.are.same({ [A] = "s1" }, ip._state().surfaces)
  end)

  it("tabs into a pane that is already open beside Neovim instead of splitting", function()
    local f = fake_cmux()
    f.panes = { EDITOR, pane("side", { "agent" }, 600, 1000) }
    ip.open(A)
    -- A split would squeeze the pane that is already there.
    assert.are.same({ LIST_PANES, open_into(A, "side") }, f.calls)
    assert.are.equal("side", ip._state().pane)
  end)

  it("picks the biggest pane that is not Neovim's own", function()
    local f = fake_cmux()
    -- Neovim's pane is the biggest of all, and must never be picked: the image
    -- would cover the editor.
    f.panes = {
      pane("strip", { "term" }, 1000, 200),
      EDITOR,
      pane("side", { "agent" }, 600, 1200),
    }
    ip.open(A)
    assert.are.same(open_into(A, "side"), f.calls[2])
  end)

  it("splits when cmux will not say which pane is Neovim's", function()
    local f = fake_cmux()
    -- Neovim's surface is in none of them, so any pick could be the editor.
    f.panes = { pane("a", { "x" }, 1000, 1000), pane("b", { "y" }, 500, 500) }
    ip.open(A)
    assert.are.same({ LIST_PANES, open_here(A), split_off("s1") }, f.calls)
  end)

  it("splits when cmux cannot list the panes", function()
    local f = fake_cmux()
    f.list_code = 1
    ip.open(A)
    assert.are.same({ "list-panes", "open", "split-off" }, f.verbs())
  end)

  it("tabs every later image straight into the same pane", function()
    local f = fake_cmux()
    ip.open(A)
    f.calls = {}
    -- A pane opened since does not pull the next image away from this one.
    f.panes = { EDITOR, pane("p1", { "s1" }, 500, 1000), pane("newer", { "z" }, 900, 1000) }
    ip.open(B)
    assert.are.same({ open_into(B, "p1") }, f.calls)
    assert.are.same({ [A] = "s1", [B] = "s2" }, ip._state().surfaces)
  end)

  it("moves to another open pane once its pane is gone", function()
    local f = fake_cmux()
    ip.open(A)
    -- Closing a pane's last tab closes the pane, so the next open into it fails.
    f.dead.p1 = true
    f.panes = { EDITOR, pane("side", { "agent" }, 600, 1000) }
    f.calls = {}
    ip.open(B)
    assert.are.same({ open_into(B, "p1"), LIST_PANES, open_into(B, "side") }, f.calls)
    assert.are.equal("side", ip._state().pane)
  end)

  it("splits a new pane once its pane is gone and Neovim is alone again", function()
    local f = fake_cmux()
    ip.open(A)
    f.dead.p1 = true
    f.calls = {}
    ip.open(B)
    assert.are.same({ open_into(B, "p1"), LIST_PANES, open_here(B), split_off("s2") }, f.calls)
    assert.are.equal("p2", ip._state().pane)
  end)

  it("swaps a re-opened image's old tab for a new one, opening before closing", function()
    local f = fake_cmux()
    ip.open(A)
    f.calls = {}
    ip.open(A)
    -- Close-then-open would close the pane with its only tab and split a new one.
    assert.are.same({ open_into(A, "p1"), { "close-surface", "--surface", "s1" } }, f.calls)
    assert.are.same({ [A] = "s2" }, ip._state().surfaces)
  end)

  it("closes the hidden tab and says so when the split fails", function()
    local f = fake_cmux()
    f.split_code = 1
    ip.open(A)
    -- The tab is sitting unselected in Neovim's pane; don't leave it there.
    assert.are.same({ "close-surface", "--surface", "s1" }, f.calls[4])
    assert.is_nil(ip._state().pane)
    assert.are.same({}, ip._state().surfaces)
    assert.are.equal(1, #notes)
    assert.matches("a.png", notes[1].msg, 1, true)
    assert.matches("split failed", notes[1].msg, 1, true)
  end)

  it("says so when cmux cannot open the file at all", function()
    local f = fake_cmux()
    f.open_code = 1
    ip.open(A)
    assert.are.same({ "list-panes", "open" }, f.verbs())
    assert.are.equal(1, #notes)
    assert.are.equal(vim.log.levels.WARN, notes[1].level)
  end)

  it("says so when the open pane will not take the image", function()
    local f = fake_cmux()
    f.panes = { EDITOR, pane("side", { "agent" }, 600, 1000) }
    f.dead.side = true
    ip.open(A)
    assert.are.same({ LIST_PANES, open_into(A, "side") }, f.calls)
    assert.is_nil(ip._state().pane)
    assert.are.equal(1, #notes)
  end)

  it("hands images to the system viewer outside cmux", function()
    local f = fake_cmux()
    cmux_bin = nil
    local opened
    vim.ui.open = function(path)
      opened = path
      return {}, nil
    end
    ip.open(A)
    assert.are.equal(A, opened)
    assert.are.same({}, f.calls)
  end)
end)
