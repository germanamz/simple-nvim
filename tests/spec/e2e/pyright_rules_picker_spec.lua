local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")

-- Drives the <leader>ld modal itself (config.pyright_rules.pick). The unit spec
-- covers the store, the cycle and the row building as pure functions; this
-- covers the glue those cannot reach — the finder, the previewer, the three
-- mappings and the in-place refresh — which is exactly where a typo or a
-- misremembered telescope API survives every other lane.
--
-- No real pyright here: pick() takes the root as an argument, so the modal is
-- driven against a fixture project and the diagnostics are set directly. Whether
-- pyright honors what it writes is e2e-lsp/pyright_rules_spec.lua's job.
--
-- Rows are read from `picker.results_bufnr` and selection is moved with the
-- picker's own `j` action, both of which telescope_spec already relies on.
-- `picker.manager` is deliberately NOT used: it is not populated at the point a
-- test can first reach the picker.
local function is_open()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].filetype == "TelescopePrompt" then
      return true
    end
  end
  return false
end

local function prompt_buf()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].filetype == "TelescopePrompt" then
      return buf
    end
  end
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
end

local function close()
  press("<Esc>")
  wait.wait_for(function()
    return not is_open()
  end, 2000, "picker did not close")
end

describe("e2e: pyright rules picker", function()
  local env, proj, rules

  before_each(function()
    env = nvim_env.setup_isolated_env()
    require("lazy").load({ plugins = { "telescope.nvim" } })
    proj = (vim.uv.fs_realpath(env) or env) .. "/proj"
    vim.fn.mkdir(proj, "p")
    package.loaded["config.pyright_rules"] = nil
    rules = require("config.pyright_rules")
  end)

  after_each(function()
    if is_open() then
      pcall(close)
    end
    vim.cmd("silent! %bwipeout!")
    vim.api.nvim_clear_autocmds({ event = "User", pattern = "PyrightRulesChanged" })
    nvim_env.teardown(env)
  end)

  -- Open, and wait until the rows have actually rendered.
  local function open()
    rules.pick(proj)
    wait.wait_for_buffer({ filetype = "TelescopePrompt", timeout = 3000 })
    local buf = assert(prompt_buf(), "no telescope prompt buffer")
    local picker =
      assert(require("telescope.actions.state").get_current_picker(buf), "no current picker")
    wait.wait_for(function()
      return #vim.tbl_filter(function(l)
        return l ~= ""
      end, vim.api.nvim_buf_get_lines(picker.results_bufnr, 0, -1, false)) > 0
    end, 5000, "results never populated")
    return picker
  end

  local function rows(picker)
    return vim.tbl_filter(function(l)
      return l ~= ""
    end, vim.api.nvim_buf_get_lines(picker.results_bufnr, 0, -1, false))
  end

  -- Walk the selection with the picker's own key until `pred` matches, so the
  -- test never depends on sort order or on telescope's internal indexing.
  local function select_row(pred, what)
    local action_state = require("telescope.actions.state")
    for _ = 1, 30 do
      local entry = action_state.get_selected_entry()
      if entry and pred(entry.value) then
        return entry
      end
      press("j")
    end
    error("never selected " .. what)
  end

  it("opens titled by the project and lists every preset rule", function()
    local picker = open()

    assert.is_truthy(
      picker.prompt_title:find("proj", 1, true),
      "expected the project in the title, got: " .. tostring(picker.prompt_title)
    )
    local lines = table.concat(rows(picker), "\n")
    for rule in pairs(rules.PRESET) do
      assert.is_truthy(lines:find(rule, 1, true), "missing row for " .. rule)
    end
    assert.is_truthy(lines:find("clear all overrides", 1, true), "missing the clear-all row")

    close()
  end)

  it("cycles the selected rule's severity on <CR> and stays open", function()
    open()
    select_row(function(v)
      return v.rule == "reportCallIssue"
    end, "reportCallIssue")

    press("<CR>")
    wait.wait_for(function()
      return rules.get(proj).reportCallIssue ~= nil
    end, 2000, "severity was never recorded")

    assert.are.equal("warning", rules.get(proj).reportCallIssue)
    assert.is_true(is_open(), "the picker should stay open for a second pick")

    close()
  end)

  it("marks the cycled rule active on the refreshed rows", function()
    local picker = open()
    select_row(function(v)
      return v.rule == "reportCallIssue"
    end, "reportCallIssue")

    press("<CR>")
    wait.wait_for(function()
      return table.concat(rows(picker), "\n"):find("→ warning", 1, true) ~= nil
    end, 3000, "the rows never refreshed to show the override")

    close()
  end)

  it("applies the whole preset on <C-p>", function()
    open()

    press("<C-p>")
    wait.wait_for(function()
      return vim.tbl_count(rules.get(proj)) >= vim.tbl_count(rules.PRESET)
    end, 3000, "preset was never applied")

    assert.same(rules.PRESET, rules.get(proj))

    close()
  end)

  it("drops the selected rule's override on <C-d>", function()
    rules.set(proj, "reportCallIssue", "none")
    open()
    select_row(function(v)
      return v.rule == "reportCallIssue"
    end, "reportCallIssue")

    press("<C-d>")
    wait.wait_for(function()
      return rules.get(proj).reportCallIssue == nil
    end, 2000, "override was never dropped")

    assert.same({}, rules.get(proj))

    close()
  end)

  it("clears every override from the sentinel row", function()
    rules.apply_preset(proj)
    open()
    select_row(function(v)
      return v.clear_all
    end, "the clear-all row")

    press("<CR>")
    wait.wait_for(function()
      return next(rules.get(proj)) == nil
    end, 2000, "overrides were never cleared")

    assert.same({}, rules.get(proj))

    close()
  end)

  -- The preview PANE is not asserted here, and cannot be: telescope opens no
  -- preview window under this harness (`picker.preview_win` is nil, so
  -- define_preview never runs). Its content is covered instead by the
  -- preview_for / preview_lines unit tests. What this checks is the other half
  -- the unit tests cannot — that live diagnostics actually reach the rendered
  -- rows.
  it("shows the live diagnostic count on the rule's row", function()
    -- Deliberately NOT a .py file: loading one here would attach the real LSP
    -- stack and fail on the isolated env's missing lsp.log directory. Neither
    -- firing() nor preview_lines() looks at filetype — only at whether the path
    -- is inside the project — so a .txt buffer exercises the same code.
    local file = proj .. "/app.txt"
    local fd = assert(io.open(file, "w"))
    fd:write("x = 1\ny = 2\n")
    fd:close()
    local target = vim.fn.bufadd(file)
    vim.fn.bufload(target)
    local ns = vim.api.nvim_create_namespace("pyright_rules_picker_spec")
    vim.diagnostic.set(ns, target, {
      { lnum = 0, col = 0, message = "argument missing", code = "reportCallIssue" },
      { lnum = 1, col = 0, message = "argument missing", code = "reportCallIssue" },
    })

    local picker = open()

    local row
    for _, line in ipairs(rows(picker)) do
      if line:find("reportCallIssue", 1, true) then
        row = line
      end
    end
    assert.is_not_nil(row, "no reportCallIssue row in " .. vim.inspect(rows(picker)))
    assert.is_truthy(
      row:find("2", 1, true),
      "expected the live count of 2 on the row, got: " .. vim.inspect(row)
    )
    -- And it sorts above the preset rules that are firing nothing.
    assert.is_truthy(rows(picker)[1]:find("reportCallIssue", 1, true), "noisiest rule not first")

    vim.diagnostic.reset(ns, target)
    close()
  end)
end)
