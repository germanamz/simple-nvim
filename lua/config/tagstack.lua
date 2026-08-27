-- The definition stack: `<C-t>` as a trustworthy one-press way back from `gd`,
-- and the only place in this config that writes Neovim's tagstack.
--
-- Why this exists
-- ---------------
-- Neovim keeps two per-window back-histories, and `<C-o>` is the wrong one for
-- "take me back to where I typed gd". The jumplist records every far motion --
-- every `/`, `}`, `G` made while reading a definition -- so walking out with
-- `<C-o>` replays all of it. The tagstack is a true LIFO of tag jumps only:
-- `<C-t>` pops one whole hop, `3<C-t>` unwinds three.
--
-- Core already pushes a frame for `gd`, but only in the single-result branch and
-- only when `on_list` is absent (buf.lua:263 and :253-260 in nvim 0.12.5), and
-- `vim.lsp.buf.references` (buf.lua:868) is a separate implementation that never
-- pushes at all. Supplying our own `on_list` makes core skip its push entirely,
-- so this module owns the push for every semantic-navigation verb and there is
-- exactly one writer.
--
-- See docs/navigation-stack.md for the design and the editor survey behind it:
-- every editor that collected "Back is too noisy" complaints answered with a
-- second, coarser history rather than a smarter Back.

local M = {}

-- kind_by_key[key] = "gd" | "grr" | ... -- what pushed a frame, for the picker's
-- kind column. Best-effort by construction: only frames pushed through here are
-- known, so a frame pushed by core or a plugin renders blank rather than guessed.
-- Keyed on frame content because settagstack hands back no identity of its own.
local kind_by_key = {}

-- Deliberately NOT keyed on the window. `:split` copies a window's tagstack, so a
-- winid-keyed lookup would miss every inherited frame in the new window and
-- render it blank -- which this file gives the specific meaning "pushed by
-- something other than us". Two frames pushed from the same position and symbol
-- by different verbs collide onto the later one; that is a cosmetic column, so
-- the simpler key wins.
local function frame_key(bufnr, lnum, col, tagname)
  return table.concat({ bufnr, lnum, col, tagname or "" }, ":")
end

--- Snapshot the current position as a push origin.
---
--- MUST be called synchronously at keypress time, never from inside a response
--- callback. `vim.lsp.util.show_document` gets exactly this wrong: it evaluates
--- `bufnr('%')`, `line('.')` and `win_getid()` when the reply lands (util.lua:
--- 1035-1041), where core's own path captures them before the request
--- (buf.lua:227-229). Move the cursor while the server is thinking and the frame
--- points at wherever you drifted to -- and because `win_getid()` is called with
--- no argument, it can be written into a different window than you jumped from.
---@return table origin
function M.capture()
  local pos = vim.api.nvim_win_get_cursor(0)
  return {
    winid = vim.api.nvim_get_current_win(),
    bufnr = vim.api.nvim_get_current_buf(),
    lnum = pos[1],
    -- nvim_win_get_cursor is 0-based on the column; a tagstack `from` wants the
    -- 1-based `col('.')` convention.
    col = pos[2] + 1,
    tagname = vim.fn.expand("<cword>"),
  }
end

--- Record `origin` as a tagstack frame on its own window. The only settagstack
--- write in this config.
---
--- Action "t" mirrors core: truncate at curidx, then push. That discards any
--- frames you had popped past, which is correct stack semantics -- taking a new
--- hop from halfway down the stack invalidates what was above it.
---@param origin table|nil
---@param kind string|nil
---@return boolean pushed
function M.push(origin, kind)
  if not origin or not origin.winid or not vim.api.nvim_win_is_valid(origin.winid) then
    return false
  end
  local from = { origin.bufnr, origin.lnum, origin.col, 0 }
  local item = { tagname = origin.tagname ~= "" and origin.tagname or "?", from = from }
  vim.fn.settagstack(origin.winid, { items = { item } }, "t")
  kind_by_key[frame_key(origin.bufnr, origin.lnum, origin.col, item.tagname)] = kind
  return true
end

