-- Per-project pyright rule severities, chosen from a picker and persisted per
-- repo. The problem this solves: a codebase that carries type annotations but
-- does not follow them by the letter — Pydantic being the canonical case —
-- draws a wall of red that buries the diagnostics worth reading.
--
-- Why per-RULE and not typeCheckingMode
-- -------------------------------------
-- The usual advice, `typeCheckingMode = "basic"`, does nothing here. The five
-- rules that produce the Pydantic noise are "error" in basic, standard AND
-- strict alike (measured against pyright 1.1.409: 12 errors on the same file in
-- all three modes; only "off" silences them, and that gives up type checking
-- wholesale). `python.analysis.diagnosticSeverityOverrides` is the only
-- server-side lever with the granularity this needs, which is why the store is
-- keyed rule-by-rule rather than holding one mode string per repo.
--
-- Why per-root settings work at all
-- ---------------------------------
-- Neovim starts one client per root_dir (lsp.lua's reuse_client_default demands
-- exact workspace-folder equality), and root_dir is fully resolved by the time
-- before_init runs — so a settings fragment keyed on the realpath'd root gives
-- genuinely different severities per project from ONE vim.lsp.config("pyright")
-- registration, with the enabled config left uncontaminated (vim.lsp deep-copies
-- it per start attempt).
--
-- The trap, and it is a silent one: `client.settings` is bound BY REFERENCE to
-- `config.settings` at Client.create, which happens BEFORE before_init runs.
-- Reassigning the field — `config.settings = vim.tbl_deep_extend(...)`, the very
-- pattern printed in Neovim's own client.lua docstring — breaks that aliasing
-- and the server never sees a thing. Everything below mutates in place. The spec
-- asserts on table identity, not just content, so a future refactor to the
-- "cleaner" reassignment fails loudly instead of quietly doing nothing.
--
-- Scope limits, both accepted rather than solved:
--   * Editor-side only. Nothing reaches the pyright CLI or CI.
--   * Whole-project only. Neovim answers one settings blob per client and
--     ignores workspace/configuration's `scopeUri`, so a "legacy/ loose, src/
--     strict" split is not reachable from here — that needs a pyrightconfig.json
--     with executionEnvironments. See docs/python-diagnostics.md.
local M = {}

local state_util = require("util.state")

-- Pyright accepts exactly these (plus booleans, which we never write). "hint" is
-- a basedpyright extension: pyright 1.1.409 silently DISCARDS it and leaves the
-- rule at its mode default — i.e. still red — so it must never appear here.
M.SEVERITIES = { "error", "warning", "information", "none" }

-- The order <CR> walks in the picker. Deliberately NOT M.SEVERITIES' order: an
-- unset rule steps to "warning" first, because the whole point of reaching for
-- this is "stop it being red" and a first press landing on "error" would be a
-- no-op for every rule in M.PRESET. "error" sits last so a rule that is off or
-- merely a warning by default can still be tightened, and the step past it
-- restores pyright's own default.
local CYCLE = { "warning", "information", "none", "error" }

-- The five rules that produce essentially all of the Pydantic noise. Pyright has
-- no plugin system — it synthesizes BaseModel.__init__ from PEP 681
-- @dataclass_transform and nothing else — so Pydantic's runtime behavior
-- (coercion, aliases, extra="allow", before-validators) is invisible to it:
--   reportCallIssue          extra="allow" kwargs; Field(alias=...) reads as both
--                            "argument missing" and "no parameter named"
--   reportArgumentType       coercion at the call site (age="23", ISO str -> datetime)
--   reportAttributeAccessIssue  reading a field that exists only via extra="allow"
--   reportAssignmentType     assigning a coercible value to a typed field
--   reportIndexIssue         dict-style subscripting of a model
-- "warning" rather than "none" on purpose: they stay in ]d, the loclist and the
-- CursorHold float, they just stop being red. Cycle any of them to "none" from
-- the picker if a given project wants them gone outright.
M.PRESET = {
  reportCallIssue = "warning",
  reportArgumentType = "warning",
  reportAttributeAccessIssue = "warning",
  reportAssignmentType = "warning",
  reportIndexIssue = "warning",
}

