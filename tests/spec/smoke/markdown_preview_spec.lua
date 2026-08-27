local nvim_env = require("tests.helpers.nvim_env")

-- Wiring only. `<leader>mp` hands the file to a cmux markdown panel, so there is
-- no preview window, no split and no renderer of ours left to assert against —
-- and nothing here may reach the cmux socket, which is the developer's live
-- terminal. So this file stops at "the keymap is on the buffer it belongs on,
-- with the right desc, and the presses that reach no cmux call do not blow up".
-- The state machine — open / move / focus / close, and every failure branch — is
-- driven through the `M._run` seam in tests/spec/unit/markdown_preview_spec.lua.
describe("smoke: markdown preview (cmux panel)", function()
  local root

  before_each(function()
    root = nvim_env.setup_isolated_env()
  end)

  after_each(function()
    nvim_env.teardown(root)
  end)

  --- `spec` with `<leader>` resolved to the configured leader, which is the form
  --- a mapping is stored under once it has been set.
  local function leader_lhs(spec)
    local leader = vim.g.mapleader or "\\"
    return (spec:gsub("<leader>", leader))
  end

  --- The current buffer's own normal-mode mapping for `lhs`, or nil. Buffer-local
  --- on purpose: `<leader>mp` exists only where the preview makes sense, and
  --- nvim_buf_get_keymap never reports a global map, so a leak into every buffer
  --- would fail these lookups rather than pass them.
  local function buf_map(lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
      if m.lhs == lhs then
        return m
      end
    end
    return nil
  end

  --- A markdown buffer in the current window, so config.options' markdown
  --- FileType autocmd — the single entry point that installs the keymap — fires.
  --- Unnamed on purpose: pressing the map on it stops at "no file on disk",
  --- which is the one press a spec can safely make.
  local function markdown_buf()
    vim.cmd("enew")
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].filetype = "markdown"
    return buf
  end

  --- Run `fn` with vim.notify captured, returning the notifications it made.
  local function with_notify(fn)
    local notified = {}
    local real_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notified, { msg = msg, level = level })
    end
    local ok, err = pcall(fn)
    vim.notify = real_notify
    assert.is_true(ok, "errored: " .. tostring(err))
    return notified
  end

  it("requires config.markdown_preview cleanly", function()
    package.loaded["config.markdown_preview"] = nil
    local ok, err = pcall(require, "config.markdown_preview")
    assert.is_true(ok, "failed to require: " .. tostring(err))
  end)

  it("requires config.open_url cleanly, sharing the same cmux detector", function()
    -- The "is this a cmux session" rule moved out of open_url into util.cmux
    -- when the preview grew a second use for it. Both consumers still have to
    -- load, and the detector has to still be there for them to call.
    package.loaded["config.open_url"] = nil
    local ok, err = pcall(require, "config.open_url")
    assert.is_true(ok, "failed to require: " .. tostring(err))
    assert.is_function(require("util.cmux").bin)
  end)

  it("registers the <leader>m markdown group in which-key", function()
    local spec = require("plugins.which-key")[1].opts.spec
    local found
    for _, entry in ipairs(spec) do
      if entry[1] == "<leader>m" then
        found = entry
      end
    end
    assert.is_not_nil(found, "no <leader>m group entry in which-key spec")
    assert.are.equal("markdown", found.group)
  end)

  it("maps buffer-local <leader>mp with a desc in markdown buffers", function()
    local buf = markdown_buf()
    local m = buf_map(leader_lhs("<leader>mp"))
    assert.is_not_nil(m, "<leader>mp not mapped in a markdown buffer")
    assert.are.equal("Toggle markdown preview", m.desc)
    assert.is_function(m.callback)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("presses <leader>mp on an unnamed buffer without erroring", function()
    local buf = markdown_buf()
    local mp = require("config.markdown_preview")
    local m = buf_map(leader_lhs("<leader>mp"))
    assert.is_not_nil(m, "<leader>mp not mapped in a markdown buffer")

    -- A buffer with no file has nothing for cmux to render, and this guard is
    -- what keeps the smoke lane off the socket: were it to regress, the seam
    -- below turns a panel opening in the developer's terminal into a failure.
    mp._run = function(args)
      error("cmux was invoked from a spec: " .. table.concat(args, " "))
    end
    local notified = with_notify(m.callback)
    mp._run = nil

    assert.are.equal(1, #notified)
    assert.is_truthy(
      notified[1].msg:find("nothing to preview", 1, true),
      "unexpected notification: " .. tostring(notified[1].msg)
    )
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("maps <leader>mp on an nvim-tree buffer, and says so when there is no node", function()
    -- The tree's copy previews the node under the cursor without opening it in a
    -- buffer first, so it is a second, independent install of the same keymap
    -- (nvim-tree's on_attach calls set_tree_keymap). With no tree on screen
    -- there is no node, which is the branch a spec can press.
    local mp = require("config.markdown_preview")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    mp.set_tree_keymap(buf)

    local m = buf_map(leader_lhs("<leader>mp"))
    assert.is_not_nil(m, "<leader>mp not mapped on the tree buffer")
    assert.are.equal("Toggle markdown preview", m.desc)

    -- Load nvim-tree here rather than inside the capture below. The keymap
    -- requires nvim-tree.api on press, and under lazy.nvim that first require is
    -- what loads the plugin and runs its setup, so anything setup chose to
    -- notify would otherwise be counted against the keymap's own one message.
    pcall(require, "nvim-tree.api")

    mp._run = function(args)
      error("cmux was invoked from a spec: " .. table.concat(args, " "))
    end
    local notified = with_notify(m.callback)
    mp._run = nil

    assert.are.equal(1, #notified)
    assert.is_truthy(
      notified[1].msg:find("no file under the cursor", 1, true),
      "unexpected notification: " .. tostring(notified[1].msg)
    )
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("recognizes markdown-family paths by name alone", function()
    -- What the tree keymap judges a node by: there is no buffer to read a
    -- filetype off. `.mdx` only resolves to a filetype once the full config is
    -- loaded, which is why this belongs in the smoke lane and not in unit.
    local ft = require("util.ft")
    assert.is_true(ft.is_markdown_path("/tmp/notes/a.md"))
    assert.is_true(ft.is_markdown_path("/tmp/notes/a.mdx"))
    assert.is_false(ft.is_markdown_path("/tmp/notes/a.lua"))
  end)
end)
