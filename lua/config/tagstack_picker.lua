-- Telescope picker over the definition stack (`<leader>j`): see the whole chain
-- of `gd` / `grr` hops and go back several levels in one step.
--
-- Why not telescope.builtin.tagstack
-- ----------------------------------
-- It exists, and it is the wrong shape. It builds the picker with the default
-- `<CR>` action, which EDITS the file without touching curidx (telescope
-- builtin/__internal.lua:1476-1512). Pick level 3 and the stack still holds three
-- frames, so the next `<C-t>` pops relative to a position you are no longer at.
-- It jumps; this pops.
--
-- The complementary key is `<C-t>` itself, which handles the 90% case of one
-- level back in a single press. This picker is for the rest -- the same division
-- Helix draws between `<C-o>` and its native `Space j` jumplist_picker.
local Overlay = require("util.overlay")
local palette = require("config.palette")
local picker_legend = require("util.picker_legend")
local tagstack = require("config.tagstack")

local M = {}

--- One display row per frame, newest first.
---
--- A frame whose buffer is gone renders as `(unloaded)` rather than being dropped:
--- telescope's own tagstack picker filters those out silently, which makes the
--- numbering disagree with the pop counts the stack actually uses.
---@param winid integer|nil
---@return table[]
function M.rows(winid)
  local frames = tagstack.frames(winid)
  local rows = {}
  for _, f in ipairs(frames) do
    rows[#rows + 1] = {
      frame = f,
      marker = f.current and "●" or " ",
      index = f.idx,
      location = f.filename and (vim.fn.fnamemodify(f.filename, ":~:.") .. ":" .. f.lnum)
        or "(unloaded)",
      tagname = f.tagname,
      kind = f.kind or "",
    }
  end
  return rows
end

--- Column widths across a row set, so the columns line up without a fixed guess.
---@param rows table[]
---@return table
function M.widths(rows)
  local w = { location = 0, tagname = 0 }
  for _, r in ipairs(rows) do
    w.location = math.max(w.location, vim.api.nvim_strwidth(r.location))
    w.tagname = math.max(w.tagname, vim.api.nvim_strwidth(r.tagname))
  end
  return w
end

local function pad(text, width)
  local extra = width - vim.api.nvim_strwidth(text)
  return extra > 0 and (text .. string.rep(" ", extra)) or text
end

--- Render one row. Trailing whitespace is trimmed so a stack with no known kinds
--- does not render a ragged right edge.
---@param row table
---@param widths table
---@return string
function M.format(row, widths)
  local line = ("%s %d  %s  %s  %s"):format(
    row.marker,
    row.index,
    pad(row.location, widths.location),
    pad(row.tagname, widths.tagname),
    row.kind
  )
  return (line:gsub("%s+$", ""))
end

-- ===================== legend =====================

local function set_legend_highlights()
  vim.api.nvim_set_hl(0, "TagStackLegend", { fg = palette.muted, default = true })
  vim.api.nvim_set_hl(0, "TagStackLegendKey", { fg = "#768390", bold = true, default = true })
end

local legend = Overlay.new()

local function close_legend()
  legend:close()
end

local function open_legend(prompt_bufnr)
  close_legend()
  set_legend_highlights()
  local results_win = picker_legend.results_win(prompt_bufnr)
  if not results_win then
    return
  end
  local segs = {}
  for _, pair in ipairs({
    { "<CR>", "pop here" },
    { "<C-x>", "drop frame" },
    { "<esc>", "close" },
  }) do
    segs[#segs + 1] = { icon = pair[1], icon_hl = "TagStackLegendKey", label = pair[2] }
  end
  local text, ranges = picker_legend.render_segments(segs, {
    separator = "   ",
    default_hl = "TagStackLegend",
  })
  local width = vim.api.nvim_win_get_width(results_win)
  text, ranges = picker_legend.fit_line(text, ranges, width)
  picker_legend.mount(legend, results_win, "tagstack_picker_legend", { text }, { ranges })
end

-- ===================== picker =====================

local function make_finder(winid)
  local finders = require("telescope.finders")
  local rows = M.rows(winid)
  local widths = M.widths(rows)
  return finders.new_table({
    results = rows,
    entry_maker = function(row)
      local line = M.format(row, widths)
      return {
        value = row,
        display = line,
        ordinal = line,
        -- The qflist previewer reads these directly.
        filename = row.frame.filename,
        lnum = row.frame.lnum,
        col = row.frame.col,
      }
    end,
  })
end

function M.open()
  -- The stack belongs to the window the key was pressed in; once telescope opens,
  -- the current window is the prompt, whose tagstack is empty.
  local winid = vim.api.nvim_get_current_win()
  local rows = M.rows(winid)
  if #rows == 0 then
    vim.notify("definition stack empty", vim.log.levels.INFO)
    return
  end

  local pickers = require("telescope.pickers")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  set_legend_highlights()

  pickers
    .new({}, {
      prompt_title = "Definition stack",
      finder = make_finder(winid),
      sorter = conf.generic_sorter({}),
      previewer = conf.qflist_previewer({}),
      initial_mode = "normal",
      attach_mappings = function(prompt_bufnr, map)
        picker_legend.attach(prompt_bufnr, function()
          open_legend(prompt_bufnr)
        end, close_legend)

        local function selected()
          local entry = action_state.get_selected_entry()
          return entry and entry.value or nil
        end

        -- <CR>: pop the stack to this frame. Closing first matters -- goto_frame
        -- drives `:pop`, which acts on the current window, and that has to be the
        -- window the stack belongs to rather than telescope's prompt.
        map({ "i", "n" }, "<CR>", function()
          local row = selected()
          if not row then
            return
          end
          actions.close(prompt_bufnr)
          if vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_set_current_win(winid)
            tagstack.goto_frame(winid, row.frame.stack_idx)
          end
        end)

        -- <C-x>: drop the frame under the cursor. Ctrl-prefixed for the same
        -- reason lsp_picker's <C-k> is: this picker opens in normal mode, where
        -- bare `x` would be taken from a list you must move around in.
        map({ "i", "n" }, "<C-x>", function()
          local row = selected()
          if not row then
            return
          end
          tagstack.drop_frame(winid, row.frame.stack_idx)
          local p = action_state.get_current_picker(prompt_bufnr)
          if p then
            p:refresh(make_finder(winid), { reset_prompt = false })
          end
        end)

        return true
      end,
    })
    :find()
end

return M
