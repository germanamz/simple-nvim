# Per-project pyright diagnostic rules

A codebase that carries type annotations but does not follow them by the letter —
Pydantic being the canonical case — draws a wall of red under pyright's defaults.
`<leader>ld` opens a picker that dials individual rules down **for that project
only**, live, with nothing written into the project itself.

`lua/config/pyright_rules.lua` + wiring in `lua/plugins/lsp.lua`. The server is
basedpyright (`lua/config/python_lsp.lua`; why, in
[python-navigation.md](python-navigation.md)), which is pyright with the same
rule names and the same config precedence, so "pyright" below means the engine
both share.

## Using it

Open any Python file in the project and press **`<leader>ld`** (or run
`:PyrightRules`).

```
Python diagnostics — myservice
● reportCallIssue                    → warning        8
  reportArgumentType                                  3
  reportAttributeAccessIssue
  reportAssignmentType
  reportIndexIssue
  [ clear all overrides for this project ]
```

Rows are every rule currently firing in the project, every rule already
overridden here, and the five preset rules regardless — noisiest first, so the
rule actually burying the buffer is under the cursor when the picker opens. The
trailing number is how many diagnostics that rule is producing right now; `●`
marks a rule with an override in force. The preview pane lists every occurrence
as `path:line  message`, so you can see what you are about to silence.

| key | action |
|---|---|
| `<CR>` | cycle the severity: default → `warning` → `information` → `none` → `error` → default |
| `<C-p>` | apply the Pydantic preset (all five rules → `warning`) |
| `<C-d>` | drop the selected rule's override outright |

Changes apply **immediately** — no `<leader>lr`, no restart. The picker stays
open, because dialing several rules down in one visit is the common case.

