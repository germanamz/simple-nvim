local nvim_env = require("tests.helpers.nvim_env")
local keymap_probe = require("tests.helpers.keymap_probe")

-- Sampled in the file's own chunk, before any example runs and before anything
-- here requires the module. Every example below loads it, so an assertion made
-- inside one could only ever observe what its neighbours already did; this
-- records what the real boot in tests/full_init.lua left behind. Plenary runs
-- each spec file in its own nvim, so nothing outside this file can dirty it.
local loaded_at_boot = {
  comments = package.loaded["config.review_comments"],
  sinks = package.loaded["config.review_sinks"],
}

-- Wiring plus the one behavior that cannot be pinned in a unit spec: a comment's
-- range following a real edit in a real buffer. Nothing here reaches cmux --
-- flush is never pressed, only the queue is exercised.
describe("e2e: review comments", function()
  local root

  -- The module is required per-example rather than in before_each, so the
  -- laziness example above stays honest.
  local function clear_queue()
    local rc = package.loaded["config.review_comments"]
    if rc then
      rc.clear()
    end
  end

  before_each(function()
    root = nvim_env.setup_isolated_env()
    clear_queue()
  end)

  after_each(function()
    clear_queue()
    nvim_env.teardown(root)
  end)

  local function leader_lhs(spec)
    local leader = vim.g.mapleader or "\\"
    return (spec:gsub("<leader>", leader))
  end

  local keys = { "<leader>ac", "<leader>al", "<leader>as", "<leader>aS", "<leader>ax" }

  it("binds all five keys with a desc", function()
    for _, lhs in ipairs(keys) do
      local resolved = leader_lhs(lhs)
      local found
      for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
        if m.lhs == resolved then
          found = m
        end
      end
      assert.is_truthy(found, lhs .. " is not mapped")
      assert.is_truthy(found.desc and found.desc ~= "", lhs .. " has no desc")
    end
  end)

  it("binds the comment key in visual mode too", function()
    assert.is_truthy(keymap_probe.resolve("x", leader_lhs("<leader>ac")))
  end)

  -- options.lua promises "nothing loads, and no cmux probe runs, until a key is
  -- pressed". Only a callback behind each key can keep that promise, so this
  -- asserts both halves: the keys answer, and the modules they would require --
  -- review_comments, and the review_sinks that pulls in util.cmux -- are still
  -- absent from package.loaded. Hoisting either require to the top of
  -- options.lua turns this red.
  it("registers every key without loading the module", function()
    assert.is_nil(loaded_at_boot.comments, "config.review_comments was loaded at boot")
    assert.is_nil(loaded_at_boot.sinks, "config.review_sinks was loaded at boot")
    for _, lhs in ipairs(keys) do
      local map = keymap_probe.resolve("n", leader_lhs(lhs))
      assert.is_truthy(map and map.callback, lhs .. " has no callback to require through")
    end
  end)

  -- Buffers are built through the API rather than :edit: editing a .lua file
  -- after the first isolated env errors on a stale cached lsp.log path.
  local function lua_buf(name, lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, root .. "/" .. name)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  it("keeps a comment pointing at its code after an edit above it", function()
    local rc = require("config.review_comments")
    local buf = lua_buf("a.lua", { "one", "two", "three", "four" })
    rc.push(buf, 3, nil, "still three")
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "inserted" })
    assert.are.equal(4, rc.resolve()[1].first)
    assert.is_truthy(rc.payload():find("#L4", 1, true))
  end)

  it("falls back to the snapshot once the buffer is unloaded", function()
    local rc = require("config.review_comments")
    local buf = lua_buf("b.lua", { "one", "two", "three" })
    rc.push(buf, 2, nil, "snapshot me")
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.are.equal(2, rc.resolve()[1].first)
  end)
end)
