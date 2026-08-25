local nvim_env = require("tests.helpers.nvim_env")

-- Regression net for config.pyright_rules, against a REAL pyright.
--
-- What only a real server can prove
-- ---------------------------------
-- The unit spec pins the in-place mutation contract by asserting on table
-- identity, but identity is a proxy. The fact it stands in for is that
-- `client.settings` is bound BY REFERENCE to `config.settings` at Client.create,
-- which runs BEFORE before_init — so the idiomatic-looking
-- `config.settings = vim.tbl_deep_extend("force", config.settings, {...})`
-- (the pattern printed in Neovim's own client.lua docstring) breaks the aliasing
-- and the server never learns a thing. That failure is completely silent: the
-- config table looks right, the picker looks like it worked, and pyright keeps
-- emitting severity 1. Only a real server distinguishes the two.
--
-- The second half is the live path: cycling a severity mutates the RUNNING
-- client's settings and notifies workspace/didChangeConfiguration. Pyright
-- ignores that notification's payload and re-pulls from client.settings, so the
-- table edit is what does the work and the notify is only the prompt — a
-- distinction that also disappears against a fake server.
--
-- Why the slow lane: self-skips without pyright on PATH, like the rest of
-- `make test-lsp`.
describe("e2e-lsp: per-project pyright rules", function()
  local root, prev_cwd

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
  end)

  after_each(function()
    for _, c in ipairs(vim.lsp.get_clients({ name = "pyright" })) do
      pcall(function()
        c:stop()
      end)
    end
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  -- One example, one isolated env: a second setup_isolated_env() in the same
  -- headless child leaves the LSP log path stale (see lsp_restart_spec).
  it("injects a recorded severity at startup and changes it live without a restart", function()
    if vim.fn.executable("pyright-langserver") ~= 1 then
      pending("pyright-langserver not on PATH (mason server not installed)")
      return
    end

    local canonical = vim.uv.fs_realpath(root) or root
    local proj = canonical .. "/proj"
    vim.fn.mkdir(proj, "p")
    local function write(name, body)
      local path = proj .. "/" .. name
      local fd = assert(io.open(path, "w"))
      fd:write(body)
      fd:close()
      return path
    end
    -- pyproject.toml (with no [tool.pyright] section, so nothing shadows the
    -- editor settings) is what pyright roots at.
    write("pyproject.toml", '[project]\nname = "probe"\nversion = "0.1.0"\n')
    -- A call missing a required argument: reportCallIssue, the same rule the
    -- Pydantic preset targets, without needing pydantic installed.
    local app =
      write("app.py", 'def greet(name: str) -> str:\n    return "hi " + name\n\n\ngreet()\n')
    vim.fn.chdir(proj)

    local rules = require("config.pyright_rules")
    rules._clear()

    -- Recorded BEFORE the client starts, so before_init has something to inject.
    rules.set(proj, "reportCallIssue", "warning")
    assert.are.equal("warning", rules.get(proj).reportCallIssue)

    local buf = vim.fn.bufadd(app)
    vim.fn.bufload(buf)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "python"

    local function live()
      return vim.tbl_filter(function(c)
        return not c:is_stopped()
      end, vim.lsp.get_clients({ bufnr = buf, name = "pyright" }))
    end
    if not vim.wait(30000, function()
      return #live() > 0
    end, 50) then
      pending("pyright did not attach within timeout; treating as unavailable")
      return
    end
    local client = live()[1]

    -- The picker and before_init must agree on the key, or overrides get written
    -- under a root nothing reads.
    assert.are.equal(rules.normalize(proj), rules.resolve_root(buf))

    -- Half one: before_init reached the table the client was bound to.
    assert.are.equal(
      "warning",
      client.settings.python.analysis.diagnosticSeverityOverrides.reportCallIssue
    )

    -- `return nil` is load-bearing, not decoration: without it the function
    -- falls off the end returning ZERO values, and `tostring(severity_of(...))`
    -- in a failure message then raises "bad argument #1 to 'tostring'" — which
    -- replaces the real assertion failure with a useless one.
    local function severity_of(rule)
      for _, d in ipairs(vim.diagnostic.get(buf)) do
        if d.code == rule then
          return d.severity
        end
      end
      return nil
    end

    -- Half two: and the SERVER acted on it. Separated into "did it publish at
    -- all" and "at which severity" on purpose. This lane runs four spec files
    -- concurrently, and a pyright that has not published yet is a slow machine,
    -- not a broken feature — the rest of `make test-lsp` self-skips on the same
    -- reasoning. A diagnostic that DOES arrive at the wrong severity is a real
    -- failure, and is asserted as one. There is no race between the two: the
    -- override is in place before `initialize` is sent, so the first publish
    -- already carries it.
    if
      not vim.wait(60000, function()
        return severity_of("reportCallIssue") ~= nil
      end, 100)
    then
      pending("pyright published no reportCallIssue diagnostic within timeout")
      return
    end
    -- Unconfigured, this rule is an error in every type-checking mode pyright
    -- has, so severity 2 can only come from the override having been honored.
    assert.are.equal(vim.diagnostic.severity.WARN, severity_of("reportCallIssue"))
    assert.are.equal(1, rules.firing(proj).reportCallIssue)

    -- Half three: the live path — no restart, no re-attach. A hard failure if it
    -- does not land: the diagnostic is already published by now, so this is only
    -- waiting on the re-pull, and never arriving means the notify path is broken.
    assert.are.equal("information", rules.cycle(proj, "reportCallIssue"))
    assert.is_true(
      vim.wait(60000, function()
        return severity_of("reportCallIssue") == vim.diagnostic.severity.INFO
      end, 100),
      "cycling did not reach the running client; severity stayed "
        .. tostring(severity_of("reportCallIssue"))
    )
    assert.are.equal(client, live()[1], "the client was restarted rather than updated in place")
  end)
end)
