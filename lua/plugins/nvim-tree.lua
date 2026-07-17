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
    -- Long names lose their tail to the 35-column sidebar, so let nvim-tree pop
    -- a one-line float over the cursor row whenever the row renders wider than
    -- the window. It only fires when the name is actually truncated, and it
    -- replays the row's NvimTreeHighlights extmarks, so the git labels and the
    -- grey/blue/teal decorator colours below carry into the float. Two silent
    -- no-ops worth knowing: the float is suppressed unless the tree window sits
    -- at screen column 0 (fine — view.side is left by default) and unless 'wrap'
    -- is off (nvim-tree forces that itself). The decorators are merged into this
    -- table in config() below.
    renderer = {
      full_name = true,
      -- Superproject branch + working state on the root repo-name row. Monochrome
      -- by necessity: root_folder_label renders as one buffer line under a single
      -- NvimTreeRootFolder highlight (a function must return a bare string; no
      -- per-part colour, and decorators do not run on the header line). The
      -- coloured submodule labels below are decorators, which do. label_plain
      -- returns "" until config.repo_status has resolved the root (cold cache),
      -- scheduling that resolve; RepoStatusChanged then reloads the header warm.
      root_folder_label = function(abs)
        local name = vim.fn.fnamemodify(abs, ":t")
        local status = require("config.repo_status").label_plain(abs)
        return status ~= "" and (name .. "   " .. status) or name
      end,
    },
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
    --
    -- Assign into opts.renderer rather than replacing it: lazy hands config()
    -- the MERGED opts, so a wholesale `opts.renderer = {...}` would silently
    -- drop the sibling renderer keys declared above (full_name among them)
    -- before setup() ever saw them. Handing nvim-tree a partial renderer table
    -- is fine — it deep-merges over its defaults — while `decorators`, being a
    -- list, still replaces the default list wholesale, which is what drops the
    -- builtin "Git" decorator.
    opts.renderer.decorators = {
      "Open",
      "Hidden",
      "Modified",
      "Bookmark",
      "Diagnostics",
      "Copied",
      require("config.nvim_tree_git").decorator(),
      -- Three sibling decorators that colour classes of nodes. Order matters:
      -- create_combined_group force-merges in list order, so the LAST one wins
      -- an overlap. git-ignored is placed last so an ignored dot-folder (.next,
      -- .venv, ...) reads grey ("ignored") rather than blue ("dot-folder").
      --   • dot-folders  -> blue  (.git, .github, ...; folders only)
      --   • symlinks     -> teal  (file and directory links)
      --   • git-ignored  -> grey  (shown via I; from config.ignore_filter)
      require("config.nvim_tree_dotfolder").decorator(),
      require("config.nvim_tree_symlink").decorator(),
      require("config.nvim_tree_ignore").decorator(),
      -- Per-submodule branch/status labels, placed AFTER the folder name (its own
      -- decorator because it uses icon_placement="after", vs the git decorator's
      -- "before"). Resolves each submodule's status lazily, only when its row is
      -- visible. Independent placement, so its order vs the trio above is moot.
      require("config.nvim_tree_submodule").decorator(),
      "Cut",
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
    -- Repaint autocmds (ReviewBaseChanged/HeadChanged, SmartCodesRefreshed,
    -- FocusGained) live in config.nvim_tree_git so their registration is
    -- testable and idempotent across config() re-runs.
    require("config.nvim_tree_git").register_autocmds()
    -- The tree stays put while a Telescope picker is open; it's dismissed only
    -- when a file is actually opened — from the tree (quit_on_open above) or
    -- from a picker (the select mappings in lua/plugins/telescope.lua, which
    -- close the tree first so the file lands in a full window, not the sidebar).
  end,
}
