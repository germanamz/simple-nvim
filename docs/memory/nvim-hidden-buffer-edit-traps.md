---
type: memory
title: "Nvim hidden-buffer edit traps"
kind: reference
description: "Three verified nvim API traps behind the duplicated/lost gopls package clause on nvim-tree create — no BufModifiedSet on hidden-buffer API edits, nvim_buf_attach refuses unloaded buffers, buffer names are realpath'd"
---

# Nvim hidden-buffer edit traps

Found 2026-08-31 fixing "creating `internal/nice/better/better.go` from
nvim-tree gives the package line once per directory, and sometimes not at all"
(see [[lsp-stale-on-tree-delete-rename]]; write-up in docs/lsp-fs-sync.md).

**Upstream trigger:** nvim-tree's `actions/fs/create-file.lua:93` dispatches
`FolderCreated` after every `mkdir` but passes `new_file_path` — the whole
target path — not the folder it made. It is that event's ONLY dispatch site, so
`FolderCreated`'s payload is never the created folder. Creating `a/b/c.go`
announces `c.go` once per missing directory plus once as `FileCreated`, and
gopls answers each `didCreateFiles` with its own package clause.

Three nvim behaviors verified by probe while fixing it — each one fails
*silently*, so none is inferable from reading code:

1. `nvim_buf_set_lines` on a non-current buffer sets `'modified'` but fires
   **neither `BufModifiedSet` nor `TextChanged`**. Server edits reaching a
   hidden buffer are invisible to both hooks.
2. `nvim_buf_attach` **refuses an unloaded buffer**, reporting it only via its
   return value (no error). At `BufNew` the buffer is always unloaded, so
   attaching there is a no-op. Use `BufNew` + `vim.schedule`: one
   `apply_workspace_edit` opens the buffer and applies the edit in a single tick.
3. Buffer names are **resolved** — `vim.uri_to_bufnr` stores the realpath — so
   any name comparison against a path from elsewhere must resolve both ends
   (`vim.uv.fs_realpath`). Bites on macOS tempdirs (`/var` → `/private/var`) and
   any symlinked repo. Same family as [[nvim-float-winbar-row-trap]] and
   [[nvim-virtual-lines-and-headless-lies]]: the API reports success while
   doing nothing.

Also confirmed: `vim.lsp.util.apply_text_edits` never writes the buffer, so an
LSP edit for a file nobody has open lands in a hidden dirty buffer and the file
on disk stays empty.

**gopls will not stub a file it already has open.** A create with no server
running is held and asked for at each server's `on_init` (wired in
lua/plugins/lsp.lua) — NOT `LspAttach`: by LspAttach the buffer that started the
server has gone out as `textDocument/didOpen` (`text = "\n"`, nvim always sends
one line) and `didCreateFiles` then returns zero edits. Same file, asked at
`on_init`: clause comes straight back. Do not "simplify" this to LspAttach.

**How to apply:** when an LSP-driven edit "doesn't happen", check the DISK
content and the buffer content separately before theorising — they diverge. And
check the lsp.log for what actually went on the wire: the notification being
sent does not mean the server acted on it.
