-- Legend strip under a telescope picker: the generic machinery for rendering
-- highlighted segment rows, anchoring them in a float below the picker's
-- results window, and tying that float's lifetime to the prompt buffer.
-- Extracted from telescope_smart (where it was all local) when the buffers
-- picker grew its own flags legend — same precedent as util.overlay: share the
-- byte-identical plumbing, keep each caller's content local.
local M = {}

-- Resolve the telescope results window for a prompt buffer, or nil if telescope
-- isn't loaded / the window is gone.
function M.results_win(prompt_bufnr)
  local ok, action_state = pcall(require, "telescope.actions.state")
  if not ok then
    return nil
  end
  local picker = action_state.get_current_picker(prompt_bufnr)
  local results_win = picker and picker.results_win
  if not results_win or not vim.api.nvim_win_is_valid(results_win) then
    return nil
  end
  return results_win
end

-- Append one segment (optional icon / count / label) to `text`, recording
-- {hl, start_col, end_col} byte ranges into `ranges`.
local function append_segment(text, ranges, seg, separator, opts)
  if separator and #text > 0 then
    text = text .. separator
  end
  if seg.icon and seg.icon ~= "" then
    local s = #text
    text = text .. seg.icon
    if seg.icon_hls then
      for _, h in ipairs(seg.icon_hls) do
        table.insert(ranges, { h[3], s + h[1], s + h[2] })
      end
    else
      table.insert(ranges, { seg.icon_hl or opts.default_hl, s, #text })
    end
  end
  if seg.count ~= nil then
    if seg.icon and seg.icon ~= "" then
      text = text .. " "
    end
    local s = #text
    text = text .. tostring(seg.count)
    table.insert(ranges, { opts.count_hl or opts.default_hl, s, #text })
  end
  if seg.label and seg.label ~= "" then
    text = text .. " "
    local s = #text
    text = text .. seg.label
    table.insert(ranges, { opts.default_hl, s, #text })
  end
  return text
end

-- Render segments into one line + highlight ranges. opts: separator (between
-- segments), default_hl (icons/labels without an explicit group), count_hl
-- (counts; falls back to default_hl).
function M.render_segments(segs, opts)
  local text, ranges = "", {}
  for i, seg in ipairs(segs) do
    text = append_segment(text, ranges, seg, i > 1 and opts.separator or nil, opts)
  end
  return text, ranges
end

-- Center `text` in `width` (shifting ranges along) and right-pad to the full
-- width; text at or above the width is returned unchanged.
function M.fit_line(text, ranges, width)
  local w = vim.api.nvim_strwidth(text)
  if w < width then
    local pad = math.floor((width - w) / 2)
    if pad > 0 then
      text = string.rep(" ", pad) .. text
      for _, r in ipairs(ranges) do
        r[2] = r[2] + pad
        r[3] = r[3] + pad
      end
    end
    local extra = width - vim.api.nvim_strwidth(text)
    if extra > 0 then
      text = text .. string.rep(" ", extra)
    end
  end
  return text, ranges
end

-- Create the legend buffer + window anchored just BELOW the results window (so
-- it never occludes result rows), falling back to overlaying the window's
-- bottom rows only when there's no room beneath it. No-op if the legend would
-- be taller than results.
function M.mount(overlay, results_win, ns_name, lines, ranges_by_line)
  local pos = vim.api.nvim_win_get_position(results_win)
  local width = vim.api.nvim_win_get_width(results_win)
  local height = vim.api.nvim_win_get_height(results_win)
  if #lines > height then
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local ns = vim.api.nvim_create_namespace(ns_name)
  for lnum, ranges in ipairs(ranges_by_line) do
    for _, r in ipairs(ranges) do
      vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, r[2], { end_col = r[3], hl_group = r[1] })
    end
  end

  -- Prefer the row directly under the results window; only overlay the bottom
  -- rows (the old anchor) when sitting below would run into the command line.
  -- vim.o.lines counts the cmdline rows, so reserve cmdheight of them.
  local below_row = pos[1] + height
  local row = below_row
  if below_row + #lines > vim.o.lines - vim.o.cmdheight then
    row = pos[1] + height - #lines
  end

  local win = overlay:mount(buf, {
    relative = "editor",
    row = row,
    col = pos[2],
    width = width,
    height = #lines,
    style = "minimal",
    focusable = false,
    noautocmd = true,
    zindex = 250,
  })
  -- style="minimal" doesn't touch 'wrap' and the float inherits the global, so
  -- a row longer than the window would wrap onto (and hide) the next legend
  -- row. Clip overlong rows instead.
  vim.wo[win].wrap = false
  return win
end

-- Wire the legend lifecycle to a picker's prompt buffer: open (deferred so the
-- picker windows exist by the time it runs), close when the prompt buffer is
-- left or wiped, re-open on terminal resize. Telescope repositions its own
-- windows in place on a resize (same prompt_bufnr), so the editor-anchored
-- legend would be left stranded; re-rendering re-anchors it. The buffer-local
-- autocmds are auto-removed when the prompt buffer is wiped.
function M.attach(prompt_bufnr, open, close)
  vim.schedule(open)
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufLeave" }, {
    buffer = prompt_bufnr,
    once = true,
    callback = close,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    buffer = prompt_bufnr,
    callback = function()
      vim.schedule(open)
    end,
  })
end

return M