-- Resolved per call, not at require time: stdpath("data") follows $XDG_DATA_HOME
-- at call time and the test harness swaps that per test. Same reasoning as
-- config.review_base's state_path.
function M.state_path()
  return vim.fn.stdpath("data") .. "/nvim-pyright-rules.json"
end

--- The key a root is stored under. Realpath'd so a symlinked checkout and its
--- target cannot end up with two divergent entries — and so the key matches what
--- before_init computes from the client's own root_dir.
---@param root string|nil
---@return string|nil
function M.normalize(root)
  if not root then
    return nil
  end
  return vim.uv.fs_realpath(root) or root
end

-- Decoded state, memoized. M.get is reached from before_init and from every
-- picker rebuild; caching the decoded table keeps those off the disk. Populated
-- lazily, written through on every write_state. Module-local, so the harness's
-- package.loaded reset gives each test a fresh cache.
local cache

local function decode_state()
  local raw = state_util.read_file(M.state_path())
  if not raw or raw == "" then
    return {}
  end
  local ok, data = pcall(vim.json.decode, raw)
  if ok and type(data) == "table" then
    return data
  end
  return {}
end

local function read_state()
  if not cache then
    cache = decode_state()
  end
  return cache
end

-- Shallow copy of the live state so a mutator edits a throwaway table: if the
-- atomic write fails, the cache stays consistent with disk instead of holding an
-- edit that never persisted (config.review_base's copy_state, same contract).
local function copy_state()
  local out = {}
  for root, rules in pairs(read_state()) do
    local copy = {}
    for rule, severity in pairs(rules) do
      copy[rule] = severity
    end
    out[root] = copy
  end
  return out
end

local function write_state(state)
  if not state_util.write_atomic(M.state_path(), vim.json.encode(state)) then
    -- Nothing persisted: keep the cache on what disk actually holds.
    return
  end
  cache = state
end

local function fire(root, rules)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "PyrightRulesChanged",
    data = { root = root, rules = rules },
  })
end

