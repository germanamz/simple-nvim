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

-- Misc quality-of-life
opt.termguicolors = true
opt.mouse = "a"
opt.clipboard = "unnamedplus"

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
opt.laststatus = 2
opt.wrap = true
opt.linebreak = true -- wrap at word boundaries, not mid-word
opt.breakindent = true -- wrapped lines keep indent
opt.showbreak = "↪ "

-- Force wrap inside diff mode (vim disables it by default, diffview inherits)
vim.api.nvim_create_autocmd({ "OptionSet" }, {
  pattern = "diff",
  callback = function()
    if vim.v.option_new == "1" then
      vim.opt_local.wrap = true
      vim.opt_local.linebreak = true
    end
  end,
})
vim.api.nvim_create_autocmd({ "FileType" }, {
  pattern = { "DiffviewFiles", "DiffviewFileHistory" },
  callback = function()
    vim.opt_local.wrap = true
    vim.opt_local.linebreak = true
  end,
})

-- Writing-friendly markdown: paragraph numbering in gutter, thin ruler line at
-- column 80, hard-wrap before the word that would push past textwidth.
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "markdown", "mdx" },
  callback = function(args)
    vim.opt_local.textwidth = 80
    vim.opt_local.formatoptions:append("t") -- auto-wrap text using textwidth
    vim.keymap.set("n", "<leader>w", "gqG", {
      buffer = args.buf,
      desc = "Rewrap from cursor to end of file",
    })
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
