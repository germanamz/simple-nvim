# Review Base — Design

Show file changes and in-buffer hunks relative to a user-chosen git ref (e.g. `origin/main`) instead of only the index. Optimized for reviewing PRs/MRs and multi-commit agent work.

## Motivation

Current state:
- `<leader><space>` → `smart_files` picker marks staged/modified/untracked, then lists the rest of the tree
- Gitsigns shows hunks for working-tree vs index
- Both are anchored to the index; there is no way to say "show me everything that changed on this branch vs `origin/main`" and have the picker *and* buffer highlights reflect that.

Goal: introduce a per-repo "review base" ref. When set, `smart_files` includes files changed in commits on the current branch, and gitsigns highlights each buffer's hunks against the same base. Persisted per repo so the setting survives editor restarts.

## User-facing behavior

### Keymaps

| Keymap | Action |
|---|---|
| `<leader>gB` | Open branch picker. On select, save ref for the current repo and run `smart_files`. |
| `<leader>gX` | Clear saved review base for the current repo. |
| `<leader><space>` | (Unchanged) `smart_files`. If a base is set, picker uses it. If not, behaves exactly as today. |

No auto-prompt. First use in a new repo behaves like today; opt in via `<leader>gB`.

### Branch picker

Telescope picker built with the same primitives as `smart_files`. Prompt title: `Review base (current: <ref or "none">)`.

Entries, in order, deduped:

1. `[ clear base ]` — sentinel; selection calls `M.clear`.
2. `origin/HEAD` resolved (e.g. `origin/main`) — auto-detected default.
3. Current branch's upstream if any and different from #2.
4. Local branches (`git branch --format=%(refname:short)`).
5. Remote branches (`git branch -r --format=%(refname:short)`, excluding `origin/HEAD`).

The active base (if any) is prefixed with `●` in the entry display.

Preview: `git log --oneline --decorate <ref>..HEAD`. Empty message when `<ref>` equals `HEAD`.

Legend card (floating window, bottom-center, same pattern as the existing `smart_files` legend, closed on `BufLeave`/`BufWipeout`):

```
 ● active base
```

### `smart_files` changes

When a base is set and resolves:

- Compute committed-vs-base: `git -C <root> diff --name-only <base>..HEAD`.
- New bucket added with marker `◈` and highlight `SmartFilesCommitted` (e.g. magenta/purple).
- Priority order for markers (a file gets the highest-priority marker that applies):
  1. ◆ staged
  2. ● modified
  3. ○ untracked
  4. ◈ committed-vs-base (new)
  5. rest (unmarked)
- Prompt title becomes `Files (base: <ref>)`.
- Legend extends to: ` ◆ staged   ● modified   ○ untracked   ◈ vs <ref> `.

When no base is set, `smart_files` behaves as today.

### Gitsigns changes

Hunks in each buffer reflect diff vs the saved base (not the index) when a base is set.

- On `on_attach(bufnr)` and on the `User ReviewBaseChanged` autocmd, call `require("gitsigns").change_base(ref, true)` (global=true) if a base is set for this repo, or `change_base(nil, true)` to clear.
- `<leader>hd` (`gs.diffthis`) continues to work and is implicitly scoped to the active base.
- Existing custom hunk highlighting (`mark_hunks`) is unchanged; gitsigns emits `GitSignsUpdate` as normal and the existing listener repaints.

## Architecture

### New module: `lua/config/review_base.lua`

Owns state, persistence, branch-picker UI, and the change-notification autocmd.

Public API:

```lua
local M = {}

function M.get(root)           -- string | nil
function M.set(root, ref)      -- writes to disk, fires User ReviewBaseChanged {root, ref}
function M.clear(root)         -- writes to disk, fires User ReviewBaseChanged {root, ref=nil}
function M.resolve(root, ref)  -- boolean: git -C <root> rev-parse --verify <ref>
function M.pick(root, on_done) -- opens branch picker; on select calls set/clear then on_done(ref|nil)
function M.bootstrap()         -- at startup: drop entries whose ref no longer resolves
return M
```

### Persistence

- Path: `vim.fn.stdpath("data") .. "/nvim-review-base.json"`.
- Shape: `{ ["/abs/path/to/repo-toplevel"] = "origin/main", ... }`.
- Atomic write: write to `path .. ".tmp"` then `os.rename` over the target.
- Malformed/missing JSON: treated as empty map; first successful write replaces it.
- Repo root key: `git -C <cwd> rev-parse --show-toplevel`.

### Change notification

`M.set` and `M.clear` fire:

```lua
vim.api.nvim_exec_autocmds("User", {
  pattern = "ReviewBaseChanged",
  data = { root = root, ref = ref_or_nil },
})
```

This is the single coupling point; telescope and gitsigns listen and refresh themselves.

### Modified files

- `lua/config/telescope_smart.lua` — reads `review_base.get(root)`, computes the committed bucket, adds the marker/highlight/legend extensions, updates prompt title. No change to the existing picker layout or legend window mechanism.
- `lua/plugins/gitsigns.lua` — calls `apply_base()` helper from `on_attach` and from a `User ReviewBaseChanged` autocmd; calls `review_base.bootstrap()` during `config`.
- `lua/plugins/telescope.lua` — adds `<leader>gB` and `<leader>gX` to the existing keys table.

No changes to `diffview.lua` (`<leader>gm` remains hard-coded to `origin/main...HEAD`; independent of the review base).

## Edge cases

- **Not in a git repo** — `<leader>gB`/`<leader>gX` echo `Not a git repo` and no-op. `smart_files` behaves as today.
- **Saved ref deleted remotely** — `bootstrap()` drops it at startup. If deleted mid-session, next `smart_files` call sees `resolve() == false`, silently clears, falls back to index.
- **Detached HEAD** — `<ref>..HEAD` works as-is; no special casing.
- **Empty diff (base == HEAD)** — committed bucket is empty; gitsigns shows no hunks, which is correct.
- **Corrupted JSON on disk** — caught by `pcall(vim.json.decode)`; treated as empty; next write overwrites.
- **Concurrent writes from two nvim instances** — last-write-wins. Acceptable for single-user workflow.
- **Large repos** — `git diff --name-only <base>..HEAD` is fast; legend rebuild and marker lookup are O(1) per entry.

## Manual test plan

1. `<leader>gB` → pick `origin/main` → confirm `smart_files` auto-opens with `◈` markers on committed-vs-main files and legend shows `vs origin/main`.
2. Open a committed-vs-base file → confirm gitsigns hunks highlight diff vs `origin/main`, not the index.
3. Restart nvim → reopen the same file → confirm base persisted and hunks still vs base.
4. `<leader>gX` → legend shrinks, markers revert, gitsigns hunks return to working-tree-vs-index.
5. Set base to a local branch, delete that branch in another terminal, restart nvim → confirm silent fallback to index mode (no error).
6. Open a second repo in a different nvim session → confirm its base is independent of the first repo's.
