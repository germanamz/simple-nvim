# Block Scope Guides Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Draw vertical guide lines marking the foldable blocks the cursor is nested inside — the cursor's innermost block and each parent light up brighter, siblings and the rest of the file stay dim — without the code ever reflowing.

**Architecture:** One module, `lua/config/block_guides.lua`. Pure logic (indent math, ancestor-chain computation, per-row guide classification) is separated from the treesitter collector and the renderer so the logic is unit-tested with no parsers, and treesitter/render behavior is e2e-tested. Rendering uses a decoration provider (`nvim_set_decoration_provider`) emitting **ephemeral** overlay extmarks per visible line, so guides sit on existing indentation whitespace (no width change) and only visible lines cost anything.

**Tech Stack:** Neovim 0.11+ native API, `nvim-treesitter` (`main` branch) folds queries, `plenary` busted test harness (`make test-unit` / `make test-e2e`).

**Spec:** `docs/superpowers/specs/2026-06-08-block-scope-guides-design.md`

---

## File structure

| File | Responsibility |
|---|---|
| `lua/config/block_guides.lua` (create) | The whole feature: pure helpers, treesitter collector + per-changedtick cache, decoration provider, highlights, toggle, `setup()`. |
| `init.lua` (modify) | One line: `require("config.block_guides").setup()`. |
| `tests/spec/unit/block_guides_spec.lua` (create) | Pure-logic unit tests: `_indent_width`, `chain_at`, `guides_at`. Sandbox-safe (no treesitter, no UI). |
| `tests/spec/e2e/block_guides_spec.lua` (create) | Treesitter + render: `collect_foldable_blocks`, `guides_for_row`, toggle/keymap wiring. Run with the sandbox disabled. |

**Data shape** used across all functions — a *block* is a Lua table `{ s, e, col }`:
- `s`, `e`: 0-indexed start/end rows of the foldable extent (inclusive). Cursor containment is `s <= row <= e`.
- `col`: 0-indexed display column where this block's vertical guide is painted (the display width of the block header's leading indentation).

> **Sandbox note (from repo memory / `tests/README.md`):** the e2e tier writes swap/parser/git state and must be run with the Claude sandbox **disabled**. The unit tier is sandbox-safe. Run e2e steps with `dangerouslyDisableSandbox` only when a step shows a sandbox-caused failure.

---

### Task 1: Pure indent-width helper + module skeleton

**Files:**
- Create: `lua/config/block_guides.lua`
- Test: `tests/spec/unit/block_guides_spec.lua`

- [ ] **Step 1: Write the failing test**

Create `tests/spec/unit/block_guides_spec.lua`:

```lua
local bg = require("config.block_guides")

describe("config.block_guides", function()
  describe("_indent_width", function()
    it("counts leading spaces", function()
      assert.are.equal(4, bg._indent_width("    code", 2))
    end)

    it("returns 0 for no indentation", function()
      assert.are.equal(0, bg._indent_width("code", 2))
    end)

    it("expands a leading tab to the next tab stop", function()
      assert.are.equal(4, bg._indent_width("\tcode", 4))
    end)

    it("mixes spaces then a tab, snapping to the tab stop", function()
      -- 2 spaces (w=2), then a tab advances to the next multiple of 4 → 4
      assert.are.equal(4, bg._indent_width("  \tcode", 4))
    end)

    it("stops at the first non-whitespace character", function()
      assert.are.equal(2, bg._indent_width("  x  y", 2))
    end)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/spec/unit/block_guides_spec.lua"`
Expected: FAIL — `module 'config.block_guides' not found`.

- [ ] **Step 3: Write minimal implementation**

Create `lua/config/block_guides.lua`:

```lua
-- Block scope guides: vertical lines marking the foldable blocks the cursor is
-- nested inside. Persistent dim guides on every foldable block; the cursor's
-- ancestor chain (innermost + parents, siblings excluded) lights up brighter.
-- Rendered via a decoration provider with ephemeral overlay extmarks, so the
-- code never reflows and only visible lines cost anything. See
-- docs/superpowers/specs/2026-06-08-block-scope-guides-design.md.
local M = {}

-- Display width of a line's leading whitespace, honoring tab stops.
function M._indent_width(line, tabstop)
  tabstop = tabstop or 8
  local w = 0
  for i = 1, #line do
    local ch = line:sub(i, i)
    if ch == " " then
      w = w + 1
    elseif ch == "\t" then
      w = w + (tabstop - (w % tabstop))
    else
      return w
    end
  end
  return w
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/spec/unit/block_guides_spec.lua"`
Expected: PASS — 5 successes.

