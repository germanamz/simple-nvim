# Dotted-chain textobject (`ao` / `io`)

mini.ai adds one custom textobject to this config, `o`, that selects a whole
dotted identifier chain as a single unit. Given:

```
someFunc("another arg", app.property)
```

with the cursor anywhere in `app.property`, `dio` deletes the whole chain. Vanilla
motions do not have a clean equivalent: `viW` overshoots to `app.property)` because
WORDs are whitespace-delimited, `iw` grabs only one segment, and `v3e` is fragile.

Combined with mini.surround's `f` (function call) surrounding, the chain becomes
easy to wrap:

```
someFunc("another arg", app.property)
                        ^ cursor anywhere in the chain

gsaiof  →  prompts "Function name:"  →  fooFunc
        →  someFunc("another arg", fooFunc(app.property))
```

That is `gsa` (add surrounding) plus `io` (inner dotted chain) plus `f` (function
call). Installing mini.ai also brings `ia` / `aa` (argument) and `af` / `if`
(function call) for free.

## Keys and separators

`a` and `i` select the same span; there is no meaningful "inside" of an
identifier, and `iw` already gives one segment. The key is `o` for "object":
nothing in Vim or mini.ai binds `ao` / `io`, so it shadows nothing. `s` would have
shadowed the builtin sentence textobject, which matters under the markdown writing
mode, and `.` would have shadowed mini.ai's own between-dots default.

What counts as a separator is per-filetype. The base class is word characters plus
`.` everywhere, extended with `:` for lua, rust, and cpp, and `?` for the
ts/js family (optional chaining). So `app.property`, `obj:method`,
`std::vec::Vec`, and `app?.property` all select as one chain in the right
filetype.

### Why `->` is not a separator

C's `ptr->field` is deliberately unsupported. A Lua character class cannot express
"a `-` followed by `>`", so admitting the arrow means putting `-` into the class,
which then also matches subtraction:

```
arr[i-1]   → would select  i-1   (want: i)
n-1        → would select  n-1   (want: n)
```

Unspaced index math like `i-1` and `n-1` is pervasive in C, so the arrow costs more
than it buys. Spaced arithmetic (`i - 1`) survives because the space breaks the
class. Go does not need the arrow at all: it auto-dereferences, so pointer field
access is plain `.`, and its arrow-shaped operator `<-` is never part of an
identifier chain.

## How it works

The feature is a small pure module, `lua/config/dotted_chain.lua` (named for what
it matches, not `ai_*`, since `lua/config/ai.lua` and `ai_models.lua` already exist
for minuet completion), plus a plugin spec, `lua/plugins/mini-ai.lua`. mini.ai
invokes a callable spec at textobject
time in the current buffer, so `vim.bo.filetype` resolves correctly with no
FileType autocmd and no buffer-local state.

`M.spec(ft)` returns a composed mini.ai pattern, with `C` being the filetype's
character class:

```lua
{ "%f[" .. C .. "][" .. C .. "]*[%w_]", "^[^%w_]*()().*()()$" }
```

**The outer match** finds the chain. Its frontier `%f[C]` is the whole reason this
works. mini.ai resolves competing covering matches narrowest-wins. A naive
`%f[%w_]` frontier matches at every segment start, so in `app.property` it matches
both at `a` and at the `p` of `property`, producing two covering spans; with the
cursor on `property` the narrower one wins and you silently get just `property`.
Using `%f[C]` requires the previous character to be neither a word char nor a
separator, so a frontier matches at `a` but not at `p` (whose previous char, `.`,
is in `C`). Exactly one span exists, so there is no narrower competitor. The
trailing `[%w_]` forces the match to end on a word char, so `-- see app.` selects
`app`, not `app.`. This is the same idiom mini.surround already uses for function
calls.

**The extraction pattern** derives the `a` / `i` spans from the matched text. Four
empty captures placed identically make `io` equal `ao`. Its one job is stripping a
leading separator, which matters for method chains where the frontier matches at
the leading dot:

```js
const x = arr
  .filter(Boolean)   // raw span is `.filter`; extraction strips it → `filter`
  .map(f)
```

`^[^%w_]*` is filetype-agnostic: the outer match can only contain `C` characters,
so any leading non-word character is by definition a separator, and one extraction
pattern serves every filetype.

## Behavior

Verified against real lines with a narrowest-wins emulation of mini.ai's span
selection:

