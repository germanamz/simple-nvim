-- "Changed files only" filter for nvim-tree, toggled with C in the tree. The
-- builtin C (git_clean) is inert here because builtin git is off (see
-- lua/plugins/nvim-tree.lua), so it has no status to read. This reads the
-- status the git decorator already labels from instead: config.telescope_smart's
-- per-cwd codes snapshot, which covers the files inside submodules and the
-- commit-diverged (bumped) submodules too. No extra git runs.
--
-- A file survives iff it has a code (worktree or changed since the review base,
-- the same set <leader>gs lists). A folder survives iff config.nvim_tree_git
-- would give it a */• marker, so the filter and the markers can never disagree.
-- Wired into filters.custom next to config.ignore_filter; nvim-tree evaluates it
-- synchronously per entry while scanning a directory, so it is table lookups
-- only. A cold codes cache hides everything until the async refresh lands, and
-- the existing SmartCodesRefreshed reload then re-filters with the fresh codes.
local M = {}

local git = require("util.git")
local path_util = require("util.path")
local nvim_tree_git = require("config.nvim_tree_git")

local enabled = false

-- The kept relpaths for one codes snapshot, rebuilt only when telescope_smart
-- hands back a new codes table (every refresh mints one), so the per-entry check
-- stays O(1).
local memo_codes, memo_keep

local function keep_set(codes, dirty_subs)
  if codes ~= memo_codes then
    local keep = {}
    for p in pairs(codes) do
      keep[p] = true
    end
    for dir in pairs(nvim_tree_git._dir_markers(codes, dirty_subs)) do
      keep[dir] = true
    end
    memo_codes, memo_keep = codes, keep
  end
  return memo_keep
end

function M.is_enabled()
  return enabled
end

-- THE FILTER. Returns true to HIDE. Fails open (shows) wherever there is no
-- status to judge by: outside a repo, the cwd itself, and paths outside the cwd
-- (the codes are cwd-relative, and the tree can be re-rooted above it).
function M.hides(abs)
  if not enabled then
    return false
  end
  local cwd = vim.fn.getcwd()
  -- Resolved at call time, not module load, so specs can stub _refresh.
  local codes, _, _, root, dirty_subs = require("config.telescope_smart")._refresh(cwd)
  if not root then
    return false
  end
  -- path_util.relative appends a slash to an existing directory ("src/");
  -- the kept keys are slash-free.
  local rel = path_util.relative(abs, cwd):gsub("/$", "")
  if rel == "" or rel:sub(1, 1) == "/" then
    return false
  end
  return not keep_set(codes, dirty_subs or {})[rel]
end

-- The tree window's winbar: the mappings hint, or the active filter while one is on.
function M.winbar()
  if enabled then
    return "%#DiagnosticWarn#  changed only%*%#Comment# · C to clear%*"
  end
  return "%#Comment#  g? — all mappings%*"
end

-- Re-run the tree's filters and keep the cursor on the same node (or its
-- nearest visible parent), exactly what nvim-tree's own filter toggles do.
-- Shared by C here and I (config.ignore_filter), whose flags nvim-tree does not
-- know about. No-op when the tree has never loaded.
function M.refilter()
  if not package.loaded["nvim-tree"] then
    return
  end
  local explorer = require("nvim-tree.core").get_explorer()
  if not explorer then
    return
  end
  local node = explorer:get_node_at_cursor()
  explorer:reload_explorer()
  if node then
    explorer:focus_node_or_parent(node)
  end
end

local function set_winbar()
  local win = package.loaded["nvim-tree"] and require("nvim-tree.view").get_winnr()
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_option_value("winbar", M.winbar(), { win = win })
  end
end

-- C in the tree. Turning it on expands every surviving folder from the root, so
-- each changed file is on screen after one key press; turning it off leaves
-- those folders open in the full tree. expand_all's max_folder_discovery cap
-- (300) bounds the expansion.
function M.toggle()
  if not enabled and not git.root(vim.fn.getcwd()) then
    vim.notify(require("config.review_base").MSG_NOT_A_REPO, vim.log.levels.WARN)
    return
  end
  enabled = not enabled
  M.refilter()
  if enabled and package.loaded["nvim-tree"] then
    local explorer = require("nvim-tree.core").get_explorer()
    if explorer and require("nvim-tree.api").tree.is_visible() then
      explorer:expand_all()
    end
  end
  set_winbar()
end

return M
