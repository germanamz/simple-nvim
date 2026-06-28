-- Minimal harness for unit tests: plenary only, plus the project's lua/ on rtp.
-- Runs against a pre-warmed cache (`make warm` first).
vim.env.NVIM_BOOTSTRAP = "0"

-- Keep tests hermetic: never read or write the user's ShaDa. Specs that load or
-- wipe real file buffers (the git_head lifecycle / statusline scoping tests)
-- otherwise touch the shared state path, which fails on a corrupt or contended
-- shada file and could clobber the user's marks/history.
vim.o.shadafile = "NONE"

local data = vim.fn.stdpath("data")
vim.opt.rtp:prepend(data .. "/lazy/plenary.nvim")

local config_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(config_dir)

package.path = config_dir .. "/tests/?.lua;" .. config_dir .. "/tests/?/init.lua;" .. package.path
