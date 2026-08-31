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
--     package-clause stub), coalesced to one announcement per tree create, held
--     for the next server's on_init when none covers the path yet, and the
--     returned stub written to disk when it lands in a buffer nobody has open
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

-- gopls returns its package-clause stub as a workspace/applyEdit, and
-- vim.lsp.util.apply_text_edits applies it to a buffer it loads for the
-- occasion without ever writing that buffer. For a file nobody has opened, the
-- clause therefore lives only in a hidden modified buffer while the file on
-- disk stays empty — wipe the buffer, or open the repo from anywhere else, and
-- the stub is simply gone. So write it ourselves, and only while the file sits
-- in no window: once the user has it on screen the buffer is theirs, and
-- flushing their unsaved edits behind their back is not ours to do.
--
-- The hook is BufNew, from the vim.uri_to_bufnr apply_workspace_edit opens
-- with, because the obvious alternatives do not fire at all: apply_text_edits
-- reaches a hidden buffer through nvim_buf_set_lines, and an API write to a
-- non-current buffer emits neither BufModifiedSet nor TextChanged (verified).
-- Holds both halves of the stub plumbing: the per-create BufNew watchers
-- below, and the LspAttach deferral further down.
local stub_group = vim.api.nvim_create_augroup("LspFsSyncStub", { clear = true })

-- How long to keep waiting for the server's edit before giving up on it. A
-- server may decline to stub at all, and an armed autocmd must not outlive the
-- create that armed it.
local STUB_TIMEOUT_MS = 30000

