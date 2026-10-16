---
type: memory
title: "Nvim-tree decorator gotchas"
kind: project
description: "Custom nvim-tree decorators get metatable-less api-node CLONES (fields only, no node methods); renderer.decorators LIST ORDER decides overlap winner (last wins). Powers the grey/blue/teal ignore/dotfolder/symlink trio."
---

# Nvim-tree decorator gotchas

Two non-obvious rules govern the custom nvim-tree renderer decorators in this
config (`lua/config/nvim_tree_git.lua`, `nvim_tree_ignore.lua` [grey],
`nvim_tree_dotfolder.lua` [blue], `nvim_tree_symlink.lua` [teal], sharing
`util.hl.define_dim` for a theme-blended colour):

**1. Custom decorators receive sanitized api-node CLONES, not real nodes.** A
decorator extending `require("nvim-tree.api").Decorator` (as ours do) is handed
an api-node clone (built by `Node:clone` in the plugin) at
`renderer/builder.lua` — the `elseif api_node` branch. BUILTIN decorators get the
real node. The clone copies plain FIELDS only (`type`, `absolute_path`, `name`,
`git_status`, ...) but NOT the `Node` metatable, so any node METHOD is nil:
`node:is_dotfile()` crashes with `attempt to call method 'is_dotfile' (a nil
value)` during `api.tree.reload()`. Fix: read fields only. Dotfile-ness =
`absolute_path:match("([^/]+)/?$")` first char `.`; symlink = `node.type ==
"link"` (both FileLinkNode and DirectoryLinkNode report "link"; real dirs are
"directory"). The builtin `Hidden` decorator never hits this because its
`highlight_range == "none"` guard short-circuits before `node:is_dotfile()`.

**2. renderer.decorators LIST ORDER = overlap winner (LAST wins).**
`Builder:create_combined_group` force-merges the per-node highlight groups with
`vim.tbl_extend("force", ...)` in decorators-list order, so the decorator later
in the list overrides earlier ones for the same node. The trio is ordered
`dot-folder, symlink, ignore` (ignore LAST) on purpose: dirs that are BOTH
static-ignored AND dotted (`.next`, `.venv`, `.turbo`, ...) resolve to grey
("ignored"), not blue. To flip that, move the ignore decorator earlier.

**3. `path_util.relative(node.absolute_path, cwd)` gets a TRAILING SLASH for
directory nodes.** `util.path.relative` runs `fnamemodify(:p)`, which appends `/`
to an existing directory, so a directory node's rel comes out `childA/`, not
`childA`. A decorator matching directory nodes against a slash-free key set (e.g.
a submodule set keyed `childA`, `childA/grand`) must strip it:
`(path_util.relative(node.absolute_path, self.cwd):gsub("/$", ""))`. This is an
e2e-only failure — unit tests that call the matching helper directly bypass the
`:icons` rel computation and never see the slash. This SILENTLY BIT the
`nvim_tree_git` directory rollup markers too (2026-07): `self.dirs[rel]` looked up
`server/cmd/` against slash-free keys `server/cmd` and always missed, so
the `•`/`*` dir marker NEVER rendered for any folder — files worked (no slash on a
file rel), dirs didn't. Fixed by extracting `nvim_tree_git._dir_icon(dirs, rel)`
which strips the slash before the lookup; pinned by an e2e case asserting a `*` on
the containing directory row (`tests/spec/e2e/nvim_tree_git_labels_spec.lua`). The
dir marker now renders `*` for a subtree with worktree (uncommitted) changes and
keeps `•` for a base-only subtree.

**4. `renderer.root_folder_label` is plain-text, single-highlight ONLY.** It takes
`string | false | fun(abs)->string` and renders the return as ONE buffer line
under a single `NvimTreeRootFolder` group (`renderer/builder.lua` `format_root_name`
/ `build_header`); a non-string return falls through to the literal `???`. No
per-part colour, no `%#Group#` markup (renders literally), and decorators do NOT
run on the header line. So coloured root-line status is impossible there — the
winbar (statusline markup) is the only coloured option. Used monochrome for the
superproject branch/status header; see [[nvim-tree-workspace-branch-status]].

Tests: pure predicates `_is_dotfolder`/`_is_symlink` in
`tests/spec/unit/nvim_tree_decorators_spec.lua` + `util.hl` in `hl_spec.lua`;
colour distinctness, dispatch, overlap precedence, and the no-crash reload
regression in `tests/spec/e2e/nvim_tree_decorators_spec.lua`.

See [[nvim-tree-ignore-filter]], [[nvim-tests-need-sandbox-disabled]],
[[nvim-e2e-single-file-needs-minimal-init]], [[nvim-tree-workspace-branch-status]].
