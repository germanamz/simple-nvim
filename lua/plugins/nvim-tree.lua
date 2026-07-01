-- File-tree explorer with reveal-to-current-file. Launching nvim on a
-- directory (`nvim .`) opens nvim-tree instead of netrw; netrw is still
-- reachable on demand via init.lua's <leader>E (:Explore), which hijack_netrw
-- leaves untouched.
return {
  "nvim-tree/nvim-tree.lua",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  cmd = { "NvimTreeToggle", "NvimTreeFindFile", "NvimTreeFindFileToggle" },
  keys = {
    {
      "<leader>e",
      "<cmd>NvimTreeFindFileToggle<cr>",
      desc = "File tree (reveal current file)",
    },
  },
  -- Stay lazy for `nvim file.txt`, but when nvim is launched on a directory
  -- force the plugin to load during startup. setup() must run before the
  -- directory buffer is read so manage_netrw can strip netrw's FileExplorer
  -- autocmds and the hijack BufEnter handler is in place to win the race.
  init = function()
    if vim.fn.argc() >= 1 and vim.fn.isdirectory(vim.fn.argv(0)) == 1 then
      require("lazy").load({ plugins = { "nvim-tree.lua" } })
    end
  end,
  opts = {
    -- Take over directory buffers (so `nvim .` shows the tree) while leaving
    -- netrw's :Explore command alone for the <leader>E fallback.
    disable_netrw = false,
    hijack_netrw = true,
    -- Expand the tree to highlight whatever buffer is focused — but NOT for
    -- non-file buffers (terminals, prompts, help). Revealing crosses into
    -- whichever submodule the file lives in; with builtin git off (see the git
    -- block below) this is now a pure fs scandir — no per-submodule git spawn —
    -- and ignore-hiding is filled asynchronously by config.ignore_filter. The
    -- exclude still spares the reveal for plain buffer switches into terminals.
    update_focused_file = {
      enable = true,
      exclude = function(args)
        return vim.bo[args.buf].buftype ~= ""
      end,
    },
    view = { width = 35 },
    -- Coalesce fs-watcher churn. A superproject's many submodule .git dirs and
    -- build outputs emit bursts of events; the 50ms default reloads too eagerly.
    filesystem_watchers = { enable = true, debounce_delay = 200 },
    -- Treat the tree as an on-demand picker: close it once a file is opened so
    -- it's only visible when you're actively browsing, not all the time.
    actions = { open_file = { quit_on_open = true } },
    filters = {
      dotfiles = false, -- show dotfiles (toggle with H)
      -- Builtin git is off (below), so its git_ignored filter is inert. Hide
      -- ignored files through config.ignore_filter instead: an O(1), fork-free
      -- predicate (static heavy-dir set + lazy async `git check-ignore` oracle).
      -- Toggle with I (remapped to the custom filter in on_attach below).
      git_ignored = false,
      custom = function(p)
        return require("config.ignore_filter").is_ignored(p)
      end,
    },
    -- Builtin git is OFF. In a superproject it spawns one *synchronous*
    -- `git status --ignored` per submodule and trips a module-level, never-reset
    -- 5-timeout kill switch that *permanently* disables git integration — which
    -- silently broke the git_ignored filter "after a while" as submodule count
    -- grew. Nothing here needs builtin git: the decorator sources labels from
    -- config.telescope_smart (not Filters:git), repaints come from the autocmds
    -- in config() below (not the .git watcher), and ignore-hiding now comes from
    -- config.ignore_filter. With git off the kill switch can never fire.
    git = { enable = false },
    -- Keep all default mappings, but rebind I to toggle the custom filter (the
    -- builtin I toggles git_ignored, now inert) so ignored-visibility still
    -- toggles from its usual key.
    on_attach = function(bufnr)
      local api = require("nvim-tree.api")
      api.config.mappings.default_on_attach(bufnr)
      vim.keymap.set("n", "I", api.filter.custom.toggle, {
        buffer = bufnr,
        noremap = true,
        silent = true,
        nowait = true,
        desc = "nvim-tree: Toggle Filter: Ignored (custom)",
      })
    end,
    -- The "Diagnostics" decorator listed in renderer.decorators below is inert
    -- unless diagnostics integration is enabled here.
    diagnostics = { enable = true },
  },
  config = function(_, opts)
    -- Swap the builtin Git decorator for the smart-picker-aligned one (same
    -- porcelain labels, same review base — see config.nvim_tree_git). Built
    -- here, not in `opts`, because the decorator class extends nvim-tree.api
    -- and so can only be created once the plugin is loaded.
    opts.renderer = {
      decorators = {
        "Open",
        "Hidden",
        "Modified",
        "Bookmark",
        "Diagnostics",
        "Copied",
        require("config.nvim_tree_git").decorator(),
        "Cut",
      },
    }
    require("nvim-tree").setup(opts)
    -- Subscribe to nvim-tree's rename/move/delete events and forward them to
    -- the LSP (workspace/willRenameFiles). Deferred to here — not the plugin's
    -- own config — so it only runs once nvim-tree is loaded, keeping nvim-tree
    -- lazy. The matching capabilities are advertised at startup in lsp.lua.
    require("lsp-file-operations").setup()
    -- Pin a one-line hint to the top of the tree window. nvim-tree sets the
    -- buffer's filetype in a scratch window before moving it to the side
    -- window, so a FileType hook targets the wrong window — use TreeOpen,
    -- which fires once the real window exists.
    local api = require("nvim-tree.api")
    api.events.subscribe(api.events.Event.TreeOpen, function()
      local win = require("nvim-tree.view").get_winnr()
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_option_value("winbar", "%#Comment#  g? — all mappings%*", { win = win })
      end
    end)
    -- Trailing-slash- and symlink-insensitive directory compare. The decorator
    -- renders with self.cwd = fnamemodify(getcwd, ":p"), so the SmartCodesRefreshed
    -- event below carries a data.cwd with a TRAILING SLASH that getcwd() lacks: a
    -- raw `==` never matched, so that handler's reload was silently skipped. It
    -- went unnoticed only because nvim-tree's builtin git supplied its own redraws;
    -- with builtin git off (see opts.git) this handler is the sole repaint path, so
    -- normalize both ends.
    local function same_dir(a, b)
      return vim.fn.resolve(vim.fn.fnamemodify(a, ":p"))
        == vim.fn.resolve(vim.fn.fnamemodify(b, ":p"))
    end
    -- Re-render the tree when the review base or HEAD changes (external
    -- checkout) so labels appear or vanish immediately. Force-refresh the
    -- codes cache first — its 500ms TTL could otherwise serve codes computed
    -- against the old base or branch.
    vim.api.nvim_create_autocmd("User", {
      pattern = { "ReviewBaseChanged", "HeadChanged" },
      callback = function(args)
        -- Both events carry their repo root in data.root and fire per-submodule
        -- (each watched root has its own HEAD watcher). The decorator only ever
        -- computes codes for getcwd(), so a change in a *different* root can't
        -- alter any displayed label — skip the refresh for it. resolve() both
        -- sides so a symlinked cwd still matches.
        local root = args.data and args.data.root
        if root and vim.fn.resolve(root) ~= vim.fn.resolve(vim.fn.getcwd()) then
          return
        end
        if not api.tree.is_visible() then
          return
        end
        -- Fetch fresh codes for the new base/HEAD off the main thread, then
        -- reload so the decorator repaints with them. Going through the async
        -- core directly (not the deduped non-blocking read) guarantees a refresh
        -- with the *current* inputs even if a prior refresh is still in flight.
        require("config.telescope_smart")._refresh_async(vim.fn.getcwd(), function()
          if api.tree.is_visible() then
            api.tree.reload()
          end
        end)
      end,
    })
    -- The codes cache now refreshes asynchronously, so the decorator's first
    -- render on a cold cache shows no git labels. When a refresh for the
    -- displayed cwd lands, reload the tree so the labels appear. The reload runs
    -- a fresh decorator pass that reads the now-warm cache (no further async
    -- kick), so this does not loop.
    vim.api.nvim_create_autocmd("User", {
      pattern = "SmartCodesRefreshed",
      callback = function(args)
        local cwd = args.data and args.data.cwd
        if cwd and same_dir(cwd, vim.fn.getcwd()) and api.tree.is_visible() then
          api.tree.reload()
        end
      end,
    })
    -- Re-sync the git decorations when focus returns to nvim. A commit or
    -- `git add` from another terminal changes file status without moving HEAD,
    -- so config.git_head's HEAD watcher never fires ReviewBaseChanged/HeadChanged
    -- and the labels would stay stale until a manual reload. Force-refresh the
    -- codes cache for the cwd off the main thread, then reload so the decorator
    -- repaints. Only when the tree is on screen — skip the git spawn otherwise.
    -- (gitsigns hunks and the statusline re-sync on the same FocusGained event
    -- from their own modules.)
    vim.api.nvim_create_autocmd("FocusGained", {
      callback = function()
        if not api.tree.is_visible() then
          return
        end
        require("config.telescope_smart")._refresh_async(vim.fn.getcwd(), function()
          if api.tree.is_visible() then
            api.tree.reload()
          end
        end)
      end,
    })
    -- The tree stays put while a Telescope picker is open; it's dismissed only
    -- when a file is actually opened — from the tree (quit_on_open above) or
    -- from a picker (the select mappings in lua/plugins/telescope.lua, which
    -- close the tree first so the file lands in a full window, not the sidebar).
  end,
}
