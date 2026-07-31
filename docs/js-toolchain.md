# JS/TS toolchain detection

A JavaScript/TypeScript project's formatter and linter are detected from its own
config files and dispatched to. Prettier no longer runs unconditionally.

This is the whole record: what was broken, how it works, what was decided and
rejected, what ships imperfect, and how to diagnose it.

## The defect

Saving a `.ts` file rewrote single quotes to double in projects whose style rules
say single. Reproduced against `~/projects/errno`, which sets its quote rule in
ESLint and has no prettier config:

```
~/projects/errno/.eslintrc.js:16    '@stylistic/quotes': ['error', 'single']

$ prettier --find-config-path src/is-errno.ts
[error] Can not find configure file for "src/is-errno.ts".

$ cat src/is-errno.ts | prettier --stdin-filepath …/src/is-errno.ts
import { Errno, isErrnoSymbol } from "./errno";
```

Three facts composed: `config/formatters.lua` sent every web filetype to
`{ prettierd, prettier }` unconditionally; conform never asked whether prettier
was configured (`require_cwd` defaults to `false`); and prettier's default is
`singleQuote: false`. With no project config, prettier's default beat the
project's real rule — which lived in ESLint, a tool nothing here ran.

Not a submodule bug: it reproduces in a standalone repo. A repo carrying
`prettier.config.mjs` was never affected.

## How detection works

`config/js_toolchain.lua` walks up from the buffer, listing each directory once,
and fills two independent slots. Nearest config wins; ties inside one directory
break by table priority — so a package with its own `.prettierrc` inside a
biome-rooted monorepo formats with prettier.

**Formatter** — gates whether conform runs a tool:

| # | Tool | Markers |
|---|---|---|
| 1 | biome | `biome.json`, `biome.jsonc`, `.biome.json`, `.biome.jsonc` |
| 2 | dprint | `dprint.json`, `.dprint.json`, `dprint.jsonc`, `.dprint.jsonc` |
| 3 | oxfmt | `.oxfmtrc.json`, `.oxfmtrc.jsonc`, `oxfmt.config.ts` |
| 4 | prettier | the `.prettierrc*` / `prettier.config.*` family, or a `"prettier"` key in `package.json` |
| 5 | eslint | the `eslint.config.*` / `.eslintrc*` family, or an `"eslintConfig"` key in `package.json` |

**Linter** — gates whether biome/oxlint's server starts, or `eslint_d` runs:

| # | Tool | Markers |
|---|---|---|
| 1 | biome | `biome.json`, `biome.jsonc`, or `package.json` text matching `biomejs` |
| 2 | oxlint | `.oxlintrc.json`, `.oxlintrc.jsonc`, `oxlint.config.ts`, `package.json` text matching `oxlint`/`vite-plus`, or a `vite.config.ts` mentioning both `vite-plus` and `lint:` |
| 3 | eslint | same as the formatter eslint row |

The tables are not one list under two names. FORMATTER mirrors what conform's
builtins accept; LINTER mirrors what each language server's own root resolution
accepts, because the server — not conform — decides whether it starts. They
diverge both ways: conform's biome formatter accepts `.biome.json` and
lspconfig's resolver does not, so a repo using only that file gets biome
formatting with eslint diagnostics. A marker set narrower than the tool's own
rules declines to run a tool the project considers configured; a set wider than
the server's silences `eslint_d` while no server attaches.

### The two `package.json` probes differ on purpose

Collapsing them into one "cleaner" helper reintroduces a real bug.

The prettier and eslint rows do a **top-level key lookup** on decoded JSON,
because those keys genuinely are top-level conventions and it is how conform's
own `prettierd.lua` reads the file.

The biome and oxlint linter rows **scan raw text line by line**, because that is
literally what lspconfig does — `root_markers_with_field`
(`lua/lspconfig/util.lua`, currently 61-98; named because line numbers drift)
iterates `file:lines()` and calls `line:find(pattern)`, unparsed. So `biomejs`
matches the devDependencies line `"@biomejs/biome": "^2.5.5",`, not a key that
essentially never exists.

