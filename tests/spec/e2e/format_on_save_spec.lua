local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")

-- Exercises the real format-on-save path: conform.nvim is configured with
-- `format_on_save`, so writing a buffer should reformat it via the matching
-- formatter before the bytes hit disk. We use lua/stylua because stylua is a
-- committed dev dependency (`make lint`/`make fmt`), so it's reliably on PATH.
describe("e2e: format on save (conform.nvim)", function()
  local root, prev_cwd

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
  end)

  after_each(function()
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  it("reformats a lua buffer with stylua when written", function()
    if vim.fn.executable("stylua") ~= 1 then
      pending("stylua not on PATH")
      return
    end

    local path = root .. "/sample.lua"
    -- Deliberately unformatted: no spaces around `=`, tight braces. stylua
    -- canonicalizes this to `local x = { 1, 2 }`.
    local unformatted = "local x={1,2}\n"
    local fd = assert(io.open(path, "w"))
    fd:write(unformatted)
    fd:close()

    vim.cmd("edit " .. path)
    local bufnr = vim.api.nvim_get_current_buf()
    assert.are.equal("lua", vim.bo[bufnr].filetype)

    vim.cmd("write")

    wait.wait_for(function()
      local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
      return line == "local x = { 1, 2 }"
    end, 5000, "buffer was not reformatted by stylua on save")

    -- The formatted result must also be what landed on disk.
    local disk = assert(io.open(path, "r")):read("*a")
    assert.are.equal("local x = { 1, 2 }\n", disk)
  end)
end)
