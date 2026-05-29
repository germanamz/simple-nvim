local nvim_env = require("tests.helpers.nvim_env")

-- The CursorHold autocmd that pops a diagnostic float is registered at
-- module-load time in lua/plugins/lsp.lua (top-level, not gated behind a lazy
-- load), so it is already wired up once full_init has run lazy.setup.

local function open_floats()
  local floats = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      floats[#floats + 1] = win
    end
  end
  return floats
end

local function close_floats()
  for _, win in ipairs(open_floats()) do
    pcall(vim.api.nvim_win_close, win, true)
  end
end

local function float_text_matching(needle)
  for _, win in ipairs(open_floats()) do
    local fbuf = vim.api.nvim_win_get_buf(win)
    local text = table.concat(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false), "\n")
    if text:find(needle, 1, true) then
      return text
    end
  end
  return nil
end

describe("e2e: diagnostics float on CursorHold", function()
  local root, ns

  before_each(function()
    root = nvim_env.setup_isolated_env()
    ns = vim.api.nvim_create_namespace("diag_float_spec")
    close_floats()
  end)

  after_each(function()
    close_floats()
    vim.cmd("silent! %bwipeout!")
    nvim_env.teardown(root)
  end)

  it("pops a float with the message when the cursor sits on a diagnostic", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local value = missing_symbol" })

    vim.diagnostic.set(ns, buf, {
      {
        lnum = 0,
        col = 14,
        end_lnum = 0,
        end_col = 28,
        severity = vim.diagnostic.severity.ERROR,
        message = "undefined global `missing_symbol`",
        source = "spec",
      },
    })

    -- col 16 is inside the marked range [14, 28), so scope="cursor" matches.
    vim.api.nvim_win_set_cursor(0, { 1, 16 })
    vim.api.nvim_exec_autocmds("CursorHold", {})

    assert.is_not_nil(
      float_text_matching("undefined global `missing_symbol`"),
      "no float contained the diagnostic message"
    )
  end)

  it("opens no diagnostic float when the cursor is off the marked range", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "local value = missing_symbol",
      "local ok = true",
    })

    vim.diagnostic.set(ns, buf, {
      {
        lnum = 0,
        col = 14,
        end_lnum = 0,
        end_col = 28,
        severity = vim.diagnostic.severity.ERROR,
        message = "off-range-marker",
      },
    })

    close_floats()
    -- Line 2 has no diagnostic; scope="cursor" must not surface line 1's.
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_exec_autocmds("CursorHold", {})

    assert.is_nil(
      float_text_matching("off-range-marker"),
      "diagnostic float opened while the cursor was off the marked range"
    )
  end)
end)
