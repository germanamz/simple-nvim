-- Long-line peek: after the cursor has rested ~2.5s on a line too wide for the
-- window, the line unfolds in place -- soft-wrapped across the rows below it --
-- and folds back on the next cursor move, scroll, edit or mode change (a
-- keypress that changes none of those, `<C-g>` say, leaves it up). 'wrap' stays off globally
-- (config/options.lua:255); this is the one line you are actually reading,
-- shown in full, without scrolling the viewport sideways to reach its tail.
--
-- Automatic only. There is deliberately no keymap: the whole point is that the
-- text you are already staring at eventually shows itself. The dwell guard also
-- refuses to fire mid-keystroke -- a float appearing while a mapping is
-- half-typed or an operator is pending reads as a malfunction.
--
-- HOW IT RENDERS (and why not the obvious alternatives)
-- A borderless, non-focusable float over the cursor line showing the *same
-- buffer* with 'wrap' on, plus a `virt_lines` extmark of (height - 1) blank
-- rows on that line so the real code below is pushed down by exactly what the
-- float covers. The line appears to grow extra rows; nothing is hidden and the
-- parent's view is provably untouched (winsaveview() is identical before,
-- during and after).
--   • Rejected -- rendering the tail as `virt_lines` text instead of a float:
--     virtual lines carry no highlighting of their own, so every decoration
--     would have to be re-derived by hand. Slicing treesitter captures per row
--     costs 0.29-1.4 ms/row on injection-heavy buffers, silently misses
--     injected languages, and cannot see gitsigns word-diff or treesitter
--     highlights at all (both are ephemeral extmarks, invisible to
--     nvim_buf_get_extmarks). Sharing the buffer with a float gets treesitter,
--     LSP semantic tokens, inlay hints and diagnostic underlines for free.
--   • Rejected -- toggling window-local 'wrap': it reflows the entire viewport,
--     not the one line, and breaks block_guides (its `virt_text_win_col` bars
--     paint only on each buffer line's first screen row).
--   • Rejected -- benlubas/wrapping-paper.nvim, the only published plugin with
--     this architecture: it is manual-trigger, *enters* the float, and drops
--     your column permanently on close (its teardown restores nothing).
--   • Rejected -- util.overlay, which every other float here goes through: its
--     :close() deletes the buffer it mounted, and this float mounts the user's
--     real buffer. Reusing it would wipe the file you are editing.
--
-- See docs/superpowers/long-line-peek.md.
local M = {}

-- Dwell before the line unfolds. Long enough to read as a deliberate pause
-- rather than a twitch -- this fires unprompted, so it must not go off while you
-- are still moving through the file -- and well clear of 'updatetime' (250), so
-- it never reads as part of the gitsigns blame / LSP highlight beat.
M.DELAY_MS = 2500

local ns = vim.api.nvim_create_namespace("long_line_peek")

-- Width of a window's text area -- everything left of it (number, sign and fold
-- columns) is `textoff`. Clamped at 0 so a window narrower than its own gutter
-- cannot produce negative geometry.
---@param wininfo table a getwininfo() entry
---@return integer
function M.text_width(wininfo)
  return math.max(0, wininfo.width - wininfo.textoff)
end

-- Can this line ever be fully visible? Deliberately independent of `leftcol`:
-- a line wider than the text area is clipped at every horizontal scroll
-- position, and one that fits is always reachable by scrolling back. A
-- zero-width text area answers false rather than firing on every line.
---@param line_width integer display width of the line
---@param text_width integer display width of the window's text area
---@return boolean
function M.is_clipped(line_width, text_width)
  return text_width > 0 and line_width > text_width
end

-- How tall the float may be, and how many filler rows go under the line.
--
-- The spacer is one row shorter than the float because the float's first row
-- sits on the cursor line's own screen row -- a real buffer row that needs no
-- filler. Off by one here and the code below the line visibly jumps.
--
-- `height` is floored at 1: nvim_win_set_config rejects 0 with "expected
-- positive Integer", which would surface as an E5108 on an ordinary keypress
-- whenever the cursor sat on the last usable screen row.
---@param opts table {wrapped_height, rows_available}
---@return table {height, spacer, truncated}
function M.geometry(opts)
  local height = math.max(1, math.min(opts.wrapped_height, opts.rows_available))
  return {
    height = height,
    spacer = height - 1,
    truncated = height < opts.wrapped_height,
  }
end

-- Would this geometry actually show anything new? A one-row float renders
-- exactly the screenful the clipped line already rendered, so it is a flicker
-- with no payload. Reachable only with the cursor on the last usable screen
-- row -- 'scrolloff' (8) keeps it well clear of the bottom otherwise.
---@param geo table a geometry() result
---@return boolean
function M.reveals_more(geo)
  return geo.height >= 2
