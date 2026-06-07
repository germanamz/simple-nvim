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
local git = require("util.git")
local git_status_codes = require("config.git_status_codes")
local Overlay = require("util.overlay")

-- ===================== helpers =====================

local function parse_status_path(raw)
  local arrow = raw:find(" %-> ")
  if arrow then
    raw = raw:sub(arrow + 4)
  end
  return (raw:gsub('^"(.*)"$', "%1"))
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

M._parse_status_path = parse_status_path
M._format_prefix = git_status_codes.code_to_display

-- Parse `git status --porcelain` into per-path XY codes and worktree counts.
local function parse_worktree_status(root, codes, counts)
  -- --untracked-files=all lists each untracked file individually; without it
  -- git collapses a fully-untracked directory to a single "dir/" entry, which
  -- would show (and try to open) the directory instead of the new file.
  local lines, ok = git.run({ "status", "--porcelain", "--untracked-files=all" }, { cwd = root })
  if not ok then
    return
  end
  for _, line in ipairs(lines) do
    if #line >= 4 then
      local x = line:sub(1, 1)
      local y = line:sub(2, 2)
      codes[parse_status_path(line:sub(4))] = x .. y

      local cat = git_status_codes.category(git_status_codes.dominant_letter(x, y))
      if cat then
        counts[cat] = counts[cat] + 1
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

-- Parse `git diff --name-status base..HEAD` into base-only 'b<letter>' codes
-- (only for paths not already changed in the worktree) and base counts.
local function parse_committed_history(root, base, codes, counts)
  local lines, ok = git.run({ "diff", "--name-status", base .. "..HEAD" }, { cwd = root })
  if not ok then
    return
  end
  for _, line in ipairs(lines) do
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
        local cat = git_status_codes.category(status_char)
        if cat and counts.base[cat] ~= nil then
          counts.base[cat] = counts.base[cat] + 1
        end
        if not codes[path] then
          codes[path] = "b" .. status_char
        end
      end
    end
  end
end

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
    base = { added = 0, modified = 0, deleted = 0, renamed = 0 },
  }

  parse_worktree_status(root, codes, counts)
  if base and review_base.resolve(root, base) then
    parse_committed_history(root, base, codes, counts)
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
  local root = git.root(cwd)
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
  vim.api.nvim_set_hl(0, "SmartFilesBase", { fg = "#d896ff", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesUnstaged", { fg = "#888888", default = true })
  vim.api.nvim_set_hl(0, "SmartFilesLegend", { fg = "#888888", default = true })
  vim.api.nvim_set_hl(0, "SmartFilesLegendCount", { fg = "#cccccc", bold = true, default = true })
end

local legend = Overlay.new()

local function close_legend()
  legend:close()
end

local function append_segment(text, ranges, seg, separator)
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
      table.insert(ranges, { seg.icon_hl or "SmartFilesLegend", s, #text })
    end
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

-- Pure: turn the counts table into the two legend rows (worktree + base),
-- dropping zero-count entries and appending a "vs <base>" trailer when a base
-- is set and has any nonzero category. Exposed for unit testing.
local function build_legend_segments(counts, base)
  local function b_icon(letter, type_hl)
    return {
      icon = "b" .. letter,
      icon_hls = { { 0, 1, "SmartFilesBase" }, { 1, 2, type_hl } },
    }
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

  local worktree = nonzero({
    { icon = "A", icon_hl = "SmartFilesAdded", count = counts.added, label = "added" },
    { icon = "M", icon_hl = "SmartFilesModified", count = counts.modified, label = "modified" },
    { icon = "D", icon_hl = "SmartFilesDeleted", count = counts.deleted, label = "deleted" },
    { icon = "R", icon_hl = "SmartFilesRenamed", count = counts.renamed, label = "renamed" },
    { icon = "?*", icon_hl = "SmartFilesUntracked", count = counts.untracked, label = "untracked" },
    { icon = "*", icon_hl = "SmartFilesUnstaged", count = counts.unstaged, label = "unstaged" },
  })

  local base_list = {}
  if base then
    local b = counts.base or {}
    base_list = nonzero({
      vim.tbl_extend("force", b_icon("A", "SmartFilesAdded"), { count = b.added, label = "added" }),
      vim.tbl_extend(
        "force",
        b_icon("M", "SmartFilesModified"),
        { count = b.modified, label = "modified" }
      ),
      vim.tbl_extend(
        "force",
        b_icon("D", "SmartFilesDeleted"),
        { count = b.deleted, label = "deleted" }
      ),
      vim.tbl_extend(
        "force",
        b_icon("R", "SmartFilesRenamed"),
        { count = b.renamed, label = "renamed" }
      ),
    })
    if #base_list > 0 then
      table.insert(base_list, { label = "vs " .. base })
    end
  end

  return { worktree = worktree, base_list = base_list }
end
M._build_legend_segments = build_legend_segments

-- Resolve the telescope results window for a prompt buffer, or nil if telescope
-- isn't loaded / the window is gone.
local function picker_results_win(prompt_bufnr)
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

-- Render the segment rows into padded statuscolumn lines + their highlights.
local function render_legend_lines(groups, width)
  local lines, ranges_by_line = {}, {}
  for _, segs in ipairs({ groups.worktree, groups.base_list }) do
    if #segs > 0 then
      local text, ranges = render_segments(segs, "   ")
      text, ranges = fit_line(text, ranges, width)
      table.insert(lines, text)
      table.insert(ranges_by_line, ranges)
    end
  end
  return lines, ranges_by_line
end

-- Create the floating legend buffer + window anchored to the bottom of the
-- telescope results window. No-op if the legend would be taller than results.
local function create_legend_window(results_win, lines, ranges_by_line)
  local pos = vim.api.nvim_win_get_position(results_win)
  local width = vim.api.nvim_win_get_width(results_win)
  local height = vim.api.nvim_win_get_height(results_win)
  if #lines > height then
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local ns = vim.api.nvim_create_namespace("smart_files_legend")
  for lnum, ranges in ipairs(ranges_by_line) do
    for _, r in ipairs(ranges) do
      vim.api.nvim_buf_add_highlight(buf, ns, r[1], lnum - 1, r[2], r[3])
    end
  end

  legend:mount(buf, {
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

local function open_legend(prompt_bufnr, counts, base)
  close_legend()
  set_legend_highlights()
  if not counts then
    return
  end
  local results_win = picker_results_win(prompt_bufnr)
  if not results_win then
    return
  end

  local groups = build_legend_segments(counts, base)
  if #groups.worktree == 0 and #groups.base_list == 0 then
    return
  end

  local width = vim.api.nvim_win_get_width(results_win)
  local lines, ranges_by_line = render_legend_lines(groups, width)
  if #lines == 0 then
    return
  end
  create_legend_window(results_win, lines, ranges_by_line)
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
      local prefix_text, prefix_hls = git_status_codes.code_to_display(code)
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
