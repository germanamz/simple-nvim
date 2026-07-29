-- Sticky ancestor folders for nvim-tree: the folders containing the cursor row
-- stay pinned to the top of the tree window once they scroll out of view, the
-- way nvim-treesitter-context pins enclosing functions in a code buffer.
--
-- The pinned rows are COPIED verbatim out of the tree buffer — text plus the
-- extmarks nvim-tree painted on them — rather than re-rendered. That is what
-- makes every decorator work in the header for free, now and later: the git
-- labels, the grey/blue/teal ignored/dot-folder/symlink trio, the devicons, and
-- the submodule branch/status labels all arrive with the row.
--
-- See docs/superpowers/specs/2026-07-29-nvim-tree-sticky-folders-design.md.
local M = {}

local Overlay = require("util.overlay")

-- nvim-tree paints a row through two namespaces and we need both. Highlights
-- carries the inline colours (devicons, the git decorator's icon_placement
-- "before" labels, the dot-folder/symlink/ignored trio); Extmarks carries the
-- icon_placement "after" virt_text, which is where config.nvim_tree_submodule
-- hangs each submodule's branch and status.
local NS_HIGHLIGHTS = vim.api.nvim_create_namespace("NvimTreeHighlights")
local NS_EXTMARKS = vim.api.nvim_create_namespace("NvimTreeExtmarks")
local NS_HEADER = vim.api.nvim_create_namespace("nvim_tree_context")

-- Mark details worth carrying over. Deliberately a whitelist: the details table
-- also reports derived and namespace-scoped fields that nvim_buf_set_extmark
-- rejects, so copying it wholesale would fail on every mark.
local COPY = {
  "hl_group",
  "hl_eol",
  "hl_mode",
  "priority",
  "conceal",
  "virt_text",
  "virt_text_pos",
  "virt_text_win_col",
  "virt_text_hide",
  "right_gravity",
}

local overlay = Overlay.new()
local enabled = true
local cache = {}

-- Buffer lines of the cursor node's ancestor folders, root-most first.
--
-- The root repo row is excluded for free: nvim-tree's line map starts BELOW the
-- root header (core.get_nodes_starting_line() skips it), so the root node is
-- never a value in it and the walk terminates when the lookup misses. Any other
-- gap in the map — a filtered or grouped node — stops the walk the same way,
-- which is the conservative choice: a chain is only ever truncated at the top.
function M._ancestors(node, line_of)
  local lines = {}
  local n = node and node.parent
  while n and line_of[n] do
    table.insert(lines, 1, line_of[n])
    n = n.parent
  end
  return lines
end

-- How many ancestors to pin, given their buffer lines (root-most first), the
-- window's first visible line, and the cursor line.
--
-- Port of nvim-treesitter-context's mode="cursor" rule (context.lua:376): pin an
-- ancestor only if it is NOT in view, where "in view" accounts for the rows the
-- header will itself cover. That self-reference is why this cascades — pinning
-- two rows hides the row at `topline`, so an ancestor sitting there gets pulled
-- in on the next step. Ancestor lines strictly increase, so the pinned set is
-- always a prefix and one pass suffices.
--
-- `cap` keeps the header from ever covering the cursor row.
function M._pinned(lines, topline, cursor_line)
  local cap = cursor_line - topline
  local h = 0
  for _, line in ipairs(lines) do
    if h >= cap or line >= topline + h then
      break
    end
    h = h + 1
  end
  return h
end

-- line -> node and node -> line for the currently rendered tree, memoised
-- against the buffer's changedtick. nvim-tree rewrites the whole buffer on every
-- draw, so the tick invalidates this exactly when the tree changes and never in
-- between: moving the cursor across a warm tree costs two table lookups.
function M._maps(tree_buf)
  local tick = vim.api.nvim_buf_get_changedtick(tree_buf)
  if cache.buf == tree_buf and cache.tick == tick then
    return cache.by_line, cache.line_of
  end
  local core = require("nvim-tree.core")
  local explorer = core.get_explorer()
  if not explorer then
    return nil
  end
  local by_line = explorer:get_nodes_by_line(core.get_nodes_starting_line())
  local line_of = {}
  for line, node in pairs(by_line) do
    line_of[node] = line
  end
  cache = { buf = tree_buf, tick = tick, by_line = by_line, line_of = line_of }
  return by_line, line_of
end

local function define_highlights()
  -- Match the sidebar's own background rather than NormalFloat, so the header
  -- reads as part of the tree instead of as a popup over it.
  vim.api.nvim_set_hl(0, "NvimTreeContext", { link = "NvimTreeNormal", default = true })
  -- Same separator the code buffers already show under a treesitter context.
  vim.api.nvim_set_hl(
    0,
    "NvimTreeContextBottom",
    { link = "TreesitterContextBottom", default = true }
  )
end

-- Replay one tree row's extmarks onto `dst_row` of the header buffer. The text
-- is byte-identical, so the source columns transfer unchanged.
local function copy_marks(tree_buf, src_line, buf, dst_row)
  local srow = src_line - 1
  for _, ns in ipairs({ NS_HIGHLIGHTS, NS_EXTMARKS }) do
    local marks = vim.api.nvim_buf_get_extmarks(
      tree_buf,
      ns,
      { srow, 0 },
      { srow, -1 },
      { details = true }
    )
    for _, mark in ipairs(marks) do
      local col, details = mark[3], mark[4]
      local opts = {}
      for _, field in ipairs(COPY) do
        opts[field] = details[field]
      end
      -- Tree rows are single-line, so an end position only ever stays on the
      -- same row; drop anything that would spill onto the next pinned row.
      if details.end_row == srow then
        opts.end_row, opts.end_col = dst_row, details.end_col
      end
      pcall(vim.api.nvim_buf_set_extmark, buf, NS_HEADER, dst_row, col, opts)
    end
  end
