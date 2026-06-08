local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")
local git_fixture = require("tests.helpers.git_fixture")
local bg = require("config.block_guides")

describe("e2e: block_guides", function()
  local root, prev_cwd

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
  end)

  after_each(function()
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  -- Opens a lua buffer with nested blocks and waits for treesitter to attach.
  local function open_sample()
    local content = table.concat({
      "local function foo()", -- row 0: function header
      "  local x = 1", -- row 1
      "  if cond then", -- row 2: if header
      "    do_thing()", -- row 3 (cursor here)
      "    more()", -- row 4
      "  end", -- row 5
      "end", -- row 6
      "", -- row 7
    }, "\n")
    local repo = git_fixture.repo({
      commits = { { files = { ["sample.lua"] = content } }, message = "init" },
    })
    local canonical = vim.uv.fs_realpath(repo) or repo
    vim.fn.chdir(canonical)
    vim.cmd("edit " .. canonical .. "/sample.lua")
    local buf = vim.api.nvim_get_current_buf()
    wait.wait_for(function()
      return vim.treesitter.highlighter.active[buf] ~= nil
    end, 5000, "treesitter highlighter never attached")
    return buf
  end

  it("collects the function and the nested if as foldable blocks", function()
    local buf = open_sample()
    local blocks = bg.collect_foldable_blocks(buf)

    -- Find a block by its start row.
    local by_start = {}
    for _, b in ipairs(blocks) do
      by_start[b.s] = b
    end

    assert.is_not_nil(by_start[0], "expected a foldable block starting at row 0 (function)")
    assert.are.equal(6, by_start[0].e)
    assert.are.equal(0, by_start[0].col)

    assert.is_not_nil(by_start[2], "expected a foldable block starting at row 2 (if)")
    assert.are.equal(2, by_start[2].col)
  end)

  it("renders active + chain guides for the cursor's row", function()
    local buf = open_sample()
    local blocks = bg.blocks_for(buf)
    local chain = bg.chain_at(blocks, 3) -- cursor on row 3 (inside the if)

    -- Row 3 body is indented 4; both the function (col 0) and if (col 2) cover
    -- it. The if is innermost → active; the function is a parent → chain.
    local guides = bg.guides_for_row(blocks, chain, buf, 3)
    assert.are.same({
      { col = 0, tier = "chain" },
      { col = 2, tier = "active" },
    }, guides)
  end)

  it("draws guides through a blank line inside a block", function()
    local buf = open_sample()
    -- Append a blank line inside the if body, then a closing line.
    vim.api.nvim_buf_set_lines(buf, 4, 4, false, { "" }) -- new blank row 4
    local blocks = bg.blocks_for(buf)
    local chain = bg.chain_at(blocks, 3)
    local guides = bg.guides_for_row(blocks, chain, buf, 4) -- the blank row
    assert.is_true(#guides >= 1, "expected guides to draw through the blank line")
  end)
end)
