# LSP ↔ filesystem sync on nvim-tree delete/rename

Root-cause analysis (2026-07-25) of: "deleting files from nvim-tree makes the
LSP go crazy; renaming a package is worse" — observed in
`~/projects/lola-workspace` (superproject; `lola-server` = Go/gopls,
`lola-web` = pnpm monorepo/ts_ls). Includes the verified fix design.

## Confirmed root cause

The config deliberately disables `workspace/didChangeWatchedFiles` for every
server (`lua/plugins/lsp.lua`, the multi-submodule perf tradeoff). That was
sold as "servers won't auto-refresh on *out-of-editor* changes", but it also
silenced the only channel that reported **in-editor** nvim-tree operations for
most servers:

- **gopls relies entirely on client-side `didChangeWatchedFiles`** to learn
  about creates/deletes/renames (golang/go#67995; gopls integrator docs). It
  advertises no rename/delete LSP `fileOperations` — live capability dump
  shows only `fileOperations.didCreate` (import-stub feature;
  golang/go#51037 for the rest is still open).
- The `nvim-lsp-file-operations` plugin bridges nvim-tree events only to
  servers that advertise `fileOperations` — so for gopls it sends **nothing**
  on delete/rename. 3.5 months of `~/.local/state/nvim/lsp.log` contain zero
  `willRenameFiles` / `didDeleteFiles` / `didChangeWatchedFiles` client
  notifications.

Net effect: after a delete or package-dir rename in nvim-tree, gopls's
snapshot still contains the old files. Every subsequent diagnostics pass
re-stats them → error storm, broken features, until the LSP is restarted.

### Evidence

- **Log forensics**: the 2026-07-25 07:44:21–27 storm — 40 error lines
  (`stat .../internal/module/topic/*.go: no such file or directory`,
  `diagnostics failed`, `while diagnosing changed files`) across 5 deleted
  files, ending only at the next nvim restart. Same staleness family:
  `no package metadata for file` × 578 lines (315 in lola-workspace) across
  many days, biggest burst 292 lines in one minute.
- **Live repro** (headless nvim, real config, real workspace): create scratch
  package `internal/lspreprotmp/{lib,user}.go`, wait for gopls to resolve
  `Lib()`, delete `lib.go` on disk → over 20 s of buffer edits gopls **never**
  reports `undefined: Lib` (stale snapshot). Package-dir rename: same.
  Caveat for future repros: Go tooling ignores `_`/`.`-prefixed dirs — a
  `__foo` scratch dir makes gopls skip the package entirely.
- **Heal validated**: hand-sending
  `client:notify("workspace/didChangeWatchedFiles", { changes = {{ uri = <old file>, type = 3 }} })`
  made the correct `undefined: Lib` diagnostic appear within seconds. gopls
  processes this notification unconditionally — no dynamic-registration
  handshake required (`gopls/internal/server/text_synchronization.go` converts
  changes straight to `file.Modification{OnDisk:true}`).

### ts_ls side (live repro in lola-web)

- Single ts_ls client, rooted at `lola-web` (pnpm-lock.yaml), correct.
- ts_ls advertises **only** `fileOperations.willRename`
  (`**/*.{ts,js,jsx,tsx,mjs,mts,cjs,cts}` files + `**` folders).
- Deletes: the plugin sends nothing, but tsserver runs its **own native fs
  watcher** when LSP watching is off — missing-import diagnostics appeared
  ~3 s after an on-disk delete. ts_ls self-heals; gopls does not.
- File rename via the plugin works (import edit applied; 79 ms sync block),
  but the edited importer buffers are left **modified and unsaved** — disk
  keeps the broken import until the user saves.
- Folder rename ("rename a package"): ts_ls returns edits for importers
  outside the folder; `apply_workspace_edit` silently creates **hidden dirty
  buffers** for importers that weren't open, disk stays broken, and the open
  buffer inside the folder gets a bogus `Cannot find module` because
  tsserver's watcher saw the directory vanish.

### Secondary defects (source-verified)

1. **URI desync on rename of open buffers**: nvim-tree's
   `rename_loaded_buffers` does `nvim_buf_set_name` + `silent! write!` +
   `:edit`; vim.lsp has no BufFilePost handling, so the server keeps a
   phantom document open under the old URI while later `didChange`/`didSave`
   target a new URI it never opened.
2. **nvim-lsp-file-operations liabilities**: `vim.lsp.get_active_clients()`
   (deprecation warning spammed on every operation) and dot-call
   `client.request_sync` (compat removal planned); synchronous
   `request_sync` with a **10 s** timeout per client on the UI thread;
   applies every client's WorkspaceEdit in sequence (double-apply risk with
   overlapping roots); hard-errors if a callback fires before `setup()`;
   near-dormant upstream.
3. **Folder deletes** fire only `FolderRemoved` (after deletion, no per-file
   events); copy-paste in nvim-tree fires no events at all (upstream gap).

## Fix design

Replace the plugin with a small config module, e.g. `lua/config/lsp_fs_sync.lua`
(testable, idempotent registration per repo conventions), subscribed from
nvim-tree's `config()`:

- **Delete** (`FileRemoved`, `FolderRemoved`): notify every client whose
  `root_dir` is a prefix of the path:
  `workspace/didChangeWatchedFiles { uri, type = Deleted }`. This is the
  validated gopls heal; harmless no-op for ts_ls.
- **Create** (`FileCreated`, `FolderCreated`): same with `type = Created`
  (also send `workspace/didCreateFiles` to servers advertising
  `fileOperations.didCreate` — gopls's package-stub nicety).
- **Rename** (`WillRenameNode` → before fs_rename):
  1. For clients advertising `fileOperations.willRename` with matching
     filters (ts_ls): `client:request_sync("workspace/willRenameFiles", …)`
     with a short timeout (~2 s, not 10 s), apply the returned edit. Runs
     pre-rename, so URIs are valid — same as VS Code semantics.
  2. Detach clients from buffers at/under the old path
     (`vim.lsp.buf_detach_client` → clean `didClose` under the old URI).
     nvim-tree's own `:edit` after the rename re-fires FileType →
     `vim.lsp.enable` re-attaches → clean `didOpen` under the new URI.
     This kills the URI desync.
- **Rename** (`NodeRenamed` → after): notify
  `didChangeWatchedFiles { Deleted old, Created new }` to root-matching
  clients; `workspace/didRenameFiles` to servers advertising `didRename`.
- lsp.lua keeps advertising `fileOperations` will/didRename capabilities;
  drop the plugin spec and its `setup()` call.
- Modern APIs throughout (`vim.lsp.get_clients`, colon-call methods).

Out of scope / accepted: changes made outside nvim-tree (terminal, git) still
need `<leader>lr` — that's the documented watcher-off tradeoff; nvim-tree
copy-paste emits no events to hook; importer buffers edited by willRename
stay unsaved-dirty (VS Code parity).

### The rewrite depends on a client being alive, not on it having buffers

`on_will_rename` asks every client whose `root_dir` covers the path and never
requires that client to have attached buffers — so a client whose buffers are all
closed still rewrites importers repo-wide, and no covering client means the rename
silently leaves every importer pointing at the old path. Measured directly: the
importer was rewritten with a bufferless-but-alive client, and untouched once that
client was stopped, with `:messages` empty.

That is why `on_will_rename` now `notify_once`es when a `ts/tsx/js/jsx` rename
found no server advertising `willRename`, and why the idle-client sweep
(`config.lsp_reap`) is manual rather than an automatic reaper. Residue: the guard
detects "nobody to ask", not "somebody answered nothing" — with ts_ls split per
package, a surviving workspace-rooted client can cover the path and return no
edits. See docs/lsp-typescript-version.md.

## Implemented (lua/config/lsp_fs_sync.lua) + review hardening

Shipped as designed, plus three fixes out of an adversarial review:

- **Failed-rename recovery**: nvim-tree fires `WillRenameNode` before
  `fs_rename` and bails on failure (EXDEV/EACCES) without `NodeRenamed`, which
  would have left the detached buffers LSP-less until `:edit`. The detach is
  tracked per old-path and a `vim.schedule`d check re-attaches (with a
  warning) when no `NodeRenamed` cleared it — the whole rename is synchronous
  in one event-loop tick, so the scheduled callback runs strictly after the
  outcome is known.
- **Cross-root moves**: `didChangeWatchedFiles` is scoped per endpoint
  (Deleted(old) to clients covering old, Created(new) to clients covering
  new), and the willRename/didRename loops run over the union — moving a
  package between submodules now reaches the destination root's server.
- **`:Lazy reload` safety**: `register()` is guarded by events-table identity,
  not a boolean — a reload wipes nvim-tree's handler table, and a fresh
  `api.events` must re-subscribe while a same-table re-run must not double up.

Refuted-by-review non-issues worth remembering: overlapping-root double-apply
cannot occur here (single client per root; union dedupes by id), and
`FolderCreated`'s payload quirks are inherited nvim-tree behavior with no
user-visible consequence.