- [ ] **Step 5: Commit**

```bash
git add lua/config/block_guides.lua tests/spec/unit/block_guides_spec.lua
git commit -m "Add block_guides module with pure indent-width helper"
```

---

### Task 2: Pure ancestor-chain computation

**Files:**
- Modify: `lua/config/block_guides.lua`
- Test: `tests/spec/unit/block_guides_spec.lua`

- [ ] **Step 1: Write the failing test**

Add inside the top-level `describe("config.block_guides", ...)` block in `tests/spec/unit/block_guides_spec.lua`:

```lua
  describe("chain_at", function()
    -- function (rows 0..6) containing a sibling if (1..2) and the cursor's
    -- if (3..5); cursor on row 4.
    local blocks = {
      { s = 0, e = 6, col = 0 }, -- 1: function
      { s = 1, e = 2, col = 2 }, -- 2: sibling if
      { s = 3, e = 5, col = 2 }, -- 3: cursor's if
    }

    it("returns the innermost containing block as active", function()
      local chain = bg.chain_at(blocks, 4)
      assert.are.equal(3, chain.active)
    end)

    it("includes the parent in the chain set", function()
      local chain = bg.chain_at(blocks, 4)
      assert.is_true(chain.set[1]) -- function (parent)
      assert.is_true(chain.set[3]) -- the if (innermost)
    end)

    it("excludes sibling blocks the cursor is not inside", function()
      local chain = bg.chain_at(blocks, 4)
      assert.is_nil(chain.set[2]) -- sibling if
    end)

    it("has no active block when the cursor is outside every block", function()
      local chain = bg.chain_at(blocks, 10)
      assert.is_nil(chain.active)
    end)

    it("picks the deeper block on an extent tie via larger col", function()
      local tied = {
        { s = 0, e = 2, col = 0 },
        { s = 0, e = 2, col = 2 },
      }
      assert.are.equal(2, bg.chain_at(tied, 1).active)
    end)
  end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/spec/unit/block_guides_spec.lua"`
Expected: FAIL — `attempt to call field 'chain_at' (a nil value)`.

- [ ] **Step 3: Write minimal implementation**

In `lua/config/block_guides.lua`, add before `return M`:

```lua
-- blocks: array of { s, e, col } (0-indexed rows; col = display column).
-- Returns { active = <index|nil>, set = { [index] = true } } for the blocks
-- whose extent contains cursor_row; active = innermost (smallest extent, then
-- deeper col on a tie).
function M.chain_at(blocks, cursor_row)
  local containing = {}
  for i, b in ipairs(blocks) do
    if cursor_row >= b.s and cursor_row <= b.e then
      containing[#containing + 1] = i
    end
  end
  table.sort(containing, function(ia, ib)
    local a, b = blocks[ia], blocks[ib]
    local da, db = a.e - a.s, b.e - b.s
    if da ~= db then
      return da < db
    end
    return a.col > b.col
  end)
  local set = {}
  for _, i in ipairs(containing) do
    set[i] = true
  end
  return { active = containing[1], set = set }
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/spec/unit/block_guides_spec.lua"`
Expected: PASS — 10 successes total.

- [ ] **Step 5: Commit**

```bash
git add lua/config/block_guides.lua tests/spec/unit/block_guides_spec.lua
git commit -m "Add pure ancestor-chain computation to block_guides"
```

---

### Task 3: Pure per-row guide classification

**Files:**
- Modify: `lua/config/block_guides.lua`
- Test: `tests/spec/unit/block_guides_spec.lua`

- [ ] **Step 1: Write the failing test**

Add inside the top-level `describe` block:

