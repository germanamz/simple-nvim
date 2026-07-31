# JS/TS toolchain detection

How a JavaScript/TypeScript project's formatter and linter are detected from
its own config files, why prettier no longer runs unconditionally, and how to
tell which tool is actually handling a buffer.

## The defect

Saving a `.ts` file used to rewrite single quotes to double quotes in projects
whose style rules say single. Reproduced end to end against
`~/projects/errno`, which sets its quote rule in ESLint and has no prettier
config at all:

```
~/projects/errno/.eslintrc.js:16    '@stylistic/quotes': ['error', 'single']
~/projects/errno/src/is-errno.ts:1  import { Errno, isErrnoSymbol } from './errno';

$ prettier --find-config-path src/is-errno.ts
[error] Can not find configure file for "src/is-errno.ts".

$ cat src/is-errno.ts | prettier --stdin-filepath …/src/is-errno.ts
import { Errno, isErrnoSymbol } from "./errno";
```

Three facts compose into the failure: `lua/config/formatters.lua` sent every
web filetype to `{ "prettierd", "prettier" }` unconditionally; conform never
asked whether prettier was configured for the project (`require_cwd` defaults
to `false`, so a formatter with no resolved config still runs); and prettier's
own default is `singleQuote: false`. With no project config, prettier's
default wins over the project's actual style rule, which lives in ESLint —
a tool nothing in this config even ran. A repo that already carries a
`prettier.config.mjs` (`~/projects/digitt-credit-health`) was never affected;
this was purely a problem for projects that never opted into prettier.

The fix is `lua/config/js_toolchain.lua`: before formatting or linting a JS/TS
buffer, walk up from it and ask what the project itself configures, then
dispatch to that.

## Two slots, not one

A project's formatter and linter are frequently different tools — biome
formats while eslint lints, prettier formats while oxlint lints — so both are
resolved independently in a single upward directory walk from the buffer.
Each level is listed once; entries are tested against two ordered marker
tables, and the first hit in each table wins for that slot:

**Formatter** (gates whether conform runs a tool):

| Priority | Tool | Markers |
|---|---|---|
| 1 | biome | `biome.json`, `biome.jsonc`, `.biome.json`, `.biome.jsonc` |
| 2 | dprint | `dprint.json`, `.dprint.json`, `dprint.jsonc`, `.dprint.jsonc` |
| 3 | oxfmt | `.oxfmtrc.json`, `.oxfmtrc.jsonc`, `oxfmt.config.ts` |
| 4 | prettier | the `.prettierrc*` / `prettier.config.*` family, or a `"prettier"` key in `package.json` |
| 5 | eslint | the `eslint.config.*` / `.eslintrc*` family, or an `"eslintConfig"` key in `package.json` |

**Linter** (gates whether biome/oxlint's language server starts, or eslint_d
runs on save):

| Priority | Tool | Markers |
|---|---|---|
| 1 | biome | `biome.json`, `biome.jsonc`, or `package.json` text matching `biomejs` |
| 2 | oxlint | `.oxlintrc.json`, `.oxlintrc.jsonc`, `oxlint.config.ts`, `package.json` text matching `oxlint`/`vite-plus`, or a `vite.config.ts` that mentions both `vite-plus` and `lint:` |
| 3 | eslint | same as the formatter eslint row |

Nearest config wins; ties inside one directory break by table priority — a
package carrying its own `.prettierrc` inside a biome-rooted monorepo formats
with prettier, which is what that package's authors intended.

