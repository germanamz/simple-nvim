-- Global statusline. Eagerly loaded so it works in buffers that don't trigger
-- file-oriented events (e.g. netrw, which doesn't fire BufReadPre/BufNewFile
-- and therefore wouldn't lazy-load gitsigns or any statusline setup gated on
-- it). Branch and review base are cached per-buffer to avoid running git on
-- every redraw, and refreshed asynchronously so BufEnter never blocks on a
-- process spawn.
local M = {}

local path = require("util.path")
local git = require("util.git")

-- Bounds the async rev-parse spawn. The FocusGained sweep's in-flight guard
-- only releases via refresh_dir's on_done, so an unbounded spawn hung on a
-- network gitdir would wedge the guard and silently drop every future sweep.
local GIT_TIMEOUT_MS = 10000

-- Resolve repo toplevel, HEAD sha, and branch in one git spawn, off the main
-- thread, and fan the result out to every buffer in `bufs` — the answer is a
-- function of `dir` alone, so buffers sharing a start dir share one spawn.
-- `--show-toplevel` prints even when the HEAD lookups fail (e.g. a repo
-- with no commits yet), so the toplevel is parsed regardless of exit code and
-- the sha/branch only on success. Detached HEAD prints "HEAD" → treated as none.
-- The sha is only used to seed config.git_head's watcher (which gates on it).
-- `on_done` fires exactly once in every outcome — result applied, spawn failed
-- or timed out, or the fan-out itself errored — because the FocusGained
-- sweep's in-flight guard hangs off it and must never wedge.
local function refresh_dir(dir, bufs, on_done)
  local cmd = {
    "git",
    "-C",
    dir,
    "rev-parse",
    "--show-toplevel",
    "HEAD",
    "--abbrev-ref",
    "HEAD",
  }
  local spawned = pcall(vim.system, cmd, { text = true, timeout = GIT_TIMEOUT_MS }, function(out)
    local lines = vim.split(out.stdout or "", "\n", { trimempty = true })
    -- exit 0 prints { toplevel, sha, branch-or-"HEAD" }; a no-commit repo exits
    -- nonzero with just { toplevel } (no sha), and outside a repo prints nothing.
    -- The sha is resolved here only to seed the HEAD watcher in one spawn.
    local root = lines[1]
    local sha = (out.code == 0) and lines[2] or nil
    local branch = (out.code == 0 and lines[3]) or ""
    if branch == "HEAD" then
      branch = ""
    end
    vim.schedule(function()
      local ok, err = pcall(function()
        local base = (root and require("config.review_base").get(root)) or ""
        for _, buf in ipairs(bufs) do
          if vim.api.nvim_buf_is_valid(buf) then
            vim.b[buf].nvim_review_base = base
            vim.b[buf].nvim_git_branch = (root and branch) or ""
          end
        end
        -- Lazily start the repo's HEAD watcher; its HeadChanged broadcast drives
        -- refresh_all_buffers, so external checkouts repaint without waiting for
        -- a buffer event. Hand it the {sha, branch} we just resolved so its first
        -- watch doesn't re-spawn git.head (normalize detached/unborn "" → nil).
        if root then
          require("config.git_head").watch(
            root,
            { sha = sha, branch = branch ~= "" and branch or nil }
          )
        end
        vim.cmd("redrawstatus!")
      end)
      if on_done then
        on_done()
      end
      if not ok then
        vim.notify("statusline: refresh fan-out failed: " .. tostring(err), vim.log.levels.WARN)
      end
    end)
  end)
  if not spawned then
    for _, buf in ipairs(bufs) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.b[buf].nvim_review_base = ""
        vim.b[buf].nvim_git_branch = ""
      end
    end
    if on_done then
      on_done()
    end
  end
end

local function refresh(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  refresh_dir(path.buf_start_dir(buf), { buf })
end

-- Refresh loaded buffers' cached branch/base and repaint the statusline. With a
-- `root` (the data.root a HeadChanged/ReviewBaseChanged carries) only buffers in
-- that repo are re-resolved: a checkout or base change in one submodule can't
-- move another submodule's branch/base, so re-spawning git for every buffer
-- across every submodule is wasted work. nil sweeps all loaded buffers (the
-- VimEnter startup pass and the <leader>gR manual refresh, where any root may
-- have changed). The buffer-list scan itself stays O(buffers) — cheap, and
-- buf_in_root's root resolution is memoized.
local function refresh_all_buffers(root, on_done)
  -- Group buffers by their spawn key (start dir): N buffers in one directory
  -- get identical git answers, so the sweep costs one spawn per unique
  -- directory (fanned out by refresh_dir), not one per buffer.
  local groups = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and (root == nil or git.buf_in_root(buf, root)) then
      local dir = path.buf_start_dir(buf)
      groups[dir] = groups[dir] or {}
      table.insert(groups[dir], buf)
    end
  end
  local pending = vim.tbl_count(groups)
  local function dir_done()
    pending = pending - 1
    if pending == 0 and on_done then
      on_done()
    end
  end
  if pending == 0 and on_done then
    on_done()
  end
  for dir, bufs in pairs(groups) do
    refresh_dir(dir, bufs, dir_done)
  end
  vim.cmd("redrawstatus!")
end

-- Public manual-refresh entry point for the <leader>gR git refresh keymap. Does
-- the same work as the event-driven path (ReviewBaseChanged/HeadChanged):
-- re-resolve every loaded buffer's branch/base and repaint the statusline.
M.refresh_all = refresh_all_buffers

function _G.git_branch_status()
  -- nvim_git_branch is kept live by config.git_head's watcher (HeadChanged →
  -- refresh) and exists for every buffer, attached or not; gitsigns_head is
  -- the fallback for roots where that watcher could not start.
  local head = vim.b.nvim_git_branch
  if not head or head == "" then
    head = vim.b.gitsigns_head
  end
  local base = vim.b.nvim_review_base
  local has_head = head and head ~= ""
  local has_base = base and base ~= ""
  if not has_head and not has_base then
    return ""
  end
  if has_head and has_base then
    return string.format(" %s ↗ %s ", head, base)
  end
  if has_head then
    return string.format(" %s ", head)
  end
  return string.format(" ↗ %s ", base)
