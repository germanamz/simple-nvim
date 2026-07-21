# Documentation

Reference notes for this Neovim config. The config itself is described in the
top-level `CLAUDE.md`; these documents cover the parts that are worth explaining
beyond the code.

## Contents

- **[keybindings.md](keybindings.md).** A searchable cheatsheet of this config's
  keymaps plus the built-in motions that are easy to forget.
- **[smart-files.md](smart-files.md).** The `<leader><leader>` file picker: what
  it shows, and how it opens fast on superprojects with hundreds of submodules.
- **[nvim-tree-git.md](nvim-tree-git.md).** Git integration in the file tree:
  branch and status for the superproject and each submodule, plus the tiered
  scanning model that keeps it fast.
- **[dotted-chain-textobject.md](dotted-chain-textobject.md).** The `ao` / `io`
  mini.ai textobject that selects a whole dotted identifier chain.
- **[leak-diagnostics.md](leak-diagnostics.md).** The capture playbook for the
  2026-07 CPU and memory runaway, and the defects it turned up.

## The git-at-scale throughline

Several of these documents share one concern: this config is used on large
superprojects, monorepos with hundreds of git submodules over tens of thousands
of files, and naive git integration is far too slow there. The file picker and the
file tree both grew out of the same work and share machinery:

- **Cheap submodule discovery.** Both enumerate submodules by reading `.gitmodules`
  directly rather than running `git submodule status --recursive`, which spawns a
  subprocess per submodule. `telescope_smart._submodule_paths_async` is the shared
  enumerator. See [smart-files.md](smart-files.md).
- **A shared status cache, scanned incrementally.** Per-submodule status is
  computed once and cached, keyed by each submodule's index mtime so an unchanged
  submodule is never re-scanned. `config.submodule_status` owns the cache and both
  the picker and the tree read from it. See [nvim-tree-git.md](nvim-tree-git.md).
- **Leak-safe timers and spawns.** The [leak audit](leak-diagnostics.md) set the
  discipline the rest of the config follows: bounded concurrency on git fan-outs,
  timeouts on every spawn, and one reused timer rather than one per event.
