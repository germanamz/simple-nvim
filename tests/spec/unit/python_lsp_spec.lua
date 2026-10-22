-- Pins config.python_lsp: the Python type server's per-root wiring.
--
--   * before_init hands the server the project's interpreter (config.python_env)
--     as python.pythonPath — MUTATING config.settings in place, because
--     client.settings is already aliased to that table by the time before_init
--     runs (config.pyright_rules' header has the whole story), and the server
--     answers workspace/configuration out of client.settings.
--   * the statusline names the interpreter the server started with, so a wrong
--     one is visible before it sends `gd` somewhere strange.
--   * a branch switch, or packages installed into the venv, restarts the server:
--     didChangeWatchedFiles is off in this config, so the server never hears
--     about either on its own.
local M = require("config.python_lsp")

describe("config.python_lsp", function()
  local dir, saved_venv, saved_data

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    dir = vim.uv.fs_realpath(dir)
    saved_venv = vim.env.VIRTUAL_ENV
    saved_data = vim.env.XDG_DATA_HOME
    vim.env.VIRTUAL_ENV = nil
    -- config.pyright_rules persists under stdpath("data"); keep it in the tempdir.
    vim.env.XDG_DATA_HOME = dir .. "/data"
    package.loaded["config.pyright_rules"] = nil
    M._reset()
  end)

  after_each(function()
    vim.env.VIRTUAL_ENV = saved_venv
    vim.env.XDG_DATA_HOME = saved_data
    package.loaded["config.pyright_rules"] = nil
    vim.fn.delete(dir, "rf")
  end)

  local function touch(rel, body)
    local path = dir .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "w"))
    f:write(body or "")
    f:close()
    return path
  end

  local function venv(rel)
    touch(rel .. "/pyvenv.cfg", "home = /usr/bin\n")
    touch(rel .. "/bin/python")
    vim.fn.mkdir(dir .. "/" .. rel .. "/lib/python3.12/site-packages", "p")
    return dir .. "/" .. rel
  end

  -- What lspconfig's lsp/basedpyright.lua contributes before before_init runs.
  local function config_for(root)
    return {
      root_dir = root,
      settings = { basedpyright = { analysis = { autoSearchPaths = true } } },
    }
  end

  local function fake_client(root)
    return { name = M.server, root_dir = root, config = { root_dir = root } }
  end

  it("names the server and the settings section its analysis keys live in", function()
    assert.are.equal("basedpyright", M.server)
    assert.are.equal("basedpyright", M.section)
  end)

  describe("before_init", function()
    it("sets python.pythonPath to the project venv, in place", function()
      local v = venv("proj/.venv")
      local config = config_for(dir .. "/proj")
      local settings = config.settings
      M.before_init({}, config)
      assert.are.equal(v .. "/bin/python", config.settings.python.pythonPath)
      -- Identity, not content: a reassigned table would never reach the server.
      assert.are.equal(settings, config.settings)
    end)

    it("finds a workspace venv above the root inside the repository", function()
      touch("ws/.git/HEAD", "ref: refs/heads/main\n")
      local v = venv("ws/.venv")
      vim.fn.mkdir(dir .. "/ws/packages/api", "p")
      local config = config_for(dir .. "/ws/packages/api")
      M.before_init({}, config)
      assert.are.equal(v .. "/bin/python", config.settings.python.pythonPath)
    end)

    it("leaves pythonPath unset when nothing identifies an interpreter", function()
      vim.fn.mkdir(dir .. "/proj", "p")
      local config = config_for(dir .. "/proj")
      M.before_init({}, config)
      assert.is_nil(config.settings.python)
    end)

    it("still folds the recorded rule severities in", function()
      vim.fn.mkdir(dir .. "/proj", "p")
      require("config.pyright_rules").set(dir .. "/proj", "reportCallIssue", "warning")
      local config = config_for(dir .. "/proj")
      M.before_init({}, config)
      assert.are.equal(
        "warning",
        config.settings.basedpyright.analysis.diagnosticSeverityOverrides.reportCallIssue
      )
    end)

    it("records what it resolved for the root", function()
      local v = venv("proj/.venv")
      M.before_init({}, config_for(dir .. "/proj"))
      local env = M.env(dir .. "/proj")
      assert.are.equal("venv", env.kind)
      assert.are.equal(v, env.venv)
    end)
  end)

  describe("label", function()
    it("names a venv inside the root by its path relative to it", function()
      venv("proj/.venv")
      M.before_init({}, config_for(dir .. "/proj"))
      assert.are.equal(" py:.venv ", M.label(dir .. "/proj"))
    end)

    it("names a pyenv interpreter by its version", function()
      local saved = vim.env.PYENV_ROOT
      vim.env.PYENV_ROOT = dir .. "/pyenv"
      touch("pyenv/versions/3.12.10/bin/python")
      touch("proj/.python-version", "3.12\n")
      M.before_init({}, config_for(dir .. "/proj"))
      vim.env.PYENV_ROOT = saved
      assert.are.equal(" py:pyenv 3.12.10 ", M.label(dir .. "/proj"))
    end)

    it("says PATH when the server was left to find python itself", function()
      vim.fn.mkdir(dir .. "/proj", "p")
      M.before_init({}, config_for(dir .. "/proj"))
      assert.are.equal(" py:PATH ", M.label(dir .. "/proj"))
    end)

    it("is empty for a root no server was started for", function()
      assert.are.equal("", M.label(dir .. "/nowhere"))
    end)
  end)

  describe("status", function()
    it("labels the buffer's Python client", function()
      venv("proj/.venv")
      M.before_init({}, config_for(dir .. "/proj"))
      assert.are.equal(" py:.venv ", M.status(0, { fake_client(dir .. "/proj") }))
    end)

    it("is empty without a Python client", function()
      assert.are.equal("", M.status(0, {}))
    end)
  end)

  describe("refresh", function()
    local restarted

    before_each(function()
      restarted = {}
      M._restart = function(clients, reason)
        for _, c in ipairs(clients) do
          table.insert(restarted, { root = c.root_dir, reason = reason })
        end
      end
    end)

    it("restarts the clients inside a repository whose HEAD moved", function()
      local inside = fake_client(dir .. "/repo/pkg")
      local outside = fake_client(dir .. "/other")
      M.on_head_changed(dir .. "/repo", { inside, outside })
      assert.are.same({ { root = dir .. "/repo/pkg", reason = "branch changed" } }, restarted)
    end)

    it("does not take a sibling sharing the repository's name prefix for a child", function()
      M.on_head_changed(dir .. "/repo", { fake_client(dir .. "/repo-backup") })
      assert.are.same({}, restarted)
    end)

    it("restarts a client whose venv gained or lost packages", function()
      local v = venv("proj/.venv")
      -- A package install adds a directory to site-packages, moving its mtime.
      -- Backdated before the server "starts", so the change is visible even on
      -- a filesystem with coarse timestamps.
      local sp = v .. "/lib/python3.12/site-packages"
      vim.uv.fs_utime(sp, 1, 1)
      M.before_init({}, config_for(dir .. "/proj"))
      vim.fn.mkdir(sp .. "/newpkg", "p")
      M.check_envs({ fake_client(dir .. "/proj") })
      assert.are.same({ { root = dir .. "/proj", reason = "packages changed" } }, restarted)
    end)

    it("leaves a client alone when nothing in its venv changed", function()
      venv("proj/.venv")
      M.before_init({}, config_for(dir .. "/proj"))
      M.check_envs({ fake_client(dir .. "/proj") })
      assert.are.same({}, restarted)
    end)

    it("restarts a client that started without a venv once one appears", function()
      vim.fn.mkdir(dir .. "/proj", "p")
      M.before_init({}, config_for(dir .. "/proj"))
      venv("proj/.venv")
      M.check_envs({ fake_client(dir .. "/proj") })
      assert.are.same({ { root = dir .. "/proj", reason = "venv appeared" } }, restarted)
    end)

    it("ignores clients it never initialised", function()
      venv("proj/.venv")
      M.check_envs({ fake_client(dir .. "/proj") })
      assert.are.same({}, restarted)
    end)
  end)
end)
