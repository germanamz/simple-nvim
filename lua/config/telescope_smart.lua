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
local path_util = require("util.path")

-- ===================== helpers =====================

local function parse_status_path(raw)
  local arrow = raw:find(" %-> ")
  if arrow then
    raw = raw:sub(arrow + 4)
  end
  return (raw:gsub('^"(.*)"$', "%1"))
end

-- ===================== git status / counts =====================

M._parse_status_path = parse_status_path
M._format_prefix = git_status_codes.code_to_display

-- Apply `git status --porcelain` lines to per-path XY codes and worktree counts.
-- Pure (no shellout) so the sync and async fetch paths share it.
local function apply_worktree_lines(lines, codes, counts)
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

-- Sync fetch + parse of `git status --porcelain`.
-- --untracked-files=all lists each untracked file individually; without it git
-- collapses a fully-untracked directory to a single "dir/" entry, which would
-- show (and try to open) the directory instead of the new file.
local function parse_worktree_status(root, codes, counts)
  local lines, ok = git.run({ "status", "--porcelain", "--untracked-files=all" }, { cwd = root })
  if not ok then
    return
  end
  apply_worktree_lines(lines, codes, counts)
end

-- Apply `git diff --name-status base..HEAD` lines to base-only 'b<letter>'
-- codes (only for paths not already changed in the worktree) and base counts.
-- Pure (no shellout) so the sync and async fetch paths share it.
local function apply_committed_lines(lines, codes, counts)
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

local function parse_committed_history(root, base, codes, counts)
  local lines, ok = git.run({ "diff", "--name-status", base .. "..HEAD" }, { cwd = root })
  if not ok then
    return
  end
  apply_committed_lines(lines, codes, counts)
end

