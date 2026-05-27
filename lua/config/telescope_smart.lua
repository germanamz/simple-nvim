-- Smart file pickers with git-status-aware prefixes.
--
-- After `M.setup()` runs, telescope's `make_entry.gen_from_file` is wrapped
-- so the same prefixes appear in every file-listing picker (find_files,
-- oldfiles, the smart pickers, etc.). Codes are cached per-cwd for ~500ms
-- so successive picker opens don't re-shell out to git.
--
-- Prefix scheme (single dominant letter + color):
--     A   added       (green)
--     M   modified    (blue)
--     D   deleted     (gray)
--     R   renamed     (teal)
--     ?   untracked   (brown)
--
-- A trailing '*' marks the file as having unstaged worktree changes.
-- Absence of '*' means the change is fully staged:
--     A     staged add
--     M     staged modification
--     M*    worktree modification (unstaged or staged+further edits)
--     D     staged delete
--     D*    worktree delete
--     ?*    untracked (always shown with '*')
--     R     staged rename
--
-- When a review base is set (see config.review_base), files that differ
-- from the base in committed history but have no current worktree change
-- get a leading 'b' (purple), with the type letter retaining its color:
--     bA   added in a commit since base
--     bM   modified in a commit since base
--     bD   deleted in a commit since base
--     bR   renamed in a commit since base

local M = {}

local review_base = require("config.review_base")

-- ===================== helpers =====================

local function git_root_at(cwd)
  local out = vim.fn.systemlist({
    "git",
    "-C",
    cwd or vim.fn.getcwd(),
    "rev-parse",
    "--show-toplevel",
  })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return out[1]
end

local function parse_status_path(raw)
  local arrow = raw:find(" %-> ")
  if arrow then
    raw = raw:sub(arrow + 4)
  end
  return (raw:gsub('^"(.*)"$', "%1"))
end

local function hl_for_letter(c)
  if c == "A" then
    return "SmartFilesAdded"
  elseif c == "R" or c == "C" then
    return "SmartFilesRenamed"
  elseif c == "D" then
    return "SmartFilesDeleted"
  elseif c == "M" or c == "T" then
    return "SmartFilesModified"
  elseif c == "?" then
    return "SmartFilesUntracked"
  end
end

-- format_prefix: turn an XY porcelain code (or 'b<letter>' for base-only)
-- into a 2-char text prefix plus a list of {range, hl} tuples.
local function format_prefix(code)
  if not code or code == "" then
    return "  ", {}
  end
  if code == "??" then
    return "?*", { { { 0, 2 }, "SmartFilesUntracked" } }
  end
  if code:sub(1, 1) == "b" then
    local letter = code:sub(2, 2)
    local lhl = hl_for_letter(letter)
    local hls = { { { 0, 1 }, "SmartFilesBase" } }
    if lhl then
      table.insert(hls, { { 1, 2 }, lhl })
    end
    return "b" .. letter, hls
  end
  local x = code:sub(1, 1)
  local y = code:sub(2, 2)
  local dominant = (x ~= " " and x ~= "?") and x or y
  if dominant == "" or dominant == " " then
    return "  ", {}
  end
  local marker = (y ~= " " and y ~= "?") and "*" or " "
  local dhl = hl_for_letter(dominant)
  local hls = {}
  if dhl then
    table.insert(hls, { { 0, 1 }, dhl })
  end
  if marker == "*" then
    table.insert(hls, { { 1, 2 }, "SmartFilesUnstaged" })
  end
  return dominant .. marker, hls
end

