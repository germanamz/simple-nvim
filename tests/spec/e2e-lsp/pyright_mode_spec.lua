local nvim_env = require("tests.helpers.nvim_env")

-- Regression net for config.pyright_mode, against the REAL Python type server.
--
-- What only a real server can prove
-- ---------------------------------
-- The unit spec pins what the module writes. That the writing WORKS rests on
-- three facts about basedpyright that a fake server cannot stand in for:
--   * a [tool.pyright] section that sets no mode puts the server in its
--     "recommended" mode, editor settings notwithstanding — so a rule plain
--     pyright does not have (reportImplicitStringConcatenation) fires;
--   * an untracked pyrightconfig.json outranks that pyproject.toml, and its
--     "extends" still pulls the project's settings in;
--   * the restart makes the new file land without file watching.
-- After :PythonQuiet the recommended-only rule must be gone while the
-- standard-mode error (reportCallIssue) stays: quieter, not switched off.
--
-- Why the slow lane: self-skips without the server on PATH, like the rest of
-- `make test-lsp`.
describe("e2e-lsp: type-checking mode of a project with its own config", function()
  local root, prev_cwd, prev_notify, sent
  local server = require("config.python_lsp").server

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
    prev_notify = vim.notify
    sent = {}
    vim.notify = function(msg, level)
      table.insert(sent, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.notify = prev_notify
    for _, c in ipairs(vim.lsp.get_clients({ name = server })) do
      pcall(function()
        c:stop()
      end)
    end
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  local function said(text)
    for _, n in ipairs(sent) do
      if n.msg:find(text, 1, true) then
        return n
      end
    end
    return nil
  end

  -- One example, one isolated env: a second setup_isolated_env() in the same
  -- headless child leaves the LSP log path stale (see lsp_restart_spec).
  it("warns about recommended mode, and :PythonQuiet brings it down to standard", function()
    if vim.fn.executable(server .. "-langserver") ~= 1 then
      pending(server .. "-langserver not on PATH (mason server not installed)")
      return
    end

    local canonical = vim.uv.fs_realpath(root) or root
    local proj = canonical .. "/proj"
    vim.fn.mkdir(proj, "p")
    vim.fn.system({ "git", "-C", proj, "init", "-q" })
    assert.are.equal(0, vim.v.shell_error, "git init failed")
    local function write(name, body)
      local path = proj .. "/" .. name
      local fd = assert(io.open(path, "w"))
      fd:write(body)
      fd:close()
      return path
    end
    -- The project configures the checker but leaves the mode unset.
    write("pyproject.toml", '[project]\nname = "probe"\nversion = "0.1.0"\n\n[tool.pyright]\n')
    local app = write(
      "app.py",
      'def greet(name: str) -> str:\n    return "hi " + name\n\n\ngreet()\nGREETING = "a" "b"\n'
    )
    vim.fn.chdir(proj)

    require("config.pyright_mode")._clear()

    local buf = vim.fn.bufadd(app)
    vim.fn.bufload(buf)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "python"

    local function live()
      return vim.tbl_filter(function(c)
        return not c:is_stopped()
      end, vim.lsp.get_clients({ bufnr = buf, name = server }))
    end
    if not vim.wait(20000, function()
      return #live() > 0
    end, 50) then
      pending(server .. " did not attach within timeout; treating as unavailable")
      return
    end
    local first = live()[1]

    -- The warning went out on attach, naming the file and the way out.
    local warning = said("sets no typeCheckingMode")
    assert.is_not_nil(warning, "no warning on attach; sent: " .. vim.inspect(sent))
    assert.is_truthy(warning.msg:find("pyproject.toml", 1, true))
    assert.is_truthy(warning.msg:find(":PythonQuiet", 1, true))

    local function has(rule)
      for _, d in ipairs(vim.diagnostic.get(buf)) do
        if d.code == rule then
          return true
        end
      end
      return false
    end

    -- A slow server is a slow machine, not a broken feature (the rest of the
    -- lane self-skips on the same reasoning).
    if
      not vim.wait(15000, function()
        return has("reportImplicitStringConcatenation")
      end, 100)
    then
      pending(server .. " published no recommended-mode diagnostic within timeout")
      return
    end

    vim.cmd("PythonQuiet")

    assert.are.equal("standard", require("config.pyright_mode").mode(proj .. "/pyrightconfig.json"))
    local exclude = table.concat(vim.fn.readfile(proj .. "/.git/info/exclude"), "\n")
    assert.is_truthy(exclude:find("/pyrightconfig.json", 1, true))
    assert.is_not_nil(said(server .. " restarted"), "no restart; sent: " .. vim.inspect(sent))

    -- A hard failure from here on: the server was already publishing, so a
    -- restarted one that never drops the rule means the override did not land.
    assert.is_true(
      vim.wait(20000, function()
        local now = live()[1]
        return now ~= nil
          and now.id ~= first.id
          and has("reportCallIssue")
          and not has("reportImplicitStringConcatenation")
      end, 100),
      "after :PythonQuiet the recommended-only rule still fires (or the server never came back)"
    )
  end)
end)