--- Navigate `origin.winid` to `item` and, only if that worked, record the frame.
---
--- Push-on-success, not push-on-intent. Helix shipped the opposite and had to fix
--- it (helix#2663): `push_jump` before the navigation left a stale entry behind
--- whenever the jump was cancelled.
---
--- `item` is a quickfix-shaped entry -- `{ filename, lnum, col }`, 1-based col --
--- which is what `vim.lsp.util.locations_to_items` produces, so callers get
--- offset-encoding conversion from core rather than reimplementing it.
---@param origin table|nil
---@param item table|nil
---@param kind string|nil
---@return boolean jumped
function M.jump(origin, item, kind)
  if not item then
    return false
  end
  local win = origin and origin.winid or nil
  if not win or not vim.api.nvim_win_is_valid(win) then
    -- The window `gd` was pressed in has since been closed. Land in the current
    -- one and re-aim the frame at it: pushing into a dead window id silently
    -- records nothing, which would leave `<C-t>` unarmed after a successful jump
    -- -- the one outcome this module exists to prevent.
    win = vim.api.nvim_get_current_win()
    origin = origin and vim.tbl_extend("force", {}, origin, { winid = win }) or nil
  end

  local bufnr = item.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    if not item.filename or item.filename == "" then
      return false
    end
    bufnr = vim.fn.bufadd(item.filename)
  end
  if not bufnr or bufnr == 0 then
    return false
  end

  -- The jumplist mark has to go in before the window moves (it records where the
  -- cursor IS), while the tagstack frame carries its position explicitly and so
  -- can wait until the move has actually succeeded. A bare `m'` with no
  -- subsequent move adds no jumplist entry, so setting it early is free.
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! m'")
  end)

  vim.bo[bufnr].buflisted = true
  local ok = pcall(vim.api.nvim_win_set_buf, win, bufnr)
  if not ok then
    return false
  end
  -- Clamp to the buffer as loaded rather than letting an out-of-range line fail
  -- silently: the buffer swap has already happened, so a discarded failure leaves
  -- the window in the right file at whatever line its mark happened to hold, and
  -- reports that as a successful jump.
  local target = math.max(1, item.lnum or 1)
  local last = vim.api.nvim_buf_line_count(bufnr)
  pcall(
    vim.api.nvim_win_set_cursor,
    win,
    { math.min(target, math.max(1, last)), math.max(0, (item.col or 1) - 1) }
  )
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zv") -- open folds over the destination
  end)
  if vim.api.nvim_get_current_win() ~= win then
    pcall(vim.api.nvim_set_current_win, win)
  end

  M.push(origin, kind)
  return true
end

--- The tagstack of `winid` as picker-ready rows, newest first.
---
--- Each row carries `stack_idx`, its 1-based index into the raw items list, which
--- is what `goto_frame` and `drop_frame` address frames by. `current` marks the
--- frame curidx points at; after a fresh push curidx is one past the end, so no
--- row is current and every row is behind you.
---@param winid integer|nil
---@return table[] rows, integer curidx, integer length
function M.frames(winid)
  winid = winid or vim.api.nvim_get_current_win()
  local st = vim.fn.gettagstack(winid)
  local items = st.items or {}
  local length = st.length or #items
  local curidx = st.curidx or (length + 1)

  local rows = {}
  for i = 1, length do
    local j = length - i + 1 -- newest first
    local it = items[j] or {}
    local from = it.from or {}
    local bufnr = from[1]
    local lnum = from[2] or 1
    local col = from[3] or 1
    rows[i] = {
      idx = i,
      stack_idx = j,
      tagname = it.tagname or "?",
      bufnr = bufnr,
      lnum = lnum,
      col = col,
      valid = bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
      filename = bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr)
        or nil,
      kind = kind_by_key[frame_key(bufnr, lnum, col, it.tagname)],
      current = j == curidx,
    }
  end
  return rows, curidx, length
end

--- `<C-t>`: pop `count` frames.
---
--- Thin over native `:{count}pop` so counts and 'jumpoptions' view restoration
--- behave exactly as Vim intends. The wrapper exists for the message: a bare
--- `<C-t>` on an empty stack raises `E73: Tag stack empty`, which reads like a
--- malfunction rather than "there is nothing to go back to".
---@param count integer|nil
---@return boolean popped
function M.pop(count)
  count = math.max(1, count or 1)
  local ok, err = pcall(vim.cmd, count .. "pop")
  if ok then
    return true
  end
  local msg = tostring(err)
  if msg:find("E73") then
    vim.notify("definition stack empty", vim.log.levels.INFO)
  elseif msg:find("E555") then
    vim.notify("at the bottom of the definition stack", vim.log.levels.INFO)
  else
    vim.notify(msg, vim.log.levels.WARN)
  end
  return false
