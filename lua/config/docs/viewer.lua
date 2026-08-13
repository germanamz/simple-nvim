-- The two-pane documentation reader: an outline window beside a content window.
--
-- Nothing here knows a language. The adapter hands over argv that renders a
-- COMPLETE page (`go doc -all`, `pydoc <module>`, `man <page>`) and a pure
-- parser that turns those lines into an outline; this module owns the windows,
-- the history, the keymaps and the highlighting.
--
-- Why a whole page rather than a fragment
-- ---------------------------------------
-- The float this replaces rendered `go doc net/http` — an index of signatures
-- with no way to reach `type Client`'s actual documentation. Rendering the
-- whole package instead (60-70ms for net/http's 3006 lines) means every type,
-- method and constant is already in the buffer, so selecting one in the
-- outline is a SCROLL, not another subprocess. It also makes `/` search the
-- entire package, which is the thing a float could never offer.
--
-- The invariants from config.docs still hold: no network on the keypress, and
-- nothing blocks — the page command runs async and the panes fill on callback.

local Overlay = require("util.overlay")
local palette = require("config.palette")

local M = {}

-- Wide enough for `  └ CloseIdleConnections` without truncating the common
-- case, narrow enough to leave the content pane a readable measure.
local OUTLINE_WIDTH = 30

-- `go doc` wraps its prose at 80 columns and pads it by 4, so a content pane
-- below ~85 rewraps nothing and simply hides the right edge of the text.
local CONTENT_WIDTH = 85

-- Below this the three columns cannot coexist: the docs pair alone wants
-- OUTLINE + CONTENT + 2 separators, and a code window narrower than 40 is not
-- worth keeping. Under it the session takes its own tab instead of squeezing.
local MIN_SPLIT_COLUMNS = OUTLINE_WIDTH + CONTENT_WIDTH + 2 + 40

local ns = vim.api.nvim_create_namespace("docs_viewer")

-- Declaration kind -> the highlight its NAME gets. The keyword before it is
-- always painted as a keyword, so only the identifier varies.
local KIND_HL = {
  section = "Title",
  type = "@type",
  class = "@type",
  func = "@function",
  method = "@function",
  const = "@constant",
  var = "@variable",
}

---@class DocsSession
---@field outline_win integer
---@field outline_buf integer
---@field content_win integer
---@field content_buf integer
---@field origin_win integer     -- where `gd` sends you back to
---@field adapter DocAdapter
---@field coord DocCoord
---@field ctx DocCtx
---@field entries DocEntry[]     -- the unfiltered outline
---@field rows integer[]         -- outline buffer line -> index into `entries`
---@field history table[]        -- {coord, cursor} back-stack
---@field future table[]         -- forward-stack, for <C-i>
---@field qualifiers table|nil   -- cached adapter.qualifiers answer for this page

---@type DocsSession|nil
local session = nil

-- The `?` panel. Declared beside the session rather than next to the code that
-- builds it so close() can tear it down too: it is a separate float, and a
-- session closing out from under it would otherwise leave it on screen.
local help = Overlay.new()

--- How to lay the panes out at a given terminal width.
---
--- Pure so the narrow-terminal decision can be tested without a UI. Returning
--- a mode rather than reflowing is deliberate: one rule the user can predict
--- beats a layout that rearranges itself as the window resizes.
---@param columns integer
---@return {mode: "split"|"tab", outline: integer, content: integer}
function M._layout(columns)
  if type(columns) ~= "number" or columns < MIN_SPLIT_COLUMNS then
    -- In its own tab the pair owns the width, so the content pane takes
    -- whatever the outline does not.
    local width = math.max(20, (columns or 80) - OUTLINE_WIDTH - 1)
    return { mode = "tab", outline = OUTLINE_WIDTH, content = width }
  end
  return { mode = "split", outline = OUTLINE_WIDTH, content = CONTENT_WIDTH }
end

--- Depth of `entries[i]` by walking its parent chain.
---
--- Guarded against a cycle rather than trusting the parser: an adapter that
--- pointed an entry at itself would otherwise hang the render, and a bad
--- outline must degrade to a flat list, not to a frozen editor.
---@param entries DocEntry[]
---@param i integer
---@return integer
function M._depth(entries, i)
  local depth, guard = 0, 0
  local at = entries[i] and entries[i].parent
  while at and guard < 32 do
    depth = depth + 1
    guard = guard + 1
    at = entries[at] and entries[at].parent
  end
  return depth
end

--- The entry declared on `lnum`, when `word` is the name it declares.
---
--- Disambiguates the case _find_entry cannot: `Do` is a method on several
--- types in net/http, and a bare label match returns whichever came first. If
--- the cursor is sitting on the declaration line itself, that line IS the
--- answer. Gated on the word matching the label so that a cursor elsewhere on
--- the same line — on `*Request` in `func (c *Client) Do(req *Request)` —
--- still resolves to what it is actually pointing at.
---@param entries DocEntry[]
---@param lnum integer
---@param word string
---@return integer|nil
function M._entry_at(entries, lnum, word)
  if type(entries) ~= "table" then
    return nil
  end
  for i, e in ipairs(entries) do
    if e.lnum == lnum and e.label == word then
      return i
    end
  end
  return nil
end

--- The entry `word` names, or nil.
---
--- Tier one of following a name: everything already on this page resolves here,
--- for free, with no process and no network. `symbol` is tried before `label`
--- so an unambiguous `Client.Do` wins, and a type or func outranks a method on
--- a bare name — `Get` in net/http means the package function, not
--- `Client.Get`, which you would have written as `Client.Get` to ask for.
---@param entries DocEntry[]
---@param word string
---@return integer|nil
function M._find_entry(entries, word)
  if type(entries) ~= "table" or type(word) ~= "string" or word == "" then
    return nil
  end
  local by_label = nil
  for i, e in ipairs(entries) do
    if e.symbol == word then
      return i
    end
    if e.label == word and e.kind ~= "section" then
      if e.kind ~= "method" then
        return i
      end
      by_label = by_label or i
    end
  end
  return by_label
end

--- Render `entries` into outline buffer lines.
---
--- Returns the text and the line -> entry map together, because the two must
--- agree exactly and a filtered outline makes them diverge otherwise.
---@param entries DocEntry[]
---@param subset integer[]|nil  -- indices to show; nil means all, as a tree
---@return string[] lines, integer[] rows
function M._render_outline(entries, subset)
  local lines, rows = {}, {}
  if subset then
    -- A filtered outline is flat and fully qualified: the matches no longer
    -- sit under their parents, so `Do` alone would not say whose.
    for _, i in ipairs(subset) do
      local e = entries[i]
      if e then
        lines[#lines + 1] = "  " .. (e.symbol or e.label or "?")
        rows[#rows + 1] = i
      end
    end
    return lines, rows
  end
  for i, e in ipairs(entries) do
    local depth = M._depth(entries, i)
    lines[#lines + 1] = string.rep("  ", depth) .. (e.label or "?")
    rows[#rows + 1] = i
  end
  return lines, rows
end

--- Is the session usable from where the cursor is right now?
---
--- Windows in another tabpage do not count. Reusing them would yank the user
--- to a different tab on a keypress that only asked to read some docs.
---@return boolean
local function session_live()
  if not session then
    return false
  end
  if
    not vim.api.nvim_win_is_valid(session.content_win)
    or not vim.api.nvim_win_is_valid(session.outline_win)
  then
    return false
  end
  local tab = vim.api.nvim_get_current_tabpage()
  return vim.api.nvim_win_get_tabpage(session.content_win) == tab
end

--- Drop the session's windows and forget it.
function M.close()
  help.origin = nil
  help:close()
  if not session then
    return
  end
  local wins = { session.outline_win, session.content_win }
  local origin = session.origin_win
  session = nil
  for _, w in ipairs(wins) do
    if vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  if origin and vim.api.nvim_win_is_valid(origin) then
    pcall(vim.api.nvim_set_current_win, origin)
  end
end

--- Give a scratch buffer the options both panes share.
---@param buf integer
---@param name string
local function prepare_buf(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  -- A stale buffer under this name survives a session close, and
  -- nvim_buf_set_name errors rather than stealing it.
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 and existing ~= buf and vim.api.nvim_buf_is_valid(existing) then
    pcall(vim.api.nvim_buf_delete, existing, { force = true })
  end
  pcall(vim.api.nvim_buf_set_name, buf, name)
end

--- Create the pane pair, leaving the cursor in the outline.
---@return DocsSession
local function create_session()
  local layout = M._layout(vim.o.columns)
  local origin = vim.api.nvim_get_current_win()

  if layout.mode == "tab" then
    vim.cmd("tabnew")
  else
    -- One split for the pair, then divide it, so the code window loses exactly
    -- the pair's width once instead of being resized twice.
    vim.cmd("botright vertical " .. (layout.outline + layout.content + 1) .. "vsplit")
  end
  local content_win = vim.api.nvim_get_current_win()
  local content_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(content_win, content_buf)

  vim.cmd("leftabove vertical " .. layout.outline .. "vsplit")
  local outline_win = vim.api.nvim_get_current_win()
  local outline_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(outline_win, outline_buf)

  prepare_buf(content_buf, "godoc://content")
  prepare_buf(outline_buf, "godoc://outline")

  vim.wo[outline_win].winfixwidth = true
  vim.wo[outline_win].number = false
  vim.wo[outline_win].relativenumber = false
  vim.wo[outline_win].signcolumn = "no"
  vim.wo[outline_win].cursorline = true
  vim.wo[outline_win].wrap = false
  vim.wo[content_win].wrap = true
  vim.wo[content_win].linebreak = true
  vim.wo[content_win].number = false
  vim.wo[content_win].relativenumber = false
  vim.wo[content_win].signcolumn = "no"

  return {
    outline_win = outline_win,
    outline_buf = outline_buf,
    content_win = content_win,
    content_buf = content_buf,
    origin_win = origin,
    entries = {},
    rows = {},
    history = {},
    future = {},
  }
end

--- Scroll the content pane so `lnum` sits at the top of the window.
---
--- `zt` rather than `zz`: a declaration reads downward, so putting it at the
--- top shows its documentation instead of centring it with half the body
--- scrolled off.
---@param lnum integer
local function reveal(lnum)
  if not session or not vim.api.nvim_win_is_valid(session.content_win) then
    return
  end
  local last = vim.api.nvim_buf_line_count(session.content_buf)
  lnum = math.max(1, math.min(lnum or 1, last))
  vim.api.nvim_win_set_cursor(session.content_win, { lnum, 0 })
  vim.api.nvim_win_call(session.content_win, function()
    vim.cmd("normal! zt")
  end)
end

--- Move the content pane to the outline row the cursor is on.
---
--- Exposed because a CursorMoved autocmd never fires in a headless script — the
--- input queue is not drained there — so the e2e specs drive this directly.
function M.follow()
  if not session or not vim.api.nvim_win_is_valid(session.outline_win) then
    return
  end
  local row = vim.api.nvim_win_get_cursor(session.outline_win)[1]
  local idx = session.rows[row]
  local entry = idx and session.entries[idx]
  if entry then
    reveal(entry.lnum)
  end
end

--- Paint declaration lines from the outline we already parsed.
---
--- Free structure: the parser has told us which lines are declarations and of
--- what kind, so no second pass and no treesitter over text that is not valid
--- source. Persistent extmarks, not ephemeral ones — ephemeral marks are
--- accepted without error and then never drawn outside a decoration provider.
---@param buf integer
---@param lines string[]
---@param entries DocEntry[]
local function highlight(buf, lines, entries)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, e in ipairs(entries) do
    local line = lines[e.lnum]
    if line then
      local hl = KIND_HL[e.kind] or "@variable"
      if e.kind == "section" then
        vim.api.nvim_buf_set_extmark(buf, ns, e.lnum - 1, 0, {
          end_col = #line,
          hl_group = hl,
        })
      else
        local kw = line:match("^(%l+)%s")
        if kw then
          vim.api.nvim_buf_set_extmark(buf, ns, e.lnum - 1, 0, {
            end_col = #kw,
            hl_group = "@keyword",
          })
        end
        -- Anchored past the keyword so `func Get` highlights the name and not
        -- an earlier accidental substring.
        local label = e.label and e.label:match("^[%w_]+")
        if label then
          local s, fin = line:find(label, kw and (#kw + 1) or 1, true)
          if s then
            vim.api.nvim_buf_set_extmark(buf, ns, e.lnum - 1, s - 1, {
              end_col = fin,
              hl_group = hl,
            })
          end
        end
      end
    end
  end
end

--- Put `subset` (nil for the whole tree) into the outline pane.
---@param s DocsSession
---@param subset integer[]|nil
local function set_outline(s, subset)
  local text, rows = M._render_outline(s.entries, subset)
  s.rows = rows
  vim.bo[s.outline_buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.outline_buf, 0, -1, false, text)
  vim.bo[s.outline_buf].modifiable = false
end

--- Move the outline cursor to the row showing `idx`, if it is showing.
---@param s DocsSession
---@param idx integer
local function select_row(s, idx)
  for row, at in ipairs(s.rows) do
    if at == idx then
      pcall(vim.api.nvim_win_set_cursor, s.outline_win, { row, 0 })
      return
    end
  end
end

--- Put a rendered page into the panes.
---@param lines string[]
---@param title string
---@param focus_symbol string|nil
local function fill(lines, title, focus_symbol)
  local s = session
  vim.bo[s.content_buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.content_buf, 0, -1, false, lines)
  vim.bo[s.content_buf].modifiable = false

  -- A parser that throws must cost the outline, not the page: the content is
  -- already readable and searchable without it.
  local ok, entries = pcall(s.adapter.outline, lines)
  s.entries = (ok and type(entries) == "table") and entries or {}
  highlight(s.content_buf, lines, s.entries)
  set_outline(s, nil)

  vim.wo[s.outline_win].winbar = title
  vim.wo[s.content_win].winbar = title

  -- Park on the symbol the caller asked about, else the top of the page.
  local target = focus_symbol and M._find_entry(s.entries, focus_symbol) or nil
  if target then
    select_row(s, target)
    reveal(s.entries[target].lnum)
  else
    reveal(1)
  end
end

--- Narrow the outline to entries fuzzy-matching `query`.
---
--- `matchfuzzy` over the fully-qualified symbols, so `clientdo` finds
--- `Client.Do`. An empty query restores the tree, which is what `<Esc>` calls
--- — handled here rather than at the prompt so clearing the filter works from
--- the mapping too, not only by answering the prompt with nothing.
---
--- Split from the prompt so specs can exercise it without vim.ui.input, which
--- cannot be answered from a headless script.
---@param query string|nil
function M.apply_filter(query)
  local s = session
  if not s then
    return
  end
  if not query or query == "" then
    return set_outline(s, nil)
  end

  local names, index = {}, {}
  for i, e in ipairs(s.entries) do
    if e.kind ~= "section" then
      names[#names + 1] = e.symbol or e.label or ""
      index[#index + 1] = i
    end
  end
  local ok, matched = pcall(vim.fn.matchfuzzy, names, query)
  if not ok then
    return
  end

  local want = {}
  for _, name in ipairs(matched) do
    for j, candidate in ipairs(names) do
      if candidate == name then
        want[#want + 1] = index[j]
        names[j] = "\0" -- consumed, so duplicates map to distinct entries
        break
      end
    end
  end

  set_outline(s, want)
  if #s.rows > 0 then
    pcall(vim.api.nvim_win_set_cursor, s.outline_win, { 1, 0 })
    M.follow()
  end
end

--- Prompt for a filter.
local function filter()
  local s = session
  vim.ui.input({ prompt = "Filter symbols: " }, function(query)
    -- The session can be closed, or replaced by a different page, while the
    -- prompt is open.
    if s and s == session then
      M.apply_filter(query)
    end
  end)
end

--- Follow the name under the cursor in the content pane.
---
--- Three tiers, cheapest first, and the first two cover nearly everything:
--- a name on this page scrolls, a qualified name into another package renders,
--- and anything else says so rather than guessing a destination.
function M.follow_name()
  local s = session
  if not s then
    return
  end
  local word = require("config.docs")._dotted_word()
  if word == "" then
    return
  end
  -- Captured now, not inside try(): the qualifiers lookup is async and the
  -- current window may not still be the content pane when it answers.
  local line = vim.api.nvim_get_current_line()

  local idx = M._find_entry(s.entries, word)
  if idx then
    -- Same page: scroll, and move the outline cursor to match so the two panes
    -- never disagree about where you are.
    select_row(s, idx)
    return reveal(s.entries[idx].lnum)
  end

  if not s.adapter.xref then
    return
  end

  local function try(quals)
    -- `line` is overridden with the content pane's current line, not the
    -- source buffer's: adapters that read syntax around the cursor are being
    -- asked about the DOCS text here. It is what lets the C adapter tell a
    -- `printf(3)` cross-reference from the word printf in a sentence.
    local ctx = vim.tbl_extend("force", s.ctx or {}, {
      qualifiers = quals,
      word = word,
      line = line,
    })
    local ok, coord = pcall(s.adapter.xref, word, s.coord, ctx)
    if not ok or not coord then
      return vim.notify("docs: nothing to follow at " .. word, vim.log.levels.INFO)
    end
    M.open(s.adapter, coord, s.ctx, { push = true })
  end

  -- Qualifiers are fetched lazily and cached: a page you only read never pays
  -- for them, and the first <CR> on a qualified name pays once.
  if s.qualifiers or not s.adapter.qualifiers then
    return try(s.qualifiers)
  end
  s.adapter.qualifiers(s.coord, s.ctx, function(map)
    if session ~= s then
      return
    end
    s.qualifiers = map or {}
    try(s.qualifiers)
  end)
end

--- Open the real source for the symbol under the cursor.
---
--- Lands in the window the session was opened from, so the docs panes stay put
--- and the file appears where you were already editing.
function M.goto_source()
  local s = session
  if not s then
    return
  end
  if not s.adapter.locate then
    return vim.notify("docs: no source mapping for this page", vim.log.levels.INFO)
  end

  local word = require("config.docs")._dotted_word()
  local lnum = vim.api.nvim_win_get_cursor(s.content_win)[1]
  local idx = M._entry_at(s.entries, lnum, word) or M._find_entry(s.entries, word)
  local symbol = idx and s.entries[idx].symbol or (word ~= "" and word or nil)
  if not symbol then
    return
  end

  local coord = vim.tbl_extend("force", s.coord or {}, { symbol = symbol })
  s.adapter.locate(coord, s.ctx, function(loc)
    -- A failed lookup leaves the reader exactly as it was: you are still
    -- reading, and closing the panes would punish a keypress that did nothing.
    if not loc then
      return vim.notify("docs: no source found for " .. symbol, vim.log.levels.INFO)
    end

    -- `gd` means "take me to the implementation". Once the source is open,
    -- gopls is attached and its own gd/gr/K take over, so the reader has done
    -- its job — and leaving it up strands two windows that only `q` from
    -- *inside* them can close.
    --
    -- Closing before opening the file also removes the "which window do I put
    -- this in" problem: close() restores focus to wherever the lookup started,
    -- and once the panes are gone the current window is necessarily a real one.
    M.close()
    vim.cmd.edit(vim.fn.fnameescape(loc.file))
    -- Clamped because a whole-module location is legitimately line 0:
    -- inspect.getsourcelines() reports 0 for a module object, and cursor rows
    -- are 1-based.
    pcall(vim.api.nvim_win_set_cursor, 0, { math.max(1, loc.lnum or 1), 0 })
    vim.cmd("normal! zz")
  end)
end

--- Step through the history stack. `delta` is -1 for back, 1 for forward.
---@param delta integer
function M.history(delta)
  local s = session
  if not s then
    return
  end
  local from, to = s.history, s.future
  if delta > 0 then
    from, to = s.future, s.history
  end
  local entry = table.remove(from)
  if not entry then
    return vim.notify("docs: no further history", vim.log.levels.INFO)
  end
  to[#to + 1] = { coord = s.coord, cursor = vim.api.nvim_win_get_cursor(s.content_win) }
  M.open(s.adapter, entry.coord, s.ctx, { restore = entry.cursor })
end

-- ===========================================================================
-- Keymaps, as data
-- ===========================================================================
--
-- One table binds the keys AND renders the `?` panel. A help list maintained
-- separately from the mappings is a help list that goes stale on the first key
-- anyone adds, so there is deliberately no second copy to fall out of step —
-- and a unit test asserts every bound key is documented here.
--
-- An entry with no `fn` is documentation only: `j`/`k` and `/` are Neovim's own
-- keys doing their own thing, which is half the point of using real buffers
-- rather than a float, and a reader deserves to be told they work.
--
-- `lhs` overrides `keys` when the display form is not a literal mapping —
-- `<C-o> / <C-t>` reads as one row but binds two.

---@class DocsKey
---@field keys string           -- as shown in the panel
---@field help string           -- one line, lowercase, no trailing period
---@field lhs string[]|nil      -- what to actually map, when it differs
---@field fn function|nil       -- absent for keys Neovim already provides

---@type {pane: "outline"|"content"|"both", title: string, keys: DocsKey[]}[]
M.KEYS = {
  {
    pane = "outline",
    title = "Outline pane",
    keys = {
      { keys = "j / k", help = "move — the content pane follows" },
      {
        keys = "<CR>",
        help = "show it, then focus the content pane",
        fn = function()
          M.follow()
          local s = session
          if s and vim.api.nvim_win_is_valid(s.content_win) then
            vim.api.nvim_set_current_win(s.content_win)
          end
        end,
      },
      { keys = "f", help = "filter symbols (clientdo → Client.Do)", fn = filter },
      {
        keys = "<Esc>",
        help = "clear the filter",
        fn = function()
          M.apply_filter("")
        end,
      },
    },
  },
  {
    pane = "content",
    title = "Content pane",
    keys = {
      { keys = "/ n N", help = "search — the whole package is in this buffer" },
      { keys = "<C-d> / <C-u>", help = "scroll by half a screen" },
      { keys = "<CR>", help = "follow the name under the cursor", fn = M.follow_name },
      { keys = "gd", help = "go to the real source, closing the reader", fn = M.goto_source },
      {
        keys = "<C-o> / <C-t>",
        lhs = { "<C-o>", "<C-t>" },
        help = "back",
        fn = function()
          M.history(-1)
        end,
      },
      {
        keys = "<C-i>",
        help = "forward",
        fn = function()
          M.history(1)
        end,
      },
      {
        keys = "o",
        help = "open the hosted page in the browser pane",
        fn = function()
          local s = session
          if not s then
            return
          end
          local ok, url = pcall(s.adapter.url or function() end, s.coord, s.ctx)
          if ok and url then
            require("config.open_url").open(url)
          else
            vim.notify("docs: no web page for this entry", vim.log.levels.INFO)
          end
        end,
      },
    },
  },
  {
    pane = "both",
    title = "Either pane",
    keys = {
      {
        keys = "?",
        help = "this panel",
        fn = function()
          M.toggle_help()
        end,
      },
      { keys = "q", help = "close the reader", fn = M.close },
    },
  },
}

--- The buffers a key group applies to.
---@param s DocsSession
---@param pane "outline"|"content"|"both"
---@return integer[]
local function bufs_for(s, pane)
  if pane == "outline" then
    return { s.outline_buf }
  end
  if pane == "content" then
    return { s.content_buf }
  end
  return { s.outline_buf, s.content_buf }
end

-- Column the help text starts at. Wide enough for the longest key spelling
-- (`<C-d> / <C-u>`) with a gutter, so every description lines up.
local HELP_KEY_WIDTH = 15

--- Render the panel's lines, plus the highlight ranges for each.
---
--- Pure, so the layout can be asserted without opening a window. `current` is
--- the pane the cursor is in; its section gets the marker, which is the only
--- thing distinguishing "keys you can press right now" from "keys the other
--- pane has".
---@param current "outline"|"content"|nil
---@return string[] lines, table[] ranges_by_line
function M._help_lines(current)
  local lines, ranges = {}, {}

  local function push(text, spans)
    lines[#lines + 1] = text
    ranges[#ranges + 1] = spans or {}
  end

  for i, group in ipairs(M.KEYS) do
    if i > 1 then
      push("")
    end
    local marker = (group.pane == current) and "▸ " or "  "
    local title = marker .. group.title
    push(title, { { 0, #title, group.pane == current and "DocsHelpActive" or "DocsHelpTitle" } })
    for _, key in ipairs(group.keys) do
      local pad = string.rep(" ", math.max(1, HELP_KEY_WIDTH - vim.api.nvim_strwidth(key.keys)))
      local text = "    " .. key.keys .. pad .. key.help
      local key_end = 4 + #key.keys
      push(text, {
        { 4, key_end, "DocsHelpKey" },
        { key_end, #text, "DocsHelpText" },
      })
    end
  end
  return lines, ranges
end

--- Close the help panel and go back to the pane it was opened from.
local function close_help()
  local back = help.origin
  help.origin = nil
  help:close()
  if back and vim.api.nvim_win_is_valid(back) then
    pcall(vim.api.nvim_set_current_win, back)
  end
end

--- Show the key panel, or dismiss it if it is already up.
---
--- Entered rather than left floating beside the cursor: a panel you can not
--- focus needs its dismissal keys bound in whatever buffer you happened to be
--- in, and `?` pressed twice then has to mean two different things depending on
--- which pane you were in. Entering it makes `?`, `q` and `<Esc>` mean exactly
--- one thing.
function M.toggle_help()
  if help.win and vim.api.nvim_win_is_valid(help.win) then
    return close_help()
  end
  local s = session
  if not s then
    return
  end

  local win = vim.api.nvim_get_current_win()
  local current = (win == s.outline_win and "outline")
    or (win == s.content_win and "content")
    or nil

  vim.api.nvim_set_hl(0, "DocsHelpTitle", { fg = palette.muted, bold = true, default = true })
  vim.api.nvim_set_hl(0, "DocsHelpActive", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "DocsHelpKey", { link = "Special", default = true })
  vim.api.nvim_set_hl(0, "DocsHelpText", { fg = palette.muted, default = true })

  local lines, ranges = M._help_lines(current)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for row, spans in ipairs(ranges) do
    for _, span in ipairs(spans) do
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, span[1], {
        end_col = span[2],
        hl_group = span[3],
      })
    end
  end
  vim.bo[buf].modifiable = false

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.api.nvim_strwidth(line))
  end
  width = width + 2

  -- Centred on the editor rather than on a pane. A `relative = "win"` float
  -- measures from the first TEXT row, below the winbar these panes carry, so
  -- the arithmetic would be quietly off by one; the editor has no such trap.
  help.origin = win
  help:mount(buf, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - #lines) / 2) - 2),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = #lines,
    style = "minimal",
    border = "rounded",
    title = " Docs reader ",
    title_pos = "center",
    zindex = 250,
  })

  if not (help.win and vim.api.nvim_win_is_valid(help.win)) then
    return
  end
  vim.api.nvim_set_current_win(help.win)
  vim.wo[help.win].cursorline = false
  for _, lhs in ipairs({ "?", "q", "<Esc>", "<CR>" }) do
    vim.keymap.set("n", lhs, close_help, { buffer = buf, nowait = true, desc = "Docs: close help" })
  end
  -- Leaving the panel by any other route (a window jump, the session closing)
  -- must not strand it on screen.
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        if help.win and vim.api.nvim_win_is_valid(help.win) then
          help.origin = nil
          help:close()
        end
      end)
    end,
  })
end

--- Bind the pane keymaps. Buffer-local, so nothing leaks into your own maps.
---@param s DocsSession
local function attach_keys(s)
  local function nmap(buf, lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, desc = desc })
  end

  for _, group in ipairs(M.KEYS) do
    for _, key in ipairs(group.keys) do
      if key.fn then
        for _, buf in ipairs(bufs_for(s, group.pane)) do
          for _, lhs in ipairs(key.lhs or { key.keys }) do
            nmap(buf, lhs, key.fn, "Docs: " .. key.help)
          end
        end
      end
    end
  end

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = s.outline_buf,
    callback = M.follow,
    desc = "Docs: content follows the outline cursor",
  })
  -- If either pane is closed by hand, the session is over; leaving half a
  -- layout behind would make the next lookup reuse a window that no longer has
  -- a partner.
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = { tostring(s.outline_win), tostring(s.content_win) },
    once = true,
    callback = function()
      vim.schedule(M.close)
    end,
  })
end

--- Render `coord` in the viewer.
---
--- `on_fail` is what the driver wants to do when the page command produces
--- nothing — normally "open the hosted page instead" — so this module never has
--- to know about URLs or the browser.
---@param adapter DocAdapter
---@param coord DocCoord
---@param ctx DocCtx
---@param opts {push: boolean|nil, restore: integer[]|nil, on_fail: fun()|nil}|nil
function M.open(adapter, coord, ctx, opts)
  opts = opts or {}
  local ok, page = pcall(adapter.page, coord, ctx)
  if not ok or not page or type(page.cmd) ~= "table" then
    return opts.on_fail and opts.on_fail()
  end

  vim.system(page.cmd, { text = true, timeout = 5000 }, function(res)
    vim.schedule(function()
      if res.code ~= 0 or not res.stdout or res.stdout == "" then
        return opts.on_fail and opts.on_fail()
      end

      local fresh = not session_live()
      if fresh then
        if session then
          M.close()
        end
        session = create_session()
      end
      local s = session
      if opts.push and s.coord then
        s.history[#s.history + 1] = {
          coord = s.coord,
          cursor = vim.api.nvim_win_get_cursor(s.content_win),
        }
        s.future = {}
      end
      s.adapter, s.coord, s.ctx = adapter, coord, ctx
      s.qualifiers = nil

      local lines = vim.split(res.stdout, "\n", { trimempty = false })
      fill(lines, page.title or "docs", coord.symbol)
      if opts.restore then
        reveal(opts.restore[1])
      end
      if fresh then
        attach_keys(s)
      end
      if vim.api.nvim_win_is_valid(s.outline_win) then
        vim.api.nvim_set_current_win(s.outline_win)
      end
    end)
  end)
end

--- Test seam: the live session, or nil.
---@return DocsSession|nil
function M._session()
  return session
end

return M
