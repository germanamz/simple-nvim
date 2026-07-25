local nvim_env = require("helpers.nvim_env")

-- Fake LSP client: records notify/request_sync calls; colon-call methods like
-- the real vim.lsp.Client. `respond` lets a test script the willRenameFiles
-- response (nil = timeout).
local function fake_client(opts)
  local c = {
    id = opts.id or 1,
    name = opts.name or "fake",
    root_dir = opts.root_dir,
    offset_encoding = "utf-16",
    server_capabilities = opts.server_capabilities or {},
    notifications = {},
    requests = {},
    _respond = opts.respond,
  }
  function c:notify(method, params)
    table.insert(self.notifications, { method = method, params = params })
    return true
  end
  function c:request_sync(method, params, timeout_ms, bufnr)
    table.insert(
      self.requests,
      { method = method, params = params, timeout_ms = timeout_ms, bufnr = bufnr }
    )
    if self._respond then
      return self._respond(method, params)
    end
    return nil
  end
  return c
end

local function notifications_of(client, method)
  return vim.tbl_filter(function(n)
    return n.method == method
  end, client.notifications)
end

describe("config.lsp_fs_sync", function()
  local env_root, M
  local orig_get_clients, orig_detach, orig_attach, orig_notify
  local clients, attached, detached, reattached, warnings

  before_each(function()
    env_root = nvim_env.setup_isolated_env()
    package.loaded["config.lsp_fs_sync"] = nil
    M = require("config.lsp_fs_sync")

    clients = {}
    attached = {} -- bufnr -> list of clients
    detached = {} -- recorded {bufnr, client_id}
    reattached = {} -- recorded {bufnr, client_id}
    warnings = 0
    orig_get_clients = vim.lsp.get_clients
    orig_detach = vim.lsp.buf_detach_client
    orig_attach = vim.lsp.buf_attach_client
    orig_notify = vim.notify
    vim.lsp.get_clients = function(filter)
      if filter and filter.bufnr then
        return attached[filter.bufnr] or {}
      end
      return clients
    end
    vim.lsp.buf_detach_client = function(bufnr, client_id)
      table.insert(detached, { bufnr = bufnr, client_id = client_id })
    end
    vim.lsp.buf_attach_client = function(bufnr, client_id)
      table.insert(reattached, { bufnr = bufnr, client_id = client_id })
      return true
    end
    vim.notify = function()
      warnings = warnings + 1
    end
  end)

  after_each(function()
    -- Drain this spec's scheduled failed-rename recoveries before restoring
    -- the stubs, so a will-rename without a completing on_renamed neither
    -- leaks re-attach records into the next test nor hits the real APIs.
    vim.wait(20)
    vim.lsp.get_clients = orig_get_clients
    vim.lsp.buf_detach_client = orig_detach
    vim.lsp.buf_attach_client = orig_attach
    vim.notify = orig_notify
    nvim_env.teardown(env_root)
  end)

  describe("on_removed", function()
    it(
      "notifies didChangeWatchedFiles(Deleted) to the client whose root covers the path",
      function()
        local go = fake_client({ id = 1, root_dir = "/ws/server" })
        clients = { go }
        M.on_removed("/ws/server/internal/lib.go")
        local sent = notifications_of(go, "workspace/didChangeWatchedFiles")
        assert.are.equal(1, #sent)
        assert.are.same({
          changes = { { uri = vim.uri_from_fname("/ws/server/internal/lib.go"), type = 3 } },
        }, sent[1].params)
      end
    )

    it(
      "skips clients whose root does not cover the path, including prefix-without-boundary",
      function()
        local sibling = fake_client({ id = 1, root_dir = "/ws/web" })
        local boundary = fake_client({ id = 2, root_dir = "/ws/serv" })
        clients = { sibling, boundary }
        M.on_removed("/ws/server/internal/lib.go")
        assert.are.equal(0, #sibling.notifications)
        assert.are.equal(0, #boundary.notifications)
      end
    )

    it("skips clients with no root_dir", function()
      local rootless = fake_client({ id = 1, root_dir = nil })
      clients = { rootless }
      M.on_removed("/ws/server/internal/lib.go")
      assert.are.equal(0, #rootless.notifications)
    end)
  end)

  describe("on_created", function()
    it("notifies didChangeWatchedFiles(Created) to root-matching clients", function()
      local go = fake_client({ id = 1, root_dir = "/ws/server" })
      clients = { go }
      M.on_created("/ws/server/internal/new.go")
      local sent = notifications_of(go, "workspace/didChangeWatchedFiles")
      assert.are.equal(1, #sent)
      assert.are.same({
        changes = { { uri = vim.uri_from_fname("/ws/server/internal/new.go"), type = 1 } },
      }, sent[1].params)
    end)

    it("also sends didCreateFiles to servers advertising a matching didCreate filter", function()
      local go = fake_client({
        id = 1,
        root_dir = "/ws/server",
        server_capabilities = {
          workspace = {
            fileOperations = {
              didCreate = { filters = { { scheme = "file", pattern = { glob = "**/*.go" } } } },
            },
          },
        },
      })
      clients = { go }
      M.on_created("/ws/server/internal/new.go")
      local sent = notifications_of(go, "workspace/didCreateFiles")
      assert.are.equal(1, #sent)
      assert.are.same(
        { files = { { uri = vim.uri_from_fname("/ws/server/internal/new.go") } } },
        sent[1].params
      )
    end)

    it("does not send didCreateFiles when the filter does not match", function()
      local go = fake_client({
        id = 1,
        root_dir = "/ws/server",
        server_capabilities = {
          workspace = {
            fileOperations = {
              didCreate = { filters = { { scheme = "file", pattern = { glob = "**/*.go" } } } },
            },
          },
        },
      })
      clients = { go }
      M.on_created("/ws/server/notes.txt")
      assert.are.equal(0, #notifications_of(go, "workspace/didCreateFiles"))
      assert.are.equal(1, #notifications_of(go, "workspace/didChangeWatchedFiles"))
    end)
  end)

  describe("on_will_rename", function()
    local ts_caps = {
      workspace = {
        fileOperations = {
          willRename = {
            filters = {
              {
                scheme = "file",
                pattern = { glob = "**/*.{ts,js,jsx,tsx,mjs,mts,cjs,cts}", matches = "file" },
              },
              { scheme = "file", pattern = { glob = "**", matches = "folder" } },
            },
          },
        },
      },
    }

    it("requests willRenameFiles with a short timeout and applies the returned edit", function()
      local importer = "/ws/web/src/main.ts"
      local buf = vim.api.nvim_create_buf(false, false)
      vim.api.nvim_buf_set_name(buf, importer)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "import { util } from './util';" })

      local ts = fake_client({
        id = 1,
        root_dir = "/ws/web",
        server_capabilities = ts_caps,
        respond = function()
          return {
            result = {
              changes = {
                [vim.uri_from_fname(importer)] = {
                  {
                    range = {
                      start = { line = 0, character = 22 },
                      ["end"] = { line = 0, character = 28 },
                    },
                    newText = "./util2",
                  },
                },
              },
            },
          }
        end,
      })
      clients = { ts }

      M.on_will_rename("/ws/web/src/util.ts", "/ws/web/src/util2.ts")

      assert.are.equal(1, #ts.requests)
      local req = ts.requests[1]
      assert.are.equal("workspace/willRenameFiles", req.method)
      assert.are.same({
        files = {
          {
            oldUri = vim.uri_from_fname("/ws/web/src/util.ts"),
            newUri = vim.uri_from_fname("/ws/web/src/util2.ts"),
          },
        },
      }, req.params)
      -- Guard against the 10s UI freeze the old plugin allowed.
      assert.is_true(req.timeout_ms ~= nil and req.timeout_ms <= 2000)
      assert.are.equal(
        "import { util } from './util2';",
        vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
      )
    end)

    it("does not request from clients lacking the willRename capability", function()
      local go = fake_client({ id = 1, root_dir = "/ws/web" })
      clients = { go }
      M.on_will_rename("/ws/web/src/util.ts", "/ws/web/src/util2.ts")
      assert.are.equal(0, #go.requests)
    end)

    it("does not request when no filter matches the old path", function()
      local ts = fake_client({ id = 1, root_dir = "/ws/web", server_capabilities = ts_caps })
      clients = { ts }
      M.on_will_rename("/ws/web/src/style.css", "/ws/web/src/style2.css")
      assert.are.equal(0, #ts.requests)
    end)

    it("matches folder filters when renaming a directory", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local ts = fake_client({ id = 1, root_dir = "/", server_capabilities = ts_caps })
      clients = { ts }
      M.on_will_rename(dir, dir .. "2")
      assert.are.equal(1, #ts.requests)
      vim.fn.delete(dir, "rf")
    end)

    it("survives a timed-out request without applying anything", function()
      local ts =
        fake_client({ id = 1, root_dir = "/ws/web", server_capabilities = ts_caps, respond = nil })
      clients = { ts }
      assert.has_no.errors(function()
        M.on_will_rename("/ws/web/src/util.ts", "/ws/web/src/util2.ts")
      end)
      assert.are.equal(1, #ts.requests)
    end)

    it("detaches clients from the renamed buffer and buffers under a renamed directory", function()
      local inside = vim.api.nvim_create_buf(false, false)
      vim.api.nvim_buf_set_name(inside, "/ws/server/pkg/user.go")
      local outside = vim.api.nvim_create_buf(false, false)
      vim.api.nvim_buf_set_name(outside, "/ws/server/other/main.go")
      -- Shares the "/ws/server/pkg" prefix without the "/" boundary — a plain
      -- startswith(old) scan would wrongly detach it.
      local sibling = vim.api.nvim_create_buf(false, false)
      vim.api.nvim_buf_set_name(sibling, "/ws/server/pkgstore/db.go")

      local go = fake_client({ id = 7, root_dir = "/ws/server" })
      clients = { go }
      attached[inside] = { go }
      attached[outside] = { go }
      attached[sibling] = { go }

      M.on_will_rename("/ws/server/pkg", "/ws/server/pkg2")

      assert.are.same({ { bufnr = inside, client_id = 7 } }, detached)
    end)

    it("detaches the exactly-named buffer on a single-file rename", function()
      -- Distinct path per test: specs share one nvim, and a second buffer with
      -- an already-used name would E95 on nvim_buf_set_name.
      local buf = vim.api.nvim_create_buf(false, false)
      vim.api.nvim_buf_set_name(buf, "/ws/server/pkgone/user.go")
      local go = fake_client({ id = 3, root_dir = "/ws/server" })
      clients = { go }
      attached[buf] = { go }

      M.on_will_rename("/ws/server/pkgone/user.go", "/ws/server/pkgone/user2.go")

      assert.are.same({ { bufnr = buf, client_id = 3 } }, detached)
    end)

    it("requests willRenameFiles from a destination-root client on a cross-root move", function()
      local dest = fake_client({ id = 2, root_dir = "/ws/b", server_capabilities = ts_caps })
      clients = { dest }
      M.on_will_rename("/ws/a/src/x.ts", "/ws/b/src/x.ts")
      assert.are.equal(1, #dest.requests)
      assert.are.equal("workspace/willRenameFiles", dest.requests[1].method)
    end)

    it("re-attaches detached clients when the rename never completes", function()
      -- nvim-tree fires WillRenameNode before fs_rename and bails on failure
      -- (EXDEV, EACCES) without NodeRenamed — the detach must be undone or the
      -- buffer silently loses its LSP until :edit.
      local buf = vim.api.nvim_create_buf(false, false)
      vim.api.nvim_buf_set_name(buf, "/ws/server/pkgfail/user.go")
      local go = fake_client({ id = 7, root_dir = "/ws/server" })
      clients = { go }
      attached[buf] = { go }

      M.on_will_rename("/ws/server/pkgfail", "/ws/server/pkgfail2")
      assert.are.same({ { bufnr = buf, client_id = 7 } }, detached)
      -- No NodeRenamed: pump the loop so the scheduled recovery runs.
      vim.wait(100, function()
        return #reattached > 0
      end)

      assert.are.same({ { bufnr = buf, client_id = 7 } }, reattached)
      assert.are.equal(1, warnings)
    end)

    it("does not re-attach after the rename completes", function()
      local buf = vim.api.nvim_create_buf(false, false)
      vim.api.nvim_buf_set_name(buf, "/ws/server/pkgok/user.go")
      local go = fake_client({ id = 7, root_dir = "/ws/server" })
      clients = { go }
      attached[buf] = { go }

      M.on_will_rename("/ws/server/pkgok", "/ws/server/pkgok2")
      M.on_renamed("/ws/server/pkgok", "/ws/server/pkgok2")
      vim.wait(50)

      assert.are.same({}, reattached)
    end)
  end)

  describe("on_renamed", function()
    it(
      "notifies didChangeWatchedFiles with Deleted(old) + Created(new) to root-matching clients",
      function()
        local go = fake_client({ id = 1, root_dir = "/ws/server" })
        clients = { go }
        M.on_renamed("/ws/server/pkg", "/ws/server/pkg2")
        local sent = notifications_of(go, "workspace/didChangeWatchedFiles")
        assert.are.equal(1, #sent)
        assert.are.same({
          changes = {
            { uri = vim.uri_from_fname("/ws/server/pkg"), type = 3 },
            { uri = vim.uri_from_fname("/ws/server/pkg2"), type = 1 },
          },
        }, sent[1].params)
      end
    )

    it("sends didRenameFiles to servers advertising a matching didRename filter", function()
      local srv = fake_client({
        id = 1,
        root_dir = "/ws/web",
        server_capabilities = {
          workspace = {
            fileOperations = {
              didRename = {
                filters = { { scheme = "file", pattern = { glob = "**/*.ts", matches = "file" } } },
              },
            },
          },
        },
      })
      clients = { srv }
      M.on_renamed("/ws/web/src/a.ts", "/ws/web/src/b.ts")
      local sent = notifications_of(srv, "workspace/didRenameFiles")
      assert.are.equal(1, #sent)
      assert.are.same({
        files = {
          {
            oldUri = vim.uri_from_fname("/ws/web/src/a.ts"),
            newUri = vim.uri_from_fname("/ws/web/src/b.ts"),
          },
        },
      }, sent[1].params)
    end)

    it("splits Deleted/Created per endpoint on a cross-root move", function()
      -- Moving a package between submodules: the source client must hear
      -- Deleted(old), the destination client Created(new) — the old-only
      -- scoping left the destination gopls stale.
      local src = fake_client({ id = 1, root_dir = "/ws/a" })
      local dest = fake_client({ id = 2, root_dir = "/ws/b" })
      clients = { src, dest }
      M.on_renamed("/ws/a/pkg", "/ws/b/pkg")

      local src_sent = notifications_of(src, "workspace/didChangeWatchedFiles")
      assert.are.equal(1, #src_sent)
      assert.are.same(
        { changes = { { uri = vim.uri_from_fname("/ws/a/pkg"), type = 3 } } },
        src_sent[1].params
      )
      local dest_sent = notifications_of(dest, "workspace/didChangeWatchedFiles")
      assert.are.equal(1, #dest_sent)
      assert.are.same(
        { changes = { { uri = vim.uri_from_fname("/ws/b/pkg"), type = 1 } } },
        dest_sent[1].params
      )
    end)

    it("sends didRenameFiles to a destination-root client on a cross-root move", function()
      local dest = fake_client({
        id = 2,
        root_dir = "/ws/b",
        server_capabilities = {
          workspace = {
            fileOperations = {
              didRename = {
                filters = { { scheme = "file", pattern = { glob = "**/*.ts", matches = "file" } } },
              },
            },
          },
        },
      })
      clients = { dest }
      M.on_renamed("/ws/a/src/x.ts", "/ws/b/src/x.ts")
      assert.are.equal(1, #notifications_of(dest, "workspace/didRenameFiles"))
    end)
  end)

  describe("register", function()
    local function fake_events()
      return {
        Event = {
          WillRenameNode = "WillRenameNode",
          NodeRenamed = "NodeRenamed",
          FileRemoved = "FileRemoved",
          FolderRemoved = "FolderRemoved",
          FileCreated = "FileCreated",
          FolderCreated = "FolderCreated",
        },
        subscriptions = {},
      }
    end

    it("subscribes the six tree events exactly once, even when called twice", function()
      local ev = fake_events()
      ev.subscribe = function(event, fn)
        table.insert(ev.subscriptions, { event = event, fn = fn })
      end
      M.register(ev)
      M.register(ev)
      assert.are.equal(6, #ev.subscriptions)
      local seen = {}
      for _, s in ipairs(ev.subscriptions) do
        seen[s.event] = true
      end
      for _, name in pairs(ev.Event) do
        assert.is_true(seen[name], "missing subscription for " .. name)
      end
    end)

    it("re-subscribes when handed a fresh events table (post :Lazy reload)", function()
      -- :Lazy reload nvim-tree wipes nvim-tree.events (and its handler table)
      -- but not this module, so a boolean guard would leave fs-sync dead: the
      -- guard must key on the events-table identity instead.
      local ev1 = fake_events()
      ev1.subscribe = function(event, fn)
        table.insert(ev1.subscriptions, { event = event, fn = fn })
      end
      M.register(ev1)
      local ev2 = fake_events()
      ev2.subscribe = function(event, fn)
        table.insert(ev2.subscriptions, { event = event, fn = fn })
      end
      M.register(ev2)
      assert.are.equal(6, #ev1.subscriptions)
      assert.are.equal(6, #ev2.subscriptions)
    end)

    it("routes tree payloads to the handlers (fname vs folder_name vs old/new_name)", function()
      local ev = fake_events()
      local handlers = {}
      ev.subscribe = function(event, fn)
        handlers[event] = fn
      end
      M.register(ev)

      local go = fake_client({
        id = 1,
        root_dir = "/ws/server",
        server_capabilities = {
          workspace = {
            fileOperations = {
              willRename = { filters = { { scheme = "file", pattern = { glob = "**/*.go" } } } },
            },
          },
        },
      })
      clients = { go }
      handlers.FileRemoved({ fname = "/ws/server/a.go" })
      handlers.FolderRemoved({ folder_name = "/ws/server/pkg" })
      handlers.FileCreated({ fname = "/ws/server/b.go" })
      handlers.FolderCreated({ folder_name = "/ws/server/pkg2" })
      handlers.WillRenameNode({ old_name = "/ws/server/e.go", new_name = "/ws/server/f.go" })
      handlers.NodeRenamed({ old_name = "/ws/server/c.go", new_name = "/ws/server/d.go" })

      local watched = notifications_of(go, "workspace/didChangeWatchedFiles")
      assert.are.equal(5, #watched)
      assert.are.equal(vim.uri_from_fname("/ws/server/a.go"), watched[1].params.changes[1].uri)
      assert.are.equal(vim.uri_from_fname("/ws/server/pkg"), watched[2].params.changes[1].uri)
      assert.are.equal(vim.uri_from_fname("/ws/server/b.go"), watched[3].params.changes[1].uri)
      assert.are.equal(vim.uri_from_fname("/ws/server/pkg2"), watched[4].params.changes[1].uri)
      assert.are.equal(2, #watched[5].params.changes)

      -- WillRenameNode plumbing: old/new must land in oldUri/newUri, in order.
      assert.are.equal(1, #go.requests)
      assert.are.equal("workspace/willRenameFiles", go.requests[1].method)
      assert.are.equal(vim.uri_from_fname("/ws/server/e.go"), go.requests[1].params.files[1].oldUri)
      assert.are.equal(vim.uri_from_fname("/ws/server/f.go"), go.requests[1].params.files[1].newUri)
    end)
  end)

  describe("capabilities", function()
    it("advertises the file operations the module actually performs", function()
      assert.are.same({
        workspace = {
          fileOperations = {
            willRename = true,
            didRename = true,
            didCreate = true,
          },
        },
      }, M.capabilities())
    end)
  end)
end)