end

-- The `virt_lines` payload: n blank rows. They are always fully covered by the
-- float, so their highlight never shows; NonText is the honest group for a row
-- that is structurally empty.
---@param n integer
---@return table[]
function M.spacer_lines(n)
  local lines = {}
  for _ = 1, n do
    lines[#lines + 1] = { { "", "NonText" } }
  end
  return lines
end

-- Is the editor in a state where an unprompted float is welcome? Pure over a
-- context table so the whole matrix is unit-testable without driving a real
-- session into each mode.
--
-- `mode` is compared exactly against "n" -- mode(1) returns the *full* mode
-- string, so operator-pending is "no" and must not slip through a prefix test.
-- `state` carries state("mo"): "m" while a mapping is half-typed, "o" while an
-- operator waits for its motion. `buftype` alone excludes the tree (nofile),
-- telescope (prompt), help, quickfix and terminals, so no filetype denylist is
-- needed.
---@param ctx table {mode, state, pumvisible, buftype, relative, large}
---@return boolean
function M.eligible(ctx)
  return ctx.mode == "n"
    and ctx.state == ""
    and not ctx.pumvisible
    and ctx.buftype == ""
    and ctx.relative == ""
    and not ctx.large
end

-- ---------------------------------------------------------------------------
-- Impure shell
-- ---------------------------------------------------------------------------

-- The peek reads as "this whole block is one line", so it takes CursorLine's
-- background across every row it occupies. Derived rather than linked: the
-- float maps it onto `Normal`, and CursorLine sets only `bg` in most themes --
-- a link would leave the text with no foreground of its own.
local function ensure_highlights()
  local cursorline = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false })
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  vim.api.nvim_set_hl(0, "LongLinePeek", {
    bg = cursorline.bg or normal.bg,
    fg = normal.fg,
  })
end

-- { float = <win>, buf = <buf> } while a peek is on screen.
local active = nil

-- Guards the window/extmark writes in open() from re-entering through the
-- autocmds that drive rearm(). nvim_open_win runs with noautocmd, and setting
-- or deleting a virt_lines extmark fires neither CursorMoved nor WinScrolled,
-- but the flag makes that independent of those guarantees holding.
local opening = false

-- Tear down the float and the spacer. Only the *window* is closed -- the buffer
-- belongs to the user (see the util.overlay note in the header).
local function close()
  if not active then
    return
  end
  local a = active
  active = nil
  if vim.api.nvim_win_is_valid(a.float) then
    pcall(vim.api.nvim_win_close, a.float, true)
  end
  if vim.api.nvim_buf_is_valid(a.buf) then
    pcall(vim.api.nvim_buf_clear_namespace, a.buf, ns, 0, -1)
  end
end

M._close = close

local function current_ctx()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  return {
    mode = vim.fn.mode(1),
    state = vim.fn.state("mo"),
    pumvisible = vim.fn.pumvisible() == 1,
    buftype = vim.bo[buf].buftype,
    relative = vim.api.nvim_win_get_config(win).relative,
    large = require("util.largefile").is_large(buf),
  }
end

-- The only code that maps live editor state onto eligible()'s pure matrix.
-- Exported because eligible() being exhaustively unit-tested proves nothing
-- about whether the fields it reads are spelled right: `state()` for
-- `state("mo")`, or `mode()` for `mode(1)`, both leave the suite green and the
-- feature dead (or firing mid-operator).
M._ctx = current_ctx

-- Options the float needs on top of style="minimal". Every one of these is
-- load-bearing:
--   • 'wrap' -- a float inherits the *current* window's value, so it arrives
--     false here and the whole feature would be a no-op.
--   • 'signcolumn' -- minimal sets "auto", which shifts the text 2 cells right
--     of the parent's the moment the line carries a gitsigns sign.
--   • 'list' -- the parent renders spaces as "·" (options.lua:12-21); without
--     this the unfolded rows would not look like the line they replace.
--   • 'scrolloff' -- non-zero would fight winrestview for the float's topline.
--   • 'foldenable' -- minimal does not touch it, and an inherited fold would
--     collapse the very line being peeked.
local function configure_float(fw, win)
  local wo = vim.wo[fw]
  wo.wrap = true
  wo.linebreak = false -- break at the column, not at word boundaries, so the
  -- rows line up with the real line's own truncation point
  wo.signcolumn = "no"
  wo.number = false
  wo.relativenumber = false
  wo.cursorline = false
  wo.foldenable = false
  wo.scrolloff = 0
  wo.sidescrolloff = 0
  wo.list = vim.wo[win].list
  wo.listchars = vim.wo[win].listchars
  wo.winhighlight = table.concat({
    "Normal:LongLinePeek",
    "NormalFloat:LongLinePeek",
    "NormalNC:LongLinePeek",
    "EndOfBuffer:LongLinePeek",
  }, ",")