local function fresh_counts()
  return {
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
end

function M._git_changes(root, base)
  local codes = {}
  local counts = fresh_counts()

  parse_worktree_status(root, codes, counts)
  if base and review_base.resolve(root, base) then
    parse_committed_history(root, base, codes, counts)
  end

  return codes, counts
end

local function split_lines(s)
  return vim.split(s or "", "\n", { trimempty = true })
end

-- Async sibling of _git_changes: fetch `git status` (and, when a base is set,
-- `git diff`) via vim.system so the UI never blocks on git over a large
-- superproject tree. vim.system callbacks run in a fast context where most of
-- the API is off-limits, so all parsing is vim.schedule'd back onto the main
-- loop. Calls cb(codes, counts).
local function git_changes_async(root, base, cb)
  local function finish(wt_lines, df_lines)
    local codes, counts = {}, fresh_counts()
    apply_worktree_lines(wt_lines, codes, counts)
    if df_lines then
      apply_committed_lines(df_lines, codes, counts)
    end
    cb(codes, counts)
  end
  vim.system(
    { "git", "-C", root, "status", "--porcelain", "--untracked-files=all" },
    { text = true },
    function(wt)
      local wt_lines = wt.code == 0 and split_lines(wt.stdout) or {}
      vim.schedule(function()
        if base and review_base.resolve(root, base) then
          vim.system(
            { "git", "-C", root, "diff", "--name-status", base .. "..HEAD" },
            { text = true },
            function(df)
              local df_lines = df.code == 0 and split_lines(df.stdout) or {}
              vim.schedule(function()
                finish(wt_lines, df_lines)
              end)
            end
          )
        else
          finish(wt_lines, nil)
        end
      end)
    end
  )
end

-- The command that lists every file from the cwd. rg/fd honor each (sub)repo's
-- .gitignore; the `find` fallback honors nothing, so it gets explicit excludes
-- for the heavy dirs a polyglot superproject is full of — a bare find would
-- otherwise walk every node_modules / target / .venv across every submodule.
local function list_all_cmd()
  if vim.fn.executable("rg") == 1 then
    return { "rg", "--files", "--hidden", "--glob", "!.git" }
  elseif vim.fn.executable("fd") == 1 then
    return { "fd", "--type", "f", "--hidden", "--exclude", ".git" }
  else
    return {
      "find",
      ".",
      "-type",
      "f",
      "-not",
      "-path",
      "*/.git/*",
      "-not",
      "-path",
      "*/node_modules/*",
      "-not",
      "-path",
      "*/.venv/*",
      "-not",
      "-path",
      "*/target/*",
      "-not",
      "-path",
      "*/build/*",
      "-not",
      "-path",
      "*/dist/*",
    }
  end
end

function M._list_all()
  return vim.fn.systemlist(list_all_cmd())
end

-- Async sibling of _list_all: stream the file list off the main thread so a big
-- superproject doesn't freeze the editor while a picker is opening.
function M._list_all_async(cwd, cb)
  vim.system(list_all_cmd(), { cwd = cwd, text = true }, function(out)
    local files = out.code == 0 and split_lines(out.stdout) or {}
    vim.schedule(function()
      cb(files)
    end)
  end)
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
  return vim.uv.hrtime() / 1e6
end

-- Async core: resolve root, fetch git changes off the main thread, rewrite the
-- per-path keys relative to cwd, store them in the cache, then hand them to cb.
local function refresh_codes_async(cwd, cb)
  cwd = cwd or vim.fn.getcwd()
  local root = git.root(cwd)
  if not root then
    cache = { codes = {}, counts = nil, base = nil, root = nil, cwd = cwd, time = ms_now() }
    if cb then
      cb({}, nil, nil, nil)
    end
    return
  end
  local base = review_base.get(root)
  git_changes_async(root, base, function(raw_codes, counts)
    local codes = {}
    for p, c in pairs(raw_codes) do
      codes[path_util.relative(root .. "/" .. p, cwd)] = c
    end
    cache = { codes = codes, counts = counts, base = base, root = root, cwd = cwd, time = ms_now() }
    if cb then
      cb(codes, counts, base, root)
    end
  end)
end
M._refresh_async = refresh_codes_async

-- Non-blocking read of the codes cache. On a fresh hit it returns immediately;
-- otherwise it kicks a deduped async refresh and returns whatever is cached now
-- (possibly empty, or for a prior cwd). Consumers that need the fresh result
-- listen for `User SmartCodesRefreshed`. Nothing here shells out synchronously
-- for git status — that synchronous call was the picker/tree open-time freeze.
local refreshing = {}

local function refresh_codes(cwd, force)
  cwd = cwd or vim.fn.getcwd()
  local now = ms_now()
  if not force and cache.cwd == cwd and (now - cache.time) < 500 then
    return cache.codes, cache.counts, cache.base, cache.root
  end
  if not refreshing[cwd] then
    refreshing[cwd] = true
    refresh_codes_async(cwd, function()
      refreshing[cwd] = nil
      vim.api.nvim_exec_autocmds("User", { pattern = "SmartCodesRefreshed", data = { cwd = cwd } })
    end)
  end
  if cache.cwd == cwd then
    return cache.codes, cache.counts, cache.base, cache.root
  end
  local root = git.root(cwd)
  local base = root and review_base.get(root) or nil
  return {}, nil, base, root
end

function M._refresh(cwd, force)
  return refresh_codes(cwd, force)
end

-- ===================== highlights & legend =====================

local function set_legend_highlights()
  git_status_codes.define_highlights()
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
      vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, r[2], { end_col = r[3], hl_group = r[1] })
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

-- Both pickers fetch git status (and the file list) asynchronously and open in
-- the callback: the editor never blocks while git/rg run over the superproject,
-- and by the time open_picker builds its entries the cache is fresh, so the
-- status prefixes (via the patched gen_from_file) are correct on first render.
function M.smart_files()
  local cwd = vim.fn.getcwd()
  local codes_res, files_res
  local function maybe_open()
    if not (codes_res and files_res) then
      return
    end
    local base = codes_res.base
    open_picker({
      title = base and ("Files (base: " .. base .. ")") or "Files",
      results = M._merge_results(codes_res.codes, files_res),
      cwd = cwd,
      counts = codes_res.counts,
      base = base,
    })
  end
  refresh_codes_async(cwd, function(codes, counts, base)
    codes_res = { codes = codes, counts = counts, base = base }
    maybe_open()
  end)
  M._list_all_async(cwd, function(files)
    files_res = files or {}
    maybe_open()
  end)
end

function M.smart_files_changed()
  local cwd = vim.fn.getcwd()
  refresh_codes_async(cwd, function(codes, counts, base, root)
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
  end)
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
