---
type: memory
title: "Claudecode auto-mode fires no IDE events"
kind: reference
description: "In Claude Code auto-accept mode, edits write straight to disk and fire NO IDE/claudecode.nvim events — editor-follow can't be done plugin-side."
---

# Claudecode auto-mode fires no IDE events

Verified empirically (2026-06-30): when Claude Code runs in auto-accept
(`acceptEdits`) mode, its Edit/Write tools write directly to disk and do NOT
drive the IDE protocol — no `openDiff`, no `openFile`, no notification to a
connected editor. Test: attached a throwaway autocmd to claudecode.nvim's
"always emitted" diff-lifecycle User events (`ClaudeCodeDiffOpened`/`Closed`,
payload carries `file_path`/`new_file_path`/`reason`) on the bridged nvim; a
real auto-mode edit fired nothing, a manually dispatched event logged fine.

Implication: a "follow Claude as it edits" view in nvim is impossible
plugin-side under auto mode — the editor receives no signal. The only viable
trigger is a Claude-side `PostToolUse` hook (matcher `Edit|Write|MultiEdit`)
that pokes nvim via `nvim --server <addr> --remote`. A pure-nvim filesystem
watcher was rejected (perf landmine on 100+ submodule repos — see
[[multi-submodule-perf-changes]]).

Decision: dropped the whole idea and removed claudecode.nvim (commit
c26e374). The plugin's headline value (accept/reject diffs) is moot under
auto-accept anyway.

Operational note: nvim's `--server <sock> --remote*` IPC is blocked by the
Claude Code command sandbox (`E247: connection refused` / unix-socket errors);
run such commands with the sandbox disabled.
