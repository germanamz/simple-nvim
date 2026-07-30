-- Pins config.lsp_reap: stopping language servers that no longer serve any
-- buffer.
--
-- nvim 0.12.4 has no zero-buffer autostop — the only client:stop() sites in the
-- runtime are VimLeavePre, vim.lsp.enable(name, false), deprecated stop_client,
-- and an explicit Client:stop(). A ts_ls client left with attached_buffers = 0
-- holds its node processes (~0.7 GiB on a real repo) until you quit, so browsing
-- several monorepos in one session accumulates them.
--
-- The sweep is deliberately MANUAL (a key / a command / the end of the explicit
-- "close everything" gesture) rather than a debounced autocmd: an automatic
-- reaper silently breaks config.lsp_fs_sync's rename import-rewrite, which sends
-- workspace/willRenameFiles to every client whose root covers the path and never
-- requires that client to have attached buffers.
local reap = require("config.lsp_reap")

--- Minimal stand-in for vim.lsp.Client: only the fields idle() reads.
local function client(opts)
  local stopped = opts.stopped or false
  return {
    id = opts.id or 1,
    name = opts.name or "ts_ls",
    attached_buffers = opts.bufs or {},
    is_stopped = function()
      return stopped
    end,
    stop = function(self)
      self._stop_calls = (self._stop_calls or 0) + 1
      stopped = true
    end,
  }
end

describe("config.lsp_reap.idle", function()
  it("selects a live client with no attached buffers", function()
    local c = client({ bufs = {} })
    assert.are.same({ c }, reap.idle({ c }))
  end)

  it("skips a client that still serves a buffer", function()
    assert.are.same({}, reap.idle({ client({ bufs = { [7] = true } }) }))
  end)

  it("skips an already-stopped client so a sweep cannot double-stop", function()
    assert.are.same({}, reap.idle({ client({ stopped = true }) }))
  end)

  it("is not limited to ts_ls", function()
    -- gopls and lua_ls were measured sitting bufferless and unreaped too; a
    -- ts_ls-only sweep would report "stopped 0" while gopls held its memory.
    local g = client({ name = "gopls", id = 2 })
    local l = client({ name = "lua_ls", id = 3 })
    assert.are.equal(2, #reap.idle({ g, l }))
  end)

  it("returns an empty list for no clients", function()
    assert.are.same({}, reap.idle({}))
  end)
end)

describe("config.lsp_reap.sweep", function()
  it("stops every idle client and reports how many", function()
    local idle_a = client({ id = 1 })
    local idle_b = client({ id = 2, name = "gopls" })
    local busy = client({ id = 3, bufs = { [4] = true } })
    local n = reap.sweep({ idle_a, idle_b, busy })
    assert.are.equal(2, n)
    assert.are.equal(1, idle_a._stop_calls)
    assert.are.equal(1, idle_b._stop_calls)
    assert.is_nil(busy._stop_calls)
  end)

  it("reports zero without touching anything when all clients are busy", function()
    local busy = client({ bufs = { [1] = true } })
    assert.are.equal(0, reap.sweep({ busy }))
    assert.is_nil(busy._stop_calls)
  end)
end)