Choices persist in `stdpath("data")/nvim-pyright-rules.json`, keyed by the
realpath'd server root. That root is the workspace, not the member package, in a
uv workspace ([python-navigation.md](python-navigation.md#roots)), so rules
recorded under a member's root before that change are no longer read.

### Which severity to pick

`warning` and `information` keep the diagnostic in `]d`, the location list and
the `CursorHold` float — it just stops being red. `none` removes it entirely.
The preset uses `warning` on purpose: the goal is usually to stop the noise
drowning out real errors, not to stop checking.

`hint` is deliberately not offered. basedpyright accepts it, but plain pyright
1.1.409 silently discards it and leaves the rule at its default (still red), so
leaving it out keeps the store meaning the same thing to either server.

## Why per-rule, and not `typeCheckingMode`

The advice you will find everywhere is `typeCheckingMode = "basic"`. It does
nothing for this problem. Measured against pyright 1.1.409 on the same Pydantic
file:

| mode | errors |
|---|---|
| `off` | 0 |
| `basic` | 12 |
| `standard` (pyright's default) | 12 |
| `strict` | 12 |

The five rules involved are `"error"` in basic, standard **and** strict alike;
basic and standard differ in five entirely unrelated rules. Only `off` silences
them, and that gives up type checking wholesale.
`diagnosticSeverityOverrides` is the only server-side lever with the granularity
this needs — hence a store keyed rule-by-rule rather than one mode string per
project.

It lives under `basedpyright.analysis`, not pyright's `python.analysis`.
basedpyright reads `python.analysis` only when there is no `basedpyright`
section at all, and lspconfig always contributes one, so an override written
under the pyright name is silently ignored.

## Projects with their own pyright config

The mode does matter in one case, and there it makes things far louder. With
no config file in the project, the editor's `typeCheckingMode = "standard"`
applies, which is plain pyright's default. Once the project has a
`pyrightconfig.json`, `[tool.pyright]` or `[tool.basedpyright]`, the server
drops the editor's settings wholesale (see the first gotcha below). If that
config sets no `typeCheckingMode`, basedpyright starts it from its own default,
`"recommended"`. Measured on a 150-file package:

| setup | diagnostics |
|---|---|
| plain pyright | 175 |
| basedpyright, editor's `standard` | 174 |
| basedpyright, `[tool.pyright]` with no mode | 4,683 |

Nearly all of the difference comes from rules plain pyright does not have:
`reportDeprecated`, `reportAny`, `reportUnannotatedClassAttribute`,
`reportImplicitOverride`. No editor setting reaches past a config file, so
neither the picker nor the editor's mode can turn this down.
`lua/config/pyright_mode.lua` deals with it in two ways.

**A warning, once per project**, when the project's config leaves the mode
unset. It names the file and the line to add, in that file's syntax:
`typeCheckingMode = "standard"` in the TOML section, or
`"typeCheckingMode": "standard"` in `pyrightconfig.json`. `"standard"` is
already the default for plain pyright, Pylance and the pyright CLI, so
committing that line changes nothing for CI or teammates. The lookup follows the
config's `extends` chain, so a project that sets the mode in a shared base
config is not warned.

**`:PythonQuiet`**, for a repo you do not own. It writes an untracked
`pyrightconfig.json` at the server's root:

```jsonc
{
  // Local only, listed in .git/info/exclude: keeps basedpyright at
  // pyright's "standard" level. Delete this file to undo.
  "extends": "./pyproject.toml",
  "typeCheckingMode": "standard"
}
```

`pyrightconfig.json` outranks `pyproject.toml`, and `extends` keeps every
project setting (include, exclude, rule severities) except the mode. The
command adds the file to the repository's `.git/info/exclude`, never to
`.gitignore`, so `git status` stays clean and nothing in the repo changes. Then
it restarts the server so the file is read. To undo, delete the file and press
`<leader>lr`.

It writes nothing in three cases: the project has no config (the editor's
`standard` already applies), the config already sets `off`, `basic` or
`standard`, or the config *is* a `pyrightconfig.json`. basedpyright reads no
other file name, so an override would have to replace that file, and the
command names the line to add to it instead.

The override is a config file too, so the picker's severities still do not
apply in that project. Put per-rule severities in the override under
`diagnosticSeverityOverrides`.

`tests/spec/unit/pyright_mode_spec.lua` pins the parsing, the warning and what
the command writes. `tests/spec/e2e-lsp/pyright_mode_spec.lua` runs it against
the real server: a recommended-only rule fires, and after `:PythonQuiet` it is
gone while the standard-mode error stays.

## What is actually red

Pyright has no plugin system. It synthesizes `BaseModel.__init__` from PEP 681
`@dataclass_transform` and nothing else, so Pydantic's runtime behavior —
coercion, aliases, `extra="allow"`, before-validators — is invisible to it. The
preset covers the five rules that follow from that:

| rule | what trips it |
|---|---|
| `reportCallIssue` | `extra="allow"` kwargs; `Field(alias="x")`, which reads as *both* "argument missing" and "no parameter named" on one line; positional `Field(23)` |
| `reportArgumentType` | coercion at the call site: `age="23"`, an ISO string into a `datetime`, a `str` into a `UUID` |
| `reportAttributeAccessIssue` | reading a field that exists only via `extra="allow"` |
| `reportAssignmentType` | assigning a coercible value to a typed field |
| `reportIndexIssue` | dict-style subscripting of a model |

Two of these have real source-level fixes worth preferring where you own the
code: `validation_alias=` / `serialization_alias=` instead of `alias=` type-checks
clean, and `Model.model_validate(raw)` checks clean where `Model(raw)` does not.
(`populate_by_name=True` does **not** satisfy pyright, despite widespread claims
otherwise.)

## How it works

`before_init` is the hook that runs after `root_dir` is resolved but before the
client is created — the one moment where the project is known and the settings
are still editable. Neovim starts one client per `root_dir`, so a settings
fragment keyed on the realpath'd root gives genuinely different severities per
project from a single `vim.lsp.config("basedpyright", …)` registration, leaving
the registered config uncontaminated. `config.python_lsp`'s `before_init` runs
first, hands the server the project's interpreter, then calls this module's.

**The trap, and it is a silent one.** `client.settings` is bound *by reference*
to `config.settings` at `Client.create`, which runs **before** `before_init`. So:

```lua
-- Silent no-op. client.settings still points at the old table.
config.settings = vim.tbl_deep_extend("force", config.settings, { ... })

-- Correct. Same table the client is already holding.
config.settings.basedpyright.analysis.diagnosticSeverityOverrides = overrides
```

The first form is the pattern printed in Neovim's own `client.lua` docstring, and
it fails completely invisibly: the config table looks right, the picker looks
like it worked, and pyright keeps emitting severity 1. Both spec lanes pin
this — the unit spec asserts on table *identity*, and
`tests/spec/e2e-lsp/pyright_rules_spec.lua` proves it against a real server.

Live changes take the same table plus a `workspace/didChangeConfiguration`
notification. Pyright ignores that notification's *payload* and re-pulls from
`client.settings`, so the table edit does the work and the notify is only the
prompt.

## Gotchas

**A `pyrightconfig.json`, `[tool.pyright]` or `[tool.basedpyright]` discards all
of this.** Pyright's precedence is *wholesale*, not per-key: once it finds a
config file it never applies the client's settings group at all. An empty
section header is enough, and `pyrightconfig.json` outranks `pyproject.toml`. The module detects
this and warns once per project rather than letting the picker look like it
worked — but the fix is to put the severities in that file instead:

```json
{ "diagnosticSeverityOverrides": { "reportCallIssue": "warning" } }
```

**A project config also brings basedpyright's own default mode,**
`"recommended"`, unless it sets one. You get a warning, and `:PythonQuiet` is
the local fix ([above](#projects-with-their-own-pyright-config)).

**Editor-side only.** Nothing here reaches the pyright CLI or CI. That is the
point — it works on repos you do not own and cannot add files to — but it means
your editor and your CI can disagree. Where you *do* own the repo, a committed
`[tool.pyright]` is strictly better: same behavior in the editor, the CLI, CI,
and for teammates.

**Whole-project only.** Neovim answers one settings blob per client and ignores
`workspace/configuration`'s `scopeUri`, so "loosen `legacy/`, keep `src/` strict"
is not reachable from the editor. That needs a `pyrightconfig.json` with
`executionEnvironments` — which accepts individual rule names but **not**
`typeCheckingMode`, matches by *first* prefix in array order rather than longest,
and needs its `{"root": "."}` catch-all listed last or it swallows everything.

**Editing a pyright config file mid-session does nothing until `<leader>lr`.**
This config disables `workspace/didChangeWatchedFiles` for every server (see the
`no_watch` table in `lua/plugins/lsp.lua`), so pyright never learns the file
changed.

**Ruff is also attached.** `mason-lspconfig`'s `automatic_enable` stays on
(it excludes only `pyright`), so `ruff` and `dprint` attach to Python buffers
alongside basedpyright even though neither is declared in the `servers` table. Ruff's `F401`/`E501` are not
settable through this picker — it lists only pyright rule names (`report*`) — and
ruff does no type checking, so it is not a source of the Pydantic noise. It is
worth knowing about when a diagnostic you want gone does not appear in the list.

## Rejected

Three other routes to per-project severities look plausible and do nothing here.

- **Rewriting severities in a `textDocument/publishDiagnostics` handler.**
  Pyright dynamically registers `textDocument/diagnostic`, so Neovim *pulls* its
  diagnostics and the push handler never runs — an override fired 0 times while
  6 diagnostics landed. Every "downgrade LSP severity in Neovim" recipe built on
  that handler is a silent no-op against pyright.
  (`init_options = { disablePullDiagnostics = true }` forces push back if it is
  ever needed.) Test push versus pull with
  `client:supports_method("textDocument/diagnostic")`, not
  `server_capabilities.diagnosticProvider == nil`: pull arrives both ways —
  pyright registers it dynamically, ruff declares a static provider.
- **neoconf.nvim.** Structurally inert under the native API: it injects settings
  through `lspconfig.util.on_setup` → `on_new_config`, and neither
  `vim.lsp.config` nor `vim.lsp.enable` ever calls them.
- **A project `.nvim.lua` (`exrc`) calling `vim.lsp.config("pyright", …)`.**
  There is no protective merge priority: every `vim.lsp.config` call outside
  `lsp/*.lua` lands in the same tier (`:h lsp-config-merge`, item 4) and merges
  in call order, last wins. This config registers its servers in
  mason-lspconfig's `config()`, which runs on `BufReadPre` — after `exrc` — so
  it wins every key both set. The exrc appears to work only for keys the config
  never sets.
