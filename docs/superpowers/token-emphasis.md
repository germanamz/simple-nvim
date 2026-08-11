# Token emphasis

Comments recede, declaration names step forward, and a hairline separates one
top-level declaration from the next. Three changes solving one complaint:
**terminals are high-contrast, and in a language that puts a doc comment above
every exported declaration the comments become the loudest thing on screen.**

Go is the worst case and the reason this exists, but nothing here is Go-only.

## The problem, in numbers

`github_light_high_contrast` on a white background:

| Group | Colour | Contrast vs white |
| --- | --- | --- |
| `Normal` (identifiers) | `#010409` | 20.5:1 |
| `Function` | `#512598` | 10.2:1 |
| **`Comment`** (before) | **`#4b535d`** | **7.8:1** |
| `LineNr` | `#66707b` | 5.0:1 |
| `Whitespace` | `#e7ecf0` | 1.2:1 |

A comment sat closer to code than to chrome. Stack a three-line doc block above
every `func` and the file reads as prose with code interruptions, rather than the
other way round. Worse, declaration names and call sites were the *same* colour
(`#512598` for both `@function` and `@function.call`), so nothing marked where a
definition actually began.

## What shipped

### 1. Two tiers of comment — `lua/config/syntax_emphasis.lua`

| Tier | Value | Contrast | What lands here |
| --- | --- | --- | --- |
| Ordinary comment | `palette.muted` `#6e7781` | 4.5:1 | inline `// why` notes — the ones worth reading mid-scan |
| Doc comment | `#6e7781` blended `0.82` toward the background | ~3.2:1 | the block above a declaration, read on purpose |

`#6e7781` is not a new colour: it is GitHub's own comment grey on the
non-high-contrast light theme, and the value `lua/config/palette.lua` already
exported as `M.muted`.

`Comment` itself is set, not just `@comment`, so buffers with no treesitter
parser — notably the large files where the highlight guard deliberately falls
back to vim syntax — dim too.

### 2. Bold declaration names, plain call sites

Treesitter's queries already separate the two, and the config now leans on that:

| Bolded (a declaration) | Left alone (a use) |
| --- | --- |
| `@function` | `@function.call` |
| `@function.method` | `@function.method.call` |
| `@type.definition` | `@type` |

No new colour — bold alone. `func New` and `func (s *Server) ListenAndServe`
become anchors; `New(...)` at a call site looks exactly as it did.

The bold groups are **re-derived from the live colorscheme** on every
`ColorScheme`, reading each group's effective definition (`link = false`) and
adding `bold`. Nothing is hardcoded, so the emphasis survives a theme change.

### 3. A hairline above each declaration — `lua/config/decl_rules.lua`

A faint full-width underline on the line directly above each top-level
declaration group (doc block included). Toggle with `<Space>ur`.

What counts as a declaration is deliberately language-agnostic: **any named child
of the tree root.** In Go that is exactly `package_clause` /
`import_declaration` / `const` / `var` / `type` / `func` / `method`; Lua,
TypeScript and the rest land on their own top-level statements. There is no
per-language node table to keep in sync when a new parser is pinned.

Two refinements keep it from becoming noise:

- A declaration's group starts at its **doc block** — the run of consecutive
  comments ending on the line *directly* above it. A comment separated by a blank
  line is free-standing prose and stays outside the group.
- **Single-line declarations with no doc block get no rule.** Otherwise a run of
  `import "fmt"` lines or a stack of one-line consts would be ruled to death.
- **Trailing comments are excluded.** `} // end Alpha` and
  `const N = 3 // per attempt` parse as root-level siblings whose start row is
  one the previous node already occupies. Treated as ordinary comments they seed
  the *next* declaration's doc run, dragging its group start backwards — which
  put the rule on `println(1)` **inside the previous function's body**. A comment
  starting on a row the previous sibling already ends on belongs to the line it
  trails, and neither seeds nor extends a run.

### 4. Four retuned token hues

The variant crowded several roles together. Measured with CIEDE2000 against a
real Go buffer with gopls attached — under ~15 is uncomfortable for tokens that
sit side by side:

| Role | Was | Now | Separation |
| --- | --- | --- | --- |
| Struct fields / properties | `#023b95` blue | `#971368` magenta | 32.7 → **46.5** vs functions |
| Module qualifiers | `#a0111f` — the *exact* keyword red | `#010409` neutral | 0.0 → **35.8** vs keywords |
| Constants / `nil` / numbers | `#023b95` | `#0550ae` | 9.0 → **15.7** vs strings |
| Type definitions | `#14161b` near-black | `#702c00`, the type colour | 4.0 vs plain variables → separated by **bold** instead |

