# ts_ls runs the wrong TypeScript in pnpm monorepos

Root-cause analysis (2026-07-29) of: "types resolution breaks in large git
workspaces with 200+ submodules; shared tsconfigs don't resolve for the right
language version". Reproduced against `~/projects/lola-workspace` (superproject;
`lola-web` = pnpm monorepo) and a synthetic superproject fixture. Includes the
shipped fix and the two symptoms that turned out **not** to be this bug.

## Confirmed root cause

`typescript-language-server` chooses its TypeScript library with an
**upward-only** walk from `root_dir`
(`findPathToModule` over `MODULE_FOLDERS` = `node_modules/typescript/lib`,
`.vscode/pnpify/typescript/lib`, `.yarn/sdks/typescript/lib`; see
`lib/cli.mjs`). If nothing is found it silently uses its own **bundled** copy.

nvim-lspconfig roots `ts_ls` at the nearest **package-manager lockfile** — for
pnpm that is the workspace root. pnpm's isolated `node_modules` installs
`typescript` in the **leaf package**, which is *below* that root:

```
lola-web/                      <- root_dir (pnpm-lock.yaml)
  node_modules/                <- eslint only; NO typescript
  apps/lola-web/
    node_modules/typescript -> ../../../node_modules/.pnpm/typescript@5.9.3/...
    tsconfig.json
```

The leaf install is never on the upward path, the walk falls off the top of the
tree, and ts_ls uses the bundled TypeScript instead.

### Evidence

- Ancestor scan from `lola-web` up to `/` finds **no** `node_modules/typescript/lib`
  in any of the three module folders.
- Mason's `typescript-language-server` bundles TypeScript **6.0.3**;
  `lola-web` pins **5.9.3** — a major version apart.
- Direct LSP handshake at `rootUri = lola-web`:
  `Using Typescript version (bundled) 6.0.3 from path ".../mason/.../typescript/lib/tsserver.js"`.
- Real headless Neovim with this config, opening
  `lola-web/apps/lola-web/app/page.tsx` from the superproject cwd: the forked
  process was mason's `.../typescript/lib/tsserver.js`, and `root_dir` was
  `lola-web` as expected.
- Editor/build divergence on a shared base config: a `@repo/tsconfig/base.json`
  using `target: es5` + `moduleResolution: node` builds clean under the project's
  own 5.9.3 (`tsc` exit 0) but fails under 6.0.3 (`exit 2`, two `TS5107`
  deprecation errors).

Superprojects don't change the mechanism, they raise the odds: every submodule
pins its own TypeScript, so the more submodules, the likelier any given buffer is
being checked by a compiler the project never chose.

## The fix

`lua/config/lsp_tsdk.lua` + wiring in `lua/plugins/lsp.lua`.

Resolve the library from the **buffer's** directory upward — which reaches the
leaf package — and hand ts_ls the answer as
`initializationOptions.tsserver.path`, the setting its own
`getUserSettingVersion()` honors ahead of everything else.

Design points worth keeping:

- **`root_dir` is wrapped, not replaced.** lspconfig keeps owning root detection
  (including its deno exclusion); we only observe the `(bufnr, dir)` pair it
  settles on, because that is the one moment both are in hand. The answer is
  memoized under the root and drained by `before_init`.
- **The search stops at `root_dir`.** ts_ls already walks above the root on its
  own; a stray `~/node_modules/typescript` is unrelated to the project. No hit
  means we send nothing and ts_ls keeps its documented fallback — so the change
  can only improve on the old behaviour, never regress it.
- **Both ends of the containment test are realpath'd.** `nvim_buf_set_name`
  reports `/private/var/…` on macOS while `root_dir` keeps `/var/…`, and
  symlinked package dirs are the norm in these monorepos. Without this the walk
  gives up immediately.
- **One TypeScript per client — and "last resolution wins", not "first file".**
  tsserver hosts one library per process and Neovim starts one client per
  `root_dir`, so a monorepo whose packages pin different versions runs exactly one
  of them for every package under that root. Which one is decided by the last
  `root_dir` resolution written before that client's `before_init` runs. Client
  creation is deferred, so opening files one at a time (waiting for each attach)
  makes that the *first* buffer, while a concurrent open resolves every buffer
  before any client starts and the *last* one wins. Measured, 6/6 deterministic
  each way (see "Multiple monorepos" below).
- **The memo is a handoff, not a cache.** `root_dir` records its answer for the
  root — `nil` included — and `before_init` sends it. Recording `nil` matters:
  otherwise a package with no `typescript` of its own silently inherits whatever
  a sibling resolved earlier in the session, so the compiler depends on which
  files you happened to visit first and survives client restarts. The trade-off
  is explicit: a package with no install of its own now falls back to ts_ls's
  bundled TypeScript rather than borrowing a sibling's. That is the honest
  answer for it, and it is controllable (open the package whose version you want
  and `<leader>lr`), whereas sticky session state is not.

### Verification

- `tests/spec/unit/lsp_tsdk_spec.lua` — 14 specs: pnpm leaf install, plain repo
  root, nearest-wins, yarn PnP sdk, partial install, the root bound, and the
  `before_init` memo.