| Filetype | Line | Cursor on | Selects |
| --- | --- | --- | --- |
| go | `someFunc("another arg", app.property)` | `property` | `app.property` |
| go | `p.Field = 1` | `Field` | `p.Field` |
| go | `arr[i-1]` | `i` | `i` |
| lua | `-- see app.` | `app` | `app` |
| lua | `obj:method(1)` | `method` | `obj:method` |
| lua | `local M = require('config.foo')` | `config` | `config.foo` |
| javascript | `  .filter(Boolean)` | `filter` | `filter` |
| typescript | `const y = app?.property` | `property` | `app?.property` |
| typescript | `app.fn?.()` | `fn` | `app.fn` |
| typescriptreact | `props?.user?.name` | `user` | `props?.user?.name` |
| rust | `let v = std::vec::Vec::new()` | `vec` | `std::vec::Vec::new` |
| cpp | `std::string s` | `string` | `std::string` |
| python | `x = app.property` | `property` | `app.property` |

### Accepted imprecisions

These are intended, not bugs:

- **`a?b:c` → `a?b`** (ts/js) and **`let x:i32` → `x:i32`** (rust). Unspaced
  ternaries and type annotations. The spaced forms (`a ? b : c`, `let x: i32`),
  which Prettier and ESLint produce, select correctly.
- **Numbers, paths, and versions match as chains:** `3.14`, a leading-dot float
  `.5` → `5` (its leading `.` stripped as a separator), `"src/foo.lua"` →
  `foo.lua`, `1.2.3`. All dot-joined runs, harmless.
- **`std::vec::Vec::new()` → `std::vec::Vec::new`.** The method name is part of the
  chain; the call parens are not. `af` still covers the call form.
- **`ptr->field` → `ptr`** (c/cpp). See above.
- **Non-ASCII identifiers split at the multibyte character.** `café.property` with
  the cursor on `café` selects `caf`, because Lua's `%w` and `%f[]` frontier are
  byte-wise and never match a UTF-8 lead or continuation byte. This affects any
  identifier with an accented-Latin, Greek, Cyrillic, or CJK character. There is no
  crash, boundaries always fall on ASCII bytes, and a UTF-8-aware fix is impossible
  in Lua patterns.
- **A cursor on a chain's trailing separator selects the next chain, not the one
  under the cursor**, and is a safe no-op if none follows. The outer match ends on
  a word char, so a cursor resting on a trailing `?.`, `.`, or `::` is not covered
  by its own chain's span, and mini.ai's default `cover_or_next` reaches forward to
  the next one. Every mini.ai textobject behaves this way off its object; setting
  `search_method = "cover"` would remove the surprise but is global and would strip
  the useful forward search from the builtin objects.

## which-key labels

which-key's `text_objects` preset labels the vanilla objects but cannot know about
the ones mini.ai adds, so `lua/plugins/which-key.lua` registers labels for them in
operator-pending and visual modes (mini.ai maps `a` / `i` in both):

| Keys | Label |
| --- | --- |
| `ao` / `io` | dotted chain / inner dotted chain |
| `af` / `if` | function call / inner function call |
| `aa` / `ia` | argument / inner argument |

## Tests

`tests/spec/unit/dotted_chain_spec.lua` asserts behavior, not pattern strings: it
builds the spec via `M.spec(ft)`, runs the patterns against the sample lines, and
checks what is selected, including the narrowest-wins regression, the leading-dot
strip, the false-positive guards, and a block pinning the accepted imprecisions so
a class change cannot silently worsen them.
`tests/spec/smoke/dotted_chain_spec.lua` drives the real plugin through
`MiniAi.find_textobject` to pin what the unit emulation cannot: the
`cover_or_next` forward reach, a genuine multi-line method chain, and the
trailing-separator edge. The operator-pending keymap path (`dio`, the `gsaiof`
surround composition) is verified manually, since driving those keystrokes headless
hangs on mini's operator loops and needs a PTY.

## Not covered

- **Treesitter-based chains.** More precise, but there is no standard `@chain`
  capture, so it would need a hand-written query per language plus the
  nvim-treesitter-textobjects dependency. The only gain over patterns is avoiding
  the harmless `3.14` and path matches.
- **Arrow support (`->`)** for C. The escape hatch, if it ever proves worth it, is
  a callable pattern element: mini.ai accepts a function `f(line, init) → from, to`
  instead of a string pattern, and a small pure scanner over identifier characters
  and a list of separator tokens could match `->` exactly with no false positives.
  Such a scanner must only ever return `from >= init`, since the caller advances
  with `init = from + 1` and a backward match would loop forever.
