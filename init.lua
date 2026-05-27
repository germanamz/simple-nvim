-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out =
    vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

vim.filetype.add({ extension = { mdx = "mdx" } })

require("config.options")
require("config.lsp_refs").setup()
require("config.statusline").setup()

vim.keymap.set("n", "<leader>k?", function()
  vim.cmd.edit(vim.fn.stdpath("config") .. "/docs/keybindings.md")
end, { desc = "Open keybindings cheatsheet" })

-- Open netrw in the current window. Buffers stay loaded (just hidden);
-- `:b#` or <C-^> jumps back to the previous buffer.
vim.keymap.set("n", "<leader>e", "<cmd>Explore<cr>", { desc = "Open file tree (netrw)" })

if vim.env.NVIM_BOOTSTRAP ~= "0" then
  require("lazy").setup("plugins")
end
