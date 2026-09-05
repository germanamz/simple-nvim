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
- **[python-diagnostics.md](python-diagnostics.md).** The `<leader>ld` picker for
  per-project pyright rule severities: why `typeCheckingMode = "basic"` does
  nothing for annotated-but-sloppy codebases, which five rules Pydantic actually
  trips, and the silent aliasing trap in delivering per-root LSP settings.
- **[navigation-stack.md](navigation-stack.md).** Why `<C-o>` walks you back
  through everything you read after a `gd`, why the fix is `<C-t>` rather than a
  smarter `<C-o>` (every other editor reached the same conclusion), and the
  `<leader>j` picker over the whole hop chain.
- **[lsp-fs-sync.md](lsp-fs-sync.md).** Why deleting or renaming files from the
  file tree sent gopls and ts_ls into error storms with watchers off, and the
  in-editor notification path that replaces them.
- **[external-changes.md](external-changes.md).** What happens when something
  outside nvim rewrites a file you have open: why `'autoread'` on its own never
  fired, why a bare `:checktime` misses exactly the buffers that go stale, why
  `<leader>lr` could not clear a diagnostic no matter how often you pressed it,
  and the git caches a working-tree write cannot move.
- **[minuet-stale-guard.md](minuet-stale-guard.md).** Why AI ghost text was
  painted against a buffer it no longer fit and then never corrected, why a
  *faster* local model makes that worse rather than better, and the two-part fix
  (trailing-edge pacing plus a buffer-freshness guard) that neither half achieves
  alone.
- **[ai-accept-multicursor.md](ai-accept-multicursor.md).** Why accepting an AI
  suggestion with several cursors alive put the text at one cursor only, why
  `<Esc>` never caught the others up (multicursor replays the *redo record*, and
  an API buffer edit never enters it), and the one-primitive swap that fixes it.
- **[js-toolchain.md](js-toolchain.md).** How a JavaScript/TypeScript project's
  formatter and linter are detected, why prettier no longer runs in projects that
  never configured it, and how to diagnose which tool owns a buffer. Also the
  full decision record: what was rejected and why, and what ships imperfect.
- **[openfga.md](openfga.md).** OpenFGA `.fga` models: the out-of-tree
  treesitter parser, the vendored queries, and the model-aware completion
  source that stands in for a language server.
- **[tiltfile.md](tiltfile.md).** Tiltfiles: the starlark parser registered for
  the `tiltfile` filetype, the ftplugin the runtime lacks, and why the language
  server is the `tilt` on `PATH` rather than a mason install.
- **[zig.md](zig.md).** Zig: why `.zon` inherits the whole Zig toolchain from one
  core filetype mapping, what each half of that toolchain then does with a
  `build.zig.zon` (they disagree), why there is no lint pass, and the version
  coupling between a mason-pinned `zls` and the `zig` on `PATH`.
- **[comments.md](comments.md).** Enter continues a comment in every code
  filetype (Go's bundled ftplugin never did), Enter on the empty leader ends
  it, and `gqc` reflows a comment block: the one thing `gq` could not do while
  conform owned `formatexpr`, and why `gqip` must not be used for it.
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
