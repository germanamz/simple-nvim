-- Pins config.pyright_mode: how loud basedpyright is in a project that carries
-- its own type-checker config, and the two ways out.
--
-- The editor asks for typeCheckingMode = "standard" (config.python_lsp), but a
-- project config makes basedpyright drop the editor's settings wholesale and
-- start that config from ITS default, "recommended". Measured on a 150-file
-- package: 175 diagnostics under standard, 4,683 under recommended. So:
--   * warn once per project whose config leaves the mode unset, naming the
--     one-line fix in that file's own syntax;
--   * :PythonQuiet writes an untracked pyrightconfig.json that extends the
--     project's pyproject.toml and sets "standard", lists it in
--     .git/info/exclude, and restarts the server.
local M = require("config.pyright_mode")
local python_lsp = require("config.python_lsp")

describe("config.pyright_mode", function()
  local dir, sent, restarted, saved_restart

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    dir = vim.uv.fs_realpath(dir)
    M._clear()
    sent = {}
    M._notify = function(msg, level)
      table.insert(sent, { msg = msg, level = level })
    end
    restarted = {}
    saved_restart = python_lsp._restart
    python_lsp._restart = function(clients, reason)
      table.insert(restarted, { clients = clients, reason = reason })
    end
  end)

  after_each(function()
    M._notify = nil
    python_lsp._restart = saved_restart
    vim.fn.delete(dir, "rf")
  end)

  local function write(rel, body)
    local path = dir .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "w"))
    f:write(body)
    f:close()
    return path
  end

  local function read(path)
    local f = io.open(path, "r")
    if not f then
      return nil
    end
    local body = f:read("*a")
    f:close()
    return body
  end

  local function git_init(rel)
    local path = rel and (dir .. "/" .. rel) or dir
    vim.fn.mkdir(path, "p")
    vim.fn.system({ "git", "-C", path, "init", "-q" })
    assert.are.equal(0, vim.v.shell_error)
    return path
  end

  local function fake_client(root)
    return { name = python_lsp.server, root_dir = root, config = { root_dir = root } }
  end

  describe("mode", function()
    it("is nil when the [tool.pyright] section leaves it unset", function()
      local path =
        write("pyproject.toml", '[project]\nname = "x"\n\n[tool.pyright]\ninclude = ["src"]\n')
      assert.is_nil(M.mode(path))
    end)

    it("reads typeCheckingMode from [tool.pyright]", function()
      local path = write("pyproject.toml", '[tool.pyright]\ntypeCheckingMode = "standard"\n')
      assert.are.equal("standard", M.mode(path))
    end)

    it("reads typeCheckingMode from [tool.basedpyright]", function()
      local path = write("pyproject.toml", "[tool.basedpyright]\ntypeCheckingMode = 'strict'\n")
      assert.are.equal("strict", M.mode(path))
    end)

    it("ignores the key outside the type checker's own table", function()
      local path = write(
        "pyproject.toml",
        '[tool.pyright]\ninclude = ["src"]\n\n[[tool.pyright.executionEnvironments]]\nroot = "src"\n\n'
          .. '[tool.other]\ntypeCheckingMode = "basic"\n'
      )
      assert.is_nil(M.mode(path))
    end)

    it("does not read a commented-out key", function()
      local path = write("pyproject.toml", '[tool.pyright]\n# typeCheckingMode = "basic"\n')
      assert.is_nil(M.mode(path))
    end)

    it("reads typeCheckingMode from pyrightconfig.json, comments and all", function()
      -- basedpyright parses this file as JSONC with trailing commas allowed.
      local path = write(
        "pyrightconfig.json",
        '{\n  // local\n  "include": ["src"],\n  "typeCheckingMode": "basic",\n}\n'
      )
      assert.are.equal("basic", M.mode(path))
    end)

    it("follows extends to the file that sets it", function()
      write("pyproject.toml", '[tool.pyright]\ntypeCheckingMode = "standard"\n')
      local path = write("pkg/pyrightconfig.json", '{ "extends": "../pyproject.toml" }\n')
      assert.are.equal("standard", M.mode(path))
    end)

    it("lets the extending file win over its base", function()
      write("base.json", '{ "typeCheckingMode": "strict" }')
      local path =
        write("pyrightconfig.json", '{ "extends": "./base.json", "typeCheckingMode": "standard" }')
      assert.are.equal("standard", M.mode(path))
    end)

    it("stops on a circular extends instead of looping", function()
      write("a.json", '{ "extends": "./b.json" }')
      local path = write("b.json", '{ "extends": "./a.json" }')
      assert.is_nil(M.mode(path))
    end)
  end)

  describe("implicit", function()
    it("is nil for a project with no type-checker config", function()
      write("pyproject.toml", '[project]\nname = "x"\n')
      assert.is_nil(M.implicit(dir))
    end)

    it("is nil when the config sets a mode", function()
      write("pyproject.toml", '[tool.pyright]\ntypeCheckingMode = "standard"\n')
      assert.is_nil(M.implicit(dir))
    end)

    it("names the config that leaves the mode to basedpyright", function()
      local path = write("pyproject.toml", "[tool.pyright]\n")
      assert.are.equal(path, M.implicit(dir))
    end)

    it("judges pyrightconfig.json, which outranks pyproject.toml", function()
      write("pyproject.toml", '[tool.pyright]\ntypeCheckingMode = "standard"\n')
      local path = write("pyrightconfig.json", "{}")
      assert.are.equal(path, M.implicit(dir))
    end)
  end)

  describe("warn", function()
    it("stays quiet for a project with no type-checker config", function()
      M.warn(dir)
      assert.are.equal(0, #sent)
    end)

    it("stays quiet when the project config sets a mode", function()
      write("pyproject.toml", '[tool.pyright]\ntypeCheckingMode = "strict"\n')
      M.warn(dir)
      assert.are.equal(0, #sent)
    end)

    it("names the file, the TOML fix and :PythonQuiet for a pyproject.toml", function()
      write("pyproject.toml", "[tool.pyright]\n")
      M.warn(dir)
      assert.are.equal(1, #sent)
      assert.are.equal(vim.log.levels.WARN, sent[1].level)
      assert.is_truthy(sent[1].msg:find("pyproject.toml", 1, true))
      assert.is_truthy(sent[1].msg:find('typeCheckingMode = "standard"', 1, true))
      assert.is_truthy(sent[1].msg:find(":PythonQuiet", 1, true))
    end)

    it("gives the JSON fix, and no :PythonQuiet, for a pyrightconfig.json", function()
      -- A local override would have to BE pyrightconfig.json, so the command
      -- cannot help here; offering it would be a dead end.
      write("pyrightconfig.json", "{}")
      M.warn(dir)
      assert.are.equal(1, #sent)
      assert.is_truthy(sent[1].msg:find('"typeCheckingMode": "standard"', 1, true))
      assert.is_falsy(sent[1].msg:find(":PythonQuiet", 1, true))
    end)

    it("warns once per project, not once per buffer opened in it", function()
      write("pyproject.toml", "[tool.pyright]\n")
      M.warn(dir)
      M.warn(dir)
      M.warn(dir)
      assert.are.equal(1, #sent)
    end)
  end)

  describe("quiet", function()
    it("needs a type server on the buffer to know the project", function()
      M.quiet(0, {})
      assert.are.equal(1, #sent)
      assert.is_truthy(sent[1].msg:find("No " .. python_lsp.server .. " client", 1, true))
    end)

    it("writes nothing for a project with no type-checker config", function()
      write("pyproject.toml", '[project]\nname = "x"\n')
      M.quiet(0, { fake_client(dir) })
      assert.is_nil(read(dir .. "/pyrightconfig.json"))
      assert.is_truthy(sent[1].msg:find("standard", 1, true))
      assert.are.equal(0, #restarted)
    end)

    it("writes nothing when the project is already at standard or below", function()
      write("pyproject.toml", '[tool.pyright]\ntypeCheckingMode = "basic"\n')
      M.quiet(0, { fake_client(dir) })
      assert.is_nil(read(dir .. "/pyrightconfig.json"))
      assert.is_truthy(sent[1].msg:find("basic", 1, true))
      assert.are.equal(0, #restarted)
    end)

    it("leaves an existing pyrightconfig.json alone and says what to add", function()
      local path = write("pyrightconfig.json", '{ "include": ["src"] }')
      M.quiet(0, { fake_client(dir) })
      assert.are.equal('{ "include": ["src"] }', read(path))
      assert.are.equal(vim.log.levels.WARN, sent[1].level)
      assert.is_truthy(sent[1].msg:find('"typeCheckingMode": "standard"', 1, true))
      assert.are.equal(0, #restarted)
    end)

    it("writes a pyrightconfig.json that extends pyproject.toml at standard", function()
      git_init()
      write("pyproject.toml", '[tool.pyright]\ninclude = ["src"]\n')
      M.quiet(0, { fake_client(dir) })
      local override = dir .. "/pyrightconfig.json"
      assert.is_truthy((read(override) or ""):find('"extends": "./pyproject.toml"', 1, true))
      assert.are.equal("standard", M.mode(override))
      -- And the project now reads as configured, so the warning goes quiet too.
      assert.is_nil(M.implicit(dir))
    end)

    it("overrides a stricter mode the project sets explicitly", function()
      git_init()
      write("pyproject.toml", '[tool.basedpyright]\ntypeCheckingMode = "recommended"\n')
      M.quiet(0, { fake_client(dir) })
      assert.are.equal("standard", M.mode(dir .. "/pyrightconfig.json"))
    end)

    it("lists the override in .git/info/exclude", function()
      git_init()
      write("pyproject.toml", "[tool.pyright]\n")
      M.quiet(0, { fake_client(dir) })
      local exclude = read(dir .. "/.git/info/exclude") or ""
      assert.is_truthy(
        exclude:find("\n/pyrightconfig.json\n", 1, true) or exclude:find("^/pyrightconfig.json\n")
      )
      local status =
        vim.fn.system({ "git", "-C", dir, "status", "--porcelain", "--untracked-files=all" })
      assert.is_falsy(status:find("pyrightconfig.json", 1, true))
    end)

    it("anchors the exclude entry at the project's path inside the repository", function()
      git_init()
      local root = dir .. "/packages/api"
      write("packages/api/pyproject.toml", "[tool.pyright]\n")
      M.quiet(0, { fake_client(root) })
      local exclude = read(dir .. "/.git/info/exclude") or ""
      assert.is_truthy(exclude:find("/packages/api/pyrightconfig.json\n", 1, true))
    end)

    it("restarts the servers rooted at the project, and only those", function()
      git_init()
      write("pyproject.toml", "[tool.pyright]\n")
      local here, elsewhere = fake_client(dir), fake_client(dir .. "/other")
      M.quiet(0, { here }, { here, elsewhere })
      assert.are.equal(1, #restarted)
      assert.are.same({ here }, restarted[1].clients)
      assert.is_truthy(restarted[1].reason:find("standard", 1, true))
    end)

    it("still writes the override outside a git repository, and says it is not excluded", function()
      write("pyproject.toml", "[tool.pyright]\n")
      local client = fake_client(dir)
      M.quiet(0, { client }, { client })
      assert.are.equal("standard", M.mode(dir .. "/pyrightconfig.json"))
      assert.is_truthy(restarted[1].reason:find("not a git repository", 1, true))
    end)

    it("says what it wrote even when no server is running to restart", function()
      git_init()
      write("pyproject.toml", "[tool.pyright]\n")
      M.quiet(0, { fake_client(dir) }, {})
      assert.are.equal(0, #restarted)
      assert.are.equal(1, #sent)
      assert.is_truthy(sent[1].msg:find("pyrightconfig.json", 1, true))
    end)
  end)

  describe("_exclude", function()
    it("adds the entry once, however often it is asked", function()
      git_init()
      M._exclude(dir, "pyrightconfig.json")
      M._exclude(dir, "pyrightconfig.json")
      local exclude = read(dir .. "/.git/info/exclude") or ""
      local _, count = exclude:gsub("/pyrightconfig.json\n", "")
      assert.are.equal(1, count)
    end)

    it("starts the entry on its own line when the file lacks a final newline", function()
      git_init()
      local f = assert(io.open(dir .. "/.git/info/exclude", "w"))
      f:write("*.log")
      f:close()
      M._exclude(dir, "pyrightconfig.json")
      assert.are.equal("*.log\n/pyrightconfig.json\n", read(dir .. "/.git/info/exclude"))
    end)
  end)
end)