end

-- Build (or refresh in place) the header over `tree_win` for the given tree
-- buffer lines. Reusing the window when it is already up keeps a cursor move
-- from destroying and recreating a float on every keystroke.
local function render(tree_win, tree_buf, lines)
  local reuse = overlay.win
    and vim.api.nvim_win_is_valid(overlay.win)
    and overlay.buf
    and vim.api.nvim_buf_is_valid(overlay.buf)

  local buf = reuse and overlay.buf or vim.api.nvim_create_buf(false, true)

  local text = {}
  for i, line in ipairs(lines) do
    text[i] = vim.api.nvim_buf_get_lines(tree_buf, line - 1, line, false)[1] or ""
  end
  vim.api.nvim_buf_clear_namespace(buf, NS_HEADER, 0, -1)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
  if not reuse then
    -- Assigning 'filetype' fires FileType even when the value is unchanged, so
    -- set it once at creation rather than on every cursor move.
    vim.bo[buf].filetype = "NvimTreeContext"
  end

  for row, line in ipairs(lines) do
    copy_marks(tree_buf, line, buf, row - 1)
  end
  -- Underline the last row. Lowest priority so it only supplies the attribute
  -- the copied highlights leave unset, exactly as treesitter-context does.
  vim.api.nvim_buf_set_extmark(buf, NS_HEADER, #text - 1, 0, {
    end_row = #text,
    hl_group = "NvimTreeContextBottom",
    hl_eol = true,
    priority = 1,
  })

  -- row=0 is the first TEXT row: a relative="win" float is composited below the
  -- window's winbar, so the tree's "g? — all mappings" hint is never covered and
  -- no offset is needed. Do not "fix" this by adding one for winbar — that pushes
  -- the header a row too low and leaves one real tree row peeking out above the
  -- pinned folders, which also breaks _pinned's assumption that an h-row header
  -- covers buffer lines topline..topline+h-1.
  --
  -- Headless disagrees: nvim_win_get_position() and screenpos() both report a
  -- float's position frame-relative, so a headless probe "proves" an offset is
  -- needed. It is not — trust the renderer, not the probe.
  local win_config = {
    relative = "win",
    win = tree_win,
    row = 0,
    col = 0,
    width = vim.api.nvim_win_get_width(tree_win),
    height = #text,
    style = "minimal",
    focusable = false,
    zindex = 20,
  }

  if reuse then
    vim.api.nvim_win_set_config(overlay.win, win_config)
    return
  end
  win_config.noautocmd = true
  local win = overlay:mount(buf, win_config)
  vim.wo[win].winhighlight = "Normal:NvimTreeContext"
end

function M.close()
  overlay:close()
end

-- Recompute the header from the tree window's current cursor and scroll state.
function M.update()
  if not enabled then
    return M.close()
  end
  local ok, view = pcall(require, "nvim-tree.view")
  if not ok then
    return M.close()
  end
  local tree_win = view.get_winnr()
  if not tree_win or not vim.api.nvim_win_is_valid(tree_win) then
    return M.close()
  end
  -- Never recompute from inside our own float: it has no tree cursor, and the
  -- window it would resize is the one being read.
  if overlay.win == vim.api.nvim_get_current_win() then
    return
  end

  local tree_buf = vim.api.nvim_win_get_buf(tree_win)
  local by_line, line_of = M._maps(tree_buf)
  if not by_line then
    return M.close()
  end

  local cursor_line = vim.api.nvim_win_get_cursor(tree_win)[1]
  local topline = vim.fn.line("w0", tree_win)
  local lines = M._ancestors(by_line[cursor_line], line_of)
  local height = M._pinned(lines, topline, cursor_line)
  if height == 0 then
    return M.close()
  end

  render(tree_win, tree_buf, vim.list_slice(lines, 1, height))
end

function M.toggle()
  enabled = not enabled
  if enabled then
    M.update()
  else
    M.close()
  end
end

-- Test seam: tear the header down and forget every cached map.
function M._reset()
  M.close()
  enabled = true
  cache = {}
end

-- Wire the header to the tree's lifetime. `events` is nvim-tree's api.events,
-- passed in so this module never has to require the plugin at startup. The
-- augroup is named and cleared so a config() re-run replaces the autocmds
-- instead of stacking duplicates.
function M.register(events)
  local group = vim.api.nvim_create_augroup("nvim_tree_context", { clear = true })
  -- WinScrolled and WinResized match their pattern against the window ID, not
  -- the buffer name, so these cannot be narrowed with a "NvimTree_*" pattern the
  -- way nvim-tree's own float autocmds are — filter on the filetype instead.
  vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled", "WinResized", "WinEnter" }, {
    group = group,
    callback = function()
      if vim.bo.filetype == "NvimTree" then
        M.update()
      end
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = define_highlights })
  events.subscribe(events.Event.TreeOpen, function()
    M.update()
  end)
  events.subscribe(events.Event.TreeClose, function()
    M.close()
  end)
  define_highlights()
end

return M