end

local function open()
  if active then
    return
  end
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  local wi = vim.fn.getwininfo(win)[1]
  if not wi then
    return
  end

  -- A wrapped window clips nothing, so there is nothing to reveal -- and the
  -- geometry below would be wrong anyway: under 'wrap', winline() is the
  -- cursor's *continuation* row, not the line's first row, so the float would
  -- anchor mid-line and repaint the line a second time.
  if vim.wo[win].wrap then
    return
  end

  local textw = M.text_width(wi)
  local lnum = vim.api.nvim_win_get_cursor(win)[1]

  -- A closed fold renders as one foldtext row that is not this line, and
  -- `virt_lines` on a folded line are silently not drawn -- so the spacer would
  -- never materialise and the float would paint straight over real code below.
  if vim.fn.foldclosed(lnum) ~= -1 then
    return
  end

  -- A horizontally scrolled window draws the cursor at (virtcol - leftcol), but
  -- the float always renders the line from column 0. The cursor block would sit
  -- over an unrelated character, and a truncated peek could hide the very
  -- segment being read. Anchoring the float to the cursor's wrapped row instead
  -- would mean covering rows *above* the line too; not worth it, since landing
  -- on a long line from above keeps leftcol at 0 -- the case this feature is for.
  if vim.fn.winsaveview().leftcol ~= 0 then
    return
  end

  -- virtcol handles tabs and multibyte; '$' is one past the last cell.
  local line_width = vim.fn.virtcol({ lnum, "$" }) - 1
  if not M.is_clipped(line_width, textw) then
    return
  end

  -- Counted BEFORE the float exists: win_findbuf includes floating windows, so
  -- asking after the float has mounted `buf` always answers "at least 2" and the
  -- fallback below would be dead code.
  local shared = #vim.fn.win_findbuf(buf) > 1

  -- Rows the peek may occupy: the cursor's own row through the last text row of
  -- *this window*. Deliberately not measured against the screen, even though a
  -- float may legally overflow its parent: the spacer can only push rows inside
  -- this window, so any row the float covered past the bottom edge would belong
  -- to a neighbouring split and would be genuinely hidden -- the one thing this
  -- design exists to avoid.
  local rows_available = wi.height - vim.fn.winline() + 1
  if rows_available < 1 then
    return
  end

  -- The float is registered in `active` the instant it exists, before anything
  -- that can fail, so close() owns it from then on. Registering it at the end
  -- instead would leak a window on any error in between -- and one of the exits
  -- below is a deliberate bail, not an error.
  local function build()
    local fw = vim.api.nvim_open_win(buf, false, {
      relative = "win",
      win = win,
      row = vim.fn.winline() - 1, -- row 0 is the first *text* row, below any winbar
      col = wi.textoff,
      width = math.max(1, textw),
      height = 1,
      style = "minimal",
      focusable = false,
      zindex = 45,
      noautocmd = true,
    })
    active = { float = fw, buf = buf }
    configure_float(fw, win)
    -- Park the float's view on the peeked line. winrestview rather than `zt`:
    -- zt is bent by 'scrolloff' near the start of the buffer.
    vim.api.nvim_win_call(fw, function()
      vim.fn.winrestview({ topline = lnum, lnum = lnum, col = 0, leftcol = 0, skipcol = 0 })
    end)

    -- Measure, do not compute: 'breakindent' gives continuation rows an indent
    -- that ceil(width / textw) knows nothing about. start_vcol excludes any
    -- virt_lines sitting above the row (diagnostics, codelens).
    local h = vim.api.nvim_win_text_height(fw, {
      start_row = lnum - 1,
      start_vcol = 0,
      end_row = lnum - 1,
    })
    local geo = M.geometry({ wrapped_height = h.all, rows_available = rows_available })
    if not M.reveals_more(geo) then
      return false
    end
    vim.api.nvim_win_set_config(fw, {
      relative = "win",
      win = win,
      row = vim.fn.winline() - 1,
      col = wi.textoff,
      width = math.max(1, textw),
      height = geo.height,
    })

    -- The spacer is a *buffer* extmark, so by default it renders in every window
    -- showing this buffer: a split on the same file would get the blank rows
    -- without the float that justifies them -- a hole punched in someone else's
    -- view. nvim__ns_set scopes the namespace to the peeking window. It is an
    -- experimental double-underscore API, so treat its absence as normal: with
    -- the buffer on screen only once the spacer is safe unscoped, and with it on
    -- screen twice we drop the spacer and let the float cover the lines below.
    -- Worse than unfolding, strictly better than corrupting the other window.
    if geo.spacer > 0 then
      local scoped = pcall(vim.api.nvim__ns_set, ns, { wins = { win } })
      if scoped or not shared then
        vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
          virt_lines = M.spacer_lines(geo.spacer),
        })
      end
    end
    -- Recorded so the SafeState validator can tell whether the screen still
    -- matches what this peek was drawn against.
    active.win, active.lnum, active.winline = win, lnum, vim.fn.winline()
    return true
  end

  opening = true
  local ok, keep = pcall(build)
  opening = false
  if not ok or not keep then
    close()
  end