--- The severity overrides recorded for `root`, as a fresh table (never the
--- cache's own, which a caller could otherwise mutate behind our back).
---@param root string|nil
---@return table<string, string>
function M.get(root)
  local key = M.normalize(root)
  local rules = key and read_state()[key]
  local out = {}
  if type(rules) == "table" then
    for rule, severity in pairs(rules) do
      out[rule] = severity
    end
  end
  return out
end

--- Record `severity` for `rule` in `root`; a nil severity removes that one rule
--- and leaves its siblings alone. Persists and broadcasts only on a real change,
--- so re-picking the severity a rule already has is silent.
---@param root string|nil
---@param rule string
---@param severity string|nil one of M.SEVERITIES, or nil to restore the default
function M.set(root, rule, severity)
  local key = M.normalize(root)
  if not key or not rule then
    return
  end
  local current = read_state()[key]
  if (current and current[rule] or nil) == severity then
    return
  end
  local state = copy_state()
  state[key] = state[key] or {}
  state[key][rule] = severity
  -- Drop a root that no longer overrides anything, so the store does not
  -- accumulate empty objects that json round-trip as dicts-vs-arrays.
  if next(state[key]) == nil then
    state[key] = nil
  end
  write_state(state)
  fire(key, M.get(key))
end

--- Fold `rules` into `root`'s overrides in ONE write and ONE broadcast — the
--- picker's preset action would otherwise fire five times and make five
--- consumers recompute five times for a single user gesture.
---@param root string|nil
---@param rules table<string, string>
function M.set_many(root, rules)
  local key = M.normalize(root)
  if not key then
    return
  end
  local state = copy_state()
  state[key] = state[key] or {}
  local changed = false
  for rule, severity in pairs(rules) do
    if state[key][rule] ~= severity then
      state[key][rule] = severity
      changed = true
    end
  end
  if not changed then
    return
  end
  write_state(state)
  fire(key, M.get(key))
end

--- Apply the Pydantic preset to `root`, leaving any unrelated overrides alone.
---@param root string|nil
function M.apply_preset(root)
  M.set_many(root, M.PRESET)
end

--- The next severity in the picker's cycle. nil means "restore pyright's
--- default" — both as the argument (nothing recorded) and as the return.
---@param current string|nil
---@return string|nil
function M.next_severity(current)
  for i, severity in ipairs(CYCLE) do
    if severity == current then
      return CYCLE[i + 1]
    end
  end
  -- Unset, or a value we did not write (a hand-edited store, or "hint" from a
  -- basedpyright habit): restart the cycle rather than dead-end on it.
  return CYCLE[1]
end

--- Drop every override for `root`. Silent when there were none.
---@param root string|nil
function M.clear(root)
  local key = M.normalize(root)
  if not key or read_state()[key] == nil then
    return
  end
  local state = copy_state()
  state[key] = nil
  write_state(state)
  fire(key, {})
end

--- vim.lsp before_init hook for pyright: fold this root's overrides into the
--- settings table the client is about to be bound to.
---
--- MUTATES `config.settings` in place — see the header. `config.settings` is
--- normally non-nil by now (nvim-lspconfig's lsp/pyright.lua contributes
--- python.analysis.{autoSearchPaths,useLibraryCodeForTypes,diagnosticMode}), but
--- if it ever is nil there is nothing aliased to client.settings and creating one
--- here would be a no-op, so bail rather than pretend it worked.
---@param _ table|nil initialize params (unused)
---@param config table the resolved client config
function M.before_init(_, config)
  local rules = M.get(config and config.root_dir)
  if next(rules) == nil then
    return
  end
  local settings = config.settings
  if not settings then
    return
  end
  settings.python = settings.python or {}
  settings.python.analysis = settings.python.analysis or {}
  local overrides = settings.python.analysis.diagnosticSeverityOverrides or {}
  for rule, severity in pairs(rules) do
    overrides[rule] = severity
  end
  settings.python.analysis.diagnosticSeverityOverrides = overrides
end

-- Is `dir` inside `root`? Both must already be realpath'd; the "/" guard stops
-- /repo-backup matching /repo.
local function under(dir, root)
  return dir == root and true or vim.startswith(dir, root .. "/")
end

-- Realpath the deepest EXISTING ancestor of `dir` and re-append the rest.
-- fs_realpath answers nil for a path that is not on disk, and a buffer's
-- directory need not be (`:e src/new/thing.py` before the tree exists), so a
-- plain `fs_realpath(dir) or dir` leaves such a buffer with an unresolved prefix
-- — which on macOS (/var -> /private/var) compares as OUTSIDE a realpath'd root
-- and silently drops its diagnostics.
local function real_dir(dir)
  local tail, d = {}, dir
  while d and d ~= "" do
    local real = vim.uv.fs_realpath(d)
    if real then
      for i = #tail, 1, -1 do
        real = vim.fs.joinpath(real, tail[i])
      end
      return real
    end
    local parent = vim.fs.dirname(d)
    if parent == d then
      break
    end
    table.insert(tail, vim.fs.basename(d))
    d = parent
  end
  return dir
end

-- Walk the pyright-relevant diagnostics of every loaded buffer inside `root`,
-- calling fn(diagnostic, dir) for each. The buffer walk lives here once so
-- M.firing and M.preview_lines cannot drift on which buffers count as "in this
-- project".
local function each_diagnostic(root, fn)
  local key = M.normalize(root)
  if not key then
    return
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) or ""
    if name ~= "" then
      local dir = real_dir(vim.fs.dirname(name))
      if under(dir, key) then
        for _, d in ipairs(vim.diagnostic.get(buf)) do
          fn(d, dir, name)
        end
      end
    end
  end