-- Buffer names are RESOLVED: vim.uri_to_bufnr hands nvim the path and nvim
-- stores its realpath, so a repo reached through a symlink (anything under
-- macOS's /var/..., for one) never matches the path nvim-tree announced. Match
-- on the resolved form at both ends.
---@param path string absolute path
---@return string
local function resolved(path)
  return vim.uv.fs_realpath(path) or path
end

---@param path string absolute path of a file a server was asked to stub
local function persist_stub(path)
  local target = resolved(path)
  local autocmd_id, timer

  local function disarm()
    if autocmd_id then
      pcall(vim.api.nvim_del_autocmd, autocmd_id)
      autocmd_id = nil
    end
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
  end

  autocmd_id = vim.api.nvim_create_autocmd("BufNew", {
    group = stub_group,
    desc = "persist an LSP package-clause stub landing in an unopened buffer",
    callback = function(args)
      if resolved(vim.api.nvim_buf_get_name(args.buf)) ~= target then
        return false
      end
      local buf = args.buf
      autocmd_id = nil -- returning true below deletes it
      disarm()
      -- Deferred, not immediate: at BufNew the buffer is still unloaded (which
      -- is also why nvim_buf_attach is no use here — it refuses an unloaded
      -- buffer and reports it only through its return value). One
      -- apply_workspace_edit opens the buffer and applies the edit within a
      -- single tick, so by the next one the stub is either in there or was
      -- never coming.
      vim.schedule(function()
        if not vim.api.nvim_buf_is_loaded(buf) or not vim.bo[buf].modified then
          return
        end
        if #vim.fn.win_findbuf(buf) > 0 then
          return -- on screen: the user's buffer, and the user's :w
        end
        -- noautocmd: this is the server's stub, not a user save, and it should
        -- not drag format-on-save and the linters in behind it.
        vim.api.nvim_buf_call(buf, function()
          pcall(vim.cmd, "silent noautocmd write")
        end)
      end)
      return true
    end,
  })

  timer = vim.uv.new_timer()
  timer:start(STUB_TIMEOUT_MS, 0, vim.schedule_wrap(disarm))
end

--- Ask `client` for the stub, if it takes files like this one.
---@param client vim.lsp.Client
---@param path string
---@return boolean asked
local function request_stub(client, path)
  local op = file_op(client, "didCreate")
  if not (op and filters_match(op.filters, path, vim.fn.isdirectory(path) == 1)) then
    return false
  end
  client:notify("workspace/didCreateFiles", { files = { { uri = vim.uri_from_fname(path) } } })
  return true
end

--- A file the server still owes a stub: on disk, and still untouched.
---@param path string
---@return boolean
local function awaits_stub(path)
  local stat = vim.uv.fs_stat(path)
  return stat ~= nil and stat.type == "file" and stat.size == 0
end

-- Creates nobody could stub when they happened. gopls is the only thing that
-- knows which `package` line a new .go file wants, and in a fresh session it is
-- usually not running yet: open the tree and create a file before opening any
-- Go buffer and there is simply no client to ask, so the file stays empty. Hold
-- the create instead of dropping it and ask the first server that turns up
-- covering it — which is the moment the user opens the file. Only paths NO
-- running client covers are held: a covering server that declined the filter
-- has already answered the question.
local unstubbed = {}

-- Enough for a burst of tree creates before any server is up. A path nothing
-- ever claims would otherwise sit here for the rest of the session.
local UNSTUBBED_LIMIT = 64

---@param client vim.lsp.Client newly attached
local function stub_waiting_creates(client)
  local keep = {}
  for _, path in ipairs(unstubbed) do
    -- A file the user has since written is theirs; a stub now would land on top
    -- of their first line.
    if awaits_stub(path) then
      if root_covers(client, path) and request_stub(client, path) then
        persist_stub(path)
      else
        keep[#keep + 1] = path
      end
    end
  end
  unstubbed = keep
end

--- A server has finished initializing: ask it for any stub that was waiting on
--- a server like it. Called from every server's `on_init` in
--- lua/plugins/lsp.lua, and `on_init` specifically rather than `LspAttach`,
--- because gopls will not stub a file it already has open — and by LspAttach
--- the buffer that started the server has been sent as `textDocument/didOpen`
--- (verified: asking at LspAttach for a file the user just opened returns no
--- edit at all; asking at on_init for the same file returns the package clause).
---@param client vim.lsp.Client
function M.on_client_init(client)
  if #unstubbed > 0 then
    stub_waiting_creates(client)
  end
end

---@param path string
local function announce_created(path)
  notify_watched(path, {
    { uri = vim.uri_from_fname(path), type = vim.lsp.protocol.FileChangeType.Created },
  })
  local covered, asked = false, false
  for _, client in ipairs(watched_clients(path)) do
    covered = true
    if request_stub(client, path) then
      asked = true
    end
  end
  if asked then
    persist_stub(path)
  elseif not covered and awaits_stub(path) then
    if #unstubbed >= UNSTUBBED_LIMIT then
      table.remove(unstubbed, 1)
    end
    unstubbed[#unstubbed + 1] = path
  end
end

-- Paths announced so far in this event-loop tick, or nil when none are pending.
local pending_creates = nil

--- FileCreated / FolderCreated.
---
--- One tree create, one announcement. nvim-tree fires FolderCreated once per
--- directory it had to make and hands every one of them the WHOLE target path
--- instead of the folder just created (actions/fs/create-file.lua:93 passes
--- `new_file_path`), then fires FileCreated for that same path — so creating
--- `internal/nice/better/better.go` announced better.go three times and gopls
--- stubbed `package better` into it three times over. Coalescing per tick also
--- fixes the ordering it exposed: every folder dispatch runs BEFORE the file is
--- written, and a server will not stub a path it cannot stat yet.
---@param path string
function M.on_created(path)
  if pending_creates then
    pending_creates[path] = true
    return
  end
  pending_creates = { [path] = true }
  -- The tree's create loop is synchronous, so the whole path exists by the time
  -- this runs.
  vim.schedule(function()
    local paths = vim.tbl_keys(pending_creates)
    pending_creates = nil
    table.sort(paths)
    for _, p in ipairs(paths) do
      announce_created(p)
    end
  end)
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