end

M._open = open

local timer = nil

-- Bumped on every rearm and on exit. timer:stop() cannot recall a callback that
-- vim.schedule_wrap has ALREADY queued: if the dwell expires in the same loop
-- iteration as the keypress that ends it, the stale body still runs and pops a
-- peek the instant you press a key -- exactly the malfunction this design set
-- out to avoid. The token makes the queued body check whether it is still the
-- current one.
local generation = 0

-- Fold any open peek and restart the clock. Every event that could change what
-- is on screen routes here, so the peek never outlives the state it described.
local function rearm()
  if opening then
    return
  end
  close()
  generation = generation + 1
  if not timer then
    return
  end
  local mine = generation
  timer:stop()
  timer:start(
    M.DELAY_MS,
    0,
    vim.schedule_wrap(function()
      if mine ~= generation then
        return
      end
      if M.eligible(current_ctx()) then
        open()
      end
    end)
  )
end

-- Has the screen moved out from under an open peek? The float's row and the
-- spacer are both computed once, at open time, and several ordinary commands
-- change what they were computed against without touching the cursor: zc/zM
-- collapsing a fold above the line, a window closed with <C-w>o taking the
-- float with it, `:set wrap`. None of those fire anything in the rearm list.
--
-- SafeState runs when Neovim is about to wait for input -- after every completed
-- command -- and this only ever *validates*, never rearms, so the dwell is
-- untouched. The nil check keeps the common case (no peek on screen) to one
-- comparison.
local function drifted()
  local a = active
  if not vim.api.nvim_win_is_valid(a.float) then
    return true
  end
  if not vim.api.nvim_win_is_valid(a.win) or vim.api.nvim_get_current_win() ~= a.win then
    return true
  end
  return vim.api.nvim_win_get_cursor(a.win)[1] ~= a.lnum
    or vim.fn.winline() ~= a.winline
    or vim.fn.foldclosed(a.lnum) ~= -1
    or vim.wo[a.win].wrap
    or vim.fn.winsaveview().leftcol ~= 0
end

M._rearm = rearm

function M.setup()
  -- Idempotent: a second call would stack a second timer and a second copy of
  -- every handler. The guard is the AUGROUP, not a field on `M` -- a reload
  -- (`package.loaded[...] = nil; require(...)`, which is what :Lazy reload and a
  -- re-requiring spec do) hands out a fresh module table whose `_did_setup` is
  -- nil while the previous instance's timer is still armed. That old timer would
  -- later open a peek onto the old instance's `active`, which no live handler can
  -- reach -- an uncloseable float for the rest of the session.
  if pcall(vim.api.nvim_get_autocmds, { group = "long_line_peek" }) then
    M._did_setup = true
    return
  end
  M._did_setup = true
  local group = vim.api.nvim_create_augroup("long_line_peek", { clear = true })

  ensure_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = ensure_highlights })

  timer = vim.uv.new_timer()

  vim.api.nvim_create_autocmd({
    "CursorMoved",
    "CursorMovedI",
    "WinScrolled",
    "WinResized",
    "ModeChanged",
    "TextChanged",
    "TextChangedI",
    "InsertEnter",
    "BufEnter",
    "WinEnter",
    "BufLeave",
    "WinLeave",
  }, { group = group, callback = rearm })

  -- Fold an open peek the moment the screen stops matching it. Validate only --
  -- never rearm -- so sitting still keeps counting toward the dwell.
  vim.api.nvim_create_autocmd("SafeState", {
    group = group,
    callback = function()
      if active and drifted() then
        close()
      end
    end,
  })

  -- A wiped buffer takes its peek with it; the extmark is already gone.
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = group,
    callback = function(args)
      if active and active.buf == args.buf then
        local fw = active.float
        active = nil
        if vim.api.nvim_win_is_valid(fw) then
          pcall(vim.api.nvim_win_close, fw, true)
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      close()
      -- Retires any callback vim.schedule_wrap has already queued, which
      -- timer:close() on its own would not.
      generation = generation + 1
      if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
      end
      timer = nil
    end,
  })
end

return M
