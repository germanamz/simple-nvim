-- Pins config.python_root: where the Python type server is rooted.
--
-- lspconfig's root_markers for basedpyright are an ordered list whose search
-- stops at the first directory holding a marker, and pyproject.toml outranks
-- .git. In a uv workspace every member has a pyproject.toml, so each member got
-- its own server, each seeing only its own files for references and
-- implementations, and none of them finding the workspace's single `.venv`.
--
-- The rule, in order, each search bounded by the repository root:
--   1. the nearest directory that configures the type checker
--      (pyrightconfig.json, or [tool.pyright] / [tool.basedpyright] in its
--      pyproject.toml) — in language-server mode the server reads its config
--      only from the root, so rooting anywhere else silently drops that config;
--   2. the nearest pyproject.toml with a lockfile beside it — a uv workspace
--      keeps its one uv.lock at the top, while poetry/pdm projects and
--      independent uv projects nested in one repo each carry their own;
--   3. the nearest pyproject.toml;
--   4. otherwise nil, and the caller falls back to lspconfig's own markers.
local M = require("config.python_root")

describe("config.python_root.find", function()
  local dir

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    dir = vim.uv.fs_realpath(dir)
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  local function touch(rel, body)
    local path = dir .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "w"))
    f:write(body or "")
    f:close()
  end

  local function mkdir(rel)
    vim.fn.mkdir(dir .. "/" .. rel, "p")
    return dir .. "/" .. rel
  end

  local PROJECT = '[project]\nname = "x"\n'

  it("roots a uv workspace member at the workspace", function()
    touch("ws/pyproject.toml", PROJECT .. "\n[tool.uv.workspace]\nmembers = ['packages/*']\n")
    touch("ws/uv.lock")
    touch("ws/packages/api/pyproject.toml", PROJECT)
    local start = mkdir("ws/packages/api/src/api")
    assert.are.equal(dir .. "/ws", M.find(start, dir .. "/ws"))
  end)

  it("keeps an independent project with its own lockfile at its own root", function()
    touch("repo/tools/pyproject.toml", PROJECT)
    touch("repo/tools/uv.lock")
    touch("repo/svc/pyproject.toml", PROJECT)
    touch("repo/svc/poetry.lock")
    local start = mkdir("repo/svc/app")
    assert.are.equal(dir .. "/repo/svc", M.find(start, dir .. "/repo"))
  end)

  it("roots at the nearest pyproject.toml when no lockfile exists", function()
    touch("repo/pyproject.toml", PROJECT)
    touch("repo/lib/pyproject.toml", PROJECT)
    local start = mkdir("repo/lib/pkg")
    assert.are.equal(dir .. "/repo/lib", M.find(start, dir .. "/repo"))
  end)

  it("lets a pyrightconfig.json outrank a workspace lockfile", function()
    touch("ws/pyproject.toml", PROJECT)
    touch("ws/uv.lock")
    touch("ws/packages/api/pyproject.toml", PROJECT)
    touch("ws/packages/api/pyrightconfig.json", "{}")
    local start = mkdir("ws/packages/api/src")
    assert.are.equal(dir .. "/ws/packages/api", M.find(start, dir .. "/ws"))
  end)

  it("treats a [tool.pyright] section as type-checker config", function()
    touch("ws/pyproject.toml", PROJECT)
    touch("ws/uv.lock")
    touch("ws/packages/api/pyproject.toml", PROJECT .. "\n[tool.pyright]\nstrict = ['.']\n")
    local start = mkdir("ws/packages/api/src")
    assert.are.equal(dir .. "/ws/packages/api", M.find(start, dir .. "/ws"))
  end)

  it("treats a [tool.basedpyright] section as type-checker config", function()
    touch("ws/pyproject.toml", PROJECT)
    touch("ws/uv.lock")
    touch("ws/packages/api/pyproject.toml", PROJECT .. "\n[tool.basedpyright]\n")
    local start = mkdir("ws/packages/api/src")
    assert.are.equal(dir .. "/ws/packages/api", M.find(start, dir .. "/ws"))
  end)

  it("roots at a workspace that carries the config itself", function()
    touch("ws/pyproject.toml", PROJECT .. "\n[tool.pyright]\n")
    touch("ws/uv.lock")
    touch("ws/packages/api/pyproject.toml", PROJECT)
    local start = mkdir("ws/packages/api")
    assert.are.equal(dir .. "/ws", M.find(start, dir .. "/ws"))
  end)

  it("does not count a commented-out section header", function()
    touch("ws/pyproject.toml", PROJECT)
    touch("ws/uv.lock")
    touch("ws/packages/api/pyproject.toml", PROJECT .. "# [tool.pyright]\n")
    local start = mkdir("ws/packages/api")
    assert.are.equal(dir .. "/ws", M.find(start, dir .. "/ws"))
  end)

  it("never roots above the repository", function()
    touch("pyproject.toml", PROJECT)
    touch("uv.lock")
    touch("repo/pyproject.toml", PROJECT)
    local start = mkdir("repo/pkg")
    assert.are.equal(dir .. "/repo", M.find(start, dir .. "/repo"))
  end)

  it("returns nil when the repository has no Python project marker", function()
    touch("pyproject.toml", PROJECT)
    local start = mkdir("repo/scripts")
    assert.is_nil(M.find(start, dir .. "/repo"))
  end)

  it("searches upward without a bound when there is no repository", function()
    touch("proj/pyproject.toml", PROJECT)
    local start = mkdir("proj/a/b")
    assert.are.equal(dir .. "/proj", M.find(start, nil))
  end)

  it("starts at the directory itself", function()
    touch("proj/pyproject.toml", PROJECT)
    touch("proj/uv.lock")
    assert.are.equal(dir .. "/proj", M.find(dir .. "/proj", dir .. "/proj"))
  end)

  describe("root_dir", function()
    local function resolve(file)
      local buf = vim.fn.bufadd(file)
      local got, called = nil, false
      M.root_dir(buf, function(d)
        got, called = d, true
      end)
      vim.api.nvim_buf_delete(buf, { force = true })
      assert.is_true(called, "root_dir must always call back")
      return got
    end

    it("bounds the search by the repository holding the buffer", function()
      touch("ws/.git/HEAD", "ref: refs/heads/main\n")
      touch("ws/pyproject.toml", PROJECT)
      touch("ws/uv.lock")
      touch("ws/packages/api/pyproject.toml", PROJECT)
      assert.are.equal(dir .. "/ws", resolve(dir .. "/ws/packages/api/mod.py"))
    end)

    it("falls back to lspconfig's markers for a project with no pyproject.toml", function()
      touch("repo/.git/HEAD", "ref: refs/heads/main\n")
      touch("repo/legacy/setup.py")
      assert.are.equal(dir .. "/repo/legacy", resolve(dir .. "/repo/legacy/mod.py"))
    end)
  end)
end)