- Real headless Neovim after the fix, both fixture and `lola-web`: the forked
  process is now the project's `apps/*/node_modules/typescript/lib/tsserver.js`.
- Full suite `make test`: 732 pass / 0 fail. `make test-lsp` passes.

## Multiple monorepos in one workspace

Verified on a synthetic superproject with four submodules: two pnpm monorepos
(one with packages pinning 5.9.3 and 6.0.3 respectively), a plain npm repo with
TypeScript at its root, and a submodule with no lockfile at all.

**What works.** Resolution is per repository and correct. Opening a file in each
of three repos produced three independent ts_ls clients — one per lockfile root —
each forking *its own* project's TypeScript (the server itself reporting
`(user-setting)`, from a leaf path below the pnpm root), with clean diagnostics.
Dependency isolation is exact in both directions: each package's own import
resolves and `textDocument/definition` lands on the dep that package's
`node_modules` resolves to, while importing a *foreign* package's dep errors
`TS2307` — including between two packages that **share one client and one
tsserver process**, because tsserver keeps a separate program per tsconfig. One
client per `root_dir` does not merge module-resolution scopes.

**Mixed versions inside one monorepo are genuinely wrong, not cosmetic.** With
`apps/a1` on 5.9.3 and `apps/a2` on 6.0.3 under one root, the single client runs
one of them for both. Using a `Temporal` reference (present only in 6.0.3's
`lib.esnext`), the 5.9.3 client put a **false** `TS2304` on a2 that a2's own
`tsc` accepts, and the 6.0.3 client **swallowed** a real `TS2304` on a1 that a1's
own `tsc` reports. `<leader>lr` does re-resolve from the current buffer, with two
caveats: it detaches every *sibling* buffer under that root and they do not
re-attach on their own (`:edit` makes them rejoin the surviving client), so only
one package under a mixed-version root can be correct at a time.

**A stray lockfile can capture a lockfile-less submodule.** `vim.fs.root`'s
nested marker groups mean "nearest lockfile *anywhere* up to `/`" outranks
"nearest `.git`". With no lockfile above it, `repoD`'s root lands correctly on
the submodule, anchored by its `.git` **file** (a regular file, which
`vim.fs.root` does match). But a single `pnpm-lock.yaml` at or above the
superproject root pulls every lockfile-less submodule into **one** client rooted
over the whole tree. Submodules with their own lockfile are unaffected
(nearest-within-group still wins). Two things this module cannot fix: ts_ls's own
upward walk runs *past* `root_dir` and will adopt a stray ancestor
`node_modules/typescript` regardless of our bound, and lspconfig's `cmd` executes
`<root>/node_modules/.bin/typescript-language-server` if present — a planted
script there did run.

**Cost, measured.** Each client is 4 node processes: the
`typescript-language-server` bridge, a `--serverMode partialSemantic` syntax
server, the full semantic server, and a `typingsInstaller.js` the semantic server
forks. Four clients = 16 processes. Per warm client on *real* repos
(~300 TS files) ≈ 0.8–1.0 GiB `phys_footprint`; a second package inside the same
monorepo is **not** free (~+200 MiB). Quote `phys_footprint`, not summed RSS,
which is non-monotonic as node GCs. Extrapolating linearly — stated as
extrapolation, not measurement — ~8–10 GiB at 10 roots, ~20–25 GiB at 25, over
32 GiB at 50.

**Clients are never reaped.** nvim 0.12.4 has no zero-buffer autostop: after
`:bwipeout` of every buffer of a root, the client sat at `attached_buffers=0`
with all 4 processes alive for the full 3 minutes watched. The only
`client:stop()` sites in the runtime are `VimLeavePre`,
`vim.lsp.enable(name, false)`, deprecated `stop_client`, and an explicit
`Client:stop()`. `:lsp stop ts_ls` does reap them (17 node procs → 1); there is
no `:LspStop` in this version. On a large workspace, browsing many monorepos in
one session accumulates clients until you quit or stop them by hand.

## What was done about the limitations

Shipped after a design pass in which **all three initial recommendations were
refuted** by adversarial review and replaced by smaller, corrected ones. The
package deliberately does not multiply clients.

**Automatic Type Acquisition off** (`servers.ts_ls.init_options`). tsserver
otherwise forks a fourth node process per client to fetch `@types` for untyped JS
deps. Verified: the `typingsInstaller.js` fork is gone on `wedds`, `digitt` and
`lola-web` (4 → 3 processes per client) with no diagnostic change. Every project
here declares its `@types`, so ATA only ever bought completions for untyped JS
dependencies — which is what it forfeits.

**A per-buffer mismatch warning** (`lsp_tsdk.warn_mismatch`, wired from the
`LspAttach` ts_ls branch). One `vim.notify` WARN per `(root, got, want)` when a
buffer is served by a TypeScript whose **major** differs from the one its own
package pins. Compared by version, never by path — pnpm gives every package its
own symlink, so a path comparison fires on every healthy monorepo. Verified
firing once on a mixed fixture and staying silent on `digitt` (homogeneous),
`lola-web` (single install) and `expenses` (minor drift only).

