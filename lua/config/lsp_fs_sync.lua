-- Keep LSP servers' view of the filesystem in sync with nvim-tree file
-- operations. workspace/didChangeWatchedFiles is globally disabled (see
-- lua/plugins/lsp.lua), and that silenced the only channel most servers had
-- for in-editor deletes/renames too: gopls relies entirely on client-side
-- watching (it advertises no rename/delete fileOperations), so after a tree
-- delete or package rename its snapshot kept the old files and every
-- diagnostics pass stormed stat errors until restart. Full analysis and the
-- validated fix design: docs/lsp-fs-sync.md.
--
-- This module hand-delivers what the watcher would have sent — for the tree's
-- own operations only (external changes still need <leader>lr, the documented
-- watcher-off tradeoff):
--   • delete/create/rename → workspace/didChangeWatchedFiles (gopls processes
--     these unconditionally, registration or not; verified against source and
--     live against lola-workspace)
--   • rename → workspace/willRenameFiles request first, applying the returned
--     import-rewrite edit (ts_ls), then didRenameFiles after
--   • create → workspace/didCreateFiles to servers advertising it (gopls's
--     package-clause stub)
--   • rename of open buffers → detach clients while buffer names still carry
--     the old path, so didClose goes out under the URI the server knows;
--     nvim-tree's own post-rename :edit refires FileType and vim.lsp.enable
--     re-attaches under the new one. Without this the server keeps a phantom
--     document open at the old URI while didChange targets a new URI it never
--     opened (vim.lsp has no buffer-rename handling).
--
-- Notifications are scoped to clients whose root_dir covers the path: correct
-- servers ignore foreign URIs anyway, but skipping them avoids waking every
-- server in a many-submodule workspace for each file operation.
local M = {}

-- Bound the synchronous willRenameFiles round-trip. It must be synchronous —
-- the edit has to apply while the old path still exists, before nvim-tree
-- performs the rename — but the old plugin's 10s budget froze the UI for as
-- long as a slow server dawdled; ts_ls answers in tens of ms.
local RENAME_TIMEOUT_MS = 2000

---@param client vim.lsp.Client
---@param path string absolute path
---@return boolean
local function root_covers(client, path)
  local root = client.root_dir
  if not root then
    return false
  end
  root = root:gsub("/+$", "")
  if root == "" then -- root_dir "/" covers every absolute path
    return true
  end
  return path == root or vim.startswith(path, root .. "/")
end

---@param path string
---@return vim.lsp.Client[]
local function watched_clients(path)
  return vim.tbl_filter(function(client)
    return root_covers(client, path)
  end, vim.lsp.get_clients())
end

---@param path string scope: clients whose root covers this path
---@param changes table[] lsp.FileEvent[]
local function notify_watched(path, changes)
  for _, client in ipairs(watched_clients(path)) do
    client:notify("workspace/didChangeWatchedFiles", { changes = changes })
  end
end

---@param client vim.lsp.Client
---@param op string willRename | didRename | didCreate | ...
---@return table|nil registration options with .filters, when advertised
local function file_op(client, op)
  return vim.tbl_get(client.server_capabilities or {}, "workspace", "fileOperations", op)
end

-- LSP FileOperationFilter list vs an absolute path. `matches` restricts a
-- filter to files or folders; absent means either.
---@param filters table[]|nil
---@param path string
---@param is_dir boolean
---@return boolean
local function filters_match(filters, path, is_dir)
  for _, filter in ipairs(filters or {}) do
    local pattern = filter.pattern or {}
    local kind_ok = not pattern.matches or (pattern.matches == "folder") == is_dir
    if kind_ok and pattern.glob then
      local glob, subject = pattern.glob, path
      if vim.tbl_get(pattern, "options", "ignoreCase") then
        glob, subject = glob:lower(), subject:lower()
      end
      local ok, lpeg = pcall(vim.glob.to_lpeg, glob)
      if ok and lpeg:match(subject) then
        return true
      end
    end
  end
  return false
end

---@param old string
---@param new string
---@return table lsp.RenameFilesParams
local function rename_params(old, new)
  return {
    files = { { oldUri = vim.uri_from_fname(old), newUri = vim.uri_from_fname(new) } },
  }
end

--- FileRemoved / FolderRemoved (fires after deletion).
---@param path string
function M.on_removed(path)
  notify_watched(path, {
    { uri = vim.uri_from_fname(path), type = vim.lsp.protocol.FileChangeType.Deleted },
  })
end

--- FileCreated / FolderCreated.
---@param path string
function M.on_created(path)
  local uri = vim.uri_from_fname(path)
  notify_watched(path, {
    { uri = uri, type = vim.lsp.protocol.FileChangeType.Created },
  })
  local is_dir = vim.fn.isdirectory(path) == 1
  for _, client in ipairs(watched_clients(path)) do
    local op = file_op(client, "didCreate")
    if op and filters_match(op.filters, path, is_dir) then
      client:notify("workspace/didCreateFiles", { files = { { uri = uri } } })
    end
  end
end

-- Renames whose detach still awaits confirmation: old path -> detached
-- {buf, client_id} pairs. nvim-tree fires WillRenameNode BEFORE fs_rename and
-- bails on failure (EXDEV, EACCES) without NodeRenamed — the detach must be
-- undone then, or the buffers silently lose their LSP until :edit. The whole
-- rename is synchronous within one event-loop tick, so a vim.schedule'd check
-- runs strictly after either NodeRenamed cleared the entry (success) or
-- nothing did (failure).
local pending_detach = {}

