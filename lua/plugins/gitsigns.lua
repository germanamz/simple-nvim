return {
  "lewis6991/gitsigns.nvim",
  event = { "BufReadPre", "BufNewFile" },
  opts = {
    signcolumn = false,
    numhl = true,
    linehl = true,
    on_attach = function(bufnr)
      local gs = require("gitsigns")
      local map = function(mode, lhs, rhs, desc)
        vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
      end
      map("n", "]c", function() gs.nav_hunk("next") end, "Next hunk")
      map("n", "[c", function() gs.nav_hunk("prev") end, "Prev hunk")
      map("n", "<leader>hp", gs.preview_hunk, "Preview hunk")
      map("n", "<leader>hs", gs.stage_hunk, "Stage hunk")
      map("n", "<leader>hr", gs.reset_hunk, "Reset hunk")
      map("n", "<leader>hb", function() gs.blame_line({ full = true }) end, "Blame line")
      map("n", "<leader>hd", gs.diffthis, "Diff against index")
    end,
  },
  config = function(_, opts)
    require("gitsigns").setup(opts)
    local function paint()
      vim.api.nvim_set_hl(0, "GitSignsAddNr",    { fg = "#ffffff", bg = "#4ea862" })
      vim.api.nvim_set_hl(0, "GitSignsChangeNr", { fg = "#ffffff", bg = "#7a5d1a" })
      vim.api.nvim_set_hl(0, "GitSignsDeleteNr", { fg = "#ffffff", bg = "#c85050" })
      vim.api.nvim_set_hl(0, "GitSignsAddLn",    { bg = "#b8e0c4" })
      vim.api.nvim_set_hl(0, "GitSignsChangeLn", { bg = "#ead090" })
      vim.api.nvim_set_hl(0, "GitSignsDeleteLn", { bg = "#efb0b0" })
    end
    paint()
    vim.api.nvim_create_autocmd("ColorScheme", { callback = paint })

    function _G.gitsigns_below_status()
      local ok, gs = pcall(require, "gitsigns")
      if not ok then return "" end
      local bufnr = vim.api.nvim_get_current_buf()
      local hunks = gs.get_hunks(bufnr)
      if not hunks or #hunks == 0 then return "" end
      local cursor = vim.api.nvim_win_get_cursor(0)[1]
      local add, change, delete = 0, 0, 0
      for _, h in ipairs(hunks) do
        if h.added.start >= cursor then
          if h.type == "add" then add = add + 1
          elseif h.type == "change" then change = change + 1
          elseif h.type == "delete" then delete = delete + 1
          end
        end
      end
      local total = add + change + delete
      if total == 0 then return "" end
      return string.format(" +%d ~%d -%d ↓%d ", add, change, delete, total)
    end

    vim.o.statusline = "%f %m%r%=%{v:lua.gitsigns_below_status()} %y %l:%c "

    vim.api.nvim_create_autocmd("User", {
      pattern = "GitSignsUpdate",
      callback = function() vim.cmd("redrawstatus") end,
    })
  end,
}
