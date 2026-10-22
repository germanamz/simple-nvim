local nvim_env = require("tests.helpers.nvim_env")

-- Python navigation against the REAL type server (basedpyright).
--
-- The complaint this config change answers: in a project split across files
-- and classes, `gd` on a method called through a base class lands on the
-- abstract method, and nothing then leads to the concrete one. That `gd`
-- behaviour is correct — go-to-definition resolves on the declared type in
-- every editor — so it is pinned here, not fixed. What was missing was the
-- second command: plain pyright answered textDocument/implementation with
-- -32601. This spec proves the replacement answers it, including for a class
-- that satisfies a Protocol without inheriting from it, and that the per-root
-- wiring (config.python_lsp) reaches the running server:
--   * the project's venv arrives as python.pythonPath, and the statusline
--     names it;
--   * exactly one server answers definition requests on a Python buffer, so
--     `gd` jumps instead of opening a list of the same place twice;
--   * `grc` lists callers through config.tagstack.
--
-- One example, one isolated env: a second setup_isolated_env() in the same
-- headless child leaves the LSP log path stale (see lsp_restart_spec). Files
-- are loaded with bufadd/bufload: the LSP plugin lazy-loads on BufReadPre,
-- which only a real read fires. Self-skips without the server on PATH, like
-- the rest of `make test-lsp`.
describe("e2e-lsp: python navigation", function()
  local root, prev_cwd
  local python_lsp = require("config.python_lsp")

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
  end)

  after_each(function()
    for _, c in ipairs(vim.lsp.get_clients()) do
      pcall(function()
        c:stop(true)
      end)
    end
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  it("finds implementations behind a base class and a Protocol", function()
    if vim.fn.executable(python_lsp.server .. "-langserver") ~= 1 then
      pending(python_lsp.server .. "-langserver not on PATH (mason server not installed)")
      return
    end
    local python3 = vim.fn.exepath("python3")
    if python3 == "" then
      pending("no python3 on PATH to stand in for the project interpreter")
      return
    end

    local proj = (vim.uv.fs_realpath(root) or root) .. "/proj"
    local function write(name, lines)
      local path = proj .. "/" .. name
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      vim.fn.writefile(lines, path)
      return path
    end
    write("pyproject.toml", { "[project]", 'name = "probe"', 'version = "0.1.0"' })
    -- A venv as uv leaves it. bin/python is the real interpreter so the server
    -- can ask it for sys.path, exactly as it would a real venv's.
    write(".venv/pyvenv.cfg", { "home = /usr/bin" })
    vim.fn.mkdir(proj .. "/.venv/bin", "p")
    vim.fn.mkdir(proj .. "/.venv/lib/python3.12/site-packages", "p")
    assert(vim.uv.fs_symlink(python3, proj .. "/.venv/bin/python"))

    write("repo.py", {
      "from abc import ABC, abstractmethod", --  0
      "from typing import Protocol", --  1
      "", --  2
      "", --  3
      "class Repo(ABC):", --  4
      "    @abstractmethod", --  5
      "    def save(self, item: int) -> None: ...", --  6
      "", --  7
      "", --  8
      "class SqlRepo(Repo):", --  9
      "    def save(self, item: int) -> None:", -- 10
      "        print(item)", -- 11
      "", -- 12
      "", -- 13
      "class Saver(Protocol):", -- 14
      "    def save(self, item: int) -> None: ...", -- 15
      "", -- 16
      "", -- 17
      "class FileSaver:", -- 18  satisfies Saver, never names it
      "    def save(self, item: int) -> None:", -- 19
      "        print(item)", -- 20
    })
    local app = write("app.py", {
      "from repo import FileSaver, Repo, Saver, SqlRepo", -- 0
      "", -- 1
      "", -- 2
      "def run(r: Repo) -> None:", -- 3
      "    r.save(1)", -- 4
      "", -- 5
      "", -- 6
      "def store(s: Saver) -> None:", -- 7
      "    s.save(2)", -- 8
      "", -- 9
      "", -- 10
      "def main() -> None:", -- 11
      "    run(SqlRepo())", -- 12
      "    store(FileSaver())", -- 13
    })
    vim.fn.chdir(proj)

    local buf = vim.fn.bufadd(app)
    vim.fn.bufload(buf)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "python"

    local function live()
      return vim.tbl_filter(function(c)
        return not c:is_stopped() and c.initialized
      end, vim.lsp.get_clients({ bufnr = buf, name = python_lsp.server }))
    end
    if not vim.wait(30000, function()
      return #live() > 0
    end, 50) then
      pending(python_lsp.server .. " did not attach within timeout; treating as unavailable")
      return
    end
    local client = live()[1]

    -- The interpreter reached the running client, and the statusline says so.
    assert.are.equal(proj .. "/.venv/bin/python", client.settings.python.pythonPath)
    assert.are.equal(" py:.venv ", python_lsp.status(buf))

    -- One navigation server: Neovim merges location answers from every client.
    assert.are.equal(
      1,
      #vim.lsp.get_clients({ bufnr = buf, method = "textDocument/definition" }),
      "more than one server answers definition requests on a Python buffer"
    )

    -- "file:line" for each location a request returns, retried while the
    -- server is still analysing (an empty answer then is a slow machine, not a
    -- broken feature). An ERROR answer is final and comes back as the second
    -- value: that is how plain pyright refuses textDocument/implementation
    -- (-32601), and waiting it out would only turn a clear failure into a
    -- timeout.
    local function lines_of(method, line, character)
      local params = {
        textDocument = { uri = vim.uri_from_bufnr(buf) },
        position = { line = line, character = character },
      }
      local found, err = {}, nil
      vim.wait(30000, function()
        local res = client:request_sync(method, params, 10000, buf)
        if res and res.err then
          err = res.err.message or vim.inspect(res.err)
          return true
        end
        local result = res and res.result
        if type(result) ~= "table" then
          return false
        end
        result = (result.uri or result.targetUri) and { result } or result
        found = {}
        for _, loc in ipairs(result) do
          local uri = loc.uri or loc.targetUri
          local range = loc.targetSelectionRange or loc.range
          found[#found + 1] = vim.fs.basename(vim.uri_to_fname(uri)) .. ":" .. range.start.line
        end
        return #found > 0
      end, 250)
      table.sort(found)
      return found, err
    end

    local function assert_reaches(method, line, character, want, what)
      local found, err = lines_of(method, line, character)
      assert.is_true(
        vim.list_contains(found, want),
        ("%s: wanted %s, got {%s}%s"):format(
          what,
          want,
          table.concat(found, ", "),
          err and (" — server error: " .. err) or ""
        )
      )
    end

    -- `gd` through the base type: the abstract method, by design.
    assert.are.same({ "repo.py:6" }, (lines_of("textDocument/definition", 4, 6)))
    -- `gri` through the base type: the concrete override.
    assert_reaches("textDocument/implementation", 4, 6, "repo.py:10", "SqlRepo.save")
    -- `gri` through a Protocol: a class that never names it.
    assert_reaches("textDocument/implementation", 8, 6, "repo.py:19", "FileSaver.save")

    -- The keys are there, routed through the definition stack.
    local maps = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      maps[m.lhs] = m.desc
    end
    assert.are.equal("Implementation", maps["gri"])
    assert.are.equal("Callers", maps["grc"])
    assert.are.equal("Goto declaration (stub)", maps["gD"])

    -- `grc` on `run`: its one caller, `main`, jumped to directly.
    vim.api.nvim_win_set_cursor(0, { 4, 4 })
    require("config.tagstack").calls("incoming")
    assert.is_true(
      vim.wait(30000, function()
        return vim.api.nvim_win_get_cursor(0)[1] == 13
      end, 100),
      "grc did not land on run's caller; cursor at line " .. vim.api.nvim_win_get_cursor(0)[1]
    )
    assert.are.equal(app, vim.api.nvim_buf_get_name(0))
    assert.are.equal(1, vim.fn.gettagstack().length, "grc did not record a hop for <C-t>")
  end)
end)
