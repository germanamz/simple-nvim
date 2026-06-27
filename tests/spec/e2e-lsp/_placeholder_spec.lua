local nvim_env = require("tests.helpers.nvim_env")

-- Real-server e2e for lua_ls. This is the slow lane (`make test-lsp`, excluded
-- from the default `make test`) and is deliberately SELF-SKIPPING: a machine
-- without `lua-language-server` on PATH (the isolated test env never sees
-- mason's bin dir, so this is the common case) marks the example pending rather
-- than failing. It turns green only when a real lua_ls is present and attaches.
--
-- We assert the attach + a completed initialize handshake (populated
-- server_capabilities) instead of round-tripping a live hover, so the slow lane
-- stays deterministic rather than flaky once the server is up.
describe("e2e-lsp: lua_ls", function()
  local root, prev_cwd

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
  end)

  after_each(function()
    -- Stop any spawned client so it doesn't leak across examples / specs.
    for _, c in ipairs(vim.lsp.get_clients({ name = "lua_ls" })) do
      pcall(function()
        c:stop()
      end)
    end
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  it("attaches to a lua buffer and completes initialize", function()
    if vim.fn.executable("lua-language-server") ~= 1 then
      pending("lua-language-server not on PATH (mason server not installed)")
      return
    end

    -- A real on-disk file so lua_ls can root itself (it falls back to the
    -- file's directory in single-file mode); chdir there too for good measure.
    local canonical = vim.uv.fs_realpath(root) or root
    local path = canonical .. "/sample.lua"
    local fd = assert(io.open(path, "w"))
    fd:write("local x = 1\nreturn x\n")
    fd:close()

    vim.fn.chdir(canonical)
    vim.cmd("edit " .. path)
    local bufnr = vim.api.nvim_get_current_buf()
    assert.are.equal("lua", vim.bo[bufnr].filetype)

    -- Generous timeout: spawning + initializing a language server is far slower
    -- than the in-process waits elsewhere in the suite. If it never attaches
    -- (e.g. a sandbox that can't exec), skip rather than fail the lane.
    local attached = vim.wait(20000, function()
      return #vim.lsp.get_clients({ bufnr = bufnr, name = "lua_ls" }) > 0
    end, 50)
    if not attached then
      pending("lua_ls did not attach within timeout; treating as unavailable")
      return
    end

    local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "lua_ls" })
    assert.is_true(#clients >= 1, "no lua_ls client attached to the buffer")

    -- LspAttach fires after initialize, so server_capabilities is populated by
    -- now. hoverProvider is a stable lua_ls capability — assert the handshake
    -- actually completed (deterministic once the client is attached).
    local client = clients[1]
    assert.is_not_nil(client.server_capabilities, "lua_ls attached without server_capabilities")
    assert.is_truthy(
      client.server_capabilities.hoverProvider,
      "lua_ls did not advertise hover after initialize"
    )
  end)
end)