The two tables are not the same list under two names, and deliberately so.
FORMATTER mirrors what conform's own builtins accept; LINTER mirrors what each
language server's own root resolution accepts, because the server — not
conform — decides whether it starts. They diverge in both directions: conform's
biome formatter accepts `.biome.json`, which `nvim-lspconfig`'s biome resolver
does not, so a repo using only `.biome.json` gets biome formatting but eslint
diagnostics — and only if that repo also configures eslint; a repo with
neither resolves the linter slot to `nil` and nothing attaches. The oxlint
linter row, the other direction, accepts far more than `.oxlintrc.json`
(matching `nvim-lspconfig`'s own broader check), because a set wider than the
server's own rules would suppress `eslint_d` while no server actually starts —
the exact double-gap this design exists to avoid. A marker set narrower than
the tool's own rules means declining to run a tool the project considers
configured; a set wider than the server's own rules means silencing
`eslint_d` on the assumption a server will cover the file when it never
attaches.

## The two `package.json` probes are different on purpose

Both marker tables read `package.json`, but the formatter's prettier/eslint
rows and the linter's biome/oxlint rows probe it in different ways, and
collapsing them into one "cleaner" helper would reintroduce a real bug.

The prettier and eslint rows do a **top-level key lookup** on the decoded
JSON (`pkg.data["prettier"]`, `pkg.data["eslintConfig"]`), because that is
what those keys genuinely are — top-level configuration conventions — and
it's how conform's own `prettierd.lua` reads `package.json`.

The linter's biome and oxlint rows instead **scan the raw text line by line**
for a Lua pattern, because that is literally what `nvim-lspconfig` does: its
`root_markers_with_field` function (`lua/lspconfig/util.lua`, currently lines
61-98 — named here too, since exact line numbers drift with plugin updates)
iterates `file:lines()` and calls `line:find(pattern)` on every line,
unparsed. That's why the biome probe looks for the bare string `"biomejs"` —
it matches the **devDependencies** line `"@biomejs/biome": "^2.5.5",`, not a
top-level key, because a real project's `package.json` essentially never has
a top-level `"biomejs"` key.

If the linter rows used key lookup instead, a project that merely depends on
`@biomejs/biome` without a `biome.json` would resolve `linter = "eslint"`,
`eslint_d` would run through nvim-lint, and biome's language server would
*also* attach on its own root logic (it doesn't consult this module) —
duplicate diagnostics from two linters on every save. Matching by text is
coarse (a stray comment mentioning "oxlint" would also match), but that
coarseness belongs to the servers themselves; disagreeing with the component
that actually decides attachment is what produces the double-lint. Do not
"fix" this asymmetry — it mirrors two genuinely different tools' discovery
rules, not an oversight.

## The boundary: why `.git`'s type decides

The walk stops once both slots are filled, or at a repo boundary — but
"boundary" isn't simply "the nearest `.git`". A `.git` **directory** is a
standalone repository and always ends the walk: this config's own
`~/.config/nvim` and `~/projects/tusk` (a Go repo with hundreds of markdown
files, no `package.json`) both terminate at their own root rather than
climbing to `/`, where a stray `~/.prettierrc` would otherwise silently
govern them.

A `.git` **file** means a submodule, and there the answer depends on whether
that submodule is itself an independent JS package (does it have its own
`package.json`?). `~/projects/lola-workspace/lola-web` is a submodule with a
`package.json` — walking further up would only reach the superproject's
config, which the submodule's own toolchain has nothing to do with, so the
walk stops there. `germanamz/content/posts` is a submodule *without* a
`package.json` — a vendored markdown subtree, not an independent package — so
it correctly keeps inheriting whatever the parent project configures.

Without the directory/file distinction, every submodule boundary would behave
identically, and either markdown-only vendored subtrees would wrongly stop
inheriting their parent's config, or independent JS packages would wrongly
keep walking into a superproject that knows nothing about their toolchain.

## When nothing is detected

An unresolved formatter slot returns an **empty** conform chain, not a
fallback to some default tool. The buffer's `lsp_format` option is forced to
`"never"` on **every** JS/TS chain this dispatch returns — resolved or
empty — not just the unresolved case, and specifically per-filetype rather
than relying on this config's global default. That's necessary because the
global default (`lsp_format = "fallback"`, set once in `lua/plugins/conform.lua`)
is itself load-bearing elsewhere — it's what lets Lua fall through to `lua_ls`
when `stylua` isn't installed. Without the per-filetype override, an
unconfigured JS/TS project (or one whose resolved formatter binary simply
isn't installed) wouldn't stay untouched; it would silently fall through to
`ts_ls`'s own formatter, reformatting with tsserver's defaults instead of
prettier's — the same unwanted-default problem one layer down.

An unresolved linter slot is simpler: biome and oxlint's language servers
never start (their wrapped `root_dir` declines to call `on_dir`), and the
`BufWritePost` hook that runs `eslint_d` checks the same resolution and never
fires `try_lint`. No linter attaching is the correct outcome for a project
that configures none — see the gating principle below for why nothing tries
to compensate for that silence.

## The first save in an eslint project may come back unformatted

`eslint_d` is a daemon, and it cold-starts on its first invocation for a
project — loading ESLint, resolving the flat config, building the rule set.
That can take longer than conform's 1000ms format-on-save budget, so in an
eslint-formatted project the very first save after opening it may return
unchanged and the second one formats. This is a warm-up cost, not a broken
detection: `:ConformInfo` will still show `eslint_d` resolved for the buffer.

The linter half runs the same daemon and so shares the warm-up, with one
extra requirement: both halves must ask it about the *same* project.
`lua/plugins/nvim-lint.lua` therefore runs `eslint_d` with `cwd` set to the
nearest `package.json` **above the buffer**, matching conform's own
`eslint_d` builtin, rather than letting nvim-lint default it to the editor's
cwd. `eslint_d` caches one ESLint instance per cwd and starts flat-config
lookup there, so with a superproject open and the buffer inside a submodule
the default would resolve a different project entirely — and the failure is
invisible, since nvim-lint reports "could not find config file" as an empty
diagnostic list, indistinguishable from a clean file.

## Gate on "configured", never on "will handle this file"

The one rule that shaped every decision in this design: gate a tool's
participation on whether the **project configures it**, never on whether that
tool would actually handle a given file. It reads like an implementation
detail, but it was reached the hard way — biome's filetype list in
`lua/plugins/lsp.lua` (js/jsx/ts/tsx plus json/jsonc/css/graphql) overlaps
`jsonls`, `cssls` and the `graphql` server, which sounded like an argument for
standing those servers down whenever biome owns a project. That was rejected
after verifying, against real biome 2.5.5, that a `biome.json` can disable a
language independently of whether biome is otherwise "the project's
formatter/linter" — both `{"css":{"linter":{"enabled":false}}}` and
`{"files":{"includes":["**","!**/*.css"]}}` make biome skip `.css` files
entirely, with no error. Standing `cssls` down "because biome owns this
project" would leave those files with **no linter at all** — a silent
coverage hole, worse than the duplicate diagnostics it would have prevented.

The general shape held up under test against every relevant tool: `prettierd`
on a `.prettierignore`d file returns the input unchanged; `eslint_d` on a
flat-config-ignored file returns the input unchanged, exit code 0, no stderr;
biome on an excluded file skips it. Every one of these tools already scopes
itself and declines quietly when it doesn't apply. Two tools both attempting
to run on the same file is harmless — one of them no-ops. One tool standing
down because it assumes another tool covers the file is not harmless, because
that assumption can be wrong in ways this config has no way to observe from
the outside (a project's own `linter.enabled: false`, an `includes` exclusion,
an override block). If you find yourself proposing "stand down X because Y
already owns this project" for any pair of tools here, that proposal has
already been tried and rejected — reach for gating on configuration instead.

## The version warning reads the library, not the binary

`lua/config/js_tool_version.lua` warns once per session when the formatter
actually running for a project has a different **major** version than the one
the project's own `package.json` pins — prettier 3 changed `trailingComma` to
`"all"` and reflows markdown differently, so a save under the wrong major can
produce a diff the project's own CI rejects.

The subtlety is what "the version actually running" means for a daemon.
`prettierd` is a resident process that resolves and caches the **prettier
library** nearest the file it's asked to format — installed mason
`prettierd` 0.28.0 bundles its own prettier 3.9.0 at
`mason/packages/prettierd/node_modules/@fsouza/prettierd/node_modules/prettier`,
which is a different number from mason's separately-installed standalone
`prettier` (3.8.3). `prettierd --debug-info <file>` prints **two** version
lines: the daemon's own version first, then `prettier version: 3.9.0` — the
library that will actually format the file. Taking the first semver found in
that output reports the daemon's own 0.28.0 and produces a wrong warning (or a
wrong silence) for essentially every project, since 0.28.0 vs. any real
prettier pin always looks like a major mismatch. The parser therefore prefers
the labeled `prettier version:` line and only falls back to a bare
first-semver match when that label is absent (plain `prettier --version` has
no label at all). The same shape applies to `eslint_d`: its own `--version`
always reports its daemon version plus a static bundled-eslint number, neither
project-specific, so the probe uses `eslint_d status` instead, which reports
the project's actually-resolved local eslint.

The probe that reads that version is **asynchronous**, and has to be: its only
caller runs inside `BufWritePre`, and waiting on the subprocess froze the
editor there for up to two seconds per candidate command — four for prettier,
which falls through `prettierd` to plain `prettier`. So the first save in a
pinned project does nothing but read `package.json`, and the warning arrives a
moment later from the probe's own callback. One save late; never a stall. The
answer is then cached per root and tool for the session, so no later save pays
anything at all.

A tool only gets this check at all if it appears in `js_tool_version.lua`'s
`PACKAGES` map (currently `prettier`, `eslint`, `biome`). `oxfmt` and `dprint`
are deliberately absent — their npm package names were never verified against
a real installed copy, and a wrong guess there would silently look up a key
that never matches, making the check permanently, invisibly dead. Absence
here means "not yet safe to check," not "these tools never drift."

## Known limitation: partial biome adoption

Only the four JS/TS filetypes (`javascript`, `javascriptreact`, `typescript`,
`typescriptreact`) are slot-driven. `json`, `jsonc`, `css`, `scss`, `html`,
`yaml`, `markdown`, `mdx` and `graphql` keep the unconditional
`{ "prettierd", "prettier" }` chain regardless of what the project configures.
That means a repo that adopts biome gets its `.ts` files formatted by biome
while its `.json` and `.css` files keep formatting with prettier — which can
produce a diff biome's own CI rejects, since biome and prettier don't always
agree on formatting the same JSON.

This is accepted, not fixed, because fixing it properly needs a per-tool
filetype-capability table (which filetypes does *this* biome / dprint / oxfmt
installation actually format), and that table is unknowable in general for
`dprint` — its capabilities depend entirely on which plugins a given project
has installed into its `dprint.json`, not on the tool itself. Gating those
nine filetypes on JS-toolchain detection at all would also be wrong on its own
terms: the defect this whole feature fixes is prettier's JS-specific
`singleQuote` default, and withdrawing formatting from every markdown/YAML
file in a repo with no JS toolchain — `~/projects/tusk`, a Go repo with no
`package.json` at all — would regress a case that was never broken.

## Diagnosing a buffer

The fastest check is asking detection directly:

```
:lua vim.print(require("config.js_toolchain").resolve(0))
```

That prints the resolved `formatter`, `linter`, and the directory (`root`)
where the **first** marker was found — not necessarily where the walk
stopped. `resolve()` sets `root` the first time either slot gets a hit and
never moves it after, even though the walk keeps climbing past that point for
whichever slot is still unfilled. It matters because `js_tool_version`'s pin
check reads `package.json` from this same `root`, not from wherever the walk
eventually stopped. Still the most direct way to answer "why is this buffer
being formatted/linted this way" without inferring it from side effects.

Beyond that:

- **`:ConformInfo`** shows which formatters conform resolved for the current
  buffer and which one actually ran on the last format. For an unconfigured
  JS/TS project it lists no formatters — if it instead shows `prettier`, the
  formatter slot resolved to something other than expected (check for a stray
  ancestor config). Note that `:ConformInfo` never displays `lsp_format`, and
  that under "Formatters for this buffer" it prints an `LSP: <client>` line
  whenever a format-capable language server is attached, computed entirely
  independently of our setting (`conform/health.lua`). So an unconfigured
  TypeScript project shows `LSP: ts_ls` rather than `<none>` — that line is
  informational, **not** an indication that the LSP will format on save. It
  won't: `lsp_format = "never"` is set on every JS/TS chain this dispatch
  returns. `<none>` appears only when there is neither a formatter nor a
  format-capable client.
- **`prettier --find-config-path <file>`**, run from the project, answers
  whether prettier itself believes it has a config — this is the exact
  command from the defect reproduction above, and the fastest way to confirm
  a project genuinely has no prettier config versus one where the detection
  walk missed a marker.
- **`:checkhealth lsp`** lists attached LSP clients for the current buffer,
  which is how to confirm whether `biome` or `oxlint`'s language server
  actually started (linter slot) as opposed to neither attaching and
  `eslint_d` running instead through nvim-lint on save.

## Where the code lives

`lua/config/js_toolchain.lua` owns detection, the marker tables, the upward
walk, the boundary rule, per-directory memoization (`_clear()`), and the
`gate_root_dir` wrapper used to gate biome/oxlint's `root_dir`.
`lua/util/project.lua` holds the shared `is_root` predicate (also used by
`lua/config/lsp_root.lua` for `ts_ls`). `lua/config/js_tool_version.lua` owns
the version-mismatch warning. `lua/config/formatters.lua` wires the JS/TS
`by_ft` entries to the formatter slot; `lua/plugins/lsp.lua` registers the
gated `biome`/`oxlint` servers; `lua/plugins/nvim-lint.lua` runs `eslint_d` on
`BufWritePost` when the linter slot is `eslint`.

Cache invalidation is split across two files, and both halves matter.
`lua/plugins/conform.lua` drops the detection cache when a marker file (or
`package.json`) is written, so adding a config takes effect on save.
`lua/config/dir_cache.lua` drops it on `DirChanged` and on a `.gitmodules`
write — the cwd moving changes where an unnamed buffer resolves from, and a
`git submodule add`/`deinit` moves the boundary that decides whether a
directory inherits its superproject's config. That file clears four
directory-keyed caches on the same two triggers, of which this is one; it is
also what `<leader>gR` reaches for as the manual hatch when the topology
changed outside the editor.

Unit specs cover the pure detection and version-parsing logic; smoke
specs cover the nvim-lint wiring; `tests/spec/e2e/format_on_save_spec.lua`
drives a real conform save to pin the defect this feature fixes: an
unconfigured project comes back byte-identical, and a configured one honors
its own `.prettierrc`. Run with the sandbox disabled and
`~/.local/share/nvim/mason/bin` on `PATH`.