The field change is the load-bearing one. `a.db.Exec` put a blue field and a teal
method on either side of one dot, which is the hardest place to ask a reader to
separate two cool colours — and the dotted chain is everywhere in Go.

Two of these are worth stating as principles:

- **Modules were painted identically to `func` / `if` / `return`** (dE 0.0). A
  qualifier is scaffolding; `errors.Is` should read as one quiet namespace and
  one loud verb. Neutral, not a new hue.
- **Constants and strings shared hue 292.1° exactly**, differing only in
  lightness. No contrast tweak could have separated them — there was no hue
  signal to amplify — so the fix had to move one of them.

**Deliberately not introduced: green.** Functions are teal, and every green that
clears the other roles lands within ~21 of it, trading one hard pair for another.
Seven hue families is what this palette holds: red, rust, teal, blue, magenta,
neutral, and the two greys the comments use.

## The two traps

Both cost real time to find. Neither is guessable from the docs.

### LSP semantic tokens outrank treesitter, and gopls sends them

Treesitter highlights at priority 100; LSP semantic tokens at 125. gopls'
`semanticTokensProvider` is live in this config, and it paints:

- `@lsp.type.function` on a declaration **and on every call site** — both resolve
  up the `@`-hierarchy to `@function`. Bolding `@function` alone would have
  bolded every call.
- `@lsp.type.comment` across a whole doc comment — resolving to `@comment`, which
  would have flattened the two comment tiers straight back into one.

The discriminator is LSP's modifier: a declaration carries
`@lsp.typemod.function.definition`, a call site does not. So the LSP layer is
taught the same distinction the treesitter layer already had:

```lua
@lsp.type.<t>                    -> pinned to the plain "use" weight
@lsp.typemod.<t>.definition      -> linked back to the bold declaration group
@lsp.typemod.<t>.declaration     -> ditto (rust-analyzer and lua_ls spell it this way)
@lsp.type.comment                -> cleared outright, so treesitter's tiers survive
```

A defined-but-empty group contributes no attributes — that is what "cleared"
means, and why it works.

Three of this config's servers were checked directly, and they behave three
different ways — which is why both modifiers are wired *and* why the treesitter
layer still has to be right:

| Server | On a declaration it sends | What makes the name bold |
| --- | --- | --- |
| `gopls` | `@lsp.typemod.function.definition` | the LSP layer re-bolds |
| `ts_ls` | `@lsp.typemod.function.declaration` | the LSP layer re-bolds |
| `lua_ls` | `@lsp.type.method` — **no** defining modifier at all | treesitter's `@function` bold survives on its own |

The `lua_ls` row is the load-bearing one. Extmark attributes **OR together across
layers**: a higher-priority `bold = false` cannot clear a lower-priority `bold`.
So a server that marks nothing as a declaration costs nothing — treesitter's bold
persists through the LSP layer — while call sites stay plain because *neither*
layer bolds them. The wiring degrades correctly instead of failing closed.

One ordering subtlety in `apply()`: the *use* weight is snapshotted **before** the
declaration capture is boldened. A theme that leaves `@function.call` undefined
would resolve it up the hierarchy to `@function`, and reading it afterwards would
pick the new bold straight back up.

### Bolding a capture is not local to that capture

The first implementation bolded `@function` and `@type.definition` directly. Both
are **family roots**, and three separate things reach a root and inherit whatever
it carries:

| Group | How it reaches the root | What broke |
| --- | --- | --- |
| `@function.macro` | undefined by github-theme, so it resolves *up* the `@`-hierarchy | every Rust `println!` / `vec!` / `format!` rendered at declaration weight |
| `@lsp.type.class` | github-theme links it to `@function` | every TypeScript class reference — `new Foo()`, `let x: Foo` — went bold |
| `@lsp.type.typeParameter` | Neovim's own defaults link it to `@type.definition` | every generic `T` and `U`, in signatures *and* bodies, went bold |

Each is the exact declaration/use collapse this module exists to prevent, and the
class case was strictly worse than doing nothing: treesitter captures a TS class
name as plain `@type`, so the declaration stayed plain while the LSP layer bolded
declaration and reference alike.

`apply()` is therefore ordered **compute every plain weight → bold → re-pin**,
and handles the two reach mechanisms differently because only one is
discoverable:

