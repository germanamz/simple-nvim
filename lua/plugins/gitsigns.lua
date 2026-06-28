return {
  "lewis6991/gitsigns.nvim",
  event = { "BufReadPre", "BufNewFile" },
  opts = function()
    local review_base = require("config.review_base")
    local git = require("util.git")
    local path = require("util.path")

    local function apply_base(bufnr)
      local root = git.root(path.buf_start_dir(bufnr))
      local ref = root and review_base.get(root) or nil
      -- gitsigns has only ONE global base (config.base), shared by every attached
      -- buffer across every repo/submodule. change_base re-diffs ALL attached
      -- buffers against the ref, so calling it on each attach clobbered things:
      --   * change_base(nil, true) wiped the global base, re-diffing everything
      --     against the index even when this buffer has no review base.
      --   * a buffer in one submodule forced every other repo's buffers to
      --     re-diff against a ref that may not exist there.
      -- gitsigns already inherits config.base on attach, so a nil ref needs no
      -- action; only push a change when this root's base genuinely differs from
      -- the current global base. (Cross-repo base correctness is inherently
      -- limited by that single global base — we can't hold a per-repo base here.)
      if ref and ref ~= require("gitsigns.config").config.base then
        require("gitsigns").change_base(ref, true)
      end
    end

    return {
      signcolumn = false,
      numhl = true,
      linehl = false,
      word_diff = false,
      diff_opts = { internal = true, linematch = 60 },
      current_line_blame = true,
      current_line_blame_opts = {
        virt_text = true,
        virt_text_pos = "eol",
        -- Nonzero so blame virtual text isn't recomputed on every cursor
        -- movement while scrolling through a buffer.
        delay = 250,
        ignore_whitespace = false,
      },
      on_attach = function(bufnr)
        apply_base(bufnr)
        local gs = require("gitsigns")
        local map = function(mode, lhs, rhs, desc)
          vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
        end
        map("n", "]c", function()
          gs.nav_hunk("next")
        end, "Next hunk")
        map("n", "[c", function()
          gs.nav_hunk("prev")
        end, "Prev hunk")
        map("n", "<leader>hp", gs.preview_hunk, "Preview hunk")
        map("n", "<leader>hs", gs.stage_hunk, "Stage hunk")
        -- With a review base set, apply_base points gitsigns at that ref, so
        -- reset_hunk reverts working-tree lines to the BASE content (not the
        -- index) — it can clobber branch-committed work. Confirm first in that
        -- mode; without a base it's the ordinary reset-to-index. Checked per
        -- press because change_base fires from ReviewBaseChanged without
        -- re-running on_attach, so attach-time state would go stale.
        map("n", "<leader>hr", function()
          local root = git.root(path.buf_start_dir(bufnr))
          local ref = root and review_base.get(root)
          if ref then
            local ok = vim.fn.confirm(
              ("Review base '%s' is active — reset reverts lines to that ref, not the index. Continue?"):format(
                ref
              ),
              "&Yes\n&No",
              2
            )
            if ok ~= 1 then
              return
            end
          end
          gs.reset_hunk()
        end, "Reset hunk")
        map("n", "<leader>hb", function()
          gs.blame_line({ full = true })
        end, "Blame line")
        map("n", "<leader>hB", gs.toggle_current_line_blame, "Toggle line blame virtual text")
        map("n", "<leader>hd", gs.diffthis, "Diff against review base / index")
        map("n", "<leader>ht", gs.toggle_deleted, "Toggle deleted lines inline")
        map("n", "<leader>hi", gs.preview_hunk_inline, "Inline preview hunk")
        -- <leader>hh (toggle hunk highlights) is intentionally NOT mapped here.
        -- gitsigns never attaches to untracked / new-vs-base files, so on_attach
        -- doesn't run for them — yet those buffers still get the custom add
        -- painting and need to toggle it. The toggle is global state anyway, so
        -- the keymap is registered globally in config() instead.
      end,
    }
  end,
  config = function(_, opts)
    local review_base = require("config.review_base")
    local git = require("util.git")
    local inline_diff = require("util.inline_diff")
    local path = require("util.path")
    local palette = require("config.palette")
    -- Defer the per-root validation (one blocking `git rev-parse --verify` per
    -- stored review base) off the plugin-load critical path; it only prunes
    -- stale entries the picker would offer, and nothing below needs it now.
    vim.schedule(review_base.bootstrap)

    require("gitsigns").setup(opts)

    local function paint()
      -- Saturated tints live in config.palette (git.*) so the literal hex has a
      -- single home; the dark/light selection + the deliberate colorscheme
      -- override (no default=true) stay here.
      local g = palette.git
      -- Nr (colored line numbers) carry their own fg, so one saturated palette
      -- reads on both backgrounds.
      vim.api.nvim_set_hl(0, "GitSignsAddNr", { fg = "#ffffff", bg = g.add_nr })
      vim.api.nvim_set_hl(0, "GitSignsChangeNr", { fg = "#ffffff", bg = g.change_nr })
      vim.api.nvim_set_hl(0, "GitSignsDeleteNr", { fg = "#ffffff", bg = g.delete_nr })

      -- Line backgrounds (Ln) set only bg and inherit the buffer's own fg
      -- (treesitter/syntax). Light pastels assume a light theme — on the dark
      -- default colorscheme they put light fg on a light tint, near-illegible.
      -- Pick the tint from the active background, re-applied on the events below.
      local dark = vim.o.background == "dark"
      local add_ln = dark and g.add_ln_dark or g.add_ln_light
      local change_ln = dark and g.change_ln_dark or g.change_ln_light
      local add_inline = dark and g.add_inline_dark or g.add_inline_light

      vim.api.nvim_set_hl(0, "GitSignsAddLn", { bg = add_ln })
      vim.api.nvim_set_hl(0, "GitSignsChangeLn", { bg = change_ln })
      vim.api.nvim_set_hl(0, "GitSignsDeleteLn", { sp = g.delete, underdashed = true })

      vim.api.nvim_set_hl(0, "GitSignsAddLnInline", { bg = add_inline })
      vim.api.nvim_set_hl(0, "GitSignsChangeLnInline", { bg = add_inline })
      vim.api.nvim_set_hl(0, "GitSignsDeleteLnInline", {})

      vim.api.nvim_set_hl(0, "GitSignsDelPrev", { sp = g.delete, underdashed = true })
    end
    paint()
    -- ColorScheme resets highlight groups; OptionSet catches a bare
    -- `:set background=dark` that fires no ColorScheme.
    vim.api.nvim_create_autocmd("ColorScheme", { callback = paint })
    vim.api.nvim_create_autocmd("OptionSet", { pattern = "background", callback = paint })

    local ns = vim.api.nvim_create_namespace("gs_custom")

    -- When hunks are toggled off (<leader>hh) we hide the line backgrounds and
    -- inline word-diff but keep gitsigns' numhl (colored line numbers) as a
    -- minimal "changed line" marker. mark_hunks honors this flag. Default off:
    -- buffers open in the minimal numhl-only state; <leader>hh reveals the full
    -- highlights. Keep word_diff in opts off to match this startup state.
    local hunks_visible = false

    -- When a review base is set but the file doesn't exist in that ref (added
    -- in the current branch), gitsigns has nothing to diff against and emits
    -- zero hunks — so numhl/linehl never show, leaving the buffer looking
    -- pristine even though it's entirely new work. Detect that case and paint
    -- the whole buffer with the "add" highlight.
    local function file_new_vs_base(bufnr)
      local fname = vim.api.nvim_buf_get_name(bufnr)
      if fname == "" then
        return false
      end
      -- gitsigns never attaches to new-vs-base / untracked files (see on_attach
      -- and the BufReadPost note below), so an attached buffer can never be
      -- new-vs-base. Bail before spawning git on the editing-time GitSignsUpdate
      -- path; the unattached BufReadPost detection still runs.
      if vim.b[bufnr].gitsigns_status ~= nil then
        return false
      end
      local root = git.root(vim.fn.fnamemodify(fname, ":h"))
      if not root then
        return false
      end
      local ref = review_base.get(root)
      if not ref then
        return false
      end
      local relpath = path.relative(fname, root)
      if relpath == "" then
        return false
      end
      -- new vs base == the file does not exist in that ref (nothing to diff).
      return not git.file_in_ref(root, ref, relpath)
    end

    -- Paint every line of a new-vs-base file with the "add" highlight: gitsigns
    -- has nothing to diff against so emits no hunks. Honors the visibility
    -- toggle for the line background but always keeps the colored line numbers.
    local function paint_new_vs_base(bufnr, line_count)
      for row = 0, line_count - 1 do
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
          end_row = row + 1,
          end_col = 0,
          hl_group = hunks_visible and "GitSignsAddLn" or nil,
          number_hl_group = "GitSignsAddNr",
          hl_eol = hunks_visible or nil,
          priority = 1,
        })
      end
    end

    -- Inline word-diff for a change hunk: highlight the differing middle span in
    -- each new line and mark the deletion point carried over from the old line.
    local function paint_word_diff(bufnr, h)
      local removed = (h.removed and h.removed.lines) or {}
      local added = (h.added and h.added.lines) or {}
      for i = 1, math.min(#removed, #added) do
        local new = added[i]
        local span = inline_diff.middle_span(removed[i], new)
        local row = h.added.start + i - 2
        if span.new_mid > 0 then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, span.prefix, {
            end_col = span.prefix + span.new_mid,
            hl_group = "GitSignsAddLnInline",
            priority = 200,
          })
        end
        if span.old_mid > 0 and #new > 0 then
          local col = math.max(0, span.prefix - 1)
          if col < #new then
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, col, {
              end_col = col + 1,
              hl_group = "GitSignsDelPrev",
              priority = 5000,
            })
          end
        end
      end
    end

    -- Paint line backgrounds for add/change/delete hunks, with inline word-diff
    -- on changed lines.
    local function paint_hunks(bufnr, hunks, line_count)
      local function line_bg(row, hl)
        if row < 0 or row >= line_count then
          return
        end
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
          end_row = row + 1,
          end_col = 0,
          hl_group = hl,
          hl_eol = true,
          priority = 1,
        })
      end

      for _, h in ipairs(hunks) do
        if h.type == "add" then
          local start = (h.added.start or 1) - 1
          for i = 0, (h.added.count or 0) - 1 do
            line_bg(start + i, "GitSignsAddLn")
          end
        elseif h.type == "change" then
          local start = (h.added.start or 1) - 1
          for i = 0, (h.added.count or 0) - 1 do
            line_bg(start + i, "GitSignsChangeLn")
          end
          paint_word_diff(bufnr, h)
        elseif h.type == "delete" then
          local row = math.max(0, (h.added.start or 1) - 1)
          line_bg(row, "GitSignsDeleteLn")
        end
      end
    end

    -- `hunks`, when provided (always a table, possibly empty), is used as-is so a
    -- caller that already fetched them — the GitSignsUpdate path — doesn't pay a
    -- second gs.get_hunks (which rebuilds O(changed-line) patch strings).
    local function mark_hunks(bufnr, hunks)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      local ok, gs = pcall(require, "gitsigns")
      if not ok then
        return
      end
      hunks = hunks or gs.get_hunks(bufnr) or {}
      local line_count = vim.api.nvim_buf_line_count(bufnr)

      local new_vs_base = #hunks == 0 and file_new_vs_base(bufnr)
      vim.b[bufnr].gs_new_vs_base = new_vs_base
      if new_vs_base then
        -- A newly-added file vs the base is painted one extmark per line in a
        -- synchronous loop — fine for normal files, a freeze on a 50k-line
        -- vendored/lockfile add. Past the shared threshold skip the paint (the
        -- gs_new_vs_base flag above still drives the "[new vs base]" statusline
        -- marker); the same files skip treesitter and format-on-save too.
        if not require("util.largefile").is_large(bufnr) then
          paint_new_vs_base(bufnr, line_count)
        end
        return
      end

      -- Hunks toggled off: namespace is cleared above, colored line numbers
      -- come from gitsigns' numhl, so there's nothing else to paint.
      if not hunks_visible then
        return
      end

      paint_hunks(bufnr, hunks, line_count)
    end

    -- Per-buffer hunk summary cache for the statusline, refreshed on
    -- GitSignsUpdate (which fires exactly when hunks change). gs.get_hunks
    -- rebuilds O(changed-line) patch strings we never use here, so calling it on
    -- every statusline redraw is wasteful — worse on the large vendored/lockfile
    -- diffs a superproject is full of. We cache the type counts + each hunk's
    -- start line; only the cursor-relative above/below split is recomputed per
    -- read (cheap integer work).
    local hunk_status_cache = {} -- bufnr -> { add, change, delete, starts = {start lines} }

    -- `hunks` optional (see mark_hunks): the GitSignsUpdate path passes the same
    -- fetched table to both helpers so each update costs one gs.get_hunks, not two.
    local function refresh_hunk_status(bufnr, hunks)
      local ok, gs = pcall(require, "gitsigns")
      if not ok or not vim.api.nvim_buf_is_valid(bufnr) then
        hunk_status_cache[bufnr] = nil
        return
      end
      hunks = hunks or gs.get_hunks(bufnr)
      if not hunks or #hunks == 0 then
        hunk_status_cache[bufnr] = nil
        return
      end
      local add, change, delete, starts = 0, 0, 0, {}
      for _, h in ipairs(hunks) do
        if h.type == "add" then
          add = add + 1
        elseif h.type == "change" then
          change = change + 1
        elseif h.type == "delete" then
          delete = delete + 1
        end
        starts[#starts + 1] = h.added.start
      end
      hunk_status_cache[bufnr] = { add = add, change = change, delete = delete, starts = starts }
    end

    function _G.gitsigns_hunks_status()
      local bufnr = vim.api.nvim_get_current_buf()
      local c = hunk_status_cache[bufnr]
      if not c then
        if vim.b[bufnr].gs_new_vs_base then
          return " [new vs base] "
        end
        return ""
      end
      local cursor = vim.api.nvim_win_get_cursor(0)[1]
      local above, below = 0, 0
      for _, s in ipairs(c.starts) do
        if s < cursor then
          above = above + 1
        else
          below = below + 1
        end
      end
      return string.format(" +%d ~%d -%d ↑%d ↓%d ", c.add, c.change, c.delete, above, below)
    end

    -- Statusline counts (gitsigns_hunks_status) read gs.get_hunks directly and
    -- stay live regardless of visibility. The toggle only affects the in-buffer
    -- line backgrounds + word-diff; colored line numbers (numhl) are left on.
    -- With a `root`, repaint only that repo's buffers — used by ReviewBaseChanged,
    -- which carries the one root whose base moved; a sibling submodule's
    -- new-vs-base painting is untouched, so re-spawning git (file_new_vs_base)
    -- for every buffer across every submodule is wasted. nil repaints all (the
    -- FocusGained / <leader>gR / <leader>hh paths, where shared state changed).
    local function repaint_all(root)
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and (root == nil or git.buf_in_root(buf, root)) then
          mark_hunks(buf)
        end
      end
    end

    function _G.gitsigns_toggle_hunks()
      hunks_visible = not hunks_visible
      local gs = require("gitsigns")
      -- Flipping word_diff invalidates gitsigns' hunk cache and recomputes it
      -- asynchronously (debounced), and it does NOT fire GitSignsUpdate. So the
      -- immediate repaint below sees zero hunks when showing — it only handles
      -- hiding (clear) and new-vs-base. Poll until the cache comes back, then
      -- repaint so the line backgrounds actually reappear.
      gs.toggle_word_diff(hunks_visible)
      repaint_all()
      if hunks_visible then
        local tries = 0
        local function settle()
          tries = tries + 1
          local buf = vim.api.nvim_get_current_buf()
          local h = gs.get_hunks(buf)
          if h and #h > 0 then
            repaint_all()
          elseif tries < 40 then
            vim.defer_fn(settle, 25)
          end
        end
        vim.defer_fn(settle, 25)
      end
      vim.notify("Git hunks " .. (hunks_visible and "shown" or "hidden"))
    end

    -- Global (not buffer-local): the toggle drives shared state and repaints
    -- every buffer, and it must work in buffers gitsigns never attaches to
    -- (untracked / new-vs-base files), where on_attach never runs.
    vim.keymap.set("n", "<leader>hh", function()
      _G.gitsigns_toggle_hunks()
    end, { desc = "Toggle hunk highlights" })

    -- gitsigns watches the gitdir to self-refresh, but changes made from another
    -- terminal while nvim is backgrounded (a commit, a `git add`, a stash) often
    -- arrive as a coalesced or dropped fs event — and a plain commit moves
    -- refs/heads/<branch>, not HEAD, so config.git_head's HEAD watcher never
    -- fires either. The signs stay diffed against the pre-commit state until the
    -- buffer is reopened. Re-diff whenever focus returns so coming back to nvim
    -- always reflects the current index/HEAD. refresh() is async and
    -- FocusGained is rare (once per alt-tab, not per edit), so the re-diff is off
    -- the hot path; each attached buffer's update fires GitSignsUpdate, which
    -- repaints the highlights and statusline counts. The other git displays
    -- re-sync on the same FocusGained event from their own modules:
    -- config.statusline re-resolves the focused buffer's branch/base, and
    -- nvim-tree reloads its git decorations (see lua/plugins/nvim-tree.lua).
    vim.api.nvim_create_autocmd("FocusGained", {
      callback = function()
        require("gitsigns").refresh()
        -- Attached buffers repaint via the GitSignsUpdate that refresh() triggers;
        -- untracked / new-vs-base buffers get no such event, so repaint them here.
        repaint_all()
      end,
    })

    -- Manual full refresh, for terminals/tmux that don't forward focus events
    -- (the FocusGained path above is best-effort — see config.statusline). Does
    -- everything that path does, plus repainting unattached new-vs-base buffers,
    -- re-resolving branch/base for *every* buffer, and reloading the file tree's
    -- git labels.
    vim.keymap.set("n", "<leader>gR", function()
      require("gitsigns").refresh()
      -- Catch untracked / new-vs-base buffers gitsigns never attaches to (so
      -- they get no GitSignsUpdate); refresh() above already covers attached ones.
      repaint_all()
      require("config.statusline").refresh_all()
      -- Reload the tree's git decorator against fresh codes, if it's on screen
      -- (mirrors nvim-tree.lua's own ReviewBaseChanged refresh).
      if package.loaded["nvim-tree"] then
        local api = require("nvim-tree.api")
        if api.tree.is_visible() then
          require("config.telescope_smart")._refresh_async(vim.fn.getcwd(), function()
            if api.tree.is_visible() then
              api.tree.reload()
            end
          end)
        end
      end
      vim.notify("Refreshed git hunks & status")
    end, { desc = "Refresh git hunks & status" })

    -- Repaint only the buffer whose hunks changed (the event carries it in
    -- data.buffer); repainting every loaded buffer on each update made every
    -- edit O(open buffers). The full repaint stays on the <leader>hh toggle
    -- and ReviewBaseChanged paths, where shared state really changes.
    vim.api.nvim_create_autocmd("User", {
      pattern = "GitSignsUpdate",
      callback = function(args)
        local buf = args.data and args.data.buffer
        if buf then
          -- Fetch once, feed both: refresh_hunk_status and mark_hunks each used
          -- to call gs.get_hunks(buf) independently — two full rebuilds per update.
          local ok, gs = pcall(require, "gitsigns")
          local hunks = (ok and gs.get_hunks(buf)) or {}
          refresh_hunk_status(buf, hunks)
          mark_hunks(buf, hunks)
        else
          for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(b) then
              refresh_hunk_status(b)
            end
          end
          repaint_all()
        end
        -- After the cache is fresh, so the statusline reads the new counts.
        vim.cmd("redrawstatus")
      end,
    })

    -- Drop the cached hunk summary when a buffer goes away, so a reused bufnr
    -- never shows another file's stale counts before its first GitSignsUpdate.
    vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
      callback = function(args)
        hunk_status_cache[args.buf] = nil
      end,
    })

    vim.api.nvim_create_autocmd("User", {
      pattern = "ReviewBaseChanged",
      callback = function(args)
        local ref = args.data and args.data.ref or nil
        require("gitsigns").change_base(ref, true)
        -- Attached buffers repaint via their own GitSignsUpdate once hunks
        -- recompute against the new base; unattached (new-vs-base) buffers get no
        -- such event, so repaint them here — but only in the root whose base
        -- actually changed (a sibling submodule's new-vs-base is unaffected).
        repaint_all(args.data and args.data.root or nil)
      end,
    })

    -- gitsigns never attaches to files absent from the base/index (untracked
    -- or new-vs-base), so they get no GitSignsUpdate either. They previously
    -- relied on other buffers' updates triggering a global repaint; paint
    -- them explicitly when their file is read instead.
    vim.api.nvim_create_autocmd("BufReadPost", {
      callback = function(args)
        -- Only real, named file buffers. mark_hunks → file_new_vs_base can shell
        -- out to git (root + cat-file) when a review base is set, and this fires
        -- on every read. Special buffers (terminals, prompts, help) and unnamed
        -- scratch buffers can never be new-vs-base, so skip them entirely.
        if vim.bo[args.buf].buftype ~= "" or vim.api.nvim_buf_get_name(args.buf) == "" then
          return
        end
        vim.defer_fn(function()
          if not vim.api.nvim_buf_is_valid(args.buf) then
            return
          end
          -- Already-attached buffers are owned by GitSignsUpdate, which already
          -- painted them; re-running mark_hunks here would redundantly fetch
          -- gs.get_hunks + repaint. This path is NEEDED only for buffers gitsigns
          -- never attaches to (untracked / new-vs-base), flagged by the absence
          -- of gitsigns_status — the same attached signal file_new_vs_base uses.
          if vim.b[args.buf].gitsigns_status ~= nil then
            return
          end
          mark_hunks(args.buf)
        end, 200)
      end,
    })
  end,
}