end

--- Jump to the frame at `stack_idx`, in either direction.
---
--- `:tag` -- the natural "forward" counterpart to `:pop` -- cannot be used here.
--- A tagstack entry stores the tagname and where you came FROM, never where the
--- jump landed, so going forward means re-resolving the tagname through a tags
--- file; with no tags file that is `E433`, which is every LSP-pushed frame.
---
--- Setting curidx and popping once reaches any frame without needing one, and
--- collapses both directions into a single mechanism. Note the two calls:
--- settagstack forces curidx to one-past-the-length whenever `items` is present,
--- so a curidx-only write is the only way to position the stack.
---@param winid integer|nil
---@param stack_idx integer
---@return boolean jumped
function M.goto_frame(winid, stack_idx)
  winid = winid or vim.api.nvim_get_current_win()
  local st = vim.fn.gettagstack(winid)
  local length = st.length or 0
  if stack_idx < 1 or stack_idx > length then
    return false
  end
  vim.fn.settagstack(winid, { curidx = stack_idx + 1 }, "r")
  return M.pop(1)
end

--- Remove the frame at `stack_idx`, keeping the stack position meaningful.
---
--- Two writes on purpose. `settagstack` applies a supplied curidx BEFORE the
--- modification and then forces it to one-past-the-new-length, so passing
--- `{ items, curidx }` together silently discards the curidx -- verified: asking
--- for 2 after dropping one of three frames yields 3. The position has to be
--- restored by a second, curidx-only call.
---@param winid integer|nil
---@param stack_idx integer
---@return boolean dropped
function M.drop_frame(winid, stack_idx)
  winid = winid or vim.api.nvim_get_current_win()
  local st = vim.fn.gettagstack(winid)
  local items, length, curidx = st.items or {}, st.length or 0, st.curidx or 1
  if stack_idx < 1 or stack_idx > length then
    return false
  end

  local kept = {}
  for i, it in ipairs(items) do
    if i ~= stack_idx then
      kept[#kept + 1] = it
    end
  end
  -- Dropping a frame below the current position shifts everything above it down
  -- one; leaving curidx alone would move the marker (and every subsequent pop
  -- count) off by one. Dropping the frame you are STANDING at is different: there
  -- is no longer a frame to be at, and holding the index would put ● on whichever
  -- frame slid into that slot -- a position the user has never visited. Reset to
  -- one-past-the-end instead, the same "not positioned within the stack" state a
  -- fresh push leaves behind.
  local new_curidx = curidx == stack_idx and (#kept + 1)
    or (curidx > stack_idx and curidx - 1)
    or curidx
  new_curidx = math.max(1, math.min(new_curidx, #kept + 1))

  vim.fn.settagstack(winid, { items = kept }, "r")
  vim.fn.settagstack(winid, { curidx = new_curidx }, "r")
  return true
end

-- ===================== LSP verbs =====================

--- Multiple results: record one frame, then hand the list to quickfix.
---
--- The frame goes in HERE, once, rather than being deferred to the selection.
--- Deferring is the more principled reading of push-on-success and it was tried
--- first; intercepting the quickfix `<CR>` fails in both directions at once:
---
---   * it over-fires. The quickfix window stays open after a jump, so walking a
---     reference list -- the normal way to use one -- pushed an identical frame
---     per entry visited. At the tagstack's 20-frame cap, browsing 25 references
---     evicted every genuine `gd` hop, so `<C-t>` could no longer reach the call
---     site at any count. That is exactly the noise this feature exists to avoid.
---   * it under-fires. `]q` / `[q` (Neovim 0.11+ defaults for `:cnext`/`:cprev`),
---     `:cc`, `:cfirst` and `<C-w><CR>` never touch a buffer-local mapping, so
---     every one of them jumped with no frame at all.
---
--- There is no single "the user chose an entry" event to hook, so one frame per
--- invocation is the honest unit: you asked a semantic question and a list of
--- answers opened. The cost is that closing the list without picking anything
--- leaves one frame pointing at where you already are, which `<C-t>` resolves to
--- a no-op. That is a far cheaper failure than either of the two above.
local function open_quickfix(origin, items, title, kind)
  M.push(origin, kind)
  vim.fn.setqflist({}, " ", { title = title, items = items })
  vim.cmd("botright copen")
end

--- Route a resolved location list to the right outcome.
---
--- `always_list` keeps a verb on the list path even for a lone result. References
--- need it: core never single-jumps (buf.lua:868-908 always opens the list), and
--- with `includeDeclaration = true` a symbol used nowhere else returns exactly one
--- location -- the declaration under the cursor. Single-jumping that is a `grr`
--- that opens nothing, prints nothing and does not move.
---@param origin table|nil
---@param kind string
---@param title string
---@param items table[]
---@param opts table|nil
local function deliver(origin, kind, title, items, opts)
  opts = opts or {}
  if #items == 0 then
    vim.notify("no " .. title .. " found", vim.log.levels.INFO)
    return
  end
  if #items == 1 and not opts.always_list then
    M.jump(origin, items[1], kind)
    return
  end
  -- The verb name is what the "nothing found" message needs; the server's own
  -- list title is only good enough for the quickfix window.
  open_quickfix(origin, items, opts.list_title or title, kind)
end

--- Shared body for the location-returning verbs.
---
--- `on_list` is always supplied, which is what makes core skip its own push
--- (buf.lua:253-260 returns before the push at :267-271) and leaves this module
--- the single writer. `origin` is passed in by callers that must capture before
--- an earlier async hop -- ts_ls's source-definition fallback in particular.
---@param request fun(opts: table)
---@param kind string
---@param title string
---@param origin table|nil
function M.locations(request, kind, title, origin, opts)
  origin = origin or M.capture()
  request({
    on_list = function(list)
      local o = vim.tbl_extend("force", {}, opts or {}, { list_title = list and list.title })
      deliver(origin, kind, title, (list and list.items) or {}, o)
    end,
  })
end

function M.definition(origin)
  M.locations(vim.lsp.buf.definition, "gd", "definition", origin)
end

function M.references()
  M.locations(function(opts)
    vim.lsp.buf.references(nil, opts)
  end, "grr", "references", nil, { always_list = true })
end

function M.implementation()
  M.locations(vim.lsp.buf.implementation, "gri", "implementation")
end

function M.type_definition()
  M.locations(vim.lsp.buf.type_definition, "grt", "type definition")
end

--- ts_ls `gd`: follow the import chain to the real source.
---
--- Plain `textDocument/definition` on an imported symbol lands on the import
--- binding, not the defining file; `_typescript.goToSourceDefinition` follows it
--- through. The origin is captured HERE, before the request, because both the
--- success path and the fallback run inside the response callback where the
--- cursor may have moved -- see M.capture.
---@param client vim.lsp.Client
---@param bufnr integer
function M.ts_source_definition(client, bufnr)
  local origin = M.capture()
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)

  local function handle(locations)
    local list = {}
    if locations then
      list = vim.islist(locations) and locations or { locations }
    end
    deliver(
      origin,
      "gd",
      "definition",
      vim.lsp.util.locations_to_items(list, client.offset_encoding)
    )
  end

  client:request("workspace/executeCommand", {
    command = "_typescript.goToSourceDefinition",
    arguments = { params.textDocument.uri, params.position },
  }, function(err, result)
    if err or not result or vim.tbl_isempty(result) then
      -- The fallback re-asks with the params captured BEFORE the first request,
      -- against the originating buffer. Routing through vim.lsp.buf.definition
      -- here would look correct but is not: core's get_locations reads
      -- nvim_get_current_buf / nvim_get_current_win / getpos('.') at call time
      -- (buf.lua:218-232), and this runs inside a response callback -- so the
      -- FRAME would be early-bound while the symbol being resolved was late-bound.
      client:request("textDocument/definition", params, function(_, fallback)
        handle(fallback)
      end, origin.bufnr)
      return
    end
    handle(result)
  end, bufnr)
end

-- Exposed for the unit spec: kind bookkeeping is module-local state that a spec
-- otherwise cannot reset between examples.
function M._reset_kinds()
  kind_by_key = {}
end

return M
