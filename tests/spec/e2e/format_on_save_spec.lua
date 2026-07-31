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

  it("does not reformat on save when format-on-save is disabled", function()
    if vim.fn.executable("stylua") ~= 1 then
      pending("stylua not on PATH")
      return
    end

    local unformatted = "local x={1,2}\n"
    local path = root .. "/disabled.lua"
    local fd = assert(io.open(path, "w"))
    fd:write(unformatted)
    fd:close()

    -- Build the buffer via the API rather than :edit: a second lua :edit
    -- across a fresh isolated env re-triggers the LSP-attach path and can
    -- error on a stale lsp.log. We only need a named, lua-filetype buffer
    -- with reformattable content for conform's BufWritePre gate to see.
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, path)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = "lua"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local x={1,2}" })

    vim.g.disable_autoformat = true
    local ok, err = pcall(function()
      vim.cmd("write!") -- overwrite the pre-existing file; triggers BufWritePre
      -- Buffer stays verbatim: the gate returned nil, so conform never ran.
      assert.are.equal("local x={1,2}", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
      local disk = assert(io.open(path, "r")):read("*a")
      assert.are.equal(unformatted, disk)
    end)
    vim.g.disable_autoformat = false -- restore even if the assertions threw
    assert(ok, err)

    -- Sanity: on-demand formatting is unaffected by the on-save gate.
    require("conform").format({ async = false, timeout_ms = 10000, bufnr = bufnr })
    assert.are.equal("local x = { 1, 2 }", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
  end)

  it("honors a per-buffer disable without affecting other buffers", function()
    if vim.fn.executable("stylua") ~= 1 then
      pending("stylua not on PATH")
      return
    end

    local unformatted = "local x={1,2}\n"
    local off_path = root .. "/buf_off.lua"
    local on_path = root .. "/buf_on.lua"
    for _, p in ipairs({ off_path, on_path }) do
      local fd = assert(io.open(p, "w"))
      fd:write(unformatted)
      fd:close()
    end

    local function new_lua_buf(path)
      local b = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(b, path)
      vim.api.nvim_set_current_buf(b)
      vim.bo[b].filetype = "lua"
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "local x={1,2}" })
      return b
    end

    -- Buffer A: disabled for this buffer only (the :FormatDisable! path).
    local buf_off = new_lua_buf(off_path)
    local ok, err = pcall(function()
      vim.b[buf_off].disable_autoformat = true
      vim.cmd("write!")
      assert.are.equal("local x={1,2}", vim.api.nvim_buf_get_lines(buf_off, 0, 1, false)[1])
      assert.are.equal(unformatted, assert(io.open(off_path, "r")):read("*a"))
      -- The disable is buffer-scoped: the global flag stays off.
      assert.is_falsy(vim.g.disable_autoformat)

      -- Buffer B: a different buffer with no flag still reformats on save.
      local buf_on = new_lua_buf(on_path)
      vim.cmd("write!")
      assert.are.equal("local x = { 1, 2 }", vim.api.nvim_buf_get_lines(buf_on, 0, 1, false)[1])
      assert.are.equal("local x = { 1, 2 }\n", assert(io.open(on_path, "r")):read("*a"))
    end)
    pcall(function()
      vim.b[buf_off].disable_autoformat = false
    end)
    assert(ok, err)
  end)

  -- The defect this whole feature exists to fix: a project with no prettier config
  -- must come back byte-identical, because prettier's own default is
  -- singleQuote:false and imposing it rewrites a single-quoted codebase.
  --
  -- The buffer is built through the API rather than :edit on purpose. In this
  -- harness, editing a file with an LSP filetype after the first isolated env
  -- errors mid-BufReadPost on an lsp.log path cached from the torn-down env, and
  -- the error leaks into the next spec. nvim_buf_set_name + :write still runs
  -- BufWritePre and conform, and never enters the BufReadPost chain.
  local function write_buffer(path, contents)
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, path)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(contents, "\n", { plain = true }))
    vim.api.nvim_buf_call(bufnr, function()
      vim.bo.filetype = "typescript"
      vim.cmd("write")
    end)
    return bufnr
  end

  it("leaves a TS buffer untouched when the project configures no formatter", function()
    if vim.fn.executable("prettierd") ~= 1 and vim.fn.executable("prettier") ~= 1 then
      pending("no prettier on PATH")
      return
    end
    require("config.js_toolchain")._clear()

    local source = "import { a } from './a';\n"
    local path = root .. "/unconfigured.ts"
    local bufnr = write_buffer(path, source)

    wait.wait_for(function()
      return vim.fn.filereadable(path) == 1
    end, 5000, "file was never written")

    local disk = assert(io.open(path, "r")):read("*a")
    assert.is_truthy(disk:find("from './a';", 1, true), "single quotes were rewritten: " .. disk)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("formats a TS buffer with prettier when the project configures it", function()
    if vim.fn.executable("prettierd") ~= 1 and vim.fn.executable("prettier") ~= 1 then
      pending("no prettier on PATH")
      return
    end
    require("config.js_toolchain")._clear()

    local rc = assert(io.open(root .. "/.prettierrc", "w"))
    rc:write('{"singleQuote": true}\n')
    rc:close()

    local path = root .. "/configured.ts"
    local bufnr = write_buffer(path, 'import { a }   from "./a";\n')

    wait.wait_for(function()
      local disk = io.open(path, "r")
      if not disk then
        return false
      end
      local body = disk:read("*a")
      disk:close()
      return body:find("from './a';", 1, true) ~= nil
    end, 5000, "prettier did not apply the project's singleQuote setting")

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
