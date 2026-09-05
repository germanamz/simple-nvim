local nvim_env = require("tests.helpers.nvim_env")
local keymap_probe = require("tests.helpers.keymap_probe")

-- Wiring plus the one behavior that cannot be pinned in a unit spec: a comment's
-- range following a real edit in a real buffer. Nothing here reaches cmux --
-- flush is never pressed, only the queue is exercised.
describe("e2e: review comments", function()
  local root, rc

  before_each(function()
    root = nvim_env.setup_isolated_env()
    rc = require("config.review_comments")
    rc.clear()
  end)

  after_each(function()
    rc.clear()
    nvim_env.teardown(root)
  end)

  local function leader_lhs(spec)
    local leader = vim.g.mapleader or "\\"
    return (spec:gsub("<leader>", leader))
  end

  it("binds all five keys with a desc", function()
    for _, lhs in ipairs({ "<leader>ac", "<leader>al", "<leader>as", "<leader>aS", "<leader>ax" }) do
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

  -- Buffers are built through the API rather than :edit: editing a .lua file
  -- after the first isolated env errors on a stale cached lsp.log path.
  local function lua_buf(name, lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, root .. "/" .. name)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
  end

  it("keeps a comment pointing at its code after an edit above it", function()
    local buf = lua_buf("a.lua", { "one", "two", "three", "four" })
    rc.push(buf, 3, nil, "still three")
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "inserted" })
    assert.are.equal(4, rc.resolve()[1].first)
    assert.is_truthy(rc.payload():find("#L4", 1, true))
  end)

  it("falls back to the snapshot once the buffer is unloaded", function()
    local buf = lua_buf("b.lua", { "one", "two", "three" })
    rc.push(buf, 2, nil, "snapshot me")
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.are.equal(2, rc.resolve()[1].first)
  end)
end)