end

--- How many diagnostics each pyright rule is currently producing across the
--- loaded buffers of `root`, as { rule = count }. This is what turns the picker
--- from a list of rule names you have to already know into a list of what is
--- actually burying THIS project.
---
--- A rule is recognised by its `code` being a string starting with "report" —
--- pyright's universal rule-name convention. Filtering that way rather than on
--- `source`/namespace is deliberate: ruff also attaches to python buffers here,
--- and its codes (F401, E501) are not settable through this store, so listing
--- them as actionable rows would be a lie.
---
--- Buffer paths are compared by their DIRECTORY's realpath: the file itself may
--- not exist on disk yet (a new buffer), while its directory always does.
---@param root string|nil
---@return table<string, integer>
function M.firing(root)
  local counts = {}
  each_diagnostic(root, function(d)
    if type(d.code) == "string" and d.code:match("^report") then
      counts[d.code] = (counts[d.code] or 0) + 1
    end
  end)
  return counts
end

--- Push `root`'s recorded rules onto the pyright clients already serving it, so
--- a pick takes effect without `<leader>lr`.
---
--- Mutating `client.settings` is what does the work: Neovim answers pyright's
--- workspace/configuration requests out of that table, so the next pull sees the
--- new severities. The notify is what prompts that pull — pyright ignores the
--- notify's PAYLOAD entirely (a params-only notify changes nothing), which is why
--- the table is edited first and announced second.
---
--- The overrides leaf is rewritten wholesale rather than merged: this module is
--- its only writer, and a merge could never remove a rule the user just cycled
--- back to pyright's default.
---@param root string|nil
---@param clients table[]|nil defaults to every running pyright client
---@return integer clients updated
function M.apply(root, clients)
  local key = M.normalize(root)
  if not key then
    return 0
  end
  local rules = M.get(key)
  clients = clients or vim.lsp.get_clients({ name = "pyright" })
  local reached = 0
  for _, client in ipairs(clients) do
    local settings = client.settings
    local client_root = client.root_dir or (client.config and client.config.root_dir)
    if settings and M.normalize(client_root) == key then
      settings.python = settings.python or {}
      settings.python.analysis = settings.python.analysis or {}
      local overrides = settings.python.analysis.diagnosticSeverityOverrides or {}
      for rule in pairs(overrides) do
        overrides[rule] = nil
      end
      for rule, severity in pairs(rules) do
        overrides[rule] = severity
      end
      settings.python.analysis.diagnosticSeverityOverrides = overrides
      client:notify("workspace/didChangeConfiguration", { settings = settings })
      reached = reached + 1
    end
  end
  return reached
end

--- The picker's rows for `root`: every rule that is firing here, every rule
--- already overridden here, and the preset rules regardless — so the common
--- Pydantic case is one keypress away even in a project that is currently clean.
---@param root string|nil
---@param counts table<string, integer>|nil defaults to M.firing(root)
---@return table[] rows of { rule, severity, count }, noisiest first
function M.build_rows(root, counts)
  counts = counts or M.firing(root)
  local rules = M.get(root)
  local seen = {}
  for _, source in ipairs({ M.PRESET, counts, rules }) do
    for rule in pairs(source) do
      seen[rule] = true
    end
  end
  local rows = {}
  for rule in pairs(seen) do
    table.insert(rows, { rule = rule, severity = rules[rule], count = counts[rule] or 0 })
  end
  table.sort(rows, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return a.rule < b.rule
  end)
  return rows
end