end

-- Stubs overridden by their owning plugins once loaded. Keeps the statusline
-- format string safe to evaluate before those plugins attach.
if not _G.lsp_refs_status then
  _G.lsp_refs_status = function()
    return ""
  end
end
if not _G.gitsigns_hunks_status then
  _G.gitsigns_hunks_status = function()
    return ""
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("nvim_statusline", { clear = true })
  -- FocusGained catches what the HEAD watcher can't: a review base changed by
  -- another nvim instance (the JSON store is shared), or a root whose watcher
  -- failed to start. Best-effort — it needs the terminal (and tmux's
  -- focus-events option) to forward focus.
  -- BufEnter only needs to resolve a buffer's branch/base the first time it is
  -- seen; afterward the HEAD watcher (HeadChanged) and ReviewBaseChanged keep it
  -- live, so re-spawning git on every buffer switch is wasted work. nil = never
  -- resolved, "" = resolved-to-none. BufWritePost is dropped entirely — a write
  -- changes neither branch nor base.
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(args)
      if vim.b[args.buf].nvim_git_branch == nil then
        refresh(args.buf)
      end
    end,
  })
  -- A cwd change can move which repo an unnamed buffer resolves to — but only
  -- the current buffer's resolution, so refresh just that one.
  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function(args)
      refresh(args.buf)
    end,
  })
  -- FocusGained is the cross-instance net (another nvim changed the shared
  -- review-base store, or a watcher that never started) — and that can move
  -- ANY loaded buffer's branch/base, not just the focused one, while the
  -- BufEnter gate above never re-resolves an already-resolved buffer. Sweep
  -- them all (async spawns, and focus events are rare — once per alt-tab).
  -- Focus can bounce faster than a sweep completes (tmux pane hopping), and a
  -- sweep already in flight will deliver the same answers — so a second
  -- FocusGained is dropped until the current sweep's results have landed.
  local sweeping = false
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      if sweeping then
        return
      end
      sweeping = true
      refresh_all_buffers(nil, function()
        sweeping = false
      end)
    end,
  })
  -- Netrw sets a window-local statusline (after FileType fires) that overrides
  -- the global one even with laststatus=3. Defer the clear so it runs after
  -- netrw's own setup, and re-clear on every BufWinEnter since netrw also
  -- reapplies its statusline when re-rendering the listing.
  local function clear_netrw_statusline(buf)
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if vim.bo[buf].filetype ~= "netrw" then
        return
      end
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        vim.api.nvim_set_option_value("statusline", "", { win = win })
      end
    end)
  end
  vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter", "BufEnter" }, {
    group = group,
    callback = function(args)
      if vim.bo[args.buf].filetype ~= "netrw" then
        return
      end
      -- Only FileType reliably resolves the actually-browsed directory: a subdir
      -- buffer's name is empty at BufEnter/BufWinEnter, so refresh there would
      -- resolve the cwd, not the browsed submodule. Re-clearing the statusline
      -- must still run on every event since netrw reapplies it on each render.
      if args.event == "FileType" then
        refresh(args.buf)
      end
      clear_netrw_statusline(args.buf)
    end,
  })

  -- When nvim starts directly into netrw (e.g. `nvim .`), BufEnter for the
  -- netrw buffer can fire before this augroup is registered. Refresh once
  -- after startup completes so the initial buffer has branch/base populated.
  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    callback = function()
      refresh_all_buffers()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "ReviewBaseChanged", "HeadChanged" },
    callback = function(args)
      -- Both events carry the repo root they apply to; scope the refresh to that
      -- root's buffers (a different submodule's branch/base is untouched).
      refresh_all_buffers(args.data and args.data.root or nil)
    end,
  })
  -- Startup is covered by the VimEnter pass above (which also handles starting
  -- directly into netrw); no separate immediate refresh needed here.

  vim.o.statusline =
    "%f %m%r   %{v:lua.git_branch_status()}%=%{v:lua.lsp_refs_status()}%{v:lua.gitsigns_hunks_status()} %y %l:%c %p%% "
end

return M
