local opt = vim.opt

-- Line numbers
opt.number = true
opt.relativenumber = false
opt.numberwidth = 4
opt.signcolumn = "yes"       -- always show sign column (prevents jitter)
opt.cursorline = true

-- Whitespace rendering
opt.list = true
opt.listchars = {
  tab = "» ",
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
opt.undofile = true
opt.updatetime = 250
opt.timeoutlen = 400
opt.splitbelow = true
opt.splitright = true
opt.scrolloff = 8
opt.sidescrolloff = 8
opt.wrap = true
opt.linebreak = true         -- wrap at word boundaries, not mid-word
opt.breakindent = true       -- wrapped lines keep indent
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