--- The pyright config file in `root` that would DISCARD everything this module
--- injects, or nil when there is none.
---
--- Pyright's precedence is wholesale, not per-key: once it finds a config file it
--- never applies the client's settings group at all — not typeCheckingMode, not
--- one entry of diagnosticSeverityOverrides. An empty `[tool.pyright]` header is
--- enough to do it, and pyrightconfig.json outranks pyproject.toml. Without this
--- check the picker would look like it worked and change nothing.
---@param root string|nil
---@return string|nil path of the shadowing file
function M.shadowed(root)
  if not root then
    return nil
  end
  local json = vim.fs.joinpath(root, "pyrightconfig.json")
  if vim.uv.fs_stat(json) then
    return json
  end
  local pyproject = vim.fs.joinpath(root, "pyproject.toml")
  -- io.open + f:lines(), not io.lines: io.lines raises if the file vanished
  -- between the stat and the open. Same reasoning (and same matcher shape) as
  -- config.formatters' [tool.black] probe. Anchored at the line start so a
  -- commented-out `# [tool.pyright]` does not count, and the trailing class
  -- accepts a subtable header ([tool.pyright.defineConstant]), which implies the
  -- key just as much as the bare section does.
  local f = io.open(pyproject, "r")
  if not f then
    return nil
  end
  local found = false
  for line in f:lines() do
    if line:match("^%[tool%.pyright[%]%.]") then
      found = true
      break
    end
  end
  f:close()
  return found and pyproject or nil
end

--- Every occurrence of `rule` inside `root`, rendered one per line as
--- `relative/path.py:line  message`. This is the picker's preview: it answers
--- "what am I about to silence?" before the silencing happens.
---@param root string|nil
---@param rule string
---@return string[]
function M.preview_lines(root, rule)
  local key = M.normalize(root)
  local lines = {}
  each_diagnostic(root, function(d, dir, name)
    if d.code == rule then
      -- Pyright wraps its longer explanations onto several lines; a preview row
      -- per physical line would break the path:line alignment, so flatten them.
      table.insert(lines, {
        path = vim.fs.relpath(key, dir) or ".",
        file = vim.fs.basename(name),
        lnum = d.lnum + 1,
        message = table.concat(vim.split(d.message, "\n", { trimempty = true }), " "),
      })
    end
  end)
  if #lines == 0 then
    return { ("No %s diagnostics in the open buffers of this project."):format(rule) }
  end
  table.sort(lines, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.lnum < b.lnum
  end)
  return vim.tbl_map(function(l)
    local rel = l.path == "." and l.file or vim.fs.joinpath(l.path, l.file)
    return ("%s:%d  %s"):format(rel, l.lnum, l.message)
  end, lines)
end

--- The preview pane's content for one picker row. Split out of define_preview
--- because telescope opens no preview window under the headless test harness, so
--- a closure body is unreachable there while this is not.
---@param root string|nil
---@param row table a build_rows row, or the clear-all sentinel
---@return string[]
function M.preview_for(root, row)
  if row.clear_all then
    return { "Restores pyright's own severity for every rule overridden in this project." }
  end
  return M.preview_lines(root, row.rule)
end

--- The pyright root that owns `bufnr` — taken from the client actually serving
--- it, never from the git root: pyright roots at the nearest pyproject.toml /
--- setup.py, which in a repo of several packages is BELOW the repo top. The store
--- is keyed on whatever before_init sees as config.root_dir, so the picker has to
--- agree with the client or it writes overrides under a key nothing reads.
---@param bufnr integer
---@param clients table[]|nil defaults to the pyright clients on this buffer
---@return string|nil
function M.resolve_root(bufnr, clients)
  clients = clients or vim.lsp.get_clients({ bufnr = bufnr, name = "pyright" })
  local client = clients[1]
  if not client then
    return nil
  end
  return M.normalize(client.root_dir or (client.config and client.config.root_dir))
end

