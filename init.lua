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

-- Skip python3 provider detection: the bundled python ftplugin's has('python3')
-- check otherwise probes every interpreter on PATH (pyenv shims, ~0.7-1.4s),
-- stalling the first Python buffer. Nothing here uses :python3/pynvim —
-- completion is blink.cmp + pyright, formatting is conform.
vim.g.loaded_python3_provider = 0

-- `.tmpl` defaults to filetype `template` (no parser/LSP). Go projects use it
-- for html/template, so treat it as gohtmltmpl: gotmpl treesitter + injected
-- html + autotag (see lua/plugins/treesitter.lua, lua/plugins/nvim-ts-autotag.lua)
-- without pulling in the html LSP/prettier, which would choke on `{{ ... }}`.
--
-- `.tf` runs through core's detect.tf, which returns `terraform` only once it
-- sees a non-comment line (disambiguating from TinyFugue) — so an empty or
-- comment-only .tf lands on ft `tf` with no parser/LSP/formatter for the whole
-- session (ft isn't re-detected as you type). Pin `.tf` to terraform by
-- extension so support attaches immediately; this box has no TinyFugue files.
vim.filetype.add({ extension = { mdx = "mdx", tmpl = "gohtmltmpl", tf = "terraform" } })

require("config.options")
require("config.lsp_refs").setup()
require("config.statusline").setup()
require("config.block_guides").setup()
require("config.dir_cache").setup()
require("config.ignore_filter").setup()

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

  -- Warn when installed plugin commits drift from lazy-lock.json (see
  -- config.lock_drift). The closure keeps the require deferred so startup
  -- does no extra module load.
  vim.defer_fn(function()
    require("config.lock_drift").check()
  end, 1000)
end
