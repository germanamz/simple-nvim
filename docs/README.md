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
- **[lsp-typescript-version.md](lsp-typescript-version.md).** Why ts_ls ran
  mason's bundled TypeScript instead of the project's in pnpm monorepos, and the
  buffer-relative resolution that fixes it.
- **[lsp-fs-sync.md](lsp-fs-sync.md).** Why deleting or renaming files from the
  file tree sent gopls and ts_ls into error storms with watchers off, and the
  in-editor notification path that replaces them.
- **[js-toolchain.md](js-toolchain.md).** How a JavaScript/TypeScript project's
  formatter and linter are detected, why prettier no longer runs in projects that
  never configured it, and how to diagnose which tool owns a buffer. Also the
  full decision record: what was rejected and why, and what ships imperfect.
- **[superpowers/](superpowers/README.md).** The engineering record: how the
  larger pieces were designed and what actually shipped. Start with
  [testing.md](superpowers/testing.md) before changing anything — it covers the
  determinism pins, the four-tier suite, and the harness constraints.

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
