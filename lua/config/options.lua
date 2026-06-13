local opt = vim.opt

-- Line numbers
opt.number = true
opt.relativenumber = false
opt.numberwidth = 4
opt.signcolumn = "yes" -- always show sign column (prevents jitter)
opt.cursorline = true

-- Whitespace rendering
opt.list = true
opt.listchars = {
  tab = "» ",
  lead = "·",
  trail = "·",
  extends = "›",
  precedes = "‹",
  nbsp = "␣",
}
opt.fillchars = { eob = " " }

-- Indentation
opt.expandtab = true
opt.shiftwidth = 2
opt.tabstop = 2
opt.softtabstop = 2
opt.smartindent = true

-- Search
opt.ignorecase = true
opt.smartcase = true
opt.hlsearch = true
opt.incsearch = true

-- Toggle search-match highlighting (flips 'hlsearch'). Unlike :nohlsearch,
-- which only clears until the next search, this stays off until toggled back.
vim.keymap.set("n", "<leader>uh", "<cmd>set hlsearch!<cr>", { desc = "Toggle search highlight" })

-- netrw: tree-style listing with banner. g:netrw_treedepthstring doesn't always
-- take effect (newer netrw caches it), so we also hide the bar character by
-- setting its highlight foreground to the Normal background. Re-applied on
-- ColorScheme so :colorscheme changes don't bring the bars back.
vim.g.netrw_liststyle = 3

-- Bundled netrw maps quickhelp to <F1>, not ?. Restore the familiar ? binding.
vim.api.nvim_create_autocmd("FileType", {
  pattern = "netrw",
  callback = function(args)
    vim.keymap.set("n", "?", "<cmd>help netrw-quickmap<cr>", {
      buffer = args.buf,
      desc = "netrw quickmap help",
    })
  end,
})

local function hide_netrw_tree_bar()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal" })
  local bg = normal and normal.bg
  if bg then
    vim.api.nvim_set_hl(0, "netrwTreeBar", { fg = string.format("#%06x", bg) })
  end
end
hide_netrw_tree_bar()
vim.api.nvim_create_autocmd("ColorScheme", { callback = hide_netrw_tree_bar })

-- Misc quality-of-life
opt.termguicolors = true
opt.mouse = "a"
opt.clipboard = "unnamedplus"

-- Delete the current buffer without closing its window. When other buffers
-- remain, switch to the previous one first so the window stays on a real file
-- instead of collapsing (which would quit nvim if it's the last window). When
-- this is the *last* listed buffer, fall back to the nvim-tree explorer — the
-- same default view `nvim .` opens — instead of leaving a stuck empty buffer.
vim.keymap.set("n", "<leader>bd", function()
  local cur = vim.api.nvim_get_current_buf()
  local listed = vim.tbl_filter(function(b)
    return vim.bo[b].buflisted
  end, vim.api.nvim_list_bufs())

  if #listed > 1 then
    vim.cmd("bprevious")
    vim.cmd("bdelete " .. cur)
    return
  end

  -- Last listed buffer: delete it first so unsaved-changes errors still abort
  -- loudly (nvim leaves a throwaway empty [No Name] in the window), then open
  -- nvim-tree and drop every other window so we land on just the tree.
  vim.cmd("bdelete " .. cur)
  require("lazy").load({ plugins = { "nvim-tree.lua" } })
  require("nvim-tree.api").tree.open()
  local tree_win = vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= tree_win then
      pcall(vim.api.nvim_win_close, win, false)
    end
  end
end, { desc = "Delete buffer" })

-- Quit all windows, discarding unsaved changes
vim.keymap.set("n", "<leader>qa", "<cmd>qa!<cr>", { desc = "Quit all (force)" })

-- Save all buffers and quit
vim.keymap.set("n", "<leader>qw", "<cmd>wqa<cr>", { desc = "Save all and quit" })

-- OSC52 clipboard provider for containers/SSH (host uses pbcopy/xclip natively)
local in_container = vim.env.REMOTE_CONTAINERS == "true"
  or vim.env.CODESPACES == "true"
  or vim.uv.fs_stat("/.dockerenv") ~= nil
if in_container or vim.env.SSH_TTY then
  local osc52 = require("vim.ui.clipboard.osc52")
  vim.g.clipboard = {
    name = "OSC 52",
    copy = { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("*") },
    paste = { ["+"] = osc52.paste("+"), ["*"] = osc52.paste("*") },
  }
end

opt.undofile = true
opt.updatetime = 250
opt.timeoutlen = 400
opt.splitbelow = true
opt.splitright = true
opt.scrolloff = 8
opt.sidescrolloff = 8
opt.laststatus = 3
opt.wrap = false -- no soft-wrap; long lines (incl. wide tables) scroll horizontally

-- Writing-friendly markdown: paragraph numbering in the gutter and a thin ruler
-- at column 80 as a reading guide. 't' is cleared because the bundled markdown
-- ftplugin sets it; otherwise an editorconfig 'max_line_length' would set
-- 'textwidth' and start auto-hard-wrapping prose as you type.
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "markdown", "mdx" },
  callback = function(args)
    vim.opt_local.formatoptions:remove("t") -- never auto-hard-wrap prose
    require("config.markdown_paragraphs").attach(args.buf)
  end,
})

vim.api.nvim_create_autocmd("BufWinEnter", {
  callback = function(args)
    local ft = vim.bo[args.buf].filetype
    local mp = require("config.markdown_paragraphs")
    if ft == "markdown" or ft == "mdx" then
      mp.apply_window()
    else
      mp.detach_window()
    end
  end,
})
