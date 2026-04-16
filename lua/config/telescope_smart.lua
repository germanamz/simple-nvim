local M = {}

local function git_root()
  local out = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 then return nil end
  return out[1]
end

local function git_changes(root)
  local staged, modified, untracked = {}, {}, {}
  local st = vim.fn.systemlist({ "git", "-C", root, "diff", "--cached", "--name-only" })
  if vim.v.shell_error == 0 then
    for _, f in ipairs(st) do if f ~= "" then staged[f] = true end end
  end
  local md = vim.fn.systemlist({ "git", "-C", root, "diff", "--name-only" })
  if vim.v.shell_error == 0 then
    for _, f in ipairs(md) do if f ~= "" then modified[f] = true end end
  end
  local ut = vim.fn.systemlist({ "git", "-C", root, "ls-files", "--others", "--exclude-standard" })
  if vim.v.shell_error == 0 then
    for _, f in ipairs(ut) do if f ~= "" then untracked[f] = true end end
  end
  return staged, modified, untracked
end

local function list_all()
  if vim.fn.executable("rg") == 1 then
    return vim.fn.systemlist({ "rg", "--files", "--hidden", "--glob", "!.git" })
  elseif vim.fn.executable("fd") == 1 then
    return vim.fn.systemlist({ "fd", "--type", "f", "--hidden", "--exclude", ".git" })
  else
    return vim.fn.systemlist({ "find", ".", "-type", "f", "-not", "-path", "*/.git/*" })
  end
end

local function set_legend_highlights()
  vim.api.nvim_set_hl(0, "SmartFilesStaged",    { fg = "#5aa0d4", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesModified",  { fg = "#5ea872", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesUntracked", { fg = "#d4a84e", bold = true, default = true })
  vim.api.nvim_set_hl(0, "SmartFilesLegend",    { fg = "#888888", default = true })
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

local function open_legend()
  close_legend()
  set_legend_highlights()
  local text = " ◆ staged   ● modified   ○ untracked "
  legend_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(legend_buf, 0, -1, false, { text })
  local ns = vim.api.nvim_create_namespace("smart_files_legend")
  -- each icon (◆●○) is 3 bytes
  local function add_hl(group, s, e)
    vim.api.nvim_buf_add_highlight(legend_buf, ns, group, 0, s, e)
  end
  add_hl("SmartFilesStaged",    1,  4)
  add_hl("SmartFilesLegend",    4, 14)
  add_hl("SmartFilesModified", 14, 17)
  add_hl("SmartFilesLegend",   17, 29)
  add_hl("SmartFilesUntracked", 29, 32)
  add_hl("SmartFilesLegend",   32, #text)

  local width = vim.api.nvim_strwidth(text)
  legend_win = vim.api.nvim_open_win(legend_buf, false, {
    relative = "editor",
    row = vim.o.lines - 4,
    col = math.floor((vim.o.columns - width - 2) / 2),
    width = width,
    height = 1,
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
  local staged, modified, untracked = {}, {}, {}
  if root then staged, modified, untracked = git_changes(root) end

  local seen, results = {}, {}
  for f, _ in pairs(staged)    do if not seen[f] then seen[f] = true; table.insert(results, f) end end
  for f, _ in pairs(modified)  do if not seen[f] then seen[f] = true; table.insert(results, f) end end
  for f, _ in pairs(untracked) do if not seen[f] then seen[f] = true; table.insert(results, f) end end
  local all = list_all()
  if vim.v.shell_error == 0 then
    for _, f in ipairs(all) do
      f = f:gsub("^%./", "")
      if not seen[f] then seen[f] = true; table.insert(results, f) end
    end
  end

  local entry_maker = make_entry.gen_from_file({ cwd = vim.fn.getcwd() })

  pickers.new({}, {
    prompt_title = "Files",
    finder = finders.new_table({
      results = results,
      entry_maker = function(line)
        local e = entry_maker(line)
        local icon, hl
        if staged[line] then icon, hl = "◆ ", "SmartFilesStaged"
        elseif modified[line] then icon, hl = "● ", "SmartFilesModified"
        elseif untracked[line] then icon, hl = "○ ", "SmartFilesUntracked"
        end
        if icon then
          local base = e.display
          e.display = function(entry)
            local d, base_hl
            if type(base) == "function" then d, base_hl = base(entry) else d = base or entry.value end
            local text = icon .. d
            local hls = { { { 0, #icon }, hl } }
            if base_hl then
              for _, h in ipairs(base_hl) do
                table.insert(hls, { { h[1][1] + #icon, h[1][2] + #icon }, h[2] })
              end
            end
            return text, hls
          end
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
  }):find()

  open_legend()
end

return M
