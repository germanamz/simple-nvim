# Review comments for a coding agent

Annotate lines while reading a change, then hand the whole batch to a coding
agent in one paste. Each comment carries the `@path#L39-41` it is about, so the
agent opens exactly the code you meant.

```
<leader>ac   comment on the cursor line, or the visual selection's span
<leader>al   list queued comments — jump to one, edit it, drop it, clear them all
<leader>as   copy the batch to the clipboard
<leader>ax   discard the batch
```

The queue lives in memory and dies with the session. No comment is ever written
to disk. In Claude Code a mod can pull the batch instead of the clipboard: see
[Pulled by a Claude Code mod](#pulled-by-a-claude-code-mod).

Discarding is therefore the one irreversible action here, and `<leader>ax` sits
one key from `<leader>ac` and `<leader>as`, so it confirms first — the same
guard `<leader>hr` puts in front of a gitsigns reset while a review base is
active. The list's "Clear all" routes through the same function rather than
becoming a second, unguarded way to destroy the queue.

## Responsibilities

| file | owns |
| --- | --- |
| `lua/config/review_comments.lua` | The queue, its extmark anchors, the payload format, the four entry points behind the keymaps, and `snapshot()` / `ack()`, the pair the Claude Code mod calls over RPC. |
| `lua/config/file_reference.lua` | `relpath(buf)` — the project-root-relative path both this feature and `<leader>yl` are spelled from. |
| `lua/config/options.lua` | The four mappings and the two `:ClaudeMod*` commands, lazy-requiring their modules so nothing loads until one is used. |
| `claude-mods/nvim-review/hooks/register.tsx` | The Claude Code mod: finds this workspace's nvims, draws the band, answers `/nvim-review`, fills the prompt and acks. |
| `lua/config/claude_mods.lua` | `:ClaudeModInstall` / `:ClaudeModUninstall`: the claude CLI calls that install a mod from `claude-mods/` into one project. |

## The reference format

A comment is written `@lua/config/lsp.lua#L39-41` — single `L`, hyphen range,
one number when the range is one line. That is not a cosmetic choice: it is
exactly what Claude Code's IDE at-mention emits into its own prompt box, so a
pasted batch resolves as real file mentions rather than being read as prose.
Other agents read it as an ordinary reference.

The path comes from `file_reference.relpath`, which resolves the buffer's work
tree — except that a submodule buffer under the cwd's toplevel is spelled
`sub/file.lua`, because a bare `file.lua:42` cannot say which of 200 submodules
it means. That ladder is shared, not duplicated; `relpath` was split out of
`reference()` for exactly that reason.

## Ranges follow the code

A review is not read-only — you fix things as you go — so a comment queued
before an edit above it would name the wrong lines by the time you paste. Each
comment is therefore anchored on an extmark rather than a stored line number,
with both ends taking right gravity: an `O` above the commented line pushes the
comment down with the code it names, and an insert inside the range widens it.

The push-time line numbers are kept as a fallback for a buffer that has since
been unloaded, where there is no mark left to read. `list()`'s Jump clamps to
the buffer's current line count, because that snapshot can name a line the file
no longer has.

## Why the clipboard

The clipboard is the destination on purpose, and it replaced a working sink that
typed the batch straight into a sibling cmux pane.

That sink addressed its target by cmux **ref** (`surface:2`). Refs resolve
against the live tree at call time and nothing documents that one names the same
surface later, so a ref cached at the first flush could come to mean a different
pane — and `cmux send` would exit 0 while the review landed in another agent's
session. Silent misdelivery, with the retry-on-failure path never firing because
there was no failure. The stable `id` UUID was available all along and would
have fixed that particular bug.

It would not have fixed the rest. Injected text arrives wherever focus is in the
target pane, so a permission prompt or a picker swallows it. And during
development a probe agent demonstrated the blast radius concretely: three
payloads reached a *different* agent, in a different workspace, mid-dialog — via
`cmux rpc terminal.paste` / `surface.send_text` / `terminal.input`, which in
cmux 0.64.22 accept a `surfaceId` and silently ignore it, targeting the active
surface instead.

Driving the agent's TUI was fragile on its own terms too. `cmux send` passes raw
bytes, so DEL (`0x7f`) works as a backspace, but long bursts of one control key
are lossy — 95 DELs deleted 61 characters — and Claude Code's prompt ignores
readline bindings: `send-key ctrl+u` returns `OK` and clears nothing. A text
blob arrives intact in one call, and one sent without a trailing Enter stays an
unsubmitted draft in the existing conversation.

Pasting costs one keystroke, always lands where you are looking, works with any
agent in any terminal, and depends on no cmux API. Removing the sink also
removed the payload escaping it needed: `cmux send` turns a real newline, and
the two-character sequences `\n` and `\r`, into Enter, and `\t` into Tab, with
**no escape for a backslash** — so a multi-line batch submitted itself line by
line, and an ordinary comment like "strip the trailing `\n`" fired Enter into
the agent's prompt. `setreg` is also synchronous, which retires the in-flight
guard the async sink needed to avoid double-delivering a review.

## Pulled by a Claude Code mod

The clipboard stays the default, for every agent. In Claude Code a mod (its
hooks API, early access as of 2.1.318) pulls the batch instead: a band above
Claude's prompt reads "nvim: 2 review comments queued [ Insert ]", and the
button or `/nvim-review` puts the batch in the prompt box as an unsent draft.
It is installed per project, from nvim:

```
:ClaudeModInstall     install nvim-review into the current project
:ClaudeModUninstall   remove it again
```

`claude-mods/` is a plugin marketplace on disk
(`claude-mods/.claude-plugin/marketplace.json`), and the first install adds it
to Claude by itself. A plugin installed from a folder marketplace is read in
place, never copied, so an edit to the mod reaches a Claude session at its next
start or `/reload-plugins` with no reinstall. The install uses Claude's `local`
scope, the project's uncommitted settings.local.json: the marketplace path
exists only on this machine, so a team project's committed settings must not
name it. Claude resolves the project itself, so running the command from a
subdirectory installs into the repo's root. The mod's own tests run with
`make test-mod`.

Pulling answers what retired the cmux sink:

- **It cannot reach the wrong session.** The session that receives the batch is
  the one you pressed Insert in; nvim never addresses a session.
- **A dialog cannot swallow it.** The mod's prompt write refuses while a
  permission prompt or picker holds the keys, and the comments stay queued.
- **Nothing is escaped.** The batch crosses as a string, not keystrokes, so a
  `\n` in a comment stays text.
- **Nothing is lost.** `flush()` clears the queue as it copies, so a clipboard
  overwritten before the paste loses the batch. Over the mod, nvim drops a
  comment only when the mod acks it after the draft took it.
- **Nothing touches disk.** The mod talks to nvim over nvim's own RPC socket.

The contract is two functions in `lua/config/review_comments.lua`, called with
`nvim --server <socket> --remote-expr`:

- `snapshot()` returns one JSON string: `count`, `ids`, `text` (the payload
  `flush()` copies, absent when the queue is empty), `cwd`, and `workspace`
  (`CMUX_WORKSPACE_ID`, absent outside cmux).
- `ack(ids)` drops the comments with those ids and keeps anything queued since
  the snapshot. Ids are never reused, not even across a clear, so a late ack
  cannot land on a newer comment.

The mod finds nvim by listing the server sockets nvim creates on macOS, one
random directory per nvim under $TMPDIR/nvim.$USER/, each holding nvim.PID.0.
It keeps the nvims whose `workspace` matches its own session's (an editor pane
and an agent pane in one cmux workspace both inherit it), and outside cmux
falls back to an nvim whose cwd shares the session's tree. An nvim that had
already loaded this module before `snapshot()` existed answers with an error
and is ignored until it restarts; one that never loaded it picks up the new
file on the first query.