Under key lookup, a project depending on `@biomejs/biome` without a `biome.json`
resolves `linter = "eslint"`, `eslint_d` runs, and biome's server attaches anyway
on its own logic — duplicate diagnostics. Text matching is coarse, but that
coarseness belongs to the servers; disagreeing with the component that decides
attachment is what produces the double-lint.

### The boundary: `.git`'s type decides

The walk stops when both slots fill, or at a repo boundary — and "boundary" is
not simply "nearest `.git`".

A `.git` **directory** is a standalone repo and always ends the walk, so
`~/.config/nvim` and `~/projects/tusk` (a Go repo, hundreds of markdown files, no
`package.json`) terminate at their own root instead of climbing to `/`, where a
stray `~/.prettierrc` would govern them.

A `.git` **file** is a submodule, and there the `package.json` gate applies:
`lola-workspace/lola-web` has one, so it is sealed from its superproject;
`germanamz/content/posts` does not — a vendored markdown subtree, not an
independent package — so it keeps inheriting from its parent.

Without the distinction, either vendored subtrees stop inheriting or independent
packages keep walking into a superproject that knows nothing about them.

### When nothing is detected

An unresolved formatter slot returns an **empty** chain, and `lsp_format` is
forced to `"never"` on **every** JS/TS chain — resolved or empty — per-filetype
rather than globally. The global `lsp_format = "fallback"` is load-bearing
elsewhere: it is what lets Lua fall through to `lua_ls` when `stylua` is absent.
Without the per-filetype override an unconfigured JS/TS buffer would fall through
to `ts_ls`'s formatter — the same unwanted-default problem one layer down.

An unresolved linter slot is simpler: biome and oxlint never start (their wrapped
`root_dir` declines to call `on_dir`), and the `BufWritePost` hook never fires
`try_lint`. Nothing tries to compensate for that silence — see the gating rule.

## The rules that shaped this

### Gate on "configured", never on "will handle this file"

The one rule behind every decision here, reached the hard way.

Biome's default filetype list covers `json`, `jsonc`, `css` and `graphql` beyond
js/jsx/ts/tsx, overlapping `jsonls`, `cssls` and `graphql` — which sounded like
an argument for standing those servers down whenever biome owns a project.
Rejected after verifying against real biome 2.5.5 that a `biome.json` can disable
a language independently of owning the project: both
`{"css":{"linter":{"enabled":false}}}` and
`{"files":{"includes":["**","!**/*.css"]}}` make biome skip `.css` entirely, no
error. Standing `cssls` down "because biome owns this project" leaves those files
with **no linter at all** — a silent coverage hole, worse than the duplicate
diagnostics it prevents.

Every tool already scopes itself and declines quietly, verified:

| Tool | Out-of-scope file | Result |
|---|---|---|
| `prettierd` | in `.prettierignore` | returns input unchanged |
| `eslint_d` | matched by flat-config `ignores` | returns input unchanged, exit 0, silent |
| `biome` | excluded or language-disabled | skips it |

Two tools both running is harmless — one no-ops. One tool standing down because
it assumes another covers the file is not, because that assumption can be wrong
in ways nothing here can observe from outside. **If you find yourself proposing
"stand down X because Y owns this project" for any pair, it has been tried and
rejected.**

The overlap was removed from the other side instead: biome's `filetypes` is
narrowed to js/jsx/ts/tsx, exactly as the `graphql` server is narrowed off
tsx/jsx. That is a **static per-server list**, not a conditional stand-down —
`jsonls` and `cssls` still attach unconditionally, so no file loses a linter
under any project configuration.

### The version warning reads the library, not the binary

`config/js_tool_version.lua` warns once per session when the formatter actually
running has a different **major** than the project's `package.json` pin —
prettier 3 changed `trailingComma` to `"all"`, so the wrong major produces diffs
the project's CI rejects.