```lua
  describe("guides_at", function()
    local blocks = {
      { s = 0, e = 6, col = 0 }, -- function
      { s = 1, e = 2, col = 2 }, -- sibling if
      { s = 3, e = 5, col = 2 }, -- cursor's if
    }
    local chain = bg.chain_at(blocks, 4) -- active=3, set={1,3}

    it("classifies the innermost block as active and the parent as chain", function()
      -- row 4, indented past col 2 (e.g. body at col 4)
      local guides = bg.guides_at(blocks, chain, 4, 4)
      assert.are.same({
        { col = 0, tier = "chain" }, -- function
        { col = 2, tier = "active" }, -- cursor's if
      }, guides)
    end)

    it("marks a sibling block's guide as dim", function()
      -- row 2 is inside the sibling if (block 2) and the function (block 1)
      local guides = bg.guides_at(blocks, chain, 2, 4)
      assert.are.same({
        { col = 0, tier = "chain" }, -- function (in chain)
        { col = 2, tier = "dim" }, -- sibling if (not in chain)
      }, guides)
    end)

    it("omits a guide when the line's indent does not reach past its col", function()
      -- row 4, indent only 2 → the col-2 guide is gated out (cell has code),
      -- but the col-0 function guide still draws.
      local guides = bg.guides_at(blocks, chain, 4, 2)
      assert.are.same({ { col = 0, tier = "chain" } }, guides)
    end)

    it("draws every covering guide on a blank line (math.huge indent)", function()
      local guides = bg.guides_at(blocks, chain, 4, math.huge)
      assert.are.equal(2, #guides)
    end)

    it("returns dim guides when there is no chain", function()
      local guides = bg.guides_at(blocks, nil, 4, 4)
      assert.are.same({
        { col = 0, tier = "dim" },
        { col = 2, tier = "dim" },
      }, guides)
    end)
  end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/spec/unit/block_guides_spec.lua"`
Expected: FAIL — `attempt to call field 'guides_at' (a nil value)`.

- [ ] **Step 3: Write minimal implementation**

In `lua/config/block_guides.lua`, add before `return M`:

```lua
-- For screen `row` with leading-indent display width `row_indent` (pass
-- math.huge for blank lines so all covering guides draw), return the guides to
-- paint: array of { col, tier } sorted by col. tier is "active" for the
-- cursor's innermost block, "chain" for a parent in the chain, else "dim".
function M.guides_at(blocks, chain, row, row_indent)
  local out = {}
  for i, b in ipairs(blocks) do
    if row >= b.s and row <= b.e and row_indent > b.col then
      local tier = "dim"
      if chain then
        if chain.active == i then
          tier = "active"
        elseif chain.set[i] then
          tier = "chain"
        end
      end
      out[#out + 1] = { col = b.col, tier = tier }
    end
  end
  table.sort(out, function(a, b)
    return a.col < b.col
  end)
  return out
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/spec/unit/block_guides_spec.lua"`
Expected: PASS — 15 successes total.

- [ ] **Step 5: Commit**

```bash
git add lua/config/block_guides.lua tests/spec/unit/block_guides_spec.lua
git commit -m "Add pure per-row guide classification to block_guides"
```

---

### Task 4: Treesitter foldable-block collector + cache

**Files:**
- Modify: `lua/config/block_guides.lua`
- Test: `tests/spec/e2e/block_guides_spec.lua`

- [ ] **Step 1: Write the failing test**

Create `tests/spec/e2e/block_guides_spec.lua`:

