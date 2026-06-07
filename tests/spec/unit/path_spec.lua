-- Pins util.path.buf_start_dir, the buffer-name -> git-start-directory ladder
-- shared by statusline and gitsigns (statusline had the fuller version; this is
-- now the single source so gitsigns gains the dir-buffer / isdirectory guards).
local path = require("util.path")

describe("util.path.buf_start_dir", function()
  it("returns the parent directory of a file buffer", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, dir .. "/x.lua")
    assert.are.equal(vim.fn.resolve(dir), vim.fn.resolve(path.buf_start_dir(buf)))
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(dir, "rf")
  end)

  it("returns the directory itself when the buffer is named as a directory", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, dir)
    assert.are.equal(vim.fn.resolve(dir), vim.fn.resolve(path.buf_start_dir(buf)))
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(dir, "rf")
  end)

  it("falls back to the cwd for an unnamed buffer", function()
    local buf = vim.api.nvim_create_buf(false, true)
    assert.are.equal(vim.fn.getcwd(), path.buf_start_dir(buf))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
