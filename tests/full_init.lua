-- Full harness for smoke + e2e tests: loads the real init.lua against a
-- pre-warmed cache. Plugin install skipped via NVIM_BOOTSTRAP=0; lazy still
-- resolves plugin specs from the cache for `:Lazy` introspection.
vim.env.NVIM_BOOTSTRAP = "0"

-- Plenary's PlenaryBustedDirectory always passes `--noplugin` to child nvim
-- when `minimal_init` is set. That flips `loadplugins` off, which makes
-- `lazy.setup` short-circuit before registering any specs. Re-enable here
-- so the harness actually mirrors a real boot.
vim.go.loadplugins = true

local config_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.runtimepath:prepend(config_dir)
package.path = config_dir .. "/tests/?.lua;" .. config_dir .. "/tests/?/init.lua;" .. package.path

dofile(config_dir .. "/init.lua")

require("lazy").setup("plugins", {
  install = { missing = false },
  change_detection = { enabled = false },
})

vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
vim.cmd("runtime plugin/plenary.vim")