```lua
local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")
local git_fixture = require("tests.helpers.git_fixture")
local bg = require("config.block_guides")

describe("e2e: block_guides", function()
  local root, prev_cwd

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
  end)

  after_each(function()
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  -- Opens a lua buffer with nested blocks and waits for treesitter to attach.
  local function open_sample()
    local content = table.concat({
      "local function foo()", -- row 0: function header
      "  local x = 1", -- row 1
      "  if cond then", -- row 2: if header
      "    do_thing()", -- row 3 (cursor here)
      "    more()", -- row 4
      "  end", -- row 5
      "end", -- row 6
      "", -- row 7
    }, "\n")
    local repo = git_fixture.repo({
      commits = { { files = { ["sample.lua"] = content } }, message = "init" },
    })
    local canonical = vim.uv.fs_realpath(repo) or repo
    vim.fn.chdir(canonical)
    vim.cmd("edit " .. canonical .. "/sample.lua")
    local buf = vim.api.nvim_get_current_buf()
    wait.wait_for(function()
      return vim.treesitter.highlighter.active[buf] ~= nil
    end, 5000, "treesitter highlighter never attached")
    return buf
  end

  it("collects the function and the nested if as foldable blocks", function()
    local buf = open_sample()
    local blocks = bg.collect_foldable_blocks(buf)

    -- Find a block by its start row.
    local by_start = {}
    for _, b in ipairs(blocks) do
      by_start[b.s] = b
    end

    assert.is_not_nil(by_start[0], "expected a foldable block starting at row 0 (function)")
    assert.are.equal(6, by_start[0].e)
    assert.are.equal(0, by_start[0].col)

    assert.is_not_nil(by_start[2], "expected a foldable block starting at row 2 (if)")
    assert.are.equal(2, by_start[2].col)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run (sandbox disabled): `make test-e2e 2>&1 | tail -30`
Expected: FAIL — `attempt to call field 'collect_foldable_blocks' (a nil value)`.

- [ ] **Step 3: Write minimal implementation**

In `lua/config/block_guides.lua`, add a cache table near the top (just under `local M = {}`):

```lua
local cache = {} -- [buf] = { tick = <changedtick>, blocks = {...} }
```

Add before `return M`:

```lua
-- All foldable blocks in `buf` as { s, e, col }, via the language's folds query.
-- col is the display width of the block header's leading indentation.
function M.collect_foldable_blocks(buf)
  local blocks = {}
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return blocks
  end
  local query = vim.treesitter.query.get(parser:lang(), "folds")
  if not query then
    return blocks
  end
  local tabstop = vim.bo[buf].tabstop
  for _, tree in ipairs(parser:parse()) do
    for id, node in query:iter_captures(tree:root(), buf, 0, -1) do
      if query.captures[id] == "fold" then
        local s, _, e = node:range()
        if e > s then
          local header = vim.api.nvim_buf_get_lines(buf, s, s + 1, false)[1] or ""
          blocks[#blocks + 1] = { s = s, e = e, col = M._indent_width(header, tabstop) }
        end
      end
    end
  end
  return blocks
end

-- collect_foldable_blocks cached per buffer changedtick.
function M.blocks_for(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local c = cache[buf]
  if c and c.tick == tick then
    return c.blocks
  end
  local blocks = M.collect_foldable_blocks(buf)
  cache[buf] = { tick = tick, blocks = blocks }
  return blocks
end
```

- [ ] **Step 4: Run test to verify it passes**

Run (sandbox disabled): `make test-e2e 2>&1 | tail -30`
Expected: PASS — the block_guides e2e example passes (other e2e specs unaffected).

- [ ] **Step 5: Commit**

```bash
git add lua/config/block_guides.lua tests/spec/e2e/block_guides_spec.lua
git commit -m "Add treesitter foldable-block collector + changedtick cache"
```

---

### Task 5: Per-row render helper

**Files:**
- Modify: `lua/config/block_guides.lua`
- Test: `tests/spec/e2e/block_guides_spec.lua`

- [ ] **Step 1: Write the failing test**

Add inside the `describe("e2e: block_guides", ...)` block (reuses `open_sample`):

```lua
  it("renders active + chain guides for the cursor's row", function()
    local buf = open_sample()
    local blocks = bg.blocks_for(buf)
    local chain = bg.chain_at(blocks, 3) -- cursor on row 3 (inside the if)

    -- Row 3 body is indented 4; both the function (col 0) and if (col 2) cover
    -- it. The if is innermost → active; the function is a parent → chain.
    local guides = bg.guides_for_row(blocks, chain, buf, 3)
    assert.are.same({
      { col = 0, tier = "chain" },
      { col = 2, tier = "active" },
    }, guides)
  end)

  it("draws guides through a blank line inside a block", function()
    local buf = open_sample()
    -- Append a blank line inside the if body, then a closing line.
    vim.api.nvim_buf_set_lines(buf, 4, 4, false, { "" }) -- new blank row 4
    local blocks = bg.blocks_for(buf)
    local chain = bg.chain_at(blocks, 3)
    local guides = bg.guides_for_row(blocks, chain, buf, 4) -- the blank row
    assert.is_true(#guides >= 1, "expected guides to draw through the blank line")
  end)
```

- [ ] **Step 2: Run test to verify it fails**

Run (sandbox disabled): `make test-e2e 2>&1 | tail -30`
Expected: FAIL — `attempt to call field 'guides_for_row' (a nil value)`.

- [ ] **Step 3: Write minimal implementation**

In `lua/config/block_guides.lua`, add before `return M`:

```lua
-- Guides to paint on `row`, reading the line for its indent. Blank/whitespace-
-- only lines use math.huge so every covering guide draws through the gap.
function M.guides_for_row(blocks, chain, buf, row)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local indent = line:match("^%s*$") and math.huge or M._indent_width(line, vim.bo[buf].tabstop)
  return M.guides_at(blocks, chain, row, indent)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run (sandbox disabled): `make test-e2e 2>&1 | tail -30`
Expected: PASS — both new examples pass.

- [ ] **Step 5: Commit**

```bash
git add lua/config/block_guides.lua tests/spec/e2e/block_guides_spec.lua
git commit -m "Add per-row guide render helper with blank-line handling"
```

---

### Task 6: Highlights, decoration provider, toggle, and wiring

**Files:**
- Modify: `lua/config/block_guides.lua`
- Modify: `init.lua:31` (add the `setup()` call after `statusline`)
- Test: `tests/spec/e2e/block_guides_spec.lua`

- [ ] **Step 1: Write the failing test**

Add inside the `describe("e2e: block_guides", ...)` block:

```lua
  it("defines the three guide highlight groups", function()
    open_sample()
    for _, name in ipairs({ "BlockGuide", "BlockGuideChain", "BlockGuideActive" }) do
      local hl = vim.api.nvim_get_hl(0, { name = name })
      assert.is_true(next(hl) ~= nil, name .. " highlight group is not defined")
    end
  end)

  it("renders without error and toggles on and off", function()
    open_sample()
    assert.is_true(bg.is_enabled())
    vim.cmd("redraw")

    bg.toggle()
    assert.is_false(bg.is_enabled())
    vim.cmd("redraw")

    bg.toggle()
    assert.is_true(bg.is_enabled())
  end)

  it("registers the <leader>ub toggle keymap", function()
    open_sample()
    local found = false
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      if m.lhs == " ub" then
        found = true
        break
      end
    end
    assert.is_true(found, "<leader>ub keymap not registered")
  end)
```

- [ ] **Step 2: Run test to verify it fails**

Run (sandbox disabled): `make test-e2e 2>&1 | tail -30`
Expected: FAIL — highlight groups undefined / `bg.is_enabled` nil / keymap missing (because `setup()` isn't wired or doesn't exist yet).

- [ ] **Step 3: Write minimal implementation**

In `lua/config/block_guides.lua`, add the renderer state near the top (under the `cache` line):

```lua
local ns = vim.api.nvim_create_namespace("block_guides")
local GUIDE_CHAR = "│"
local HL = { active = "BlockGuideActive", chain = "BlockGuideChain", dim = "BlockGuide" }
local EXCLUDED_FT = { [""] = true, markdown = true, mdx = true, help = true, text = true }
local enabled = true
local draw = { active = false, blocks = nil, chain = nil } -- set per redraw in on_win
```

Add before `return M`:

```lua
function M.is_enabled()
  return enabled
end

local function eligible(buf)
  if not enabled then
    return false
  end
  if EXCLUDED_FT[vim.bo[buf].filetype] then
    return false
  end
  return vim.treesitter.highlighter.active[buf] ~= nil
end

local function ensure_highlights()
  vim.api.nvim_set_hl(0, "BlockGuide", { link = "Whitespace", default = true })
  vim.api.nvim_set_hl(0, "BlockGuideChain", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "BlockGuideActive", { link = "Function", default = true })
end

-- Decoration provider: on_win runs once per window per redraw (compute the
-- chain from that window's cursor); on_line paints ephemeral overlay guides.
local function on_win(_, win, buf)
  draw.active = false
  if not eligible(buf) then
    return false
  end
  local blocks = M.blocks_for(buf)
  if #blocks == 0 then
    return false
  end
  draw.active = true
  draw.blocks = blocks
  draw.chain = M.chain_at(blocks, vim.api.nvim_win_get_cursor(win)[1] - 1)
  return true
end

local function on_line(_, _win, buf, row)
  if not draw.active then
    return
  end
  for _, g in ipairs(M.guides_for_row(draw.blocks, draw.chain, buf, row)) do
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      ephemeral = true,
      virt_text = { { GUIDE_CHAR, HL[g.tier] } },
      virt_text_win_col = g.col,
      hl_mode = "combine",
    })
  end
end

function M.toggle()
  enabled = not enabled
  pcall(vim.api.nvim__redraw, { valid = false, flush = true })
  vim.notify("Block guides " .. (enabled and "on" or "off"))
end

function M.setup()
  ensure_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { callback = ensure_highlights })
  vim.api.nvim_set_decoration_provider(ns, { on_win = on_win, on_line = on_line })

  -- Drop the per-buffer cache when a buffer is wiped.
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    callback = function(args)
      cache[args.buf] = nil
    end,
  })

  -- Repaint the moved window on cursor move so the chain recolors across the
  -- whole viewport (a partial redraw would leave stale ephemeral guides).
  -- Coalesced to once per event-loop tick.
  local redraw_scheduled = false
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    callback = function()
      if not enabled or redraw_scheduled then
        return
      end
      redraw_scheduled = true
      local win = vim.api.nvim_get_current_win()
      vim.schedule(function()
        redraw_scheduled = false
        if vim.api.nvim_win_is_valid(win) then
          pcall(vim.api.nvim__redraw, { win = win, valid = false })
        end
      end)
    end,
  })

  vim.keymap.set("n", "<leader>ub", M.toggle, { desc = "Toggle block guides" })
end
```

In `init.lua`, add after line 30 (`require("config.statusline").setup()`):

```lua
require("config.block_guides").setup()
```

- [ ] **Step 4: Run test to verify it passes**

Run (sandbox disabled): `make test-e2e 2>&1 | tail -30`
Expected: PASS — all block_guides e2e examples pass.

- [ ] **Step 5: Commit**

```bash
git add lua/config/block_guides.lua init.lua tests/spec/e2e/block_guides_spec.lua
git commit -m "Render block guides via decoration provider; wire setup + toggle"
```

---

### Task 7: Lint, full test sweep, and manual verification

**Files:** none (verification only)

- [ ] **Step 1: Format and lint**

Run: `make fmt && make lint`
Expected: `stylua --check` passes with no diff.

- [ ] **Step 2: Run the unit suite**

Run: `make test-unit 2>&1 | tail -20`
Expected: PASS — including all `config.block_guides` pure-logic examples.

- [ ] **Step 3: Run the smoke + e2e suites (sandbox disabled)**

Run: `make test-smoke && make test-e2e 2>&1 | tail -30`
Expected: PASS — no regressions; `e2e: block_guides` green.

- [ ] **Step 4: Manual smoke check**

Open a real nested code file (e.g. `lua/config/telescope_smart.lua`) in this config and confirm by eye:
- Dim guides appear on indented blocks; the cursor's innermost block and its parents render brighter, siblings stay dim.
- Moving the cursor up/down through nested blocks recolors smoothly with no horizontal shift or flicker.
- `<leader>ub` toggles the guides off and on.
- Open a markdown file and confirm no guides render there.

- [ ] **Step 5: Commit (if fmt produced changes)**

```bash
git add -A
git commit -m "Format block_guides" || echo "nothing to commit"
```

---

## Self-review

**Spec coverage:**
- Visual model (parallel lines, parents in/siblings out, persistent dim, overlay/no-reflow) → Tasks 2, 3, 5, 6 (`chain_at`, `guides_at` tiers, `virt_text_win_col` overlay).
- Three tiers + default highlight links → Task 6 (`ensure_highlights`, `HL`).
- Block detection = treesitter foldable + ancestor chain + sibling exclusion → Tasks 4 (`collect_foldable_blocks`), 2 (`chain_at`).
- Foldable-range cache per changedtick → Task 4 (`blocks_for`).
- Decoration provider + ephemeral overlay marks + visible-only → Task 6 (`on_win`/`on_line`).
- Cursor-chain recompute on move (debounced) → Task 6 (CursorMoved coalesced redraw; chain recomputed in `on_win`).
- Activation gate (treesitter active, code ft, exclude prose) → Task 6 (`eligible`, `EXCLUDED_FT`).
- `<leader>ub` toggle, default on, ColorScheme re-apply → Task 6.
- Edge cases: blank lines (Task 5 `math.huge`), tabs (Task 1 `_indent_width`), no enclosing block (Task 2 `active=nil`; Task 3 dim), disabled buffer (Task 6 `on_win` returns false).
- `init.lua` wiring → Task 6.
- Tests: pure unit (Tasks 1–3), treesitter/render e2e (Tasks 4–6) → matches spec's testing section.

**Placeholder scan:** No TBD/TODO/"handle edge cases" — every code step shows complete code.

**Type consistency:** Block shape `{ s, e, col }`, `chain = { active, set }`, guide `{ col, tier }`, and `HL` tiers (`active`/`chain`/`dim`) are used identically across `chain_at`, `guides_at`, `guides_for_row`, `collect_foldable_blocks`, and `on_line`. The `fold` capture name, `blocks_for` cache, and `is_enabled`/`toggle` names match between implementation and tests.
