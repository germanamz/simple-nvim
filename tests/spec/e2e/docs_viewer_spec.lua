-- The two-pane docs viewer against a real `go doc -all`, because the parts that
-- broke in development are the ones no fixture reaches: whether the panes
-- actually appear, whether the content window scrolls where the outline says,
-- and whether `gd` lands on the right line of the right file in GOROOT.
--
-- net/http is the fixture on purpose. It is in every Go install, it has the
-- shapes that stress the parser (a hundred constants in one block, methods on
-- forty types, two `Get`s), and its declaration lines are stable enough to
-- assert on by symbol rather than by line number.
--
-- Headless caveats this spec is written around, all of them load-bearing:
--   * CursorMoved never fires in a script context — the input queue is not
--     drained — so the outline's follow is driven through viewer.follow()
--     rather than by moving the cursor and waiting.
--   * vim.ui.input cannot be answered, so the filter is exercised through
--     apply_filter() rather than the `f` mapping that prompts.
--   * `vim.o.columns` is 80 here, which would put the panes in a tab; it is set
--     wide so the split path — the one a real terminal takes — is what runs.

local viewer = require("config.docs.viewer")

---@param pred fun(): boolean
---@return boolean
local function wait_for(pred)
  return vim.wait(20000, pred, 25)
end

--- Index of the outline row whose entry carries `symbol`.
---@param s table
---@param symbol string
---@return integer|nil
local function row_of(s, symbol)
  for row, idx in ipairs(s.rows) do
    if s.entries[idx] and s.entries[idx].symbol == symbol then
      return row
    end
  end
end

