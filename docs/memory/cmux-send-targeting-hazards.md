---
type: memory
title: "Cmux send targeting hazards"
kind: reference
description: "cmux (as of 2026-09): rpc terminal.paste/surface.send_text/terminal.input IGNORE surfaceId and hit the active surface; send addresses by unstable ref; send has no backslash escape."
---

# Cmux send targeting hazards

Learned the hard way on 2026-09-05 while building nvim→agent review comments
(see [[docs/agent-review-comments]]). A probe agent injected three payloads
into a DIFFERENT live agent's session, in a different workspace, mid-dialog.

**Never use `cmux rpc terminal.paste` / `surface.send_text` / `terminal.input`.**
In cmux (as of 2026-09) all three accept a `surfaceId` param and **silently ignore it**,
targeting the currently active surface. Each returned the active surface's uuid
despite being passed another. `cmux send --surface <uuid>` targeted correctly on
every call — the escape was entirely through the rpc methods.

**Address by `id` (UUID), never by `ref`.** `cmux tree --json` surfaces carry
both `id` (stable uuid) and `ref` (`surface:2`). Per cmux's own CLI contract
refs "resolve before the V1 socket command is sent" — looked up against the live
tree at call time, with no documented stability. A cached ref can come to name a
different pane, and the send then **exits 0** while the text lands in the wrong
session. Silent misdelivery; no failure path fires.

**`cmux send` escape semantics** (probed against a raw `cat` with `stty raw
-echo`, bytes read back with `od -c`):
- a real `0x0a` newline arrives as `0x0d` — **Enter**, not a newline
- the two-char sequences `\n` and `\r` → Enter; `\t` → Tab; `\e`, `\0`, `\x41`
  stay literal
- **there is no escape for a backslash**: doubling does NOT protect the next
  character. `KK\\nLL` arrives as `K K \ <Enter> L L`
So a multi-line payload submits itself line by line, and an ordinary comment
containing `\n` fires Enter. Any text sink must guarantee no `0x0a`, no `0x0d`
and no `\`+`n|r|t` pair survives.

**Nested tree JSON field names differ from `caller`.** `caller` has
`surface_id`/`workspace_id`/`pane_id`; nested surfaces under
`windows[].workspaces[].panes[].surfaces[]` use `id`/`ref`/`type`/`title`, and
workspaces use `id`/`ref`. There is also a `here` boolean on the caller's surface.

**Conclusion that shipped:** typing into another agent's terminal was abandoned
for the clipboard. Even with the uuid fix, injected text lands wherever focus is
in the target pane, so a permission prompt or picker swallows it. See
`docs/agent-review-comments.md` (committed). Related:
[[docs/agent-review-comments]], [[docs/leak-diagnostics]].