The subtlety is what "actually running" means for a daemon. Mason's `prettierd`
0.28.0 **bundles its own prettier 3.9.0** (at
`…/prettierd/node_modules/@fsouza/prettierd/node_modules/prettier`, nested under
`@fsouza`), which is a different number from mason's standalone `prettier`
3.8.3. `prettierd --debug-info <file>` prints two version lines — the daemon's
first, then `prettier version: 3.9.0`. Taking the first semver reports `0.28.0`
and warns wrongly on essentially every project. The parser prefers the labeled
line and falls back to a bare match only when the label is absent. Same shape for
`eslint_d`: its `--version` reports a static bundled number, so the probe uses
`eslint_d status`, which resolves the project's local eslint.

The probe is **asynchronous** and has to be — its caller runs inside
`BufWritePre`, and waiting froze the editor up to 2s per candidate (4s for
prettier, which falls through `prettierd` to `prettier`). The first save in a
pinned project only reads `package.json`; the warning arrives from the callback.
One save late, never a stall. Cached per root+tool for the session, negatives
included, with a 2000ms cap so a hung binary cannot leak a child or accumulate a
closure per save.

A tool is only checked if it is in the `PACKAGES` map (`prettier`, `eslint`,
`biome`). `oxfmt` and `dprint` are deliberately absent — their npm package names
were never verified against a real install, and a wrong guess looks up a key that
never matches, making the check invisibly dead. Absence means "not yet safe to
check", not "these never drift".

## Decisions

| Question | Decision |
|---|---|
| Scope | Formatting **and** lint diagnostics |
| Model | Two independent slots, resolved separately |
| Diagnostics transport | biome/oxlint as language servers; ESLint via one shared `eslint_d` through nvim-lint on save |
| Empty formatter slot | Leave the buffer alone; `lsp_format = "never"` |
| Search boundary | `.git` directory ends the walk; `.git` file only when the dir has `package.json` |
| Binaries | Local-first, mason fallback, warn once per root on major mismatch |
| Filetype coverage | Only the four JS/TS filetypes are slot-driven |
| Linter root gating | biome/oxlint `root_dir` wrapped so detection governs whether they start |
| biome filetypes | Narrowed to js/jsx/ts/tsx to remove the `jsonls`/`cssls`/`graphql` overlap |

**Rejected:** standing overlapping servers down when biome owns a project (see
the gating rule); passing `--config` to enforce the boundary (gating *is* the
enforcement — an ancestor config only leaks if we launch the tool); Deno;
`standard`/`semistandard`; ESLint as a language server (Node, one process per
root — `eslint_d` is one daemon for the whole workspace); lint on `InsertLeave`.

## What shipped, and where

`config/js_toolchain.lua` owns detection, the marker tables, the walk, the
boundary, per-directory memoization (`_clear()`), and `gate_root_dir`.
`util/project.lua` holds the `is_root` predicate shared with `config/lsp_root.lua`.
`config/js_tool_version.lua` owns the drift warning. `config/formatters.lua` wires
the JS/TS `by_ft` entries to the formatter slot. `plugins/lsp.lua` registers the
gated `biome`/`oxlint` servers. `plugins/nvim-lint.lua` runs `eslint_d` on
`BufWritePost` when the linter slot is `eslint`.

Cache invalidation is split and both halves matter: `plugins/conform.lua` drops
the cache when a marker file or `package.json` is written, so adding a config
takes effect on save; `config/dir_cache.lua` drops it on `DirChanged` and on a
`.gitmodules` write, since the cwd moving changes where an unnamed buffer
resolves and `git submodule add`/`deinit` moves the boundary. `<leader>gR` is the
manual hatch.

Two defects were fixed in passing:

- **conform ran two formatters per save.** `stop_after_first` defaults to
  `false`, so `{ prettierd, prettier }` ran *both* on every web-filetype save
  against a 1000ms budget. Now set on all thirteen filetypes.
- **`make sync` installed nothing and reported success**, two independent ways.
  `mason-tool-installer` is lazy on `BufReadPre`/`BufNewFile`, so a headless
  `+MasonToolsInstallSync` with no file never loaded it (E492, exit 0) — and
  `InstallSync` passes `force_update=false`, honouring `debounce_hours=24`, so
  it no-ops if any nvim checked that day. `scripts/mason-sync.lua` now does an
  explicit `Lazy! load`, uses `MasonToolsUpdateSync`, and refuses when the
  lockfile is missing (an empty `ensure_installed` makes the sync loop hang
  forever). It cannot drift past the lockfile: every entry is pinned, and
  `force_update` is consulted only on the unpinned path.

