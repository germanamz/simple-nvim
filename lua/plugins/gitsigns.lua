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
      end,
    }
  end,
  config = function(_, opts)
    local review_base = require("config.review_base")
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

          local removed = (h.removed and h.removed.lines) or {}
          local added = (h.added and h.added.lines) or {}
          local n = math.min(#removed, #added)
          for i = 1, n do
            local old, new = removed[i], added[i]
            local olen, nlen = #old, #new
            local p = 0
            while p < olen and p < nlen and old:byte(p + 1) == new:byte(p + 1) do
              p = p + 1
            end
            local s = 0
            while s < olen - p and s < nlen - p and old:byte(olen - s) == new:byte(nlen - s) do
              s = s + 1
            end
            local old_mid = olen - p - s
            local new_mid = nlen - p - s
            local row = h.added.start + i - 2
            if new_mid > 0 then
              pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, p, {
                end_col = p + new_mid,
                hl_group = "GitSignsAddLnInline",
                priority = 200,
              })
            end
            if old_mid > 0 and nlen > 0 then
              local col = math.max(0, p - 1)
              if col < nlen then
                pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, col, {
                  end_col = col + 1,
                  hl_group = "GitSignsDelPrev",
                  priority = 5000,
                })
              end
            end
          end
        elseif h.type == "delete" then
          local row = math.max(0, (h.added.start or 1) - 1)
          line_bg(row, "GitSignsDeleteLn")
        end
      end
    end

    function _G.gitsigns_hunks_status()
      local ok, gs = pcall(require, "gitsigns")
      if not ok then
        return ""
      end
      local bufnr = vim.api.nvim_get_current_buf()
      local hunks = gs.get_hunks(bufnr)
      if not hunks or #hunks == 0 then
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

    vim.o.statusline =
      "%f %m%r%=%{v:lua.lsp_refs_status()}%{v:lua.gitsigns_hunks_status()} %y %l:%c %p%% "

    vim.api.nvim_create_autocmd("User", {
      pattern = "GitSignsUpdate",
      callback = function()
        vim.cmd("redrawstatus")
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(buf) then
            mark_hunks(buf)
          end
        end
      end,
    })
  end,
}
