-- Pins config.lsp_picker: the row model behind the LSP client picker
-- (<leader>ll / :LspList), plus its stop and restart actions.
--
-- Neovim never reaps LSP clients, so a session that visits several roots in a
-- superproject accumulates one per root. <leader>lk sweeps every idle client at
-- once and `:lsp stop <name>` kills by server name; this picker is how you see
-- what is running and act on ONE of them. Rows are ordered idle-first because a
-- client with no attached buffers is the kill candidate.
local picker = require("config.lsp_picker")

--- Minimal stand-in for vim.lsp.Client: only the fields the module reads.
local function client(opts)
  local stopped = opts.stopped or false
  return {
    id = opts.id or 1,
    name = opts.name or "ts_ls",
    attached_buffers = opts.bufs or {},
    config = { root_dir = opts.root },
    root_dir = opts.root,
    is_stopped = function()
      return stopped
    end,
    stop = function(self)
      self._stop_calls = (self._stop_calls or 0) + 1
      stopped = true
    end,
  }
end

describe("config.lsp_picker.rows", function()
  it("counts attached buffers and carries name and root", function()
    local rows =
      picker.rows({ client({ name = "gopls", root = "/r", bufs = { [3] = true, [4] = true } }) })
    assert.are.equal(1, #rows)
    assert.are.equal("gopls", rows[1].name)
    assert.are.equal("/r", rows[1].root)
    assert.are.equal(2, rows[1].nbufs)
  end)

  it("orders idle clients first, so kill candidates surface at the top", function()
    local busy = client({ id = 1, name = "aaa_busy", root = "/a", bufs = { [1] = true } })
    local idle = client({ id = 2, name = "zzz_idle", root = "/z" })
    local names = vim.tbl_map(function(r)
      return r.name
    end, picker.rows({ busy, idle }))
    assert.are.same({ "zzz_idle", "aaa_busy" }, names)
  end)

  it("breaks ties by name, then by root", function()
    local a = client({ id = 1, name = "ts_ls", root = "/b" })
    local b = client({ id = 2, name = "ts_ls", root = "/a" })
    local c = client({ id = 3, name = "gopls", root = "/c" })
    local got = vim.tbl_map(function(r)
      return r.name .. r.root
    end, picker.rows({ a, b, c }))
    assert.are.same({ "gopls/c", "ts_ls/a", "ts_ls/b" }, got)
  end)

  it("tolerates a client with no root", function()
    local rows = picker.rows({ client({ root = nil }) })
    assert.is_nil(rows[1].root)
  end)

  it("returns an empty list for no clients", function()
    assert.are.same({}, picker.rows({}))
  end)
end)

describe("config.lsp_picker.format", function()
  it("lays out name, buffer count and root", function()
    local line = picker.format({ name = "ts_ls", nbufs = 2, root = "/tmp/x" })
    assert.is_truthy(line:find("ts_ls", 1, true))
    assert.is_truthy(line:find("2 bufs", 1, true))
    assert.is_truthy(line:find("/tmp/x", 1, true))
  end)

  it("uses the singular for one buffer", function()
    assert.is_truthy(
      picker.format({ name = "gopls", nbufs = 1, root = "/r" }):find("1 buf", 1, true)
    )
    assert.is_nil(picker.format({ name = "gopls", nbufs = 1, root = "/r" }):find("1 bufs", 1, true))
  end)

  it("shortens a root under $HOME to ~", function()
    local line = picker.format({ name = "lua_ls", nbufs = 0, root = vim.env.HOME .. "/projects/x" })
    assert.is_truthy(line:find("~/projects/x", 1, true))
    assert.is_nil(line:find(vim.env.HOME .. "/projects", 1, true))
  end)

  it("says so when a client has no root", function()
    assert.is_truthy(picker.format({ name = "x", nbufs = 0, root = nil }):find("no root", 1, true))
  end)

  it("aligns the columns across rows of differing name length", function()
    local short = picker.format({ name = "x", nbufs = 0, root = "/r" })
    local long = picker.format({ name = "rust_analyzer", nbufs = 0, root = "/r" })
    assert.are.equal(short:find("/r", 1, true), long:find("/r", 1, true))
  end)
end)

describe("config.lsp_picker.kill", function()
  it("stops a live client", function()
    local c = client({})
    assert.is_true(picker.kill(c))
    assert.are.equal(1, c._stop_calls)
  end)

  it("is a no-op on an already-stopped client", function()
    local c = client({ stopped = true })
    assert.is_false(picker.kill(c))
    assert.is_nil(c._stop_calls)
  end)

  it("is a no-op on nil", function()
    assert.is_false(picker.kill(nil))
  end)
end)

describe("config.lsp_picker.restart", function()
  it("stops the client and re-attaches the buffers it had", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local c = client({ bufs = { [buf] = true } })
    local fired = 0
    local group = vim.api.nvim_create_augroup("lsp_picker_spec", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      buffer = buf,
      callback = function()
        fired = fired + 1
      end,
    })

    assert.are.equal(1, picker.restart(c))
    assert.are.equal(1, c._stop_calls)
    assert.are.equal(1, fired)

    vim.api.nvim_del_augroup_by_id(group)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("degrades to a plain stop when the client has no buffers", function()
    local c = client({ bufs = {} })
    assert.are.equal(0, picker.restart(c))
    assert.are.equal(1, c._stop_calls)
  end)

  it("skips buffers that are no longer valid", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local c = client({ bufs = { [buf] = true, [999999] = true } })
    vim.api.nvim_buf_delete(buf, { force = true })
    assert.are.equal(0, picker.restart(c))
  end)

  it("is a no-op on an already-stopped client", function()
    local c = client({ stopped = true, bufs = { [1] = true } })
    assert.is_nil(picker.restart(c))
    assert.is_nil(c._stop_calls)
  end)
end)

-- The workhorse behind both the picker's <CR> and <leader>lr. The keymap case is
-- what forces the set-of-clients shape: a tsx buffer is served by ts_ls, biome
-- and oxlint at once, and every one of them has to come back.
describe("config.lsp_picker.restart_clients", function()
  local group

  local function watch(bufs)
    local fired = {}
    group = vim.api.nvim_create_augroup("lsp_picker_restart_spec", { clear = true })
    for _, b in ipairs(bufs) do
      fired[b] = 0
      vim.api.nvim_create_autocmd("FileType", {
        group = group,
        buffer = b,
        callback = function()
          fired[b] = fired[b] + 1
        end,
      })
    end
    return fired
  end

  after_each(function()
    if group then
      pcall(vim.api.nvim_del_augroup_by_id, group)
      group = nil
    end
  end)

  it("stops every client and re-attaches the union of their buffers", function()
    local b1 = vim.api.nvim_create_buf(false, true)
    local b2 = vim.api.nvim_create_buf(false, true)
    local a = client({ id = 1, name = "ts_ls", bufs = { [b1] = true, [b2] = true } })
    local b = client({ id = 2, name = "biome", bufs = { [b1] = true } })
    local fired = watch({ b1, b2 })

    local stopped, reattached = picker.restart_clients({ a, b })

    assert.are.equal(2, stopped)
    assert.are.equal(2, reattached)
    assert.are.equal(1, a._stop_calls)
    assert.are.equal(1, b._stop_calls)
    -- b1 is served by both clients; re-firing FileType twice would run every
    -- other FileType handler (treesitter, statusline) a second time for nothing.
    assert.are.equal(1, fired[b1])
    assert.are.equal(1, fired[b2])

    vim.api.nvim_buf_delete(b1, { force = true })
    vim.api.nvim_buf_delete(b2, { force = true })
  end)

  -- The regression guard for "even <leader>lr doesn't clear them". didOpen
  -- serializes buffer LINES, never the file on disk, so restarting a server over
  -- a buffer that never re-read gives it byte-identical text and it republishes
  -- byte-identical diagnostics. bufadd+bufload is the exact shape that made this
  -- survive: loaded, never displayed — the case a bare `:checktime` skips.
  it("re-reads a hidden buffer from disk before the servers come back", function()
    local path = vim.fn.tempname() .. "-restart.txt"
    local function write(content)
      local f = assert(io.open(path, "w"))
      f:write(content)
      f:close()
    end
    local function lines(buf)
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "|")
    end

    write("before\n")
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    assert.are.equal("before", lines(buf))
    write("after\n")

    local at_reattach = {}
    group = vim.api.nvim_create_augroup("lsp_picker_restart_spec", { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      buffer = buf,
      callback = function()
        at_reattach[#at_reattach + 1] = lines(buf)
      end,
    })

    picker.restart_clients({ client({ id = 1, bufs = { [buf] = true } }) })

    assert.are.equal("after", lines(buf), "restart left the buffer holding stale text")
    -- Ordering is the whole point: a reload that lands after the re-attach is
    -- too late, because didOpen has already gone out with the old contents.
    assert.are.equal("after", at_reattach[1], "re-attached before re-reading the file")

    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(path)
  end)

  it("ignores clients that are already stopped", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local live = client({ id = 1, bufs = { [buf] = true } })
    local dead = client({ id = 2, stopped = true, bufs = { [buf] = true } })

    local stopped, reattached = picker.restart_clients({ live, dead })

    assert.are.equal(1, stopped)
    assert.are.equal(1, reattached)
    assert.is_nil(dead._stop_calls)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("skips buffers that are no longer valid", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local c = client({ bufs = { [buf] = true, [999999] = true } })
    vim.api.nvim_buf_delete(buf, { force = true })

    local stopped, reattached = picker.restart_clients({ c })

    assert.are.equal(1, stopped)
    assert.are.equal(0, reattached)
  end)

  it("returns zero counts for an empty list", function()
    local stopped, reattached = picker.restart_clients({})
    assert.are.equal(0, stopped)
    assert.are.equal(0, reattached)
  end)
end)

-- restart_all is the full-reload hatch (<leader>lR / :LspRestartAll). It differs
-- from restart_clients in the two places that matter when the LSP is wedged:
-- it stops EVERY live client rather than the current buffer's, and it takes its
-- re-attach set from the open file buffers rather than from `attached_buffers`
-- -- so it reaches a buffer whose server died, which nothing else here can.
describe("config.lsp_picker.restart_all", function()
  local tmpdir, group

  local function write_file(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
  end

  local function lines(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "|")
  end

  --- A loaded, named, hidden file buffer with a filetype: the shape a restart
  --- has to re-attach. Hidden because the stale ones never are displayed.
  local function file_buf(name, content)
    local path = tmpdir .. "/" .. name
    write_file(path, content or "")
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.bo[buf].filetype = "lua"
    return buf, path
  end

  --- Record FileType fires for `bufs` only, in order. Scoped per buffer so the
  --- assertions ignore whatever else the harness happens to have open.
  local function record_filetype(bufs)
    local fired = {}
    for _, b in ipairs(bufs) do
      vim.api.nvim_create_autocmd("FileType", {
        group = group,
        buffer = b,
        callback = function(args)
          fired[#fired + 1] = args.buf
        end,
      })
    end
    return fired
  end

  before_each(function()
    tmpdir = vim.fn.tempname() .. "-lsp-picker"
    vim.fn.mkdir(tmpdir, "p")
    group = vim.api.nvim_create_augroup("lsp_picker_restart_all_spec", { clear = true })
  end)

  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_id, group)
    -- Wipe this block's buffers before their files go: a later restart_all would
    -- otherwise sweep them, find the path missing and report a deletion.
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf):find(tmpdir, 1, true) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    vim.fn.delete(tmpdir, "rf")
  end)

  it("re-attaches a buffer no client had claimed", function()
    local served = file_buf("served.lua")
    local orphan = file_buf("orphan.lua")
    local fired = record_filetype({ served, orphan })

    picker.restart_all({ client({ bufs = { [served] = true } }) })

    assert.is_true(
      vim.tbl_contains(fired, orphan),
      "a buffer with no client is exactly what restart_clients cannot reach"
    )
  end)

  it("stops a client that never served the buffer you are standing in", function()
    local here = file_buf("here.lua")
    local there = file_buf("there.lua")
    local elsewhere = client({ id = 2, root = "/other", bufs = { [there] = true } })

    local stopped = picker.restart_all({ elsewhere }, { last_buf = here })

    assert.are.equal(1, stopped)
    assert.are.equal(1, elsewhere._stop_calls)
  end)

  it("resolves last_buf last, so the package you are in wins", function()
    local a = file_buf("a.lua")
    local b = file_buf("b.lua")
    local fired = record_filetype({ a, b })

    picker.restart_all({}, { last_buf = a })

    assert.are.equal(a, fired[#fired])
  end)

  it("skips buffers with no file behind them", function()
    local scratch = vim.api.nvim_create_buf(false, true)
    local fired = record_filetype({ scratch })

    picker.restart_all({})

    assert.are.equal(0, #fired, "re-attached a scratch buffer")
    vim.api.nvim_buf_delete(scratch, { force = true })
  end)

  it("skips a buffer with no filetype for a server to match", function()
    local buf = file_buf("plain.lua")
    vim.bo[buf].filetype = ""
    local fired = record_filetype({ buf })

    picker.restart_all({})

    assert.are.equal(0, #fired)
  end)

  it("re-reads a file that changed on disk before re-attaching", function()
    local buf, path = file_buf("changed.lua", "before\n")
    write_file(path, "after\n")
    local at_reattach
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      buffer = buf,
      callback = function()
        at_reattach = lines(buf)
      end,
    })

    picker.restart_all({})

    assert.are.equal("after", lines(buf), "restart left the buffer holding stale text")
    -- didOpen serializes buffer lines, so a re-attach that lands first hands the
    -- fresh server the same text and gets the same diagnostics back.
    assert.are.equal("after", at_reattach, "re-attached before re-reading the file")
  end)

  it("makes each buffer current while its FileType handlers run", function()
    local buf = file_buf("current.lua")
    local seen
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      buffer = buf,
      callback = function()
        seen = vim.api.nvim_get_current_buf()
      end,
    })

    picker.restart_all({})

    -- nvim_exec_autocmds sets <abuf> but does not switch buffers, while
    -- ftplugins act on the CURRENT one: $VIMRUNTIME/ftplugin/lua.lua calls
    -- vim.treesitter.start() with no bufnr. Re-attaching a buffer you are not
    -- standing in would otherwise setlocal its filetype's options onto the
    -- buffer you are.
    assert.are.equal(buf, seen)
  end)

  it("keeps re-attaching after a handler wipes one of the buffers", function()
    -- The list is computed before the first checktime, and both halves of the
    -- cycle can invalidate an entry: config.file_reload pcalls its own reload
    -- loop for exactly this reason ("a buffer can be wiped by an autocmd that an
    -- earlier reload in this same loop triggered"). Buffers fire in bufnr order,
    -- so `doomed` is already gone by the time the cycle reaches it.
    local first = file_buf("first.lua")
    local doomed = file_buf("doomed.lua")
    local last = file_buf("last.lua")
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      buffer = first,
      callback = function()
        vim.api.nvim_buf_delete(doomed, { force = true })
      end,
    })
    local fired = record_filetype({ last })

    picker.restart_all({})

    assert.is_true(vim.tbl_contains(fired, last), "a wiped buffer stopped the re-attach")
  end)

  it("re-attaches open buffers even when no client is running at all", function()
    local buf = file_buf("crashed.lua")
    local fired = record_filetype({ buf })

    local stopped, reattached = picker.restart_all({})

    assert.are.equal(0, stopped)
    assert.is_true(vim.tbl_contains(fired, buf), "a crashed server leaves nothing to walk")
    assert.is_true(reattached >= 1)
  end)
end)

-- The <leader>lR / :LspRestartAll wrapper. Split out the way config.lsp_reap
-- splits sweep_and_notify: the user asked, so say what happened either way --
-- and "nothing was running" is a real answer here, not an error, since a dead
-- server is one of the states this key exists to recover from.
describe("config.lsp_picker.restart_all_and_notify", function()
  local notify, said

  before_each(function()
    said = {}
    notify = vim.notify
    vim.notify = function(msg)
      said[#said + 1] = msg
    end
  end)

  after_each(function()
    vim.notify = notify
  end)

  it("reports the clients it stopped and the buffers it re-attached", function()
    picker.restart_all_and_notify({ client({ id = 1 }) })

    assert.are.equal(1, #said)
    assert.is_truthy(said[1]:find("restarted 1 client across", 1, true))
    assert.is_nil(said[1]:find("1 clients", 1, true), "pluralised a single client")
  end)

  it("says nothing was running rather than reporting zero clients", function()
    picker.restart_all_and_notify({})

    assert.are.equal(1, #said)
    assert.is_truthy(said[1]:find("no LSP servers were running", 1, true))
  end)
end)
