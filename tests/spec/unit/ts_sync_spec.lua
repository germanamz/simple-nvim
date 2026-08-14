describe("config.ts_sync", function()
  local M
  local info_dir
  local parser_dir

  before_each(function()
    package.loaded["config.ts_sync"] = nil
    M = require("config.ts_sync")
    info_dir = vim.fn.tempname()
    parser_dir = vim.fn.tempname()
    vim.fn.mkdir(info_dir, "p")
    vim.fn.mkdir(parser_dir, "p")
  end)

  after_each(function()
    vim.fn.delete(info_dir, "rf")
    vim.fn.delete(parser_dir, "rf")
  end)

  ---Write the revision stamp nvim-treesitter would have written.
  local function stamp(lang, body)
    local fd = assert(io.open(info_dir .. "/" .. lang .. ".revision", "w"))
    fd:write(body)
    fd:close()
  end

  ---Stand in for the compiled grammar. Only its existence is ever checked.
  local function built(lang)
    local fd = assert(io.open(parser_dir .. "/" .. lang .. ".so", "w"))
    fd:write("")
    fd:close()
  end

  ---A whole install: stamp plus compiled grammar.
  local function installed(lang, rev)
    stamp(lang, rev)
    built(lang)
  end

  describe("installed_revision", function()
    it("returns the stamped revision", function()
      stamp("lua", "aaa")

      assert.are.equal("aaa", M.installed_revision(info_dir, "lua"))
    end)

    it("returns nil when no stamp was ever written", function()
      assert.is_nil(M.installed_revision(info_dir, "lua"))
    end)

    it("trims a trailing newline", function()
      -- nvim-treesitter writes the stamp with no trailing newline, but anything
      -- that has round-tripped through an editor grows one; a false mismatch
      -- would fail the sync forever.
      stamp("lua", "aaa\n")

      assert.are.equal("aaa", M.installed_revision(info_dir, "lua"))
    end)

    it("treats an empty stamp as no stamp", function()
      -- try_install_lang writes `revision or ''`, so a registry entry with no
      -- revision leaves an empty file behind. Reporting that as the revision ""
      -- would make it compare equal to nothing and unequal to everything.
      stamp("lua", "\n")

      assert.is_nil(M.installed_revision(info_dir, "lua"))
    end)
  end)

  describe("unbuilt", function()
    it("reports nothing when both files are on disk", function()
      installed("lua", "aaa")
      installed("go", "bbb")

      assert.are.same({}, M.unbuilt({ "lua", "go" }, info_dir, parser_dir))
    end)

    it("reports a language with no stamp and no grammar", function()
      -- The cold-cache case: nothing has ever been installed.
      assert.are.same({ "lua" }, M.unbuilt({ "lua" }, info_dir, parser_dir))
    end)

    it("reports a grammar whose stamp went missing", function()
      -- The regression this function exists for. nvim-treesitter's
      -- get_installed() still calls this language installed (the .so is there),
      -- so update() keeps it, calls get_installed_revision() on it, and
      -- nvim-treesitter's util.read_file asserts on the missing file — one
      -- deleted stamp used to take the whole `make warm` down.
      built("lua")

      assert.are.same({ "lua" }, M.unbuilt({ "lua" }, info_dir, parser_dir))
    end)

    it("reports a stamped language whose grammar went missing", function()
      -- What :TSUninstall leaves behind: the .so is unlinked, the stamp is not.
      stamp("lua", "aaa")

      assert.are.same({ "lua" }, M.unbuilt({ "lua" }, info_dir, parser_dir))
    end)

    it("says nothing about which revision is installed", function()
      -- A whole install at the wrong revision is update()'s problem, not a
      -- reinstall-from-scratch case; reporting it here would report it twice.
      installed("lua", "some-other-rev")

      assert.are.same({}, M.unbuilt({ "lua" }, info_dir, parser_dir))
    end)

    it("checks only the languages it is given, in that order", function()
      built("lua")
      built("go")

      assert.are.same({ "go", "lua" }, M.unbuilt({ "go", "lua" }, info_dir, parser_dir))
    end)
  end)

  describe("unregistered", function()
    it("reports nothing when every pin has a registry entry", function()
      local parsers = { lua = { install_info = { revision = "aaa" } } }

      assert.are.same({}, M.unregistered({ "lua" }, parsers))
    end)

    it("names a pinned language upstream dropped from the registry", function()
      -- The `latex` case: nvim-treesitter removes grammars, and a pin it no
      -- longer carries has to be a warning the caller can skip past, not an
      -- abort that blocks the other thirty parsers.
      local parsers = { lua = { install_info = { revision = "aaa" } } }

      assert.are.same({ "latex" }, M.unregistered({ "latex", "lua" }, parsers))
    end)

    it("keeps an entry that carries no revision", function()
      -- Installable, just not stamp-verifiable. Telling the user to drop it
      -- from parser-revisions.lua would be the wrong advice; drift() names it
      -- instead.
      local parsers = { lua = { install_info = {} } }

      assert.are.same({}, M.unregistered({ "lua" }, parsers))
    end)
  end)

  describe("drift", function()
    it("reports nothing when every stamp matches the parser table", function()
      installed("lua", "aaa")
      installed("go", "bbb")
      local parsers = {
        lua = { install_info = { revision = "aaa" } },
        go = { install_info = { revision = "bbb" } },
      }

      assert.are.same({}, M.drift({ "lua", "go" }, parsers, info_dir, parser_dir))
    end)

    it("names both revisions when an installed parser is at the wrong one", function()
      -- The whole point: install() returns true for a language it skipped, so a
      -- successful-looking sync has to be verified against the stamps on disk.
      installed("lua", "old-rev")
      local parsers = { lua = { install_info = { revision = "pinned-rev" } } }

      local drift = M.drift({ "lua" }, parsers, info_dir, parser_dir)

      assert.are.equal(1, #drift)
      assert.is_truthy(drift[1]:match("lua"), drift[1])
      assert.is_truthy(drift[1]:match("pinned%-rev"), drift[1])
      assert.is_truthy(drift[1]:match("old%-rev"), drift[1])
    end)

    it("reports a parser that was never installed", function()
      local parsers = { lua = { install_info = { revision = "pinned-rev" } } }

      local drift = M.drift({ "lua" }, parsers, info_dir, parser_dir)

      assert.are.equal(1, #drift)
      assert.is_truthy(drift[1]:match("not installed"), drift[1])
    end)

    it("fails a matching stamp whose compiled grammar is gone", function()
      -- :TSUninstall unlinks parser/<lang>.so and leaves the stamp, so every
      -- revision comparison passes while the language has silently lost
      -- highlighting. Checking the stamp alone let `make warm` and `make check`
      -- both exit 0 on that state.
      stamp("lua", "aaa")
      local parsers = { lua = { install_info = { revision = "aaa" } } }

      local drift = M.drift({ "lua" }, parsers, info_dir, parser_dir)

      assert.are.equal(1, #drift)
      assert.is_truthy(drift[1]:match("lua%.so is missing"), drift[1])
    end)

    it("ignores trailing whitespace in a stamp", function()
      installed("lua", "aaa\n")
      local parsers = { lua = { install_info = { revision = "aaa" } } }

      assert.are.same({}, M.drift({ "lua" }, parsers, info_dir, parser_dir))
    end)

    it("reports a language the parser table doesn't carry", function()
      -- The silent failure mode of install(): an unknown language is dropped by
      -- norm_languages and install() still returns true (0 == 0 tasks done).
      -- The sync script filters these out ahead of drift() now (they are a
      -- warning, not a failure), so this is the backstop for a registry entry
      -- that exists but carries no revision to compare against.
      installed("nosuchlang", "aaa")

      local drift = M.drift({ "nosuchlang" }, {}, info_dir, parser_dir)

      assert.are.equal(1, #drift)
      assert.is_truthy(drift[1]:match("nosuchlang"), drift[1])
      assert.is_truthy(drift[1]:match("no registry entry"), drift[1])
    end)

    it("checks only the languages it is given", function()
      installed("lua", "aaa")
      local parsers = {
        lua = { install_info = { revision = "aaa" } },
        -- installed by nvim-treesitter as a dependency, not pinned by us
        luadoc = { install_info = { revision = "ccc" } },
      }

      assert.are.same({}, M.drift({ "lua" }, parsers, info_dir, parser_dir))
    end)
  end)
end)