**A gated root clamp** (`lua/config/lsp_root.lua`) — see the section above.

**A divergent-package split** (`lsp_tsdk.wrap_root_dir`). When a client for this
root already runs a different **major**, the package gets its own client rooted at
its own tsconfig. Driven by the ledger and the buffer's own resolution, never by
enumerating workspace globs: the glob version was refuted four ways, worst being
that a root-level `typescript` devDependency (a mainstream layout with no problem
at all) pinned every package to it and produced two brand-new false errors, plus
a measured 932 ms `plan()` and 1040 ms first `:edit` on a recursive `packages/**`
tree. Verified: on a major-gap fixture both packages get their own compiler in
either open order and the warning goes silent; `digitt`, `lola-web` and
`expenses` all stay at one client.

Major-only is the threshold for both the split and the warning, and they must
agree — `expenses` (5.6.2 vs 5.5.4) changes no diagnostic and splitting it costs a
measured +508 MB, so warning about it would be an unactionable nag.

**A manual idle-client sweep** (`lua/config/lsp_reap.lua`, `:LspReapIdle` /
`<leader>lk`, plus a call at the end of `<leader>bad`). Verified 3 clients / 9
processes → 0 / 0 through `<leader>bad`.

### Deliberately not done

- **Rooting ts_ls per package everywhere.** Measured 1384 → 2942 MB on a
  homogeneous real repo for zero correctness gain, 200 roots on a 200-package
  workspace, cross-package find-references 4 hits → 0, and install-less packages
  demoted to the bundled compiler.
- **One canonical version per root.** Makes the losing package *permanently*
  wrong (a real TS2503 swallowed in 4/4 open orders) and kills `<leader>lr`, the
  only escape hatch — which also falsifies the warning's own advice.
- **An automatic idle reaper.** It silently destroys `config.lsp_fs_sync`'s rename
  import-rewrite: `on_will_rename` sends `workspace/willRenameFiles` to every
  client whose root covers the path and never requires attached buffers, so a
  bufferless-but-alive client rewrites importers today and a reaped one does
  nothing. It is also a no-op in the session shape that actually accumulates
  (`hidden` is never overridden, so buffers never unload and every client stays
  "in use"). **Residue:** the manual sweep can still strip a covering client, and
  with the split in play `root_covers` may report a surviving client that answers
  no edits — so the loss is not always detectable. The `notify_once` guard in
  `on_will_rename` covers the "no server at all" case only.
- **`tsserver.useSyntaxServer = 'never'`.** Buys 166 MiB/client and costs
  0.85–1.64 s of dead hover / completion / documentSymbol / foldingRange on every
  cold start, growing with project size. Its re-warm evidence was an artifact —
  diagnostics always route to the semantic server, so time-to-first-diagnostic is
  structurally blind to it.
- **An LRU client cap.** Charges a ~1.4 s re-warm while your buffers are still
  open, and eviction strips diagnostics from live buffers until FileType re-fires.
- **`mdx_analyzer`'s hardcoded mason tsdk.** `.mdx` buffers keep the wrong-version
  exposure; it needs its own investigation rather than a copy of this plumbing.

### Unmeasured

Behaviour of the shipped package on the real 200-submodule superproject, and
whether its lockfile-less submodules carry a root `tsconfig.json` — which decides
whether the clamp fires there at all, and therefore its client-count cost. Git
worktrees (`.git` as a file with `gitdir:`) and `.git` inside `node_modules` are
unprobed against the gate; both look benign.

## Two symptoms this is *not*

Recorded so they aren't re-investigated as this bug.

- **New files on disk resolve fine.** With `didChangeWatchedFiles` disabled
  config-wide (the superproject perf tradeoff in `lua/plugins/lsp.lua`), a file
  created on disk *after* the project loaded still gets full types within
  seconds — tsserver runs its own native watcher. Refuted as a cause.
- **Unsaved new buffers genuinely lose tsconfig globals — and that is tsserver
  semantics, not a config defect.** tsserver builds a configured project's file
  set from the tsconfig's `include` globs *against disk*. A buffer with no file
  on disk can't match, so it lands in an **inferred project** with default
  compiler options: no `lib`, no `types`, no `paths`. Reproduced in real Neovim —
  a new `src/brand_new.ts` buffer reports
  `TS2580: Cannot find name 'process'`, and the diagnostic clears the moment the
  buffer is written. nvim users hit this far more than VS Code users because
  `:e path/new.ts` names a buffer without creating the file. **Workaround: `:w`
  once, early.**

## Not fixed, deliberately

`mdx_analyzer` hardcodes `init_options.typescript.tsdk` to mason's bundled
TypeScript (`lua/plugins/lsp.lua`), so `.mdx` buffers have the same
wrong-version exposure. Left alone: mdx_analyzer wraps tsserver and may depend
on the version it ships with, and there is no `.mdx` project here to verify a
change against.
