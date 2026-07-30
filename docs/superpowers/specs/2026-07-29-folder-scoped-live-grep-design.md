# Folder-scoped live grep (`<leader>fG`) — design

Status: implemented (2026-07-29).

## Problem

`<leader>fg` always greps the repo toplevel. On the superprojects this config
targets — hundreds of submodules, tens of thousands of files — a project-wide
grep for a common identifier buries the twenty matches you care about under
hundreds you do not. There was no way to say "just this folder".

## Scope

One new verb: the same `live_grep` picker narrowed to a directory the user
chooses. Nothing else changes; `<leader>fg` and `<leader>fs` keep their
project-wide behavior.

## Choosing the folder

Two mechanisms were wanted: the node under the cursor in nvim-tree, and typing a
path. They collapse into one keymap rather than two, because a *seeded prompt*
serves both:

`<leader>fG` always asks for a directory through `vim.ui.input`, pre-filled with

- the nvim-tree node under the cursor when the tree is focused (a file node seeds
  its parent folder), or
- the focused buffer's own folder anywhere else (the cwd for an unnamed buffer).

The common case ("this folder") is one `<CR>`; the path stays editable, so you can
backspace a component to widen, `<Tab>`-complete deeper, or replace it entirely.
The alternative — tree binding fires immediately, other buffers prompt — saves one
keypress but makes the same key mean two different things depending on where the
cursor is, and gives up widening from the tree.

## Module: `lua/config/telescope_grep.lua`

One module owns "what directory does a grep picker search", both scopes:

| Function      | Responsibility |
| ------------- | -------------- |
| `root()`      | Repo toplevel, cwd outside a repo. The project-wide scope `<leader>fg` / `<leader>fs` use. Moved here from the file-local `grep_root` in `lua/plugins/telescope.lua`, which now delegates, so the two scopes are not defined in different files. |
| `seed()`      | The directory the prompt opens on (tree node, else `util.path.buf_start_dir`). |
| `grep(dir)`   | Normalize `dir`, then open `live_grep` scoped to it. Returns the directory searched, or `nil` when the path does not exist. |
| `prompt()`    | `vim.ui.input` seeded per `seed()`, then `grep()`. |

### Normalization

`grep()` accepts what a human types or yanks:

- `~` and `$VAR` expand; a relative path resolves against the cwd, matching the
  vocabulary the prompt's `completion = "dir"` speaks.
- A path pointing at a **file** collapses to its parent — the same rule `seed()`
  applies to a file node, so one behavior covers both entry points.
- A path that is neither notifies at `WARN` and opens no picker. The message
  trims the trailing slash `:p` adds, which would otherwise read as if the user
  had typed it.
- Empty or `nil` is a silent no-op, as is a cancelled prompt (`<Esc>` yields
  `nil`) or a cleared line.

`seed()` probes directory-ness with `isdirectory()` rather than reading
`node.type`, because nvim-tree hands out field-only clones of its nodes whose
shape is not guaranteed (the trap recorded in `config.nvim_tree_hl_decorator`).
The filesystem is the authority anyway.

### Prompt seed shortening

The seed is shown through `:.` — cwd-relative when it lives under the cwd,
absolute otherwise — because that is what `completion = "dir"` completes against.
A trailing slash makes `<Tab>` continue *inside* the seeded directory instead of
completing its siblings.

`:.` has no relative form for the cwd **itself** and hands back the absolute path,
which made the most ordinary seed there is (any buffer at the project root, or an
unnamed one) a 60-character prompt line. That case is special-cased to `.`, found
while testing rather than while designing.

### Title

`prompt_title = "Live Grep (" .. relative-to-root .. ")"`, the basename when the
scope *is* the root. Without it a scoped picker is indistinguishable from
`<leader>fg`'s, and a scoped search over a subtree with no matches looks like a
broken project-wide grep. `util.path.relative` leaves paths outside the root
absolute.

Passing `cwd` only sets ripgrep's search directory: the `pickers.live_grep`
`additional_args` from telescope's `setup()` still apply, so the result set
matches `<leader>fg`'s (hidden files searched, `.git` pruned) rather than quietly
differing.

## Keymap

`<leader>fG` → `prompt()`, registered **once** in the telescope spec's `keys`
(which lazy-loads telescope on press). No second buffer-local binding in
nvim-tree's `on_attach`: nvim-tree maps no leader keys buffer-locally, so the
global mapping is not shadowed inside the tree, and `seed()` detects the tree
itself. The e2e spec presses the key from inside the tree, so the day that
assumption breaks, a test fails.

Lands in the existing which-key `find` group; no group entry needed.

## Tests

`tests/spec/unit/telescope_grep_spec.lua` (18) — stubs `telescope.builtin`,
`nvim-tree.api` and `vim.ui.input`: scope and title passed through, file → parent,
`~` and relative expansion, root basename, missing path warns and opens nothing,
empty/cancelled/whitespace no-ops, seed from each source, `./` for the cwd,
`root()` in and out of a repo.

`tests/spec/e2e/telescope_grep_dir_spec.lua` (3) — real nvim-tree, real telescope,
real ripgrep: the cursor parks on a directory node and the prompt is seeded from
it; a root-level file node seeds `./`; accepting the seed greps recursively below
the folder and excludes a sibling match above it.

`tests/spec/e2e/telescope_spec.lua` — one added case answers the prompt with an
explicit path and asserts a match inside the scope is found while an identical
needle outside it is not. Asserting the title alone would pass even if `cwd` were
dropped.

## Docs

`docs/keybindings.md`: `<Space>fG` rows in the three tables that list `<Space>fg`,
plus a "Grep in one folder" subsection covering the seeding rules and the editable
path.
