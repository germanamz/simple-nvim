-- Pins config.python_env: which interpreter a Python project runs, shared by
-- the type server (config.python_lsp feeds it to basedpyright as pythonPath)
-- and the docs adapter (pydoc must run against the project's packages).
--
-- The case that motivated pulling it out of the docs adapter is a uv
-- workspace: one `.venv` at the workspace top, members below it with their own
-- pyproject.toml. A root-only lookup from a member finds nothing, the server
-- falls back to `python` on PATH, and every third-party import resolves to the
-- bundled stubs or to nothing at all.
local M = require("config.python_env")

describe("config.python_env", function()
  local dir, saved_venv, saved_pyenv

  before_each(function()
    -- Resolved: on macOS tempname() is under /var, a symlink to /private/var,
    -- and every path the module hands back is compared against these.
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    dir = vim.uv.fs_realpath(dir)
    saved_venv = vim.env.VIRTUAL_ENV
    saved_pyenv = vim.env.PYENV_ROOT
    vim.env.VIRTUAL_ENV = nil
    vim.env.PYENV_ROOT = dir .. "/no-pyenv"
  end)

  after_each(function()
    vim.env.VIRTUAL_ENV = saved_venv
    vim.env.PYENV_ROOT = saved_pyenv
    vim.fn.delete(dir, "rf")
  end)

  local function mkdir(rel)
    local path = dir .. "/" .. rel
    vim.fn.mkdir(path, "p")
    return path
  end

  local function touch(rel, body)
    local path = dir .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "w"))
    f:write(body or "")
    f:close()
    return path
  end

  -- A venv as uv, virtualenv and `python -m venv` all leave it: pyvenv.cfg at
  -- the top, an interpreter under bin/, packages under lib/pythonX.Y.
  local function venv(rel)
    touch(rel .. "/pyvenv.cfg", "home = /usr/bin\n")
    touch(rel .. "/bin/python")
    mkdir(rel .. "/lib/python3.12/site-packages")
    return dir .. "/" .. rel
  end

  describe("venv_dir", function()
    it("finds .venv in the root", function()
      local v = venv("proj/.venv")
      assert.are.equal(v, M.venv_dir(dir .. "/proj"))
    end)

    it("prefers .venv over venv when both exist", function()
      local dot = venv("proj/.venv")
      venv("proj/venv")
      assert.are.equal(dot, M.venv_dir(dir .. "/proj"))
    end)

    it("ignores a .venv directory with no pyvenv.cfg", function()
      mkdir("proj/.venv/bin")
      assert.is_nil(M.venv_dir(dir .. "/proj"))
    end)

    it("does not look above the root when no top is given", function()
      venv("ws/.venv")
      mkdir("ws/packages/api")
      assert.is_nil(M.venv_dir(dir .. "/ws/packages/api"))
    end)

    it("walks up to the top to find a workspace venv", function()
      local v = venv("ws/.venv")
      mkdir("ws/packages/api")
      assert.are.equal(v, M.venv_dir(dir .. "/ws/packages/api", dir .. "/ws"))
    end)

    it("prefers the nearest venv on the way up", function()
      venv("ws/.venv")
      local own = venv("ws/packages/api/.venv")
      assert.are.equal(own, M.venv_dir(dir .. "/ws/packages/api", dir .. "/ws"))
    end)

    it("never walks past the top", function()
      venv(".venv")
      mkdir("ws/packages/api")
      assert.is_nil(M.venv_dir(dir .. "/ws/packages/api", dir .. "/ws"))
    end)

    it("ignores a top that is not an ancestor of the root", function()
      venv("other/.venv")
      mkdir("proj")
      assert.is_nil(M.venv_dir(dir .. "/proj", dir .. "/other"))
    end)

    it("accepts an activated VIRTUAL_ENV inside the top", function()
      local v = venv("ws/envs/dev")
      mkdir("ws/packages/api")
      vim.env.VIRTUAL_ENV = v
      assert.are.equal(v, M.venv_dir(dir .. "/ws/packages/api", dir .. "/ws"))
    end)

    it("rejects an activated VIRTUAL_ENV belonging to another project", function()
      -- Neovim inherits whatever shell launched it; another project's venv
      -- resolves imports against packages this one never declared.
      vim.env.VIRTUAL_ENV = venv("elsewhere/.venv")
      mkdir("proj")
      assert.is_nil(M.venv_dir(dir .. "/proj", dir .. "/proj"))
    end)

    it("does not take a sibling sharing the root's name prefix for a child", function()
      vim.env.VIRTUAL_ENV = venv("proj-backup/.venv")
      mkdir("proj")
      assert.is_nil(M.venv_dir(dir .. "/proj"))
    end)

    it("returns nil for a nil root", function()
      assert.is_nil(M.venv_dir(nil))
    end)
  end)

  describe("pyenv_interpreter", function()
    before_each(function()
      vim.env.PYENV_ROOT = dir .. "/pyenv"
      touch("pyenv/versions/3.10.14/bin/python")
      touch("pyenv/versions/3.12.10/bin/python")
      touch("pyenv/versions/3.12.4/bin/python")
    end)

    it("takes an exact version directory", function()
      assert.are.equal(dir .. "/pyenv/versions/3.12.4/bin/python", M.pyenv_interpreter("3.12.4"))
    end)

    it("resolves a bare minor version to its highest patch release", function()
      -- uv writes `.python-version` with a bare minor version.
      assert.are.equal(dir .. "/pyenv/versions/3.12.10/bin/python", M.pyenv_interpreter("3.12"))
    end)

    it("matches on a component boundary only", function()
      assert.is_nil(M.pyenv_interpreter("3.1"))
    end)

    it("returns nil for a version pyenv does not have", function()
      assert.is_nil(M.pyenv_interpreter("3.13"))
    end)
  end)

  describe("resolve", function()
    it("reports a venv interpreter with its venv", function()
      local v = venv("proj/.venv")
      assert.are.same(
        { exe = v .. "/bin/python", venv = v, kind = "venv" },
        M.resolve(dir .. "/proj", dir .. "/proj")
      )
    end)

    it("falls back to the pyenv version a .python-version names", function()
      vim.env.PYENV_ROOT = dir .. "/pyenv"
      touch("pyenv/versions/3.12.10/bin/python")
      touch("ws/.python-version", "3.12\n")
      mkdir("ws/packages/api")
      assert.are.same(
        { exe = dir .. "/pyenv/versions/3.12.10/bin/python", kind = "pyenv" },
        M.resolve(dir .. "/ws/packages/api", dir .. "/ws")
      )
    end)

    it("prefers a venv anywhere up to the top over a .python-version", function()
      vim.env.PYENV_ROOT = dir .. "/pyenv"
      touch("pyenv/versions/3.12.10/bin/python")
      touch("ws/packages/api/.python-version", "3.12\n")
      local v = venv("ws/.venv")
      assert.are.equal("venv", M.resolve(dir .. "/ws/packages/api", dir .. "/ws").kind)
      assert.are.equal(v, M.resolve(dir .. "/ws/packages/api", dir .. "/ws").venv)
    end)

    it("skips a venv whose interpreter is missing", function()
      touch("proj/.venv/pyvenv.cfg")
      assert.is_nil(M.resolve(dir .. "/proj", dir .. "/proj"))
    end)

    it("returns nil when nothing identifies an interpreter", function()
      mkdir("proj")
      assert.is_nil(M.resolve(dir .. "/proj", dir .. "/proj"))
    end)
  end)

  describe("site_packages", function()
    it("finds the venv's site-packages", function()
      local v = venv("proj/.venv")
      assert.are.equal(v .. "/lib/python3.12/site-packages", M.site_packages(v))
    end)

    it("returns nil for a venv with no lib directory", function()
      touch("proj/.venv/pyvenv.cfg")
      assert.is_nil(M.site_packages(dir .. "/proj/.venv"))
      assert.is_nil(M.site_packages(nil))
    end)
  end)
end)