local function relpath(abs, base)
  abs = vim.fn.fnamemodify(abs, ":p")
  base = vim.fn.fnamemodify(base, ":p")
  if base:sub(-1) ~= "/" then
    base = base .. "/"
  end
  if abs:sub(1, #base) == base then
    return abs:sub(#base + 1)
  end
  return abs
end

-- ===================== git status / counts =====================

function M._git_changes(root, base)
  local codes = {}
  local counts = {
    added = 0,
    modified = 0,
    deleted = 0,
    renamed = 0,
    untracked = 0,
    staged = 0,
    unstaged = 0,
    committed = 0,
  }

  local status = vim.fn.systemlist({ "git", "-C", root, "status", "--porcelain" })
  if vim.v.shell_error == 0 then
    for _, line in ipairs(status) do
      if #line >= 4 then
        local x = line:sub(1, 1)
        local y = line:sub(2, 2)
        local path = parse_status_path(line:sub(4))
        codes[path] = x .. y

        local dominant = (x ~= " " and x ~= "?") and x or y
        if dominant == "?" then
          counts.untracked = counts.untracked + 1
        elseif dominant == "A" then
          counts.added = counts.added + 1
        elseif dominant == "R" or dominant == "C" then
          counts.renamed = counts.renamed + 1
        elseif dominant == "D" then
          counts.deleted = counts.deleted + 1
        elseif dominant == "M" or dominant == "T" then
          counts.modified = counts.modified + 1
        end

        if x ~= " " and x ~= "?" then
          counts.staged = counts.staged + 1
        end
        if y ~= " " and y ~= "?" then
          counts.unstaged = counts.unstaged + 1
        end
        if x == "?" and y == "?" then
          counts.unstaged = counts.unstaged + 1
        end
      end
    end
  end

  if base and review_base.resolve(root, base) then
    local cm = vim.fn.systemlist({ "git", "-C", root, "diff", "--name-status", base .. "..HEAD" })
    if vim.v.shell_error == 0 then
      for _, line in ipairs(cm) do
        if line ~= "" then
          local status_char = line:sub(1, 1)
          local rest = line:sub(2):match("^%s*(.*)$") or ""
          local path
          if status_char == "R" or status_char == "C" then
            path = rest:match("\t[^\t]+\t(.+)$") or rest:match("%s+%S+%s+(.+)$")
          else
            path = rest:match("^(.+)$")
          end
          if path and path ~= "" then
            counts.committed = counts.committed + 1
            if not codes[path] then
              codes[path] = "b" .. status_char
            end
          end
        end
      end
    end
  end

  return codes, counts
end

function M._list_all()
  if vim.fn.executable("rg") == 1 then
    return vim.fn.systemlist({ "rg", "--files", "--hidden", "--glob", "!.git" })
  elseif vim.fn.executable("fd") == 1 then
    return vim.fn.systemlist({ "fd", "--type", "f", "--hidden", "--exclude", ".git" })
  else
    return vim.fn.systemlist({ "find", ".", "-type", "f", "-not", "-path", "*/.git/*" })
  end
end

function M._merge_results(codes, all_files)
  local seen, results = {}, {}
  local function add(f)
    if not seen[f] then
      seen[f] = true
      table.insert(results, f)
    end
  end
  for f in pairs(codes) do
    add(f)
  end
  for _, f in ipairs(all_files) do
    f = f:gsub("^%./", "")
    add(f)
  end
  return results
end

-- ===================== codes cache (per-cwd, short TTL) =====================

local cache = { codes = {}, counts = nil, base = nil, root = nil, cwd = nil, time = 0 }

local function ms_now()
  return vim.loop.hrtime() / 1e6
end

local function refresh_codes(cwd, force)
  cwd = cwd or vim.fn.getcwd()
  local now = ms_now()
  if not force and cache.cwd == cwd and (now - cache.time) < 500 then
    return cache.codes, cache.counts, cache.base, cache.root
  end
  local root = git_root_at(cwd)
  if not root then
    cache = { codes = {}, counts = nil, base = nil, root = nil, cwd = cwd, time = now }
    return cache.codes, cache.counts, cache.base, cache.root
  end
  local base = review_base.get(root)
  local raw_codes, counts = M._git_changes(root, base)
  local codes = {}
  for p, c in pairs(raw_codes) do
    local abs = root .. "/" .. p
    codes[relpath(abs, cwd)] = c
  end
  cache = { codes = codes, counts = counts, base = base, root = root, cwd = cwd, time = now }
  return codes, counts, base, root
end

function M._refresh(cwd, force)
  return refresh_codes(cwd, force)
end

-- ===================== highlights & legend =====================

local function set_legend_highlights()
  vim.api.nvim_set_hl(0, "SmartFilesAdded", { fg = "#6cc070", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesUntracked", { fg = "#c08850", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesModified", { fg = "#5a8ed4", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesDeleted", { fg = "#9a9a9a", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesRenamed", { fg = "#4cb0a0", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesBase", { fg = "#b58fd4", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesUnstaged", { fg = "#888888", default = true })
  vim.api.nvim_set_hl(0, "SmartFilesLegend", { fg = "#888888", default = true })
  vim.api.nvim_set_hl(0, "SmartFilesLegendCount", { fg = "#cccccc", bold = true, default = true })
end

local legend_win, legend_buf

local function close_legend()
  if legend_win and vim.api.nvim_win_is_valid(legend_win) then
    vim.api.nvim_win_close(legend_win, true)
  end
  if legend_buf and vim.api.nvim_buf_is_valid(legend_buf) then
    vim.api.nvim_buf_delete(legend_buf, { force = true })
  end
  legend_win, legend_buf = nil, nil
end

local function append_segment(text, ranges, seg, separator)
  if separator and #text > 0 then
    text = text .. separator
  end
  if seg.icon and seg.icon ~= "" then
    local s = #text
    text = text .. seg.icon
    table.insert(ranges, { seg.icon_hl or "SmartFilesLegend", s, #text })
  end
  if seg.count ~= nil then
    if seg.icon and seg.icon ~= "" then
      text = text .. " "
    end
    local s = #text
    text = text .. tostring(seg.count)
    table.insert(ranges, { "SmartFilesLegendCount", s, #text })
  end
  if seg.label and seg.label ~= "" then
    text = text .. " "
    local s = #text
    text = text .. seg.label
    table.insert(ranges, { "SmartFilesLegend", s, #text })
  end
  return text
end

local function render_segments(segs, separator)
  local text, ranges = "", {}
  for i, seg in ipairs(segs) do
    text = append_segment(text, ranges, seg, i > 1 and separator or nil)
  end
  return text, ranges
end

local function fit_line(text, ranges, width)
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

local function open_legend(prompt_bufnr, counts, base)
  close_legend()
  set_legend_highlights()
  if not counts then
    return
  end

  local ok, action_state = pcall(require, "telescope.actions.state")
  if not ok then
    return
  end
  local picker = action_state.get_current_picker(prompt_bufnr)
  local results_win = picker and picker.results_win
  if not results_win or not vim.api.nvim_win_is_valid(results_win) then
    return
  end

  local type_segments = {
    { icon = "A", icon_hl = "SmartFilesAdded", count = counts.added, label = "added" },
    { icon = "M", icon_hl = "SmartFilesModified", count = counts.modified, label = "modified" },
    { icon = "D", icon_hl = "SmartFilesDeleted", count = counts.deleted, label = "deleted" },
    { icon = "R", icon_hl = "SmartFilesRenamed", count = counts.renamed, label = "renamed" },
    { icon = "?*", icon_hl = "SmartFilesUntracked", count = counts.untracked, label = "untracked" },
  }
  local scope_segments = {
    { count = counts.staged, label = "staged" },
    { icon = "*", icon_hl = "SmartFilesUnstaged", count = counts.unstaged, label = "unstaged" },
  }
  if base then
    table.insert(scope_segments, {
      icon = "b",
      icon_hl = "SmartFilesBase",
      count = counts.committed,
      label = "vs " .. base,
    })
  end

  local function nonzero(segs)
    local out = {}
    for _, s in ipairs(segs) do
      if (s.count or 0) > 0 then
        table.insert(out, s)
      end
    end
    return out
  end
  local types = nonzero(type_segments)
  local scopes = nonzero(scope_segments)
  if #types == 0 and #scopes == 0 then
    return
  end

  local pos = vim.api.nvim_win_get_position(results_win)
  local width = vim.api.nvim_win_get_width(results_win)
  local height = vim.api.nvim_win_get_height(results_win)

  -- Try single-line first; fall back to two lines if it overflows.
  local lines, ranges_by_line = {}, {}
  local all = {}
  for _, t in ipairs(types) do
    table.insert(all, t)
  end
  for _, s in ipairs(scopes) do
    table.insert(all, s)
  end
  local combo_text, combo_ranges = render_segments(all, "    ")
  if vim.api.nvim_strwidth(combo_text) <= width then
    combo_text, combo_ranges = fit_line(combo_text, combo_ranges, width)
    table.insert(lines, combo_text)
    table.insert(ranges_by_line, combo_ranges)
  else
    if #types > 0 then
      local t, r = render_segments(types, "   ")
      t, r = fit_line(t, r, width)
      table.insert(lines, t)
      table.insert(ranges_by_line, r)
    end
    if #scopes > 0 then
      local t, r = render_segments(scopes, "   ")
      t, r = fit_line(t, r, width)
      table.insert(lines, t)
      table.insert(ranges_by_line, r)
    end
  end

  if #lines == 0 or #lines > height then
    return
  end

  legend_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(legend_buf, 0, -1, false, lines)
  local ns = vim.api.nvim_create_namespace("smart_files_legend")
  for lnum, ranges in ipairs(ranges_by_line) do
    for _, r in ipairs(ranges) do
      vim.api.nvim_buf_add_highlight(legend_buf, ns, r[1], lnum - 1, r[2], r[3])
    end
  end

  legend_win = vim.api.nvim_open_win(legend_buf, false, {
    relative = "editor",
    row = pos[1] + height - #lines,
    col = pos[2],
    width = width,
    height = #lines,
    style = "minimal",
    focusable = false,
    noautocmd = true,
    zindex = 250,
  })
end

-- ===================== picker core =====================

local function open_picker(opts)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local make_entry = require("telescope.make_entry")

  set_legend_highlights()

  pickers
    .new({}, {
      prompt_title = opts.title,
      finder = finders.new_table({
        results = opts.results,
        entry_maker = make_entry.gen_from_file({ cwd = opts.cwd }),
      }),
      sorter = conf.file_sorter({}),
      previewer = conf.file_previewer({}),
      attach_mappings = function(prompt_bufnr, _)
        vim.schedule(function()
          open_legend(prompt_bufnr, opts.counts, opts.base)
        end)
        vim.api.nvim_create_autocmd({ "BufWipeout", "BufLeave" }, {
          buffer = prompt_bufnr,
          once = true,
          callback = close_legend,
        })
        return true
      end,
    })
    :find()
end

function M.smart_files()
  local cwd = vim.fn.getcwd()
  local codes, counts, base = refresh_codes(cwd, true)
  local all = M._list_all()
  if vim.v.shell_error ~= 0 then
    all = {}
  end
  local results = M._merge_results(codes, all)
  open_picker({
    title = base and ("Files (base: " .. base .. ")") or "Files",
    results = results,
    cwd = cwd,
    counts = counts,
    base = base,
  })
end

function M.smart_files_changed()
  local cwd = vim.fn.getcwd()
  local codes, counts, base, root = refresh_codes(cwd, true)
  if not root then
    vim.notify("Not a git repo", vim.log.levels.WARN)
    return
  end
  local results = {}
  for f in pairs(codes) do
    table.insert(results, f)
  end
  table.sort(results)
  if #results == 0 then
    vim.notify("No changes vs " .. (base or "index"), vim.log.levels.INFO)
    return
  end
  open_picker({
    title = base and ("Changed files (base: " .. base .. ")") or "Changed files",
    results = results,
    cwd = cwd,
    counts = counts,
    base = base,
  })
end

-- ===================== telescope integration =====================

local patched = false

function M.setup()
  if patched then
    return
  end
  set_legend_highlights()
  local ok, make_entry = pcall(require, "telescope.make_entry")
  if not ok then
    return
  end
  local original = make_entry.gen_from_file
  make_entry.gen_from_file = function(opts)
    opts = opts or {}
    local cwd = opts.cwd or vim.fn.getcwd()
    local codes = refresh_codes(cwd)
    local base_maker = original(opts)
    return function(line)
      local e = base_maker(line)
      if not e then
        return nil
      end
      local path = e.value
      if type(path) == "string" then
        path = path:gsub("^%./", "")
      end
      local code = codes[path]
      local prefix_text, prefix_hls = format_prefix(code)
      local pad = prefix_text .. " "
      local plen = #pad
      local base_display = e.display
      e.display = function(entry)
        local d, base_hl
        if type(base_display) == "function" then
          d, base_hl = base_display(entry)
        else
          d = base_display or entry.value
        end
        local text = pad .. (d or "")
        local hls = {}
        for _, ph in ipairs(prefix_hls) do
          table.insert(hls, ph)
        end
        if base_hl then
          for _, h in ipairs(base_hl) do
            table.insert(hls, { { h[1][1] + plen, h[1][2] + plen }, h[2] })
          end
        end
        return text, hls
      end
      return e
    end
  end
  patched = true
end

return M
