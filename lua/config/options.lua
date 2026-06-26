local opt = vim.opt
local ft_util = require("util.ft")

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
  space = "·", -- show interior spaces too, not just leading/trailing
  trail = "·",
  extends = "›",
  precedes = "‹",
  nbsp = "␣",
}
opt.fillchars = { eob = " " }

-- Go (and go.mod) keep real tabs by gofmt convention. Render those tabs with
-- the same leading-space dots ('lead') instead of the global '»' glyph, while
-- preserving the other whitespace markers (trailing spaces, nbsp, …). Width
-- stays at 'tabstop' (2), so each tab shows as 'lead'-repeated columns.
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "go", "gomod" },
  callback = function()
    local chars = vim.opt.listchars:get()
    local dot = chars.lead or "·"
    chars.tab = dot .. dot -- 1st char shown, 2nd repeated to fill the tab width
    vim.opt_local.listchars = chars
  end,
})

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

-- Esc clears the active search, mirroring how VSCode/IntelliJ dismiss a find:
-- drop the match highlights and the search pattern so `n`/`N` won't jump back to
-- stale matches. A fresh `/` search highlights again from scratch. The trailing
-- <esc> preserves Esc's normal job of cancelling a pending count/command.
vim.keymap.set(
  "n",
  "<Esc>",
  "<cmd>nohlsearch<cr><cmd>let @/ = ''<cr><esc>",
  { desc = "Clear search highlight" }
)

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

-- Delete the current buffer without closing its window. When other *real*
-- buffers remain, switch to one first so the window stays on a file instead of
-- collapsing (which would quit nvim if it's the last window). When the last real
-- buffer is closed, fall back to the nvim-tree explorer — the same default view
-- `nvim .` opens — instead of leaving a stuck empty buffer.
--
-- "Real" excludes throwaway [No Name] scratch buffers (the empty startup buffer
-- left listed when you open a file from the tree). Counting those made closing
-- your last file land on the scratch buffer, needing a second <leader>bd to
-- reach the tree; here they don't keep you out of the explorer.
vim.keymap.set("n", "<leader>bd", function()
  local cur = vim.api.nvim_get_current_buf()

  local function is_real(b)
    return vim.bo[b].buflisted and (vim.api.nvim_buf_get_name(b) ~= "" or vim.bo[b].modified)
  end

  local others = vim.tbl_filter(function(b)
    return b ~= cur and is_real(b)
  end, vim.api.nvim_list_bufs())

  if #others > 0 then
    -- Move to a real sibling (prefer the alternate buffer) before deleting, so
    -- the window stays on a file. Don't move off a modified `cur`: skipping the
    -- pre-move keeps `bdelete`'s E89 loud without the view jumping away from a
    -- buffer that wasn't deleted.
    if not vim.bo[cur].modified then
      local alt = vim.fn.bufnr("#")
      local target = (alt ~= -1 and vim.tbl_contains(others, alt)) and alt or others[#others]
      vim.api.nvim_set_current_buf(target)
    end
    vim.cmd("bdelete " .. cur)
    return
  end

  -- No real buffers left: delete cur first so unsaved-changes errors still abort
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
  -- Sweep up the throwaway [No Name] buffers (the startup one, plus the empty
  -- buffer nvim spawns when the last file is deleted) now that they're hidden
  -- behind the tree, so they don't pile up across a session.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.bo[b].buflisted
      and vim.bo[b].buftype == ""
      and not vim.bo[b].modified
      and vim.api.nvim_buf_get_name(b) == ""
    then
      pcall(vim.api.nvim_buf_delete, b, { force = false })
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

-- Writing-friendly markdown: paragraph numbering in the gutter. 't' is cleared
-- because the bundled markdown ftplugin sets it; otherwise an editorconfig
-- 'max_line_length' would set 'textwidth' and start auto-hard-wrapping prose as
-- you type.
vim.api.nvim_create_autocmd("FileType", {
  pattern = ft_util.markdown,
  callback = function(args)
    vim.opt_local.formatoptions:remove("t") -- never auto-hard-wrap prose
    require("config.markdown_paragraphs").attach(args.buf)
  end,
})

vim.api.nvim_create_autocmd("BufWinEnter", {
  callback = function(args)
    local ft = vim.bo[args.buf].filetype
    local mp = require("config.markdown_paragraphs")
    if ft_util.is_markdown(ft) then
      mp.apply_window()
    else
      mp.detach_window()
    end
  end,
})