Finding nvims is the mod's background poll, every 3 s. Insert and
`/nvim-review` only re-ask the nvims already found, because a suspended nvim
(ctrl+z) accepts the connection and never answers: with a full scan on every
press, two of those made each insert wait out a 2 s timeout. A socket that times
out is left alone for 30 s. Each poll costs one `nvim --clean --headless`
client per matching nvim, about 25 ms each.

## Rejected, and why

Do not re-propose these without new evidence; each was investigated against
Claude Code 2.1.261's binary and the ACP spec, not just their documentation.
Claude Code mods came later and are the pull path above; none of these needs
revisiting for it.

- **ACP (Agent Client Protocol).** The standard here, and Claude Code is
  reachable through it via `zed-industries/claude-agent-acp`, Codex via
  `codex-acp`, with Gemini CLI and OpenCode native. Its `session/prompt` takes
  `Text` and `ResourceLink` blocks, both baseline, so it carries prose and file
  references natively. But its only transport is stdio, where "the client
  launches the agent as a subprocess" (Streamable HTTP is still a draft) — so it
  requires the agent to live inside Neovim rather than in its own pane. Worth
  revisiting only if that ever becomes the workflow (CodeCompanion, avante.nvim
  and agentic.nvim are Neovim-side clients); it would also bring
  `ToolCallLocation {path, line}` follow-along for free.
