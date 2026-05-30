-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
-- True on a fresh machine where lazy.nvim is not yet present. lazy.nvim
-- auto-installs missing plugins at branch HEAD (it ignores lazy-lock.json on
-- first install), so we restore to the locked commits afterwards.
local fresh_install = not (vim.uv or vim.loop).fs_stat(lazypath)
if fresh_install then
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

-- netrw fallback (nvim-tree owns <leader>e). Buffers stay loaded (just
-- hidden); `:b#` or <C-^> jumps back to the previous buffer.
vim.keymap.set("n", "<leader>E", "<cmd>Explore<cr>", { desc = "Open file tree (netrw)" })

if vim.env.NVIM_BOOTSTRAP ~= "0" then
  require("lazy").setup("plugins")

  -- On a fresh machine, snap every plugin to the commit pinned in
  -- lazy-lock.json so all computers load identical versions.
  if fresh_install then
    require("lazy").restore({ wait = true })
  end
end
