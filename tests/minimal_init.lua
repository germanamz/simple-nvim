-- Minimal harness for unit tests: plenary only, plus the project's lua/ on rtp.
-- Runs against a pre-warmed cache (`make warm` first).
vim.env.NVIM_BOOTSTRAP = "0"

local data = vim.fn.stdpath("data")
vim.opt.rtp:prepend(data .. "/lazy/plenary.nvim")

local config_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(config_dir)

package.path = config_dir .. "/tests/?.lua;" .. config_dir .. "/tests/?/init.lua;" .. package.path