- **Links are discovered.** Every defined group is scanned for a link into a
  group about to be bolded, and pinned to that group's plain weight. A theme
  update cannot quietly reintroduce the leak. The scan skips the
  `@lsp.typemod.*` groups this module creates, which link into a bolded group on
  purpose — without that skip the second `apply()` would un-bold its own work.
- **Hierarchy fallback is listed** (`M.FAMILY`), because an undefined group does
  not exist to be scanned for. Membership in the "every defined group" map is
  also what distinguishes *undefined* (falls through, must be pinned) from
  *defined-but-empty* (github-theme's `@function.builtin`, which blocks the
  hierarchy deliberately and must be left alone).

### An ephemeral extmark silently ignores `line_hl_group`

`config.block_guides` renders through a decoration provider with ephemeral
extmarks, so that was the obvious model for the rules. It does not work: an
ephemeral mark carrying `line_hl_group` is **accepted without error and never
paints.** Verified under a pty against a persistent-mark control on the adjacent
row, which painted.

Persistent marks also suit the data better. The rules depend on the buffer's
text, not on the cursor, so recomputing them every redraw would be pure waste —
and extmarks shift with the text on edits for free. Repaint runs on `FileType` /
`BufWinEnter` / `TextChanged` / `InsertLeave`, scheduled onto the next tick
(treesitter's own `FileType` handler is registered *later* than this module's, so
at event time the highlighter has not attached yet) and skipped when the
buffer's `changedtick` has not moved.

`TextChangedI` is deliberately absent: a full-buffer reparse per keystroke buys
nothing when the existing marks already shift as you type.

## Knock-on effects

Dimming `Comment` moved everything that borrows it as "a muted grey":

| Borrower | Effect | Action |
| --- | --- | --- |
| `BlockGuideChain` (links `Comment`) | tier drops 7.8:1 → 4.5:1 | **kept** — the dim/chain/active ladder becomes 1.2 / 4.5 / 10.2, better separated than the old 1.2 / 7.8 / 10.2 where chain and active nearly tied |
| `NvimTreeGitIgnored` (`define_dim` from `Comment`) | would have dimmed twice, to ~1.9:1 | **retuned**: `alpha` 0.55 → 0.7, reproducing the grey it always had |
| markdown statuscolumn `¶` counts | dimmer | kept — they are meant to be dim |
| nvim-tree `g?` winbar hint | dimmer | kept — it is a hint |

## Upstream gap fixed: `after/queries/go/highlights.scm`

nvim-treesitter's Go `highlights.scm` captures `@comment.documentation` for the
comment run above a `source_file`-level `const` / `function` / `type` / `var`,
plus the package doc — but **not above a `method_declaration`.** Every method's
doc block therefore fell back to plain `@comment` and rendered a tier *louder*
than a plain function's, which is backwards: methods are where Go's doc comments
cluster.

The `; extends` file adds the missing pattern. `tests/spec/e2e/go_doc_comments_spec.lua`
guards it along with the upstream cases, so a fixed upstream shows up as a
redundant-but-passing spec rather than a silent regression.

## Retuning

One value per knob, all in one place each:

| Knob | Where |
| --- | --- |
| Ordinary comment colour | `palette.muted` in `lua/config/palette.lua` |
| How much dimmer doc comments are | `syntax_emphasis.DOC_ALPHA` (0.82; lower = dimmer) |
| Which captures get bolded | `syntax_emphasis.EMPHASIS` |
| Hairline colour | the `0.45` blend in `decl_rules.ensure_highlights` |
| Filetypes with no rules | `decl_rules`' `EXCLUDED_FT` |

As everywhere else in this config, **no spec asserts a hex value.** The unit spec
compares relative luminance to prove doc comments are dimmer than ordinary ones,
and asserts `bold` as an attribute — the same latitude
`lsp_refs`' `LspReferenceText` underline assertion takes. After retuning, look at
a real `nvim`.

## Rejected

- **Dimming only `@comment` and leaving `Comment` alone.** Surgical, and it would
  have avoided retuning `NvimTreeGitIgnored` — but it splits the semantics of
  "comment" across two groups and leaves parserless buffers bright.
- **A `virt_lines` rule.** A dedicated row per declaration reads well and costs a
  screen row per declaration. The underline costs none.
- **Folding doc comments by default.** Hides the thing rather than ranking it.
- **Italic comments.** The theme record ruled italics out and nothing here
  changes that argument; dimming already does the job.
