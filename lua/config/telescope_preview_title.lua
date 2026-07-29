-- Preview-window titles, trimmed from the START so the file name survives.
--
-- With `dynamic_preview_title = true` telescope puts the previewed entry's path
-- in the preview border title, and plenary's border truncates an over-long
-- title from the RIGHT:
--
--   ╭ packages/some-service/src/modules/billing/handlers/create-i… ╮
--
-- i.e. it drops the one part you actually navigate by and keeps the parents.
-- These wrappers trim leading directories instead:
--
--   ╭ …/src/modules/billing/handlers/create-invoice-handler.ts ╮
--
-- matching the results window, where `path_display = filename_first` already
-- puts the name at the left edge and lets the parents run off the right.
--
-- The seam is the previewer's `_dyn_title_fn` (see telescope's
-- previewers/previewer.lua): wrapping it per previewer instance keeps every
-- other title — "File Preview", help tags, git commits — untouched, unlike a
-- patch of Previewer:title or of plenary's truncation.
local M = {}

local SEP = "/"
local ELLIPSIS = "…"

-- plenary's border renders the title as ` %s ` inside the window's top line, so
-- the widest title that escapes its own truncation is (window width - 2).
local BORDER_PADDING = 2

-- `path` shortened to at most `width` display cells by dropping LEADING path
-- segments, e.g. "…/billing/handlers/create-invoice-handler.ts". Returned
-- unchanged when it already fits or when `width` is unusable (no preview window
-- resolved) — the border then truncates as it always did.
function M.trim(path, width)
  if type(path) ~= "string" or path == "" then
    return path
  end
  if type(width) ~= "number" or width < 1 then
    return path
  end
  if vim.api.nvim_strwidth(path) <= width then
    return path
  end

  -- Whole segments first, so the result still reads as a path. Starts at 2:
  -- segment 1 is always droppable (it is "" for an absolute path, which is why
  -- this never bites a leading separator in half).
  local segments = vim.split(path, SEP, { plain = true })
  for i = 2, #segments do
    local candidate = ELLIPSIS .. SEP .. table.concat(segments, SEP, i)
    if vim.api.nvim_strwidth(candidate) <= width then
      return candidate
    end
  end

  -- Even the bare file name overflows: keep its tail (extension included), which
  -- is still a trim from the start, just mid-name.
  return require("plenary.strings").truncate(path, width, ELLIPSIS, -1)
end

local function valid_win(winid)
  return type(winid) == "number" and vim.api.nvim_win_is_valid(winid)
end

-- Title-field width for `previewer`'s preview window, or nil when no preview
-- window can be resolved. Exposed as a seam so the wrapper is unit-testable
-- without a live picker.
function M._width(previewer)
  local state = type(previewer) == "table" and previewer.state or nil
  local winid = state and state.winid or nil
  -- buffer_previewer only assigns state.winid when it creates a fresh preview
  -- buffer; on a cache hit (a resumed picker previewing an already-seen entry
  -- first) it stays nil. Fall back to the live picker layout the same way
  -- telescope's own `path_display = truncate` does — titles refresh while the
  -- picker owns the current buffer, so its status carries the layout.
  if not valid_win(winid) then
    local ok, status = pcall(function()
      return require("telescope.state").get_status(vim.api.nvim_get_current_buf())
    end)
    local layout = ok and status and status.layout or nil
    winid = layout and layout.preview and layout.preview.winid or nil
  end
  if not valid_win(winid) then
    return nil
  end
  return vim.api.nvim_win_get_width(winid) - BORDER_PADDING
end

-- Patch `previewer` in place so its dynamic title is trimmed, and return it.
-- A previewer with no dynamic title (help, git commits, autocommands) is
-- returned untouched.
function M.wrap(previewer)
  local dyn = type(previewer) == "table" and previewer._dyn_title_fn or nil
  if type(dyn) ~= "function" then
    return previewer
  end
  previewer._dyn_title_fn = function(self, entry)
    -- Through M so specs can stub the window lookup.
    return M.trim(dyn(self, entry), M._width(self))
  end
  return previewer
end

-- A drop-in replacement for one of telescope's `*_previewer` config pointers,
-- e.g. `file_previewer = wrapper("vim_buffer_cat")` mirrors telescope's own
-- default (config.lua) with the title wrapper layered on.
function M.wrapper(name)
  return function(opts)
    return M.wrap(require("telescope.previewers")[name].new(opts or {}))
  end
end

return M
