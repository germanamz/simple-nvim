-- Flags legend for the <leader>fb buffers picker: a float under the results
-- window decoding telescope's buffer indicator column (the :ls flags). The
-- content is static; the rendering/anchoring/lifecycle plumbing is shared with
-- telescope_smart's git legend (util.picker_legend).
local Overlay = require("util.overlay")
local palette = require("config.palette")
local picker_legend = require("util.picker_legend")

local M = {}

local legend = Overlay.new()

local function set_highlights()
  vim.api.nvim_set_hl(0, "BuffersLegend", { fg = palette.muted, default = true })
  -- Same bold grey as SmartFilesLegendCount: the flag glyphs are the anchors
  -- the eye pairs with the picker's indicator column.
  vim.api.nvim_set_hl(0, "BuffersLegendFlag", { fg = "#768390", bold = true, default = true })
end

-- The :ls indicator flags telescope's buffers picker can actually render:
-- make_entry.gen_from_buffer builds the column as exactly %/# .. a/h .. = .. +,
-- so the rest of :ls's alphabet (- u x R F) can never appear here and stays
-- out of the legend. Row 1 is the widest; both rows must fit the ~43-cell
-- results window of a 120-column horizontal layout (see the unit spec).
local ROWS = {
  {
    { icon = "+", label = "modified" },
    { icon = "%", label = "current" },
    { icon = "#", label = "alternate <C-^>" },
  },
  {
    { icon = "a", label = "active" },
    { icon = "h", label = "hidden" },
    { icon = "=", label = "read-only" },
  },
}

-- Render the two legend rows centered in `width`. Exposed for unit testing.
function M._build_lines(width)
  local lines, ranges_by_line = {}, {}
  for _, row in ipairs(ROWS) do
    local segs = {}
    for _, seg in ipairs(row) do
      table.insert(segs, { icon = seg.icon, icon_hl = "BuffersLegendFlag", label = seg.label })
    end
    local text, ranges =
      picker_legend.render_segments(segs, { separator = "   ", default_hl = "BuffersLegend" })
    text, ranges = picker_legend.fit_line(text, ranges, width)
    table.insert(lines, text)
    table.insert(ranges_by_line, ranges)
  end
  return lines, ranges_by_line
end

local function close_legend()
  legend:close()
end

local function open_legend(prompt_bufnr)
  close_legend()
  set_highlights()
  local results_win = picker_legend.results_win(prompt_bufnr)
  if not results_win then
    return
  end
  local width = vim.api.nvim_win_get_width(results_win)
  local lines, ranges_by_line = M._build_lines(width)
  picker_legend.mount(legend, results_win, "buffers_legend", lines, ranges_by_line)
end

-- The buffers picker with the flags legend attached (<leader>fb).
function M.open()
  require("telescope.builtin").buffers({
    attach_mappings = function(prompt_bufnr, _)
      picker_legend.attach(prompt_bufnr, function()
        open_legend(prompt_bufnr)
      end, close_legend)
      return true
    end,
  })
end

return M
