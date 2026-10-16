---
type: memory
title: "Ts_ls ran wrong TypeScript in pnpm monorepos"
kind: project
description: "ts_ls silently ran mason's bundled TypeScript (a newer major) instead of the project's in pnpm monorepos; fixed by config.lsp_tsdk buffer-relative resolution."
---

# Ts_ls ran wrong TypeScript in pnpm monorepos

typescript-language-server picks its TS library with an **upward-only** walk from
`root_dir` (`findPathToModule` over `node_modules/typescript/lib`,
`.vscode/pnpify/…`, `.yarn/sdks/…`), then silently falls back to its **bundled**
copy. lspconfig roots ts_ls at the nearest **lockfile** = the pnpm workspace
root, but pnpm installs `typescript` in the **leaf package** below it — never on
the upward path. Result: mason's bundled TS type-checked a project pinned
to an older major.

Fixed 2026-07-29 in `lua/config/lsp_tsdk.lua` (+ wiring in `lua/plugins/lsp.lua`,
specs in `tests/spec/unit/lsp_tsdk_spec.lua`, writeup in
`docs/lsp-typescript-version.md`): resolve from the **buffer's** dir upward,
bounded at root_dir, pass via `initializationOptions.tsserver.path`. `root_dir`
is *wrapped* not replaced — it's the only moment `(bufnr, dir)` are both in hand;
answer memoized under the root, drained by `before_init`.

**Multi-monorepo semantics (verified 2026-07-29):** one ts_ls client per
`root_dir`, so each monorepo gets its own client + its own TypeScript + correct
per-package dep resolution (tsserver keeps a separate program per tsconfig even
within one process). Within one root the version is decided by the **last**
resolution before `before_init` — sequential opens make that the first buffer,
concurrent opens (`nvim -p`, session restore, telescope/quickfix multi-open) the
last. 6/6 deterministic each way. Clients are **never reaped** (no zero-buffer
autostop in nvim 0.12.4); `:lsp stop ts_ls` reaps, `:LspStop` doesn't exist.
~0.8–1.0 GiB phys_footprint per warm client, 4 node procs each.

**Remedies shipped 2026-07-29** (a design pass refuted ALL THREE first-cut
recommendations; the corrected package is smaller and adds no clients on healthy
repos): ATA off in `servers.ts_ls` (drops the typingsInstaller fork, 4→3 procs);
`lsp_tsdk.warn_mismatch` (one WARN per root when a buffer's package pins a
different **major**); `lua/config/lsp_root.lua` gated clamp (root never escapes the
buffer's repo, gated on tsconfig/jsconfig at the boundary); ledger-driven
divergent-package split in `wrap_root_dir`; `lua/config/lsp_reap.lua` MANUAL sweep
(`:LspReapIdle` / `<leader>lk` / end of `<leader>bad`).

**Rejected on measurement — do not re-propose:** per-package rooting everywhere
(1384→2942 MB on a homogeneous repo, xrefs 4→0); one canonical version per root
(makes the loser permanently wrong, kills `<leader>lr`); glob-based workspace
scanning in root_dir (a root `typescript` devDependency mis-pinned every package;
932 ms plan / 1040 ms first `:edit` on recursive `packages/**`); an AUTOMATIC idle
reaper (silently kills `lsp_fs_sync`'s rename import-rewrite — `on_will_rename`
needs a covering client ALIVE, not one with buffers); `useSyntaxServer='never'`
(0.85–1.6 s dead hover/completion per cold start); LRU client cap.

Split and warning must share the **major-only** threshold — a repo whose packages
differ only by a TypeScript minor changes no diagnostic and splitting costs +508 MB, so warning
about it is an unactionable nag.

**Gotchas that cost time here:**
- The gate on the clamp is load-bearing: ungated, a git submodule vendored inside
  a TS project re-roots at
  itself, tsserver drops the file into an inferred project, false TS2307. Verified
  both ways.
- `bound()` must sit INSIDE `wrap_root_dir` (the memo is keyed by the clamped dir
  that `before_init` looks up); outside measured worse than not clamping.
- Two wrappers on one resolver need a shared re-wrap guard (`lsp_tsdk.is_wrapped`)
  or `:Lazy reload` stacks layers.
- `tsserver_in` falling off the end returned ZERO values, not nil — that makes
  `tostring(resolve(...))` raise "value expected" and silently turns
  `assert.is_nil(resolve(...))` into an argument-less call that cannot fail.
  Always `return nil` explicitly from a Lua finder.
- Fixture confound that cost the most time: symlinking a fixture package's
  `typescript` to **mason's own** typescript dir makes "(user-setting) project TS"
  and "(bundled) fallback" the same files, so the version log cannot distinguish
  fixed from broken. Use an independent install of the same version
  (e.g. another project's `node_modules/typescript` at mason's version) and confirm via the forked argv, not the version number.
- Both ends of the containment check must be realpath'd: `nvim_buf_set_name`
  reports `/private/var/…` on macOS while `root_dir` keeps `/var/…`.
- Probing tsserver with a **virtual (not-on-disk) file** puts it in an *inferred
  project* — globals vanish and it looks like a tsconfig bug. Always probe an
  on-disk file. Same reason unsaved new buffers legitimately lose tsconfig
  globals (`TS2580: Cannot find name 'process'`); it clears on `:w`. Not a config
  defect — tsserver builds project file sets from disk globs.
- Refuted: new files created on disk *after* project load resolve fine even with
  `didChangeWatchedFiles` off — tsserver has its own native watcher.

Probe technique that worked: a ~60-line stdio LSP client driving
`typescript-language-server` directly (a throwaway Node script), reading
`window/logMessage` for "Using Typescript version …". For end-to-end, headless
nvim + `ps -Ao args | grep -o '[^ ]*tsserver.js'` reveals which library forked.

See [[nvim-tree-git-perf-tiered]], [[lsp-stale-on-tree-delete-rename]].
