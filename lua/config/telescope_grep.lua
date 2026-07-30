-- Where the grep pickers search. Two scopes, one module:
--
--   root()   — the repo toplevel (cwd when outside a repo), the scope <leader>fg
--              and <leader>fs use so results always cover the whole project even
--              if the cwd has drifted from where nvim was launched.
--   prompt() — <leader>fG: the same live_grep narrowed to ONE directory, asked
--              for through vim.ui.input so the path is editable before it runs.
--
-- The prompt is seeded rather than blank: pressed in nvim-tree it starts on the
-- node under the cursor, anywhere else on the focused buffer's own directory.
-- That makes the common case ("this folder") a single <CR> while still letting
-- you backspace a component to widen, or type a path that is nowhere near where
-- the cursor happens to be.
local M = {}

-- Repo toplevel for the focused window's cwd, falling back to the cwd itself
-- outside a repo. Note this is the *cwd's* repo, not the focused buffer's — a
-- grep is a project-wide verb, so it deliberately does not narrow to the
-- submodule a buffer happens to live in (unlike the review-base keys, which do).
function M.root()
  return require("util.git").root() or vim.fn.getcwd()
end

-- Directory the <leader>fG prompt opens on.
--
-- In the tree, the node under the cursor: its own path when it is a directory,
-- else its parent, so pressing the key on a file means "the folder holding it".
-- Membership is probed with isdirectory() rather than read off node.type
-- because nvim-tree hands out field-only clones of its nodes whose shape is not
-- guaranteed (see config.nvim_tree_hl_decorator) — the filesystem is the
-- authority here anyway.
--
-- Everywhere else util.path.buf_start_dir, the same buffer -> directory ladder
-- (own path if a directory, else parent, else cwd) that statusline and gitsigns
-- resolve roots from, so an unnamed or scratch buffer degrades to the cwd
-- instead of producing a bogus seed.
function M.seed()
  if vim.bo.filetype == "NvimTree" then
    local ok, api = pcall(require, "nvim-tree.api")
    local node = ok and api.tree.get_node_under_cursor()
    local path = node and node.absolute_path
    if path and path ~= "" then
      if vim.fn.isdirectory(path) == 1 then
        return path
      end
      return vim.fn.fnamemodify(path, ":h")
    end
  end
  return require("util.path").buf_start_dir(0)
end

-- Open live_grep scoped to `dir`. Accepts what a human types: ~ and $VAR are
-- expanded, a relative path resolves against the cwd (matching what the
-- prompt's "dir" completion offered), and a path pointing at a FILE collapses
-- to its parent — the same rule seed() applies to a file node, so typing a path
-- you yanked from somewhere still lands on a folder.
--
-- Returns the directory it searched, or nil when the path does not exist, so
-- callers and tests can tell a rejected path from a picker that opened.
function M.grep(dir)
  if not dir or dir == "" then
    return nil
  end
  dir = vim.fn.fnamemodify(vim.fn.expand(dir), ":p")
  if vim.fn.isdirectory(dir) == 0 then
    if vim.fn.filereadable(dir) == 0 then
      -- Trailing slash trimmed: :p adds one, and "no such directory: foo/"
      -- reads as if the slash were part of what was typed.
      vim.notify("No such directory: " .. dir:gsub("/$", ""), vim.log.levels.WARN)
      return nil
    end
    dir = vim.fn.fnamemodify(dir, ":h")
  end
  -- The title carries the scope: a scoped picker is otherwise indistinguishable
  -- from <leader>fg's, and "Live Grep" over a subtree that happens to have no
  -- matches looks like a broken project-wide grep. Shown relative to the repo
  -- root (basename when the scope IS the root) to keep it readable in deep
  -- trees; util.path.relative leaves paths outside the root absolute.
  local rel = require("util.path").relative(dir, M.root()):gsub("/$", "")
  if rel == "" then
    rel = vim.fn.fnamemodify(dir:gsub("/$", ""), ":t")
  end
  -- cwd only sets ripgrep's search dir; the pickers.live_grep additional_args
  -- from telescope's setup() still apply, so this matches <leader>fg's result
  -- set (hidden files searched, .git pruned) rather than quietly differing.
  require("telescope.builtin").live_grep({
    cwd = dir,
    prompt_title = "Live Grep (" .. rel .. ")",
  })
  return dir
end

-- Ask for a directory, seeded per seed(), then grep it. Cancelling (<Esc>, which
-- yields nil) or clearing the line opens nothing.
function M.prompt()
  -- ":." shortens to a cwd-relative path when the seed lives under the cwd and
  -- leaves it absolute otherwise, which is exactly the vocabulary the "dir"
  -- completion below speaks (it completes against the cwd). The trailing slash
  -- makes <Tab> continue INSIDE the seeded directory instead of completing its
  -- siblings.
  local seed = M.seed()
  -- ":." has no relative form for the cwd ITSELF and hands back the absolute
  -- path — a 60-char prompt line for the most ordinary seed there is (any buffer
  -- sitting at the project root, or an unnamed one). "." is the same directory,
  -- and completion continues from it identically.
  seed = seed == vim.fn.getcwd() and "." or vim.fn.fnamemodify(seed, ":.")
  if seed ~= "" and seed:sub(-1) ~= "/" then
    seed = seed .. "/"
  end
  vim.ui.input({
    prompt = "Live grep in dir: ",
    default = seed,
    completion = "dir",
  }, function(input)
    if not input or vim.trim(input) == "" then
      return
    end
    M.grep(vim.trim(input))
  end)
end

return M
