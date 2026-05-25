-- Smart file picker with git-status-aware prefixes.
--
-- Each file in the picker gets a 2-character prefix that mirrors
-- `git status --porcelain` exactly, so what you see in the picker is what
-- you would see at the command line:
--
--     X = staged status (index slot)
--     Y = worktree status
--     space ' ' = no change in that slot
--
-- Letter meanings (any slot):
--     A — added     (green)
--     M — modified  (blue)
--     D — deleted   (gray)
--     R — renamed   (teal)
--     ? — untracked (brown; only ever appears as "??")
--
-- Common combinations:
--     'A '   staged add
--     ' M'   worktree modification (unstaged)
--     'M '   staged modification
--     'MM'   staged then further worktree modification (hybrid)
--     'AM'   staged add then worktree modification (hybrid)
--     ' D'   worktree delete (unstaged)
--     'D '   staged delete
--     'R '   staged rename
--     '??'   untracked
--
-- When a review base is set (see config.review_base), files that differ
-- from the base branch but have no current uncommitted change get a 'b'
-- prefix in the index slot:
--
--     'bA'   added in a commit since base
--     'bM'   modified in a commit since base
--     'bD'   deleted in a commit since base
--     'bR'   renamed in a commit since base
--
-- For hybrid states (e.g. 'AM'), the prefix color reflects the index slot
-- letter, matching IntelliJ's convention. Files with no change have a
-- blank 2-character pad ('  ') so filename columns stay aligned.

local M = {}

local review_base = require("config.review_base")

local function git_root()
  local out = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })
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

local function hl_for_code(code)
  if code == "??" then
    return "SmartFilesUntracked"
  end
  if code:sub(1, 1) == "b" then
    return hl_for_letter(code:sub(2, 2))
  end
  local x = code:sub(1, 1)
  if x ~= " " then
    return hl_for_letter(x)
  end
  return hl_for_letter(code:sub(2, 2))
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

local function set_legend_highlights()
  vim.api.nvim_set_hl(0, "SmartFilesAdded", { fg = "#6cc070", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesUntracked", { fg = "#c08850", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesModified", { fg = "#5a8ed4", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesDeleted", { fg = "#9a9a9a", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesRenamed", { fg = "#4cb0a0", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesBase", { fg = "#b58fd4", bold = true, default = true })
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
  if separator and #text > 1 then
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

local function open_legend(counts, base)
  close_legend()
  set_legend_highlights()

  local type_segments = {
    { icon = "A", icon_hl = "SmartFilesAdded", count = counts.added, label = "added" },
    { icon = "M", icon_hl = "SmartFilesModified", count = counts.modified, label = "modified" },
    { icon = "D", icon_hl = "SmartFilesDeleted", count = counts.deleted, label = "deleted" },
    { icon = "R", icon_hl = "SmartFilesRenamed", count = counts.renamed, label = "renamed" },
    { icon = "??", icon_hl = "SmartFilesUntracked", count = counts.untracked, label = "untracked" },
  }
  local scope_segments = {
    { icon = "X ", icon_hl = "SmartFilesLegend", count = counts.staged, label = "staged" },
    { icon = " X", icon_hl = "SmartFilesLegend", count = counts.unstaged, label = "unstaged" },
  }
  if base then
    table.insert(scope_segments, {
      icon = "bX",
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

  local lines, ranges_by_line = {}, {}
  local function push(segs)
    if #segs == 0 then
      return
    end
    local text, ranges = " ", {}
    for i, seg in ipairs(segs) do
      text = append_segment(text, ranges, seg, i > 1 and "   " or nil)
    end
    text = text .. " "
    table.insert(lines, text)
    table.insert(ranges_by_line, ranges)
  end
  push(types)
  push(scopes)

  if #lines == 0 then
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

  local width = 0
  for _, t in ipairs(lines) do
    local w = vim.api.nvim_strwidth(t)
    if w > width then
      width = w
    end
  end
  legend_win = vim.api.nvim_open_win(legend_buf, false, {
    relative = "editor",
    row = vim.o.lines - #lines - 3,
    col = math.floor((vim.o.columns - width - 2) / 2),
    width = width,
    height = #lines,
    style = "minimal",
    border = "rounded",
    focusable = false,
    noautocmd = true,
    zindex = 250,
  })
end

function M.smart_files()
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local make_entry = require("telescope.make_entry")

  set_legend_highlights()

  local root = git_root()
  local base = root and review_base.get(root) or nil
  local codes, counts = {}, {
    added = 0,
    modified = 0,
    deleted = 0,
    renamed = 0,
    untracked = 0,
    staged = 0,
    unstaged = 0,
    committed = 0,
  }
  if root then
    codes, counts = M._git_changes(root, base)
  end

  local all = M._list_all()
  if vim.v.shell_error ~= 0 then
    all = {}
  end
  local results = M._merge_results(codes, all)

  local entry_maker = make_entry.gen_from_file({ cwd = vim.fn.getcwd() })

  pickers
    .new({}, {
      prompt_title = base and ("Files (base: " .. base .. ")") or "Files",
      finder = finders.new_table({
        results = results,
        entry_maker = function(line)
          local e = entry_maker(line)
          local code = codes[line]
          local prefix = (code or "  ") .. " "
          local prefix_len = #prefix
          local code_hl = code and hl_for_code(code) or nil
          local base_display = e.display
          e.display = function(entry)
            local d, base_hl
            if type(base_display) == "function" then
              d, base_hl = base_display(entry)
            else
              d = base_display or entry.value
            end
            local text = prefix .. d
            local hls = {}
            if code and code_hl then
              table.insert(hls, { { 0, #code }, code_hl })
            end
            if base_hl then
              for _, h in ipairs(base_hl) do
                table.insert(hls, { { h[1][1] + prefix_len, h[1][2] + prefix_len }, h[2] })
              end
            end
            return text, hls
          end
          return e
        end,
      }),
      sorter = conf.file_sorter({}),
      previewer = conf.file_previewer({}),
      attach_mappings = function(prompt_bufnr, _)
        vim.api.nvim_create_autocmd({ "BufWipeout", "BufLeave" }, {
          buffer = prompt_bufnr,
          once = true,
          callback = close_legend,
        })
        return true
      end,
    })
    :find()

  open_legend(counts, base)
end

return M
