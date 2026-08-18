-- Drives the REAL multicursor.nvim cursor-adding actions, so the keymaps in
-- lua/plugins/multicursor.lua are backed by something that demonstrably works
-- rather than by function names copied out of a readme. Every assertion goes
-- through the plugin's own public API (`numCursors`), which is the same state
-- the on-screen cursors are drawn from.
--
-- Cursor COUNTS are asserted rather than post-edit buffer text: applying an
-- edit at every cursor goes through multicursor's feedkeys path, and headless
-- Neovim never drains typeahead in a script context, so a text-mutation
-- assertion would hang instead of fail. The counts still exercise the real
-- match/line-scanning logic, which is the part that can actually break.
--
-- The actions are called bare, exactly as the keymaps call them: every
-- `examples.*` function already wraps its own body in `mc.action`, so wrapping
-- them again here would nest one action inside another.
local nvim_env = require("tests.helpers.nvim_env")

describe("smoke: multiple cursors (multicursor.nvim)", function()
  local root
  local mc

  before_each(function()
    root = nvim_env.setup_isolated_env()
    -- Source the plugin directly instead of through require("lazy").load: a
    -- freshly-cloned plugin makes lazy schedule an async docs task that
    -- misbehaves under plenary's busted runner, and the lazy-load trigger is
    -- not what this spec exercises (mirrors the mini.ai smoke spec).
    vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/multicursor.nvim")
    mc = require("multicursor-nvim")
    mc.setup()
  end)

  after_each(function()
    -- Cursors outlive the buffer they were added in, so a spec that leaves one
    -- behind would poison the next one's count.
    if mc and mc.hasCursors() then
      mc.clearCursors()
    end
    nvim_env.teardown(root)
  end)

  -- Scratch buffer + cursor placement. Created through the API rather than
  -- `:edit` so no filetype is inferred and no LSP client attaches.
  local function scratch(lines, row, col)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { row or 1, col or 0 })
    return buf
  end

  local FOO = { "local foo = 1", "local bar = foo", "print(foo)" }

  -- multicursor counts the main cursor, so N added cursors reads as N + 1.
  it("adds a cursor at the next match of the word under the cursor", function()
    scratch(FOO, 1, 6)

    mc.matchAddCursor(1)

    assert.are.equal(2, mc.numCursors())
  end)

  it("adds a cursor at every match in the buffer", function()
    scratch(FOO, 1, 6)

    mc.matchAllAddCursors()

    assert.are.equal(3, mc.numCursors())
  end)

  -- The <S-Down> / <S-Up> pair: column editing down a block of lines, which is
  -- the case macOS' Mission Control bindings pushed off <C-Up>/<C-Down>.
  it("stacks cursors down a column", function()
    scratch({ "one", "two", "three" }, 1, 0)

    mc.lineAddCursor(1)
    assert.are.equal(2, mc.numCursors())

    mc.lineAddCursor(1)
    assert.are.equal(3, mc.numCursors())
  end)

  it("stacks cursors up a column", function()
    scratch({ "one", "two", "three" }, 3, 0)

    mc.lineAddCursor(-1)
    assert.are.equal(2, mc.numCursors())

    mc.lineAddCursor(-1)
    assert.are.equal(3, mc.numCursors())
  end)

  -- Each add clones the main cursor in place and then moves the main one along
  -- the motion, so reversing direction drops a clone where the main cursor was
  -- and walks the main back onto a cursor that already exists — the overlapping
  -- pair merges and the total is unchanged.
  --
  -- The consequence is worth pinning because it is genuinely surprising:
  -- <S-Up> is NOT an undo for an over-shot <S-Down>. It moves the main cursor
  -- back into the stack while leaving the stack the same size. Removing a
  -- cursor is <leader>cx (deleteCursor, in the keymap layer).
  it("keeps the stack the same size when the direction reverses", function()
    scratch({ "one", "two", "three" }, 1, 0)

    mc.lineAddCursor(1)
    mc.lineAddCursor(1)
    assert.are.equal(3, mc.numCursors())

    mc.lineAddCursor(-1)
    assert.are.equal(3, mc.numCursors())
  end)

  it("skips a match instead of adding a cursor there", function()
    scratch(FOO, 1, 6)

    -- Skip the match on line 2, then take the one on line 3: still a single
    -- added cursor, but on the far match rather than the near one.
    mc.matchSkipCursor(1)
    mc.matchAddCursor(1)

    assert.are.equal(2, mc.numCursors())
  end)

  it("restores cursors after they are cleared", function()
    scratch(FOO, 1, 6)

    mc.matchAllAddCursors()
    assert.are.equal(3, mc.numCursors())

    mc.clearCursors()
    assert.is_false(mc.hasCursors())

    mc.restoreCursors()
    assert.are.equal(3, mc.numCursors())
  end)

  -- Docs/config drift guard: docs/keybindings.md §9 documents this exact set,
  -- and the lazy `keys` list is what makes the plugin load at all. A renamed or
  -- dropped trigger should fail here rather than silently stop working.
  -- Compared as a set so the assertion does not depend on declaration order.
  it("declares the documented lazy-load triggers", function()
    local declared = {}
    for _, key in ipairs(require("plugins.multicursor").keys) do
      declared[key[1]] = true
    end

    assert.are.same({
      ["<C-n>"] = true,
      ["<S-Down>"] = true,
      ["<S-Up>"] = true,
      ["<leader>cA"] = true,
      ["<leader>cN"] = true,
      ["<leader>cS"] = true,
      ["<leader>ca"] = true,
      ["<leader>cr"] = true,
      ["<leader>cs"] = true,
    }, declared)
  end)

  -- Every <leader> mapping in this config must carry a desc (pinned by
  -- which_key_spec); the lazy triggers are what which-key sees before the
  -- plugin loads, so they need descs too.
  it("gives every lazy trigger a desc", function()
    for _, key in ipairs(require("plugins.multicursor").keys) do
      assert.is_truthy(key.desc, "missing desc for " .. key[1])
    end
  end)

  -- Regression guard for the mini.pairs interaction. Replay at the non-main
  -- cursors comes from `getreg(".")`, which stops holding the whole insert once
  -- a <CR> lands inside an auto-inserted pair — the brackets vanish at every
  -- cursor but the main one. The keymap layer neutralises the openers while
  -- cursors are alive to avoid that.
  --
  -- Headless Neovim cannot type in insert mode (it never drains typeahead in a
  -- script context), so the end-to-end proof lives in a pty probe. What is
  -- checked here is the wiring: that the layer really does map every opener in
  -- insert mode. Losing this mapping silently reintroduces corrupted edits.
  it("neutralises auto-pair openers in the keymap layer", function()
    local captured
    local real = mc.addKeymapLayer
    mc.addKeymapLayer = function(callback)
      captured = callback
    end
    local ok, err = pcall(require("plugins.multicursor").config)
    mc.addKeymapLayer = real
    assert.is_true(ok, tostring(err))
    assert.is_truthy(captured, "plugin never registered a keymap layer")

    local insert_maps = {}
    captured(function(mode, lhs, rhs)
      local modes = type(mode) == "table" and mode or { mode }
      for _, m in ipairs(modes) do
        if m == "i" then
          insert_maps[lhs] = rhs
        end
      end
    end)

    -- Each opener must map to itself, so it inserts one literal character
    -- rather than going through mini.pairs' expr mapping.
    for _, opener in ipairs({ "(", "[", "{", '"', "'", "`" }) do
      assert.are.equal(opener, insert_maps[opener], "opener not neutralised: " .. opener)
    end
  end)
end)