--- The <CR> action: advance `rule` one step around the cycle for `root`, persist
--- it, and push it to the live clients. Returns the new severity (nil = back to
--- pyright's default).
---@param root string|nil
---@param rule string
---@param clients table[]|nil defaults to every running pyright client
---@return string|nil
function M.cycle(root, rule, clients)
  local severity = M.next_severity(M.get(root)[rule])
  M.set(root, rule, severity)
  M.apply(root, clients)
  return severity
end

-- The trailing row that drops every override for the project at once. A table
-- rather than a string sentinel so it cannot collide with a rule name.
local CLEAR_SENTINEL = { clear_all = true }
M._CLEAR_SENTINEL = CLEAR_SENTINEL

local RULE_WIDTH = 34
local SEVERITY_WIDTH = 16

-- Pad to a DISPLAY width while the highlight ranges below index BYTES — the
-- marker and the arrow are multi-byte, so the two must not be conflated.
local function pad(s, width)
  local w = vim.api.nvim_strwidth(s)
  return w >= width and s or s .. string.rep(" ", width - w)
end

--- Build the telescope entry for one picker row. Separated from M.pick so the
--- rendering is testable without telescope (config.review_base's
--- _build_branch_entry, same split).
---@param row table { rule, severity, count } or the clear sentinel
---@return table
function M._build_entry(row)
  if row.clear_all then
    return {
      value = row,
      ordinal = "clear all overrides",
      display = "  [ clear all overrides for this project ]",
    }
  end

  local marker = row.severity and "● " or "  "
  local rule = pad(row.rule, RULE_WIDTH)
  -- Just "→ warning", not "error → warning": the arrow says an override is in
  -- force without asserting what pyright's default for that rule actually was,
  -- which varies per rule and per type-checking mode.
  local severity = row.severity and ("→ " .. row.severity) or ""
  local count = row.count > 0 and tostring(row.count) or ""
  local line = marker .. rule .. pad(severity, SEVERITY_WIDTH) .. count

  local ranges = {}
  if row.severity then
    table.insert(ranges, { { 0, #marker }, "PyrightRuleActive" })
    local at = #marker + #rule
    table.insert(ranges, { { at, at + #severity }, "PyrightRuleSeverity" })
  end
  if count ~= "" then
    local at = #marker + #rule + #pad(severity, SEVERITY_WIDTH)
    table.insert(ranges, { { at, at + #count }, "PyrightRuleCount" })
  end

  return {
    value = row,
    ordinal = row.rule,
    display = function()
      return line, ranges
    end,
  }
end

-- Test seam so specs can capture the message without a real UI (config.lsp_tsdk's
-- M._notify, same contract).
M._notify = nil

-- One warning per root: a project has many buffers and the fact is a property of
-- the project, not of the file you happened to open.
local warned = {}

--- Warn once that `root`'s recorded overrides are being thrown away by a pyright
--- config file. Silent when the root has nothing to lose, or nothing to lose it
--- to — this must never nag a project that simply owns its own config.
---@param root string|nil
function M.warn_shadowed(root)
  local key = M.normalize(root)
  if not key or warned[key] then
    return
  end
  if next(M.get(root)) == nil then
    return
  end
  local path = M.shadowed(root)
  if not path then
    return
  end
  warned[key] = true
  local notify = M._notify or vim.notify
  notify(
    ("%s takes precedence over editor settings, so the pyright rules recorded for %s are being ignored — set them in that file instead (docs/python-diagnostics.md)."):format(
      vim.fn.fnamemodify(path, ":~:."),
      vim.fs.basename(key)
    ),
    vim.log.levels.WARN
  )
end

-- Amber for both the marker and the severity: an override reads as "this rule
-- has been dialed down here", which is closer to an attention state than to the
-- purple "base" concept config.review_base owns. default = true so a colorscheme
-- can still have the last word.
local function ensure_highlights()
  vim.api.nvim_set_hl(0, "PyrightRuleActive", { fg = "#9a6700", bold = true, default = true })
  vim.api.nvim_set_hl(0, "PyrightRuleSeverity", { fg = "#9a6700", default = true })
  vim.api.nvim_set_hl(0, "PyrightRuleCount", {
    fg = require("config.palette").muted,
    default = true,
  })
end

--- The modal. Requires of telescope live here (call time), never at module load:
--- before_init reaches this file at LSP-start time and must not drag the picker
--- stack in with it.
---@param root string realpath'd pyright root
function M.pick(root)
  ensure_highlights()
  -- The one moment the user is definitely looking: say it here if the picks are
  -- going to be discarded by a config file in the project.
  M.warn_shadowed(root)

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  -- Rebuilt rather than mutated on every action: counts come from live
  -- diagnostics, which the server re-publishes as soon as a severity lands, so a
  -- rebuild is also how the counts stay honest.
  local function make_finder()
    local rows = M.build_rows(root)
    table.insert(rows, CLEAR_SENTINEL)
    return finders.new_table({ results = rows, entry_maker = M._build_entry })
  end

  local function refresh(prompt_bufnr)
    local ok, picker = pcall(action_state.get_current_picker, prompt_bufnr)
    if ok and picker then
      picker:refresh(make_finder(), { reset_prompt = false })
    end
  end

  local function selected()
    local entry = action_state.get_selected_entry()
    return entry and entry.value or nil
  end

  pickers
    .new({}, {
      prompt_title = "Python diagnostics — " .. vim.fs.basename(root),
      results_title = "<CR> cycle severity · <C-p> Pydantic preset · <C-d> clear rule",
      initial_mode = "normal",
      finder = make_finder(),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        title = "Occurrences in this project",
        define_preview = function(self, entry)
          vim.api.nvim_buf_set_lines(
            self.state.bufnr,
            0,
            -1,
            false,
            M.preview_for(root, entry.value)
          )
        end,
      }),
      attach_mappings = function(prompt_bufnr, map)
        -- <CR>: one step around the cycle, live. The picker deliberately stays
        -- open — dialing several rules down in one visit is the common case.
        actions.select_default:replace(function()
          local row = selected()
          if not row then
            return
          end
          if row.clear_all then
            M.clear(root)
            M.apply(root)
            vim.notify("Cleared pyright rule overrides for " .. vim.fs.basename(root))
          else
            local severity = M.cycle(root, row.rule)
            vim.notify(("%s → %s"):format(row.rule, severity or "pyright default"))
          end
          refresh(prompt_bufnr)
        end)

        -- <C-p>: the whole Pydantic preset at once, for the case this exists for.
        map({ "i", "n" }, "<C-p>", function()
          M.apply_preset(root)
          M.apply(root)
          vim.notify("Pydantic preset applied — " .. vim.iter(vim.tbl_keys(M.PRESET)):join(", "))
          refresh(prompt_bufnr)
        end)

        -- <C-d>: drop one rule's override outright, rather than cycling all the
        -- way round to reach the default again.
        map({ "i", "n" }, "<C-d>", function()
          local row = selected()
          if not row or row.clear_all then
            return
          end
          if not row.severity then
            vim.notify(row.rule .. " has no override here", vim.log.levels.WARN)
            return
          end
          M.set(root, row.rule, nil)
          M.apply(root)
          vim.notify(row.rule .. " restored to pyright's default")
          refresh(prompt_bufnr)
        end)

        return true
      end,
    })
    :find()
end

--- Entry point for the keymap and :PyrightRules. Resolves the project from the
--- pyright client on the current buffer, so the picker and before_init can never
--- disagree about which root the overrides belong to.
function M.open()
  local root = M.resolve_root(vim.api.nvim_get_current_buf())
  if not root then
    vim.notify(
      "No pyright client on this buffer — open a Python file in the project first",
      vim.log.levels.WARN
    )
    return
  end
  M.pick(root)
end

-- Drop the decoded store; the next read re-decodes from disk. For tests, and for
-- another nvim instance having edited the same file.
function M._clear()
  cache = nil
  warned = {}
end

return M