- **Claude's IDE websocket.** The complete set of IDE→Claude notifications is
  `at_mentioned`, `selection_changed` and `log_event`. `at_mentioned` takes
  strictly `{filePath, lineStart, lineEnd}` (0-indexed on the wire) and is
  rendered into the prompt as the literal string this feature already produces.
  There is no field for a comment, so the protocol is a more expensive way to
  type one string.
- **A custom `mcp__ide__` tool** over that websocket. Plausible but never
  tested — the IDE connection registers as an MCP server named `ide`, which
  already exposes `getDiagnostics` and `executeCode` — and pull-only: the agent
  must decide to call it, so it is not a notification.
- **`notifications/claude/channel`.** Real unsolicited MCP push, `{content,
  meta}`, injected into the conversation. Gated behind a `--channels` flag absent
  from `claude --help`, `channelsEnabled` in *managed* settings, an experimental
  capability handshake, and an explicit "channels feature is not currently
  available". This is the natural home for a push sink if it ships.
- **`/tmp/cc-socks/<pid>.sock`**, the cross-session messaging socket. Carries
  prose and wakes the session, but is private, unversioned, Claude-only, and
  would need `CLAUDE_CODE_MESSAGING_TOKEN` scraped from another process.
- **A file queue** the agent reads. Rejected outright: comments are a thing you
  are about to say, not a document.
- **Persisting the queue.** Comments dying with the session is the intent.

## Testing notes

`span()`'s visual-mode path leaves visual mode with `vim.cmd("normal! \27")`,
not `nvim_feedkeys`. Feeding `<Esc>` the way `file_reference.yank` does is safe
only because yank never prompts afterwards: `vim.ui.input` is `vim.fn.input()`
underneath, which drains the typeahead, so a queued `<Esc>` is the first key it
reads and cancels the prompt — no comment queued, and the editor left in visual
mode with your next keystrokes running as motions. Executing the `<Esc>`
instead (`feedkeys` with `"x"`) drains whatever else is pending, so a comment
typed ahead of the prompt runs as normal-mode commands. `normal!` touches
neither.

A headless spec cannot see any of that — it cannot enter insert mode or drive a
prompt — so the behavior was verified under a real pty, and the specs pin what
headless *can* observe. Do not "simplify" that call back to `feedkeys`.

The clipboard specs save and restore the `+` register: the suite must not
clobber the clipboard of whoever runs it. Under Claude Code's sandbox they fail
(no clipboard tool), as does any probe of a live nvim's RPC socket: see
[[sandbox-hides-live-nvim-sockets]].
