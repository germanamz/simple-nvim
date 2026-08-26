local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")

-- Real-server e2e for zls (zigtools/zls) attaching to a Zig buffer. Slow lane
-- (`make test-lsp`), and self-skipping like its siblings when the binary isn't
-- reachable — mason's bin dir is not on the shell PATH by default, so this
-- marks pending rather than failing on a machine that never ran `make sync`.
--
-- The assertion is a DIAGNOSTIC, not a hover, and that choice is the point of
-- the test. This config deliberately ships no nvim-lint pass for Zig: zls runs
-- `zig ast-check` internally and publishes the result, so the server being
-- attached is not enough — it has to actually be the thing reporting errors, or
-- Zig buffers are silently unlinted. An undeclared identifier (rather than a
-- syntax error) is used because it only surfaces if that semantic pass really
-- is running; a broken paren would be caught by the parser alone.
describe("e2e-lsp: zls", function()
  local root, prev_cwd

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
  end)

  after_each(function()
    for _, c in ipairs(vim.lsp.get_clients({ name = "zls" })) do
      pcall(function()
        c:stop()
      end)
    end
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  it("attaches to a zig buffer and reports an undeclared identifier", function()
    if vim.fn.executable("zls") ~= 1 then
      pending("zls not on PATH")
      return
    end

    -- On disk so the server can root itself; the isolated env is a git repo, so
    -- lspconfig's `.git` root marker resolves right here.
    local canonical = vim.uv.fs_realpath(root) or root
    local path = canonical .. "/main.zig"
    local fd = assert(io.open(path, "w"))
    fd:write("pub fn main() void {\n    nonexistent_function();\n}\n")
    fd:close()

    vim.fn.chdir(canonical)
    vim.cmd("edit " .. path)
    local bufnr = vim.api.nvim_get_current_buf()
    assert.are.equal("zig", vim.bo[bufnr].filetype)

    wait.wait_for(function()
      return #vim.lsp.get_clients({ bufnr = bufnr, name = "zls" }) > 0
    end, 20000, "zls never attached to the zig buffer")

    wait.wait_for(function()
      for _, d in ipairs(vim.diagnostic.get(bufnr)) do
        if d.message:find("nonexistent_function", 1, true) then
          return true
        end
      end
      return false
    end, 20000, "zls published no diagnostic naming the undeclared identifier")
  end)
end)