describe("e2e: docs viewer", function()
  local ctx = { bufnr = 0, word = "", line = "", col = 0 }
  local columns

  before_each(function()
    columns = vim.o.columns
    vim.o.columns = 200
  end)

  after_each(function()
    viewer.close()
    vim.o.columns = columns
  end)

  ---@return table|nil
  local function open_net_http()
    local go = require("config.docs.adapters.go")
    local failed = false
    viewer.open(go, { pkg = "net/http", stdlib = true }, ctx, {
      on_fail = function()
        failed = true
      end,
    })
    wait_for(function()
      local s = viewer._session()
      return failed or (s ~= nil and #(s.entries or {}) > 0)
    end)
    if failed then
      return nil
    end
    return viewer._session()
  end

  it("opens two panes holding the whole package", function()
    if vim.fn.executable("go") == 0 then
      return pending("no go toolchain on PATH")
    end
    local s = open_net_http()
    if not s then
      return pending("`go doc -all net/http` produced nothing")
    end

    assert.is_true(vim.api.nvim_win_is_valid(s.outline_win))
    assert.is_true(vim.api.nvim_win_is_valid(s.content_win))
    assert.are_not.equals(s.outline_win, s.content_win)

    -- The float this replaced showed the index only. -all is the whole package,
    -- which for net/http is thousands of lines.
    assert.is_true(vim.api.nvim_buf_line_count(s.content_buf) > 1000)
    assert.equals("net/http", vim.wo[s.content_win].winbar)

    -- Neither pane may be editable or listed: they are scratch views, and a
    -- listed buffer would show up in the buffer picker.
    assert.is_false(vim.bo[s.content_buf].modifiable)
    assert.is_false(vim.bo[s.content_buf].buflisted)
    assert.is_false(vim.bo[s.outline_buf].buflisted)
  end)

  -- The whole point of the redesign: a type's own documentation, which the
  -- index-only float could never reach.
  it("puts a type's full documentation in the buffer", function()
    if vim.fn.executable("go") == 0 then
      return pending("no go toolchain on PATH")
    end
    local s = open_net_http()
    if not s then
      return pending("`go doc -all net/http` produced nothing")
    end

    local row = row_of(s, "Client")
    assert.is_truthy(row, "net/http should expose a Client type in its outline")
    vim.api.nvim_win_set_cursor(s.outline_win, { row, 0 })
    viewer.follow()

    local at = vim.api.nvim_win_get_cursor(s.content_win)[1]
    local lines = vim.api.nvim_buf_get_lines(s.content_buf, at - 1, at + 40, false)
    assert.equals("type Client struct {", lines[1])
    -- The struct body and its field comments, not just the signature.
    local body = table.concat(lines, "\n")
    assert.is_truthy(body:match("Transport%s+RoundTripper"))
  end)

  it("scrolls to a method without re-running the page command", function()
    if vim.fn.executable("go") == 0 then
      return pending("no go toolchain on PATH")
    end
    local s = open_net_http()
    if not s then
      return pending("`go doc -all net/http` produced nothing")
    end

    local before = vim.api.nvim_buf_line_count(s.content_buf)
    local row = row_of(s, "Client.Do")
    assert.is_truthy(row, "Client.Do should be in the outline")
    vim.api.nvim_win_set_cursor(s.outline_win, { row, 0 })
    viewer.follow()

    local at = vim.api.nvim_win_get_cursor(s.content_win)[1]
    local line = vim.api.nvim_buf_get_lines(s.content_buf, at - 1, at, false)[1]
    assert.is_truthy(line:match("^func %(c %*Client%) Do%("))
    -- Same buffer, same content: this was a scroll, not another `go doc`.
    assert.equals(before, vim.api.nvim_buf_line_count(s.content_buf))
  end)

  it("filters the outline to fuzzy matches and back", function()
    if vim.fn.executable("go") == 0 then
      return pending("no go toolchain on PATH")
    end
    local s = open_net_http()
    if not s then
      return pending("`go doc -all net/http` produced nothing")
    end

    local full = #s.rows
    viewer.apply_filter("clientdo")
    assert.is_true(#s.rows < full)
    assert.is_true(#s.rows > 0)
    local first = vim.api.nvim_buf_get_lines(s.outline_buf, 0, 1, false)[1]
    assert.is_truthy(first:match("Client%.Do"))

    viewer.apply_filter("")
    assert.equals(full, #s.rows)
  end)

  -- Following a name that lives on this page must not spend a subprocess or
  -- touch the history stack — it is a scroll.
  it("follows a same-page name by scrolling, without pushing history", function()
    if vim.fn.executable("go") == 0 then
      return pending("no go toolchain on PATH")
    end
    local s = open_net_http()
    if not s then
      return pending("`go doc -all net/http` produced nothing")
    end

    local lines = vim.api.nvim_buf_get_lines(s.content_buf, 0, -1, false)
    local at = nil
    for i, l in ipairs(lines) do
      if l:match("^\tTransport RoundTripper") then
        at = i
        break
      end
    end
    assert.is_truthy(at, "net/http's Client should declare a Transport field")

    vim.api.nvim_set_current_win(s.content_win)
    vim.api.nvim_win_set_cursor(s.content_win, { at, 12 })
    viewer.follow_name()

    local landed = vim.api.nvim_win_get_cursor(s.content_win)[1]
    assert.equals("type RoundTripper interface {", lines[landed])
    assert.equals(0, #s.history)
  end)

  it("goes to the real source and closes the reader behind it", function()
    if vim.fn.executable("go") == 0 then
      return pending("no go toolchain on PATH")
    end
    local s = open_net_http()
    if not s then
      return pending("`go doc -all net/http` produced nothing")
    end

    local idx = nil
    for i, e in ipairs(s.entries) do
      if e.symbol == "Client.Do" then
        idx = i
        break
      end
    end
    assert.is_truthy(idx)
    local lnum = s.entries[idx].lnum
    local line = vim.api.nvim_buf_get_lines(s.content_buf, lnum - 1, lnum, false)[1]

    vim.api.nvim_set_current_win(s.content_win)
    vim.api.nvim_win_set_cursor(s.content_win, { lnum, line:find("Do%(") - 1 })
    local origin = s.origin_win
    viewer.goto_source()

    local landed = wait_for(function()
      if not vim.api.nvim_win_is_valid(origin) then
        return false
      end
      local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(origin))
      return name:match("net/http/client%.go$") ~= nil
    end)
    assert.is_true(landed, "gd should open net/http/client.go in the origin window")

    -- On the declaration itself, not merely somewhere in the file.
    local buf = vim.api.nvim_win_get_buf(origin)
    local row = vim.api.nvim_win_get_cursor(origin)[1]
    local src = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
    assert.is_truthy(src:match("^func %(c %*Client%) Do%("))

    -- The reader closes behind the jump. Leaving it open stranded two windows
    -- that only `q` from inside them could dismiss, so reaching the source
    -- meant <C-w>-ing back into a pane just to close it.
    assert.is_false(vim.api.nvim_win_is_valid(s.outline_win))
    assert.is_false(vim.api.nvim_win_is_valid(s.content_win))
    assert.is_nil(viewer._session())
    -- And the cursor is left in the source, not in a window that is gone.
    assert.equals(origin, vim.api.nvim_get_current_win())
  end)

  -- A lookup that finds nothing must not cost you the page you were reading.
  it("keeps the reader open when there is no source to jump to", function()
    if vim.fn.executable("go") == 0 then
      return pending("no go toolchain on PATH")
    end
    local s = open_net_http()
    if not s then
      return pending("`go doc -all net/http` produced nothing")
    end

    -- A line of prose: no symbol, so locate() has nothing to resolve.
    local lines = vim.api.nvim_buf_get_lines(s.content_buf, 0, -1, false)
    local at = nil
    for i, l in ipairs(lines) do
      if l:match("^    [A-Z][a-z]+ [a-z]+ ") then
        at = i
        break
      end
    end
    assert.is_truthy(at, "net/http's page should contain indented prose")

    vim.api.nvim_set_current_win(s.content_win)
    vim.api.nvim_win_set_cursor(s.content_win, { at, 6 })
    viewer.goto_source()

    -- Give a real locate() the chance to answer before asserting nothing moved.
    vim.wait(3000, function()
      return viewer._session() == nil
    end)
    assert.is_truthy(viewer._session(), "a failed gd must leave the reader up")
    assert.is_true(vim.api.nvim_win_is_valid(s.content_win))
  end)

  it("crosses to another package and comes back through history", function()
    if vim.fn.executable("go") == 0 then
      return pending("no go toolchain on PATH")
    end
    local s = open_net_http()
    if not s then
      return pending("`go doc -all net/http` produced nothing")
    end

    local lines = vim.api.nvim_buf_get_lines(s.content_buf, 0, -1, false)
    local at, col = nil, nil
    for i, l in ipairs(lines) do
      local found = l:find("url%.Values")
      if found then
        at, col = i, found
        break
      end
    end
    if not at then
      return pending("this net/http build never mentions url.Values")
    end

    vim.api.nvim_set_current_win(s.content_win)
    vim.api.nvim_win_set_cursor(s.content_win, { at, col })
    viewer.follow_name()

    local crossed = wait_for(function()
      local q = viewer._session()
      return q ~= nil and q.coord ~= nil and q.coord.pkg == "net/url"
    end)
    assert.is_true(crossed, "url.Values should resolve through net/http's imports")
    assert.equals(1, #viewer._session().history)

    viewer.history(-1)
    local back = wait_for(function()
      local q = viewer._session()
      return q ~= nil and q.coord ~= nil and q.coord.pkg == "net/http"
    end)
    assert.is_true(back, "history should return to net/http")
    assert.equals(1, #viewer._session().future)
  end)

  -- The panel is generated from the same table attach_keys binds, so the check
  -- worth making is that the table and the live buffers agree in BOTH
  -- directions: nothing promised is unbound, nothing bound is undocumented.
  it("binds exactly the keys the panel advertises", function()
    if vim.fn.executable("go") == 0 then
      return pending("no go toolchain on PATH")
    end
    local s = open_net_http()
    if not s then
      return pending("`go doc -all net/http` produced nothing")
    end

    ---@param buf integer
    ---@return table<string, string>
    local function keymap_of(buf)
      local out = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        -- Neovim normalises <C-t> to <C-T> on the way back out.
        out[m.lhs:gsub("<C%-(%a)>", function(c)
          return "<C-" .. c:lower() .. ">"
        end)] = m.desc
          or ""
      end
      return out
    end

    local live = { outline = keymap_of(s.outline_buf), content = keymap_of(s.content_buf) }
    local declared = { outline = {}, content = {} }

    for _, group in ipairs(viewer.KEYS) do
      for _, key in ipairs(group.keys) do
        if key.fn then
          local panes = group.pane == "both" and { "outline", "content" } or { group.pane }
          for _, pane in ipairs(panes) do
            for _, lhs in ipairs(key.lhs or { key.keys }) do
              declared[pane][lhs] = true
              assert.is_truthy(
                live[pane][lhs],
                ("%s is in the panel but not bound in the %s pane"):format(lhs, pane)
              )
            end
          end
        end
      end
    end

    for pane, maps in pairs(live) do
      for lhs, desc in pairs(maps) do
        assert.is_truthy(
          declared[pane][lhs],
          ("%s is bound in the %s pane (%s) but absent from the panel"):format(lhs, pane, desc)
        )
      end
    end
  end)

  it("opens and dismisses the key panel", function()
    if vim.fn.executable("go") == 0 then
      return pending("no go toolchain on PATH")
    end
    local s = open_net_http()
    if not s then
      return pending("`go doc -all net/http` produced nothing")
    end

    vim.api.nvim_set_current_win(s.content_win)
    viewer.toggle_help()

    local panel = vim.api.nvim_get_current_win()
    assert.are_not.equals(s.content_win, panel)
    -- A real float, so it can sit over both panes and the code window.
    assert.equals("editor", vim.api.nvim_win_get_config(panel).relative)
    local text =
      table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(panel), 0, -1, false), "\n")
    assert.is_truthy(text:find("gd", 1, true))
    -- Opened from the content pane, so that is the section marked.
    assert.is_truthy(text:find("▸ Content pane", 1, true))

    -- Toggling returns the cursor where it came from rather than leaving it in
    -- a window that no longer exists.
    viewer.toggle_help()
    assert.is_false(vim.api.nvim_win_is_valid(panel))
    assert.equals(s.content_win, vim.api.nvim_get_current_win())
  end)

  it("closes both panes together", function()
    if vim.fn.executable("go") == 0 then
      return pending("no go toolchain on PATH")
    end
    local s = open_net_http()
    if not s then
      return pending("`go doc -all net/http` produced nothing")
    end

    local outline, content = s.outline_win, s.content_win
    viewer.close()
    assert.is_false(vim.api.nvim_win_is_valid(outline))
    assert.is_false(vim.api.nvim_win_is_valid(content))
    assert.is_nil(viewer._session())
  end)
end)
