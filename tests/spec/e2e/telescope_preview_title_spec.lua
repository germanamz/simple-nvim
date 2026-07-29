-- Regression guard for the preview-title trim, driven through the real picker
-- plumbing: config.telescope_smart's picker takes its previewer from
-- `telescope.config.values.file_previewer`, which lua/plugins/telescope.lua
-- points at the wrapper. Before the wrapper, plenary's border truncated the
-- title from the right and rendered
--   ╭ packages/some-service/src/modules/billing/handlers/create-i… ╮
-- i.e. all parents, no file name.
local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")

local DEEP = "packages/some-service/src/modules/billing/handlers/create-invoice-handler.txt"
local NAME = "create-invoice-handler.txt"

local function press(keys)
  local termcodes = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(termcodes, "mx", false)
end

local function prompt_buf()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].filetype == "TelescopePrompt" then
      return buf
    end
  end
  return nil
end

describe("e2e: telescope preview title", function()
  local root, prev_cwd, prev_columns, prev_lines

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
    -- Narrow enough that a deep path cannot fit the preview title, wide enough
    -- to clear telescope's preview_cutoff (120) so a preview window exists at
    -- all. Restored in after_each — the e2e session is shared.
    prev_columns, prev_lines = vim.o.columns, vim.o.lines
    vim.o.columns, vim.o.lines = 130, 50
    require("lazy").load({ plugins = { "telescope.nvim" } })
  end)

  after_each(function()
    if prompt_buf() then
      pcall(press, "<Esc>")
      pcall(wait.wait_for, function()
        return prompt_buf() == nil
      end, 2000, "picker did not close")
    end
    vim.o.columns, vim.o.lines = prev_columns, prev_lines
    pcall(vim.fn.chdir, prev_cwd)
    -- Let an in-flight preview read land before the fixture tree goes away: the
    -- previewer loads the file from a scheduled callback, which would otherwise
    -- report ENOENT into a later spec's output.
    vim.wait(100)
    nvim_env.teardown(root)
  end)

  it("trims leading directories so the full file name stays in the title", function()
    -- A .txt file on purpose: the previewer sets a filetype on its scratch
    -- buffer, and a real source extension would drag an LSP client into the
    -- shared headless session.
    vim.fn.mkdir(root .. "/packages/some-service/src/modules/billing/handlers", "p")
    vim.fn.writefile({ "invoice" }, root .. "/" .. DEEP)
    local canonical = vim.uv.fs_realpath(root) or root
    vim.fn.chdir(canonical)

    require("config.telescope_smart")._open_picker({
      title = "Preview title probe",
      results = { DEEP },
      cwd = canonical,
    })
    wait.wait_for_buffer({ filetype = "TelescopePrompt", timeout = 3000 })

    local picker = require("telescope.actions.state").get_current_picker(assert(prompt_buf()))
    assert.is_not_nil(picker, "no current picker")

    wait.wait_for(function()
      return type(picker.preview_title) == "string" and picker.preview_title:find(NAME, 1, true)
    end, 5000, "preview title never showed the previewed path")

    local title = picker.preview_title
    assert.are.equal(
      "…",
      title:sub(1, #"…"),
      "title should be trimmed from the start: " .. title
    )
    assert.are.equal(NAME, title:sub(-#NAME), "title should end in the file name: " .. title)

    -- And the border renders it untruncated: plenary only truncates a title
    -- wider than (window width - 2), which the trim already respects.
    local preview = assert(picker.layout and picker.layout.preview, "no preview window")
    local width = vim.api.nvim_win_get_width(preview.winid)
    assert.is_truthy(
      vim.api.nvim_strwidth(title) <= width - 2,
      "title still overflows the border: " .. title
    )
    local border = vim.api.nvim_buf_get_lines(preview.border.bufnr, 0, 1, false)[1]
    assert.is_truthy(
      border and border:find(NAME, 1, true),
      "border dropped the file name: " .. tostring(border)
    )
  end)
end)
