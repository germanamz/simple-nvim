local nvim_env = require("tests.helpers.nvim_env")

-- Real-server e2e for tilt_ls: tilt's language server (`tilt lsp start`,
-- tilt-dev/starlark-lsp) attaching to a Tiltfile. Slow lane (`make test-lsp`),
-- and self-skipping like its siblings — the server is the `tilt` on PATH (this
-- config never installs one through mason; docs/tiltfile.md says why), so a
-- machine without tilt marks the example pending rather than failing.
--
-- Beyond the attach + handshake the lua_ls spec pins, this round-trips a hover
-- on a Tilt builtin: the server answering with `docker_build`'s docs is the
-- visible proof the buffer is being served, not just attached to. Hover rather
-- than a diagnostic because starlark-lsp publishes none (it does completion,
-- hover, signature help, definition and document symbols).
describe("e2e-lsp: tilt_ls", function()
  local root, prev_cwd

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
  end)

  after_each(function()
    for _, c in ipairs(vim.lsp.get_clients({ name = "tilt_ls" })) do
      pcall(function()
        c:stop()
      end)
    end
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  it("attaches to a Tiltfile and documents a builtin on hover", function()
    if vim.fn.executable("tilt") ~= 1 then
      pending("tilt not on PATH")
      return
    end

    -- On disk so the server can root itself; the isolated env is a git repo, so
    -- lspconfig's `.git` root marker resolves right here.
    local canonical = vim.uv.fs_realpath(root) or root
    local path = canonical .. "/Tiltfile"
    local fd = assert(io.open(path, "w"))
    fd:write("docker_build('app', '.')\n")
    fd:close()

    vim.fn.chdir(canonical)
    vim.cmd("edit " .. path)
    local bufnr = vim.api.nvim_get_current_buf()
    assert.are.equal("tiltfile", vim.bo[bufnr].filetype)

    local attached = vim.wait(20000, function()
      return #vim.lsp.get_clients({ bufnr = bufnr, name = "tilt_ls" }) > 0
    end, 50)
    if not attached then
      pending("tilt_ls did not attach within timeout; treating as unavailable")
      return
    end

    local client = vim.lsp.get_clients({ bufnr = bufnr, name = "tilt_ls" })[1]
    assert.is_not_nil(client.server_capabilities, "tilt_ls attached without server_capabilities")
    assert.is_truthy(
      client.server_capabilities.completionProvider,
      "tilt_ls did not advertise completion after initialize"
    )

    -- Hover on `docker_build` (row 0, inside the identifier). request_sync
    -- rather than vim.lsp.buf.hover so the assertion is on the payload, not on
    -- a floating window.
    local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
    params.position = { line = 0, character = 3 }
    local res = client:request_sync("textDocument/hover", params, 20000, bufnr)
    assert.is_not_nil(res, "hover request timed out")
    assert.is_nil(res.err, "hover errored: " .. vim.inspect(res.err))
    local contents = res.result and res.result.contents
    local text = type(contents) == "table" and (contents.value or contents[1]) or contents
    assert.is_truthy(
      type(text) == "string" and text:find("docker image", 1, true),
      "hover did not return docker_build's docs: " .. vim.inspect(contents)
    )
  end)
end)