--- WillRenameNode (fires before the rename, old path still on disk).
---@param old string
---@param new string
function M.on_will_rename(old, new)
  local is_dir = vim.fn.isdirectory(old) == 1
  local params = rename_params(old, new)
  -- Union of both endpoints' roots: a cross-root move must reach the
  -- destination's server too (a willRename server rooted there wants to
  -- rewrite its importers).
  local seen = {}
  local asked = false
  for _, path in ipairs({ old, new }) do
    for _, client in ipairs(watched_clients(path)) do
      if not seen[client.id] then
        seen[client.id] = true
        local op = file_op(client, "willRename")
        if op and filters_match(op.filters, old, is_dir) then
          asked = true
          local ok, resp = pcall(
            client.request_sync,
            client,
            "workspace/willRenameFiles",
            params,
            RENAME_TIMEOUT_MS
          )
          if ok and resp and resp.result then
            vim.lsp.util.apply_workspace_edit(resp.result, client.offset_encoding)
          end
        end
      end
    end
  end

  -- Renaming a JS/TS file with no server to ask means importers keep pointing at
  -- the old path, silently. The rewrite already depends on a client happening to
  -- be alive and covering the path — it does not need attached buffers, so a
  -- server for a repo whose buffers are all closed still does the work, and no
  -- server at all does none of it. Say so rather than letting the rename look
  -- complete. See docs/lsp-fs-sync.md.
  if not asked and not is_dir and vim.fn.fnamemodify(old, ":e"):match("^[mc]?[jt]sx?$") then
    vim.notify_once(
      "renamed without an LSP server to rewrite imports; importers may still point at the old path (<leader>lr in the project, then redo the rename)",
      vim.log.levels.WARN
    )
  end

  -- Detach clients from buffers at/under the old path while their names still
  -- carry it (detach emits didClose for the URI the server has open).
  local detached = {}
  local prefix = old .. "/"
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name == old or vim.startswith(name, prefix) then
        for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
          vim.lsp.buf_detach_client(buf, client.id)
          detached[#detached + 1] = { buf = buf, client_id = client.id }
        end
      end
    end
  end

  if #detached > 0 then
    pending_detach[old] = detached
    vim.schedule(function()
      local pend = pending_detach[old]
      if not pend then
        return -- NodeRenamed arrived: rename succeeded, :edit re-attaches
      end
      pending_detach[old] = nil
      for _, d in ipairs(pend) do
        if vim.api.nvim_buf_is_loaded(d.buf) then
          pcall(vim.lsp.buf_attach_client, d.buf, d.client_id)
        end
      end
      vim.notify(
        ("lsp_fs_sync: rename of %s did not complete; restored LSP clients"):format(old),
        vim.log.levels.WARN
      )
    end)
  end
end

--- NodeRenamed (fires after the rename).
---@param old string
---@param new string
function M.on_renamed(old, new)
  pending_detach[old] = nil
  local deleted = { uri = vim.uri_from_fname(old), type = vim.lsp.protocol.FileChangeType.Deleted }
  local created = { uri = vim.uri_from_fname(new), type = vim.lsp.protocol.FileChangeType.Created }
  local is_dir = vim.fn.isdirectory(new) == 1 -- old is already gone
  local params = rename_params(old, new)
  -- Per-endpoint scoping: on a cross-root move the source's server hears
  -- Deleted(old), the destination's Created(new), one covering both hears
  -- both. didRenameFiles goes to the same union.
  for _, client in ipairs(vim.lsp.get_clients()) do
    local covers_old = root_covers(client, old)
    local covers_new = root_covers(client, new)
    if covers_old or covers_new then
      local changes = {}
      if covers_old then
        changes[#changes + 1] = deleted
      end
      if covers_new then
        changes[#changes + 1] = created
      end
      client:notify("workspace/didChangeWatchedFiles", { changes = changes })
      local op = file_op(client, "didRename")
      if op and filters_match(op.filters, old, is_dir) then
        client:notify("workspace/didRenameFiles", params)
      end
    end
  end
end

--- Client capabilities advertising exactly the operations this module sends,
--- merged into every server's capabilities in lua/plugins/lsp.lua.
function M.capabilities()
  return {
    workspace = {
      fileOperations = {
        willRename = true,
        didRename = true,
        didCreate = true,
      },
    },
  }
end

local registered_events = nil

--- Subscribe the handlers to nvim-tree's events. Called from nvim-tree's
--- config() with require("nvim-tree.api").events (injected here so tests can
--- drive a fake). Guarded by the events-table identity, not a boolean:
--- :Lazy reload wipes nvim-tree's modules (subscriptions included) but not
--- this one, so a fresh events table must re-subscribe, while a repeat call
--- with the same table (config() re-run without reload) must not double up —
--- nvim-tree events have no unsubscribe.
---@param events table nvim-tree api.events
function M.register(events)
  if registered_events == events then
    return
  end
  registered_events = events
  local E = events.Event
  events.subscribe(E.WillRenameNode, function(args)
    M.on_will_rename(args.old_name, args.new_name)
  end)
  events.subscribe(E.NodeRenamed, function(args)
    M.on_renamed(args.old_name, args.new_name)
  end)
  events.subscribe(E.FileRemoved, function(args)
    M.on_removed(args.fname)
  end)
  events.subscribe(E.FolderRemoved, function(args)
    M.on_removed(args.folder_name)
  end)
  events.subscribe(E.FileCreated, function(args)
    M.on_created(args.fname)
  end)
  events.subscribe(E.FolderCreated, function(args)
    M.on_created(args.folder_name)
  end)
end

return M
