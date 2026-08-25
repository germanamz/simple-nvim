local nvim_env = require("helpers.nvim_env")

local function write_file(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

local function tempdir()
  local dir = vim.fn.tempname() .. "-pyright-root"
  vim.fn.mkdir(dir, "p")
  return dir
end

describe("config.pyright_rules", function()
  local env_root, M

  before_each(function()
    env_root = nvim_env.setup_isolated_env()
    package.loaded["config.pyright_rules"] = nil
    M = require("config.pyright_rules")
  end)

  after_each(function()
    vim.api.nvim_clear_autocmds({ event = "User", pattern = "PyrightRulesChanged" })
    nvim_env.teardown(env_root)
  end)

  describe("store", function()
    it("returns an empty table for a root with no overrides", function()
      assert.same({}, M.get(tempdir()))
    end)

    it("returns an empty table when the state file is malformed JSON", function()
      write_file(M.state_path(), "{not json")
      assert.same({}, M.get(tempdir()))
    end)

    it("persists one rule severity and reads it back", function()
      local root = tempdir()
      M.set(root, "reportCallIssue", "warning")
      assert.same({ reportCallIssue = "warning" }, M.get(root))
    end)

    it("keys roots independently", function()
      local a, b = tempdir(), tempdir()
      M.set(a, "reportCallIssue", "warning")
      M.set(b, "reportArgumentType", "none")
      assert.same({ reportCallIssue = "warning" }, M.get(a))
      assert.same({ reportArgumentType = "none" }, M.get(b))
    end)

    it("removes a single rule when severity is nil, leaving siblings", function()
      local root = tempdir()
      M.set(root, "reportCallIssue", "warning")
      M.set(root, "reportArgumentType", "none")
      M.set(root, "reportCallIssue", nil)
      assert.same({ reportArgumentType = "none" }, M.get(root))
    end)

    it("drops every override for a root on clear", function()
      local root = tempdir()
      M.set(root, "reportCallIssue", "warning")
      M.set(root, "reportArgumentType", "none")
      M.clear(root)
      assert.same({}, M.get(root))
    end)

    it("survives a reload of the module (the write reached disk)", function()
      local root = tempdir()
      M.set(root, "reportIndexIssue", "information")
      package.loaded["config.pyright_rules"] = nil
      assert.same({ reportIndexIssue = "information" }, require("config.pyright_rules").get(root))
    end)

    it("fires User PyrightRulesChanged once per set, carrying root and rules", function()
      local root = tempdir()
      local fires = {}
      vim.api.nvim_create_autocmd("User", {
        pattern = "PyrightRulesChanged",
        callback = function(args)
          table.insert(fires, args.data)
        end,
      })

      M.set(root, "reportCallIssue", "warning")

      assert.are.equal(1, #fires)
      assert.are.equal(M.normalize(root), fires[1].root)
      assert.same({ reportCallIssue = "warning" }, fires[1].rules)
    end)

    it("does not fire when the severity is already what was asked for", function()
      local root = tempdir()
      M.set(root, "reportCallIssue", "warning")
      local fires = 0
      vim.api.nvim_create_autocmd("User", {
        pattern = "PyrightRulesChanged",
        callback = function()
          fires = fires + 1
        end,
      })

      M.set(root, "reportCallIssue", "warning")

      assert.are.equal(0, fires)
    end)

    it("does not fire when clearing a root that has no overrides", function()
      local fires = 0
      vim.api.nvim_create_autocmd("User", {
        pattern = "PyrightRulesChanged",
        callback = function()
          fires = fires + 1
        end,
      })

      M.clear(tempdir())

      assert.are.equal(0, fires)
    end)
  end)

  describe("before_init", function()
    -- The load-bearing contract: client.settings is bound to config.settings by
    -- reference at Client.create, BEFORE before_init runs. Reassigning the field
    -- breaks that aliasing and is a silent no-op against the real server, so
    -- these assert on table IDENTITY, not just on content.
    local function config_for(root)
      return {
        root_dir = root,
        settings = { python = { analysis = { autoSearchPaths = true } } },
      }
    end

    it("injects the root's overrides into the existing settings table", function()
      local root = tempdir()
      M.set(root, "reportCallIssue", "warning")
      local config = config_for(root)

      M.before_init(nil, config)

      assert.same(
        { reportCallIssue = "warning" },
        config.settings.python.analysis.diagnosticSeverityOverrides
      )
    end)

    it("mutates settings in place rather than reassigning any level of it", function()
      local root = tempdir()
      M.set(root, "reportCallIssue", "warning")
      local config = config_for(root)
      local settings = config.settings
      local python = config.settings.python
      local analysis = config.settings.python.analysis

      M.before_init(nil, config)

      assert.are.equal(settings, config.settings)
      assert.are.equal(python, config.settings.python)
      assert.are.equal(analysis, config.settings.python.analysis)
    end)

    it("preserves the settings lspconfig already contributed", function()
      local root = tempdir()
      M.set(root, "reportCallIssue", "warning")
      local config = config_for(root)

      M.before_init(nil, config)

      assert.is_true(config.settings.python.analysis.autoSearchPaths)
    end)

    it("leaves settings untouched for a root with no overrides", function()
      local config = config_for(tempdir())

      M.before_init(nil, config)

      assert.is_nil(config.settings.python.analysis.diagnosticSeverityOverrides)
    end)

    it("builds the python.analysis path when lspconfig contributed none", function()
      local root = tempdir()
      M.set(root, "reportCallIssue", "warning")
      local config = { root_dir = root, settings = {} }

      M.before_init(nil, config)

      assert.same(
        { reportCallIssue = "warning" },
        config.settings.python.analysis.diagnosticSeverityOverrides
      )
    end)

    it("merges over pre-existing severity overrides instead of replacing them", function()
      local root = tempdir()
      M.set(root, "reportCallIssue", "warning")
      local config = config_for(root)
      config.settings.python.analysis.diagnosticSeverityOverrides =
        { reportMissingImports = "none" }

      M.before_init(nil, config)

      assert.same({
        reportMissingImports = "none",
        reportCallIssue = "warning",
      }, config.settings.python.analysis.diagnosticSeverityOverrides)
    end)

    it("is a no-op, not an error, when there is no settings table to alias", function()
      local root = tempdir()
      M.set(root, "reportCallIssue", "warning")
      local config = { root_dir = root }

      assert.has_no.errors(function()
        M.before_init(nil, config)
      end)
      assert.is_nil(config.settings)
    end)

    it("is a no-op, not an error, when the client has no root_dir", function()
      local config = config_for(nil)
      config.root_dir = nil

      assert.has_no.errors(function()
        M.before_init(nil, config)
      end)
      assert.is_nil(config.settings.python.analysis.diagnosticSeverityOverrides)
    end)
  end)

  describe("next_severity", function()
    -- One press from the default must do the USEFUL thing (stop it being red),
    -- so the cycle starts at "warning" rather than at the declared-order head.
    it("steps an unset rule to warning", function()
      assert.are.equal("warning", M.next_severity(nil))
    end)

    it("walks warning -> information -> none", function()
      assert.are.equal("information", M.next_severity("warning"))
      assert.are.equal("none", M.next_severity("information"))
    end)

    it("reaches error, so a rule can be tightened and not only loosened", function()
      assert.are.equal("error", M.next_severity("none"))
    end)

    it("returns nil from the last step, restoring pyright's own default", function()
      assert.is_nil(M.next_severity("error"))
    end)

    it("treats an unknown severity as unset rather than dead-ending", function()
      assert.are.equal("warning", M.next_severity("hint"))
    end)
  end)

  describe("apply_preset", function()
    it("sets every preset rule in one shot", function()
      local root = tempdir()
      M.apply_preset(root)
      assert.same(M.PRESET, M.get(root))
    end)

    it("names only rules pyright can actually be told about", function()
      local legal = {}
      for _, s in ipairs(M.SEVERITIES) do
        legal[s] = true
      end
      for rule, severity in pairs(M.PRESET) do
        assert.is_true(legal[severity], rule .. " uses an illegal pyright severity: " .. severity)
      end
    end)

    it("broadcasts once, not once per rule", function()
      local fires = 0
      vim.api.nvim_create_autocmd("User", {
        pattern = "PyrightRulesChanged",
        callback = function()
          fires = fires + 1
        end,
      })

      M.apply_preset(tempdir())

      assert.are.equal(1, fires)
    end)

    it("leaves unrelated overrides on the same root alone", function()
      local root = tempdir()
      M.set(root, "reportMissingImports", "none")
      M.apply_preset(root)
      assert.are.equal("none", M.get(root).reportMissingImports)
    end)
  end)

  describe("shadowed", function()
    -- Pyright's precedence is WHOLESALE, not per-key: if it finds a config file
    -- it discards the entire client settings group. An empty [tool.pyright]
    -- header is enough. Detecting it is the difference between "this feature
    -- does nothing" and "this feature tells you why it does nothing".
    it("returns nil for a project carrying no pyright config", function()
      assert.is_nil(M.shadowed(tempdir()))
    end)

    it("reports pyrightconfig.json", function()
      local root = tempdir()
      write_file(root .. "/pyrightconfig.json", "{}")
      assert.are.equal(root .. "/pyrightconfig.json", M.shadowed(root))
    end)

    it("reports a pyproject.toml carrying a [tool.pyright] section", function()
      local root = tempdir()
      write_file(root .. "/pyproject.toml", '[project]\nname = "x"\n\n[tool.pyright]\n')
      assert.are.equal(root .. "/pyproject.toml", M.shadowed(root))
    end)

    it("ignores a pyproject.toml with no [tool.pyright] section", function()
      local root = tempdir()
      write_file(root .. "/pyproject.toml", '[project]\nname = "x"\n\n[tool.ruff]\n')
      assert.is_nil(M.shadowed(root))
    end)

    it("does not mistake a commented-out section for a real one", function()
      local root = tempdir()
      write_file(root .. "/pyproject.toml", "# [tool.pyright]\n")
      assert.is_nil(M.shadowed(root))
    end)

    it("prefers pyrightconfig.json, which outranks pyproject.toml", function()
      local root = tempdir()
      write_file(root .. "/pyrightconfig.json", "{}")
      write_file(root .. "/pyproject.toml", "[tool.pyright]\n")
      assert.are.equal(root .. "/pyrightconfig.json", M.shadowed(root))
    end)
  end)

  describe("warn_shadowed", function()
    local sent

    before_each(function()
      sent = {}
      M._notify = function(msg)
        table.insert(sent, msg)
      end
    end)

    after_each(function()
      M._notify = nil
    end)

    it("stays quiet for a root with overrides but no shadowing config", function()
      local root = tempdir()
      M.set(root, "reportCallIssue", "warning")
      M.warn_shadowed(root)
      assert.are.equal(0, #sent)
    end)

    it("stays quiet for a shadowed root that has no overrides to lose", function()
      local root = tempdir()
      write_file(root .. "/pyrightconfig.json", "{}")
      M.warn_shadowed(root)
      assert.are.equal(0, #sent)
    end)

    it("names the shadowing file when overrides would be discarded", function()
      local root = tempdir()
      write_file(root .. "/pyrightconfig.json", "{}")
      M.set(root, "reportCallIssue", "warning")

      M.warn_shadowed(root)

      assert.are.equal(1, #sent)
      assert.is_truthy(sent[1]:find("pyrightconfig.json", 1, true))
    end)

    it("warns once per root, not once per buffer opened in it", function()
      local root = tempdir()
      write_file(root .. "/pyrightconfig.json", "{}")
      M.set(root, "reportCallIssue", "warning")

      M.warn_shadowed(root)
      M.warn_shadowed(root)
      M.warn_shadowed(root)

      assert.are.equal(1, #sent)
    end)
  end)

  describe("firing", function()
    local ns, bufs

    local function buffer_in(root, name, codes)
      local buf = vim.api.nvim_create_buf(false, false)
      vim.api.nvim_buf_set_name(buf, vim.fs.joinpath(root, name))
      table.insert(bufs, buf)
      local diagnostics = {}
      for i, code in ipairs(codes) do
        table.insert(diagnostics, {
          lnum = i - 1,
          col = 0,
          message = code .. " here",
          severity = vim.diagnostic.severity.ERROR,
          code = code,
        })
      end
      vim.diagnostic.set(ns, buf, diagnostics)
      return buf
    end

    before_each(function()
      ns = vim.api.nvim_create_namespace("pyright_rules_spec")
      bufs = {}
    end)

    after_each(function()
      for _, buf in ipairs(bufs) do
        vim.diagnostic.reset(ns, buf)
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
    end)

    it("returns nothing for a project with no diagnostics", function()
      assert.same({}, M.firing(tempdir()))
    end)

    it("counts each rule across every buffer in the project", function()
      local root = tempdir()
      buffer_in(root, "a.py", { "reportCallIssue", "reportCallIssue", "reportArgumentType" })
      buffer_in(root, "b.py", { "reportCallIssue" })

      assert.same({ reportCallIssue = 3, reportArgumentType = 1 }, M.firing(root))
    end)

    it("ignores diagnostics from buffers in another project", function()
      local root, other = tempdir(), tempdir()
      buffer_in(root, "a.py", { "reportCallIssue" })
      buffer_in(other, "a.py", { "reportIndexIssue" })

      assert.same({ reportCallIssue = 1 }, M.firing(root))
    end)

    -- The picker acts on pyright rule severities; ruff's F401/E501 are a
    -- different server's codes and cannot be set through this store, so listing
    -- them as actionable rows would be a lie.
    it("ignores codes that are not pyright rule names", function()
      local root = tempdir()
      buffer_in(root, "a.py", { "reportCallIssue", "F401", "E501" })

      assert.same({ reportCallIssue = 1 }, M.firing(root))
    end)

    it("ignores a diagnostic carrying no code at all", function()
      local root = tempdir()
      local buf = vim.api.nvim_create_buf(false, false)
      vim.api.nvim_buf_set_name(buf, vim.fs.joinpath(root, "a.py"))
      table.insert(bufs, buf)
      vim.diagnostic.set(ns, buf, { { lnum = 0, col = 0, message = "no code" } })

      assert.same({}, M.firing(root))
    end)
  end)

  describe("apply", function()
    local function fake_client(root)
      return {
        name = "pyright",
        root_dir = root,
        config = { root_dir = root },
        settings = { python = { analysis = { autoSearchPaths = true } } },
        sent = {},
        notify = function(self, method, params)
          table.insert(self.sent, { method = method, params = params })
          return true
        end,
      }
    end

    it("pushes the root's rules onto a client serving it", function()
      local root = tempdir()
      M.set(root, "reportCallIssue", "warning")
      local client = fake_client(root)

      M.apply(root, { client })

      assert.same(
        { reportCallIssue = "warning" },
        client.settings.python.analysis.diagnosticSeverityOverrides
      )
    end)

    it("mutates the live settings in place, never reassigning them", function()
      local root = tempdir()
      M.set(root, "reportCallIssue", "warning")
      local client = fake_client(root)
      local settings = client.settings
      local analysis = client.settings.python.analysis

      M.apply(root, { client })

      assert.are.equal(settings, client.settings)
      assert.are.equal(analysis, client.settings.python.analysis)
      assert.is_true(client.settings.python.analysis.autoSearchPaths)
    end)

    it("notifies workspace/didChangeConfiguration so the change lands without a restart", function()
      local root = tempdir()
      M.set(root, "reportCallIssue", "warning")
      local client = fake_client(root)

      M.apply(root, { client })

      assert.are.equal(1, #client.sent)
      assert.are.equal("workspace/didChangeConfiguration", client.sent[1].method)
    end)

    it("drops a rule from the live client once it is cleared from the store", function()
      local root = tempdir()
      M.set(root, "reportCallIssue", "warning")
      local client = fake_client(root)
      M.apply(root, { client })

      M.set(root, "reportCallIssue", nil)
      M.apply(root, { client })

      assert.same({}, client.settings.python.analysis.diagnosticSeverityOverrides)
    end)

    it("leaves a client rooted at another project alone", function()
      local root, other = tempdir(), tempdir()
      M.set(root, "reportCallIssue", "warning")
      local client = fake_client(other)

      M.apply(root, { client })

      assert.is_nil(client.settings.python.analysis.diagnosticSeverityOverrides)
      assert.are.equal(0, #client.sent)
    end)

    it("reports how many clients it reached", function()
      local root, other = tempdir(), tempdir()
      M.set(root, "reportCallIssue", "warning")

      assert.are.equal(2, M.apply(root, { fake_client(root), fake_client(root) }))
      assert.are.equal(0, M.apply(root, { fake_client(other) }))
    end)

    it("skips a client with no settings table rather than erroring", function()
      local root = tempdir()
      M.set(root, "reportCallIssue", "warning")
      local client = fake_client(root)
      client.settings = nil

      assert.has_no.errors(function()
        M.apply(root, { client })
      end)
      assert.are.equal(0, #client.sent)
    end)
  end)

  describe("build_rows", function()
    it("offers every preset rule even when nothing is firing", function()
      local rows = M.build_rows(tempdir(), {})
      local seen = {}
      for _, row in ipairs(rows) do
        seen[row.rule] = true
      end
      for rule in pairs(M.PRESET) do
        assert.is_true(seen[rule], "missing preset rule " .. rule)
      end
    end)

    local function find(rows, rule)
      for _, row in ipairs(rows) do
        if row.rule == rule then
          return row
        end
      end
    end

    it("carries the live count for a firing rule", function()
      local rows = M.build_rows(tempdir(), { reportCallIssue = 7 })
      assert.are.equal(7, find(rows, "reportCallIssue").count)
    end)

    it("carries the recorded severity, and nil for a rule with no override", function()
      local root = tempdir()
      M.set(root, "reportCallIssue", "none")
      local rows = M.build_rows(root, {})
      assert.are.equal("none", find(rows, "reportCallIssue").severity)
      assert.is_nil(find(rows, "reportArgumentType").severity)
    end)

    it("includes a firing rule that is neither preset nor overridden", function()
      local rows = M.build_rows(tempdir(), { reportOptionalMemberAccess = 2 })
      assert.are.equal(2, find(rows, "reportOptionalMemberAccess").count)
    end)

    it("includes an overridden rule that is neither preset nor firing", function()
      local root = tempdir()
      M.set(root, "reportPrivateImportUsage", "none")
      local rows = M.build_rows(root, {})
      assert.are.equal("none", find(rows, "reportPrivateImportUsage").severity)
    end)

    it("lists each rule exactly once when it is preset, firing and overridden", function()
      local root = tempdir()
      M.set(root, "reportCallIssue", "warning")
      local rows = M.build_rows(root, { reportCallIssue = 3 })
      local hits = 0
      for _, row in ipairs(rows) do
        if row.rule == "reportCallIssue" then
          hits = hits + 1
        end
      end
      assert.are.equal(1, hits)
    end)

    -- Noisiest first, so the rule actually burying the buffer is the one under
    -- the cursor when the picker opens.
    it("sorts by count descending, then by rule name", function()
      local rows = M.build_rows(tempdir(), { reportIndexIssue = 2, reportCallIssue = 9 })
      assert.are.equal("reportCallIssue", rows[1].rule)
      assert.are.equal("reportIndexIssue", rows[2].rule)
      local names = {}
      for i = 3, #rows do
        table.insert(names, rows[i].rule)
      end
      local sorted = vim.deepcopy(names)
      table.sort(sorted)
      assert.same(sorted, names)
    end)
  end)

  describe("cycle", function()
    local function fake_client(root)
      return {
        name = "pyright",
        root_dir = root,
        config = { root_dir = root },
        settings = { python = { analysis = {} } },
        sent = {},
        notify = function(self, method)
          table.insert(self.sent, method)
          return true
        end,
      }
    end

    it("steps an unset rule to warning and records it", function()
      local root = tempdir()
      assert.are.equal("warning", M.cycle(root, "reportCallIssue", {}))
      assert.are.equal("warning", M.get(root).reportCallIssue)
    end)

    it("walks the cycle on repeated presses", function()
      local root = tempdir()
      M.cycle(root, "reportCallIssue", {})
      assert.are.equal("information", M.cycle(root, "reportCallIssue", {}))
      assert.are.equal("none", M.cycle(root, "reportCallIssue", {}))
      assert.are.equal("error", M.cycle(root, "reportCallIssue", {}))
    end)

    it("restores pyright's default at the end of the cycle", function()
      local root = tempdir()
      M.set(root, "reportCallIssue", "error")

      assert.is_nil(M.cycle(root, "reportCallIssue", {}))
      assert.is_nil(M.get(root).reportCallIssue)
    end)

    it("pushes the new severity to the live client", function()
      local root = tempdir()
      local client = fake_client(root)

      M.cycle(root, "reportCallIssue", { client })

      assert.are.equal(
        "warning",
        client.settings.python.analysis.diagnosticSeverityOverrides.reportCallIssue
      )
      assert.are.equal("workspace/didChangeConfiguration", client.sent[1])
    end)
  end)

  describe("_build_entry", function()
    local function text(entry)
      local display = entry.display
      return type(display) == "function" and (display(entry)) or display
    end

    it("filters on the rule name, so typing it narrows the list", function()
      local entry = M._build_entry({ rule = "reportCallIssue", count = 0 })
      assert.are.equal("reportCallIssue", entry.ordinal)
    end)

    it("keeps the row reachable as the entry's value", function()
      local row = { rule = "reportCallIssue", count = 0 }
      assert.are.equal(row, M._build_entry(row).value)
    end)

    it("names the rule", function()
      local line = text(M._build_entry({ rule = "reportCallIssue", count = 0 }))
      assert.is_truthy(line:find("reportCallIssue", 1, true))
    end)

    it("marks an overridden rule and shows what it was changed to", function()
      local line =
        text(M._build_entry({ rule = "reportCallIssue", severity = "warning", count = 0 }))
      assert.is_truthy(line:find("●", 1, true))
      assert.is_truthy(line:find("warning", 1, true))
    end)

    it("leaves an unoverridden rule unmarked", function()
      local line = text(M._build_entry({ rule = "reportCallIssue", count = 0 }))
      assert.is_nil(line:find("●", 1, true))
    end)

    it("shows how many diagnostics the rule is producing", function()
      local line = text(M._build_entry({ rule = "reportCallIssue", count = 8 }))
      assert.is_truthy(line:find("8", 1, true))
    end)

    it("shows no count for a rule that is not firing", function()
      local line = text(M._build_entry({ rule = "reportCallIssue", count = 0 }))
      assert.is_nil(line:find("0", 1, true))
    end)

    it("renders the clear-all sentinel as its own row", function()
      local entry = M._build_entry({ clear_all = true })
      assert.is_truthy(text(entry):find("clear", 1, true))
      assert.is_truthy(entry.ordinal:find("clear", 1, true))
    end)
  end)

  describe("preview_lines", function()
    local ns, bufs

    local function buffer_in(root, name, diagnostics)
      local buf = vim.api.nvim_create_buf(false, false)
      vim.api.nvim_buf_set_name(buf, vim.fs.joinpath(root, name))
      table.insert(bufs, buf)
      vim.diagnostic.set(ns, buf, diagnostics)
      return buf
    end

    before_each(function()
      ns = vim.api.nvim_create_namespace("pyright_rules_preview_spec")
      bufs = {}
    end)

    after_each(function()
      for _, buf in ipairs(bufs) do
        vim.diagnostic.reset(ns, buf)
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
    end)

    it("says so when the rule is producing nothing here", function()
      local lines = M.preview_lines(tempdir(), "reportCallIssue")
      assert.are.equal(1, #lines)
      assert.is_truthy(lines[1]:lower():find("no ", 1, true))
    end)

    it("shows each occurrence as path:line with its message", function()
      local root = tempdir()
      buffer_in(root, "app/models.py", {
        {
          lnum = 11,
          col = 0,
          message = 'Argument missing for parameter "name"',
          code = "reportCallIssue",
        },
      })

      local lines = M.preview_lines(root, "reportCallIssue")

      assert.are.equal(1, #lines)
      assert.is_truthy(lines[1]:find("app/models.py:12", 1, true))
      assert.is_truthy(lines[1]:find('Argument missing for parameter "name"', 1, true))
    end)

    it("shows only the rule that was asked for", function()
      local root = tempdir()
      buffer_in(root, "a.py", {
        { lnum = 0, col = 0, message = "call", code = "reportCallIssue" },
        { lnum = 1, col = 0, message = "arg", code = "reportArgumentType" },
      })

      local lines = M.preview_lines(root, "reportCallIssue")

      assert.are.equal(1, #lines)
      assert.is_truthy(lines[1]:find("call", 1, true))
    end)

    it("shows only occurrences inside this project", function()
      local root, other = tempdir(), tempdir()
      buffer_in(root, "a.py", { { lnum = 0, col = 0, message = "mine", code = "reportCallIssue" } })
      buffer_in(
        other,
        "a.py",
        { { lnum = 0, col = 0, message = "theirs", code = "reportCallIssue" } }
      )

      local lines = M.preview_lines(root, "reportCallIssue")

      assert.are.equal(1, #lines)
      assert.is_truthy(lines[1]:find("mine", 1, true))
    end)

    it("collapses a multi-line message onto one row", function()
      local root = tempdir()
      buffer_in(root, "a.py", {
        { lnum = 0, col = 0, message = "first line\nsecond line", code = "reportCallIssue" },
      })

      local lines = M.preview_lines(root, "reportCallIssue")

      assert.are.equal(1, #lines)
      assert.is_truthy(lines[1]:find("first line", 1, true))
      assert.is_truthy(lines[1]:find("second line", 1, true))
    end)
  end)

  describe("preview_for", function()
    -- The body of the picker's define_preview, extracted so it is reachable:
    -- telescope opens no preview window in the headless harness, so the closure
    -- itself never runs there (see e2e/pyright_rules_picker_spec.lua).
    it("explains the clear-all sentinel rather than looking up a rule", function()
      local lines = M.preview_for(tempdir(), { clear_all = true })
      assert.are.equal(1, #lines)
      assert.is_truthy(lines[1]:lower():find("every rule", 1, true))
    end)

    it("shows a rule's occurrences", function()
      local root = tempdir()
      assert.same(
        M.preview_lines(root, "reportCallIssue"),
        M.preview_for(root, {
          rule = "reportCallIssue",
          count = 0,
        })
      )
    end)
  end)

  describe("resolve_root", function()
    it("answers with the root of the pyright client serving the buffer", function()
      local root = tempdir()
      local client = { name = "pyright", root_dir = root, config = { root_dir = root } }
      assert.are.equal(M.normalize(root), M.resolve_root(0, { client }))
    end)

    -- The store is keyed on the client's root_dir, which is what before_init
    -- reads. Falling back to the git root would silently write the override
    -- under a different key in any project pyright roots below the repo.
    it("returns nil when no pyright client is attached", function()
      assert.is_nil(M.resolve_root(0, {}))
    end)

    it("falls back to config.root_dir when the client exposes only that", function()
      local root = tempdir()
      local client = { name = "pyright", config = { root_dir = root } }
      assert.are.equal(M.normalize(root), M.resolve_root(0, { client }))
    end)
  end)
end)