## Known limitations and accepted residuals

**Partial biome adoption.** Only the four JS/TS filetypes are slot-driven; the
other nine keep unconditional prettier. So a biome repo formats `.ts` with biome
while `.json` and `.css` keep using prettier, which can produce diffs biome's CI
rejects. Fixing it needs a per-tool filetype-capability table, unknowable for
`dprint` — its capabilities depend on which plugins the project installs. Gating
those nine would also regress a case that was never broken: `~/projects/tusk` is
a Go repo with hundreds of markdown files and no `package.json`.

**First save in an eslint project may come back unformatted.** `eslint_d`
cold-starts per project — loading ESLint, resolving the flat config, building
rules — which can exceed the 1000ms budget. The second save formats.
`:ConformInfo` still shows `eslint_d` resolved; this is warm-up, not misdetection.

**Both halves must ask `eslint_d` about the same project.** It caches one ESLint
instance per cwd and starts flat-config lookup there, so `plugins/nvim-lint.lua`
passes `cwd` = nearest `package.json` **above the buffer**, matching conform's
builtin. With a superproject open and the buffer in a submodule, nvim-lint's
default (editor cwd) resolves a different project — and fails invisibly, since
"could not find config file" arrives as an empty diagnostic list. When there is
no `package.json` above the buffer the two halves still diverge: nvim-lint uses
the buffer's directory, conform lands on the editor's cwd.

Smaller accepted items: the version probe's bare-semver fallback is not scoped
per command, so if `prettierd` ever exits 0 without its label the daemon version
would be regrabbed; that fallback fires on any probe failure, not narrowly
ENOENT; `resolve()` returns its cached table by reference (audited — no consumer
mutates it); `config/lsp_root.lua:50` still uses `vim.uv.cwd()` where detection
now uses `vim.fn.getcwd()`; and the `oxfmt`/`dprint` marker lists were never
verified against those tools' real discovery rules — being too narrow only means
"don't run", the safe direction.

## Diagnosing a buffer

Ask detection directly:

```
:lua vim.print(require("config.js_toolchain").resolve(0))
```

That prints `formatter`, `linter`, and the directory (`root`) where the **first**
marker was found — not necessarily where the walk stopped. `resolve()` sets
`root` on the first hit and never moves it, while the walk keeps climbing for the
unfilled slot. It matters because the pin check reads `package.json` from that
same `root`.

- **`:ConformInfo`** — which formatters resolved, and which ran last. An
  unconfigured JS/TS project lists none. It never displays `lsp_format`, and it
  prints an `LSP: <client>` line whenever a format-capable server is attached,
  computed independently of our setting — so an unconfigured TypeScript project
  shows `LSP: ts_ls`. That line is informational, **not** a sign the LSP will
  format; it won't, because `lsp_format = "never"`. `<none>` appears only when
  there is neither a formatter nor a format-capable client.
- **`prettier --find-config-path <file>`** — whether prettier itself believes it
  has a config. Distinguishes "genuinely unconfigured" from "the walk missed a
  marker".
- **`:checkhealth lsp`** — whether `biome` or `oxlint` actually attached, versus
  neither attaching and `eslint_d` running through nvim-lint instead.

## Tests

Unit specs cover detection and version parsing; smoke specs cover the nvim-lint
wiring; `tests/spec/e2e/format_on_save_spec.lua` drives a real conform save to
pin the defect — an unconfigured project comes back byte-identical, a configured
one honours its `.prettierrc`.

Run with the sandbox disabled and `~/.local/share/nvim/mason/bin` on `PATH`;
without mason the prettierd probe cases self-skip and the real async path is
never exercised. E2E cases must not open JS/TS files with `:edit` — after the
first isolated env that errors mid-`BufReadPost` on a stale `lsp.log` path and
leaks into the next spec; build buffers via the API instead.
