return {
  "lewis6991/gitsigns.nvim",
  event = { "BufReadPre", "BufNewFile" },
  opts = function()
    local review_base = require("config.review_base")

    local function apply_base(bufnr)
      local fname = vim.api.nvim_buf_get_name(bufnr)
      local start = (fname ~= "" and vim.fn.fnamemodify(fname, ":h")) or vim.fn.getcwd()
      local root = review_base.git_root(start)
      local ref = root and review_base.get(root) or nil
      require("gitsigns").change_base(ref, true)
    end

    return {
      signcolumn = false,
      numhl = true,
      linehl = false,
      word_diff = true,
      diff_opts = { internal = true, linematch = 60 },
      current_line_blame = true,
      current_line_blame_opts = {
        virt_text = true,
        virt_text_pos = "eol",
        delay = 0,
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
        map("n", "<leader>hr", gs.reset_hunk, "Reset hunk")
        map("n", "<leader>hb", function()
          gs.blame_line({ full = true })
        end, "Blame line")
        map("n", "<leader>hB", gs.toggle_current_line_blame, "Toggle line blame virtual text")
        map("n", "<leader>hd", gs.diffthis, "Diff against index")
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
    review_base.bootstrap()

    require("gitsigns").setup(opts)

    vim.api.nvim_create_autocmd("User", {
      pattern = "ReviewBaseChanged",
      callback = function(args)
        local ref = args.data and args.data.ref or nil
        require("gitsigns").change_base(ref, true)
      end,
    })

    local function paint()
      vim.api.nvim_set_hl(0, "GitSignsAddNr", { fg = "#ffffff", bg = "#4ea862" })
      vim.api.nvim_set_hl(0, "GitSignsChangeNr", { fg = "#ffffff", bg = "#7a5d1a" })
      vim.api.nvim_set_hl(0, "GitSignsDeleteNr", { fg = "#ffffff", bg = "#c85050" })

      vim.api.nvim_set_hl(0, "GitSignsAddLn", { bg = "#b8e0c4" })
      vim.api.nvim_set_hl(0, "GitSignsChangeLn", { bg = "#ead090" })
      vim.api.nvim_set_hl(0, "GitSignsDeleteLn", { sp = "#c85050", underdashed = true })

      vim.api.nvim_set_hl(0, "GitSignsAddLnInline", { bg = "#8fd4a3" })
      vim.api.nvim_set_hl(0, "GitSignsChangeLnInline", { bg = "#8fd4a3" })
      vim.api.nvim_set_hl(0, "GitSignsDeleteLnInline", {})

      vim.api.nvim_set_hl(0, "GitSignsDelPrev", { sp = "#c85050", underdashed = true })
    end
    paint()
    vim.api.nvim_create_autocmd("ColorScheme", { callback = paint })

    local ns = vim.api.nvim_create_namespace("gs_custom")

    -- When hunks are toggled off (<leader>hh) we hide the line backgrounds and
    -- inline word-diff but keep gitsigns' numhl (colored line numbers) as a
    -- minimal "changed line" marker. mark_hunks honors this flag.
    local hunks_visible = true

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
      local root = review_base.git_root(vim.fn.fnamemodify(fname, ":h"))
      if not root then
        return false
      end
      local ref = review_base.get(root)
      if not ref then
        return false
      end
      local relpath = fname:sub(#root + 2)
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

    local function mark_hunks(bufnr)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      local ok, gs = pcall(require, "gitsigns")
      if not ok then
        return
      end
      local hunks = gs.get_hunks(bufnr) or {}
      local line_count = vim.api.nvim_buf_line_count(bufnr)

      local new_vs_base = #hunks == 0 and file_new_vs_base(bufnr)
      vim.b[bufnr].gs_new_vs_base = new_vs_base
      if new_vs_base then
        paint_new_vs_base(bufnr, line_count)
        return
      end

      -- Hunks toggled off: namespace is cleared above, colored line numbers
      -- come from gitsigns' numhl, so there's nothing else to paint.
      if not hunks_visible then
        return
      end

      paint_hunks(bufnr, hunks, line_count)
    end

    function _G.gitsigns_hunks_status()
      local ok, gs = pcall(require, "gitsigns")
      if not ok then
        return ""
      end
      local bufnr = vim.api.nvim_get_current_buf()
      local hunks = gs.get_hunks(bufnr)
      if not hunks or #hunks == 0 then
        if vim.b[bufnr].gs_new_vs_base then
          return " [new vs base] "
        end
        return ""
      end
      local cursor = vim.api.nvim_win_get_cursor(0)[1]
      local add, change, delete = 0, 0, 0
      local above, below = 0, 0
      for _, h in ipairs(hunks) do
        if h.type == "add" then
          add = add + 1
        elseif h.type == "change" then
          change = change + 1
        elseif h.type == "delete" then
          delete = delete + 1
        end
        if h.added.start < cursor then
          above = above + 1
        else
          below = below + 1
        end
      end
      return string.format(" +%d ~%d -%d ↑%d ↓%d ", add, change, delete, above, below)
    end

    -- Statusline counts (gitsigns_hunks_status) read gs.get_hunks directly and
    -- stay live regardless of visibility. The toggle only affects the in-buffer
    -- line backgrounds + word-diff; colored line numbers (numhl) are left on.
    local function repaint_all()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) then
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

    vim.api.nvim_create_autocmd("User", {
      pattern = "GitSignsUpdate",
      callback = function()
        vim.cmd("redrawstatus")
        repaint_all()
      end,
    })
  end,
}
