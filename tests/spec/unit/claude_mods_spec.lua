-- Pins :ClaudeModInstall / :ClaudeModUninstall: the Claude Code mods kept in
-- claude-mods/ installed into one project. The argv is the contract with the
-- claude CLI, and two parts of it are deliberate: `--marketplace <folder>`, so a
-- first install adds the folder marketplace by itself and the plugin is read in
-- place from this repo, and `--scope local`, so the project's committed
-- settings never name a folder that only exists on this machine.
local mods = require("config.claude_mods")

describe("config.claude_mods", function()
  local calls, notes, real

  before_each(function()
    calls, notes = {}, {}
    real = { system = vim.system, notify = vim.notify, executable = vim.fn.executable }
    vim.fn.executable = function(name)
      return name == "claude" and 1 or real.executable(name)
    end
    vim.notify = function(msg, level)
      notes[#notes + 1] = { msg = msg, level = level }
    end
  end)

  after_each(function()
    vim.system, vim.notify, vim.fn.executable = real.system, real.notify, real.executable
  end)

  --- Answer every claude call with `result`, recording what was run.
  local function answer(result)
    vim.system = function(args, opts, on_exit)
      calls[#calls + 1] = { args = args, opts = opts }
      on_exit(vim.tbl_extend("force", { code = 0, stdout = "", stderr = "" }, result))
    end
  end

  --- The note the run left, once its scheduled callback has run.
  local function settled()
    vim.wait(1000, function()
      return #notes > 0
    end)
    return notes[1]
  end

  it("lists the mods the marketplace holds", function()
    assert.are.same({ "nvim-review" }, mods.names())
  end)

  it("installs from the marketplace folder at local scope, in the cwd", function()
    answer({
      stdout = '{"outcome":"ok","message":"Successfully installed plugin: nvim-review@simple-nvim"}\n',
    })
    mods.install()
    settled()
    assert.are.same({
      "claude",
      "plugin",
      "install",
      "nvim-review",
      "--marketplace",
      mods.dir,
      "--scope",
      "local",
      "--json",
    }, calls[1].args)
    assert.are.equal(vim.fn.getcwd(), calls[1].opts.cwd)
    assert.is_truthy(
      vim.uv.fs_stat(vim.fs.joinpath(mods.dir, ".claude-plugin", "marketplace.json"))
    )
  end)

  it("installs the mod it is named", function()
    answer({})
    mods.install("other")
    settled()
    assert.are.equal("other", calls[1].args[4])
  end)

  it("uninstalls by plugin@marketplace at local scope", function()
    answer({
      stdout = '{"outcome":"ok","message":"Successfully uninstalled plugin: nvim-review"}\n',
    })
    mods.uninstall()
    settled()
    assert.are.same(
      { "claude", "plugin", "uninstall", "nvim-review@simple-nvim", "--scope", "local", "--json" },
      calls[1].args
    )
  end)

  it("says how a fresh install takes effect", function()
    answer({
      stdout = '{"outcome":"ok","message":"Successfully installed plugin: nvim-review@simple-nvim"}\n',
    })
    mods.install()
    local note = settled()
    assert.is_truthy(note.msg:find("Successfully installed", 1, true))
    assert.is_truthy(note.msg:find("/reload-plugins", 1, true))
    assert.are_not.equal(vim.log.levels.ERROR, note.level)
  end)

  -- The CLI answers a failure in plain text even under --json.
  it("reports a failure in the CLI's own words", function()
    answer({
      code = 1,
      stdout = '✘ Failed to uninstall plugin "nvim-review@simple-nvim": Plugin "nvim-review@simple-nvim" is not installed in local scope.\n',
    })
    mods.uninstall()
    local note = settled()
    assert.are.equal(vim.log.levels.ERROR, note.level)
    assert.is_truthy(note.msg:find("is not installed in local scope", 1, true))
  end)

  it("runs nothing without the claude CLI", function()
    answer({})
    vim.fn.executable = function()
      return 0
    end
    mods.install()
    assert.are.equal(0, #calls)
    assert.are.equal(vim.log.levels.ERROR, notes[1].level)
  end)
end)
