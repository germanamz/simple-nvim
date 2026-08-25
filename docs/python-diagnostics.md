# Per-project pyright diagnostic rules

A codebase that carries type annotations but does not follow them by the letter —
Pydantic being the canonical case — draws a wall of red under pyright's defaults.
`<leader>ld` opens a picker that dials individual rules down **for that project
only**, live, with nothing written into the project itself.

`lua/config/pyright_rules.lua` + wiring in `lua/plugins/lsp.lua`.

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
realpath'd pyright root.

### Which severity to pick

`warning` and `information` keep the diagnostic in `]d`, the location list and
the `CursorHold` float — it just stops being red. `none` removes it entirely.
The preset uses `warning` on purpose: the goal is usually to stop the noise
drowning out real errors, not to stop checking.

`hint` is deliberately not offered. It is a **basedpyright** extension; pyright
1.1.409 silently discards it and leaves the rule at its default, i.e. still red.

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
`python.analysis.diagnosticSeverityOverrides` is the only server-side lever with
the granularity this needs — hence a store keyed rule-by-rule rather than one
mode string per project.

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
project from a single `vim.lsp.config("pyright", …)` registration, leaving the
registered config uncontaminated.

**The trap, and it is a silent one.** `client.settings` is bound *by reference*
to `config.settings` at `Client.create`, which runs **before** `before_init`. So:

```lua
-- Silent no-op. client.settings still points at the old table.
config.settings = vim.tbl_deep_extend("force", config.settings, { ... })

-- Correct. Same table the client is already holding.
config.settings.python.analysis.diagnosticSeverityOverrides = overrides
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

**A `pyrightconfig.json` or `[tool.pyright]` discards all of this.** Pyright's
precedence is *wholesale*, not per-key: once it finds a config file it never
applies the client's settings group at all. An empty `[tool.pyright]` header is
enough, and `pyrightconfig.json` outranks `pyproject.toml`. The module detects
this and warns once per project rather than letting the picker look like it
worked — but the fix is to put the severities in that file instead:

```json
{ "diagnosticSeverityOverrides": { "reportCallIssue": "warning" } }
```

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

**Ruff is also attached.** `mason-lspconfig`'s `automatic_enable` defaults to
`true`, so `ruff` and `dprint` attach to Python buffers alongside pyright even
though neither is declared in the `servers` table. Ruff's `F401`/`E501` are not
settable through this picker — it lists only pyright rule names (`report*`) — and
ruff does no type checking, so it is not a source of the Pydantic noise. It is
worth knowing about when a diagnostic you want gone does not appear in the list.
