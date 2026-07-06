local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")

-- Native vim.snippet sessions (blink.cmp expands LSP/friendly-snippets items
-- through vim.snippet.expand and never calls vim.snippet.stop) end on their own
-- only from insert/select mode: the runtime's CursorMoved guard early-returns
-- in normal mode. Without help, <Esc> after accepting a placeholder completion
-- leaves the session alive and its SnippetTabstop extmark — Visual-linked by
-- default — keeps the inserted text painted like a stuck visual selection.
-- options.lua installs a ModeChanged *:n autocmd that stops the session once
-- the editor settles in normal mode; these tests drive the real mode
-- transitions headlessly. (Headless caveat: interactive insert-mode entry via
-- feedkeys kills the busted child, so the snippets are expanded from normal
-- mode — expand's own select_tabstop keys still produce the same select-mode
-- session a menu accept does.)
describe("e2e: snippet session teardown", function()
  local root

  local function flush(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  end

  local function snippet_marks(buf)
    local ns = vim.api.nvim_get_namespaces()["nvim.snippet"]
    if not ns then
      return {}
    end
    return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
  end

  before_each(function()
    root = nvim_env.setup_isolated_env()
    vim.cmd("enew")
  end)

  after_each(function()
    if vim.snippet.active() then
      vim.snippet.stop()
    end
    vim.cmd("silent! %bwipeout!")
    nvim_env.teardown(root)
  end)

  it("ends the session and its tabstop highlight on return to normal mode", function()
    local buf = vim.api.nvim_get_current_buf()

    vim.snippet.expand("Token(${1:r}),")
    flush("") -- drain select_tabstop's queued keys: lands in select mode on ${1}
    assert.are.equal("s", vim.api.nvim_get_mode().mode)
    assert.is_true(vim.snippet.active(), "snippet session did not start")

    flush("<Esc>")
    assert.are.equal("n", vim.api.nvim_get_mode().mode)

    wait.wait_for(function()
      return not vim.snippet.active()
    end, 1500, "snippet session survived returning to normal mode")
    assert.are.same({}, snippet_marks(buf), "SnippetTabstop extmarks left behind")
  end)

  it("keeps the session alive across tabstop jumps", function()
    -- Jumps between real placeholders pass through normal mode transiently
    -- (select_tabstop feedkeys "<Esc>…v…<C-g>"), so a naive stop-on-normal
    -- would kill the session mid-jump. The settle check must let jumps through.
    vim.snippet.expand("pair(${1:first}, ${2:second})")
    flush("")
    assert.is_true(vim.snippet.active(), "snippet session did not start")

    vim.snippet.jump(1)
    flush("")
    assert.are.equal("s", vim.api.nvim_get_mode().mode)
    -- Give any (wrongly) scheduled teardown a chance to run before asserting.
    vim.wait(300)
    assert.is_true(vim.snippet.active(), "tabstop jump killed the snippet session")

    flush("<Esc>")
    wait.wait_for(function()
      return not vim.snippet.active()
    end, 1500, "snippet session survived returning to normal mode after a jump")
  end)

  it("jumps to the next tabstop with <Tab> via blink's select-mode keymap", function()
    -- Guards the user-visible behavior: Tab pressed on a selected placeholder
    -- jumps to the next one instead of typing over it. Two layers can provide
    -- it — the chain's own snippet_forward (blink maps any chain containing a
    -- snippet command or function in select mode too), or core's default
    -- snippet-jump Tab mapping reached through the chain's "fallback" — so
    -- this pins the outcome, not the layer. blink only applies its
    -- buffer-local maps on InsertEnter, which headless runs can't trigger;
    -- apply them directly the way that autocmd would.
    require("lazy").load({ plugins = { "blink.cmp" } })
    local mappings =
      require("blink.cmp.keymap").get_mappings(require("blink.cmp.config").keymap, "default")
    require("blink.cmp.keymap.apply").keymap_to_current_buffer(mappings)

    vim.snippet.expand("pair(${1:first}, ${2:second})")
    flush("")
    assert.are.equal("s", vim.api.nvim_get_mode().mode)

    flush("<Tab>")
    -- blink's snippet_forward defers the jump with vim.schedule, and the
    -- options.lua settle-check is queued around it — pump the loop until the
    -- jump lands (also proving the settle-check didn't kill the session while
    -- the jump was still in flight). The busted child has no interactive main
    -- loop consuming typeahead, so the predicate drains the jump's feedkeys
    -- itself, like the real input loop would between deferred events.
    wait.wait_for(function()
      flush("")
      if vim.api.nvim_get_mode().mode ~= "s" then
        return false
      end
      local sel = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = "v" })
      return #sel == 1 and sel[1] == "second"
    end, 1500, "Tab's deferred jump never landed on the second placeholder")
    assert.is_true(vim.snippet.active(), "Tab killed the snippet session")
  end)
end)
