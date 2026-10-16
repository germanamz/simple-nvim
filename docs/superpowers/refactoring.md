# Refactoring and code quality

Two whole-config passes, both behavior-frozen, both run against a green suite at
every step.

- **2026-06 — decompose and extract.** Eight phases on `refactor/config-quality`.
  Collapse near-duplicate handlers, break up the high-complexity functions, pull
  genuinely shared logic into `lua/util/`. Unit tests went from 119 to 191.
- **2026-07 — principles review.** The whole config read against a code-quality
  catalog (DRY/AHA, KISS, SRP, coupling, performance, fail-fast). 41
  adversarially-verified findings applied: 12 bug fixes, four new modules, two new
  spec files.

The durable output of both is not the diff. It is the extraction rule, and the
list of things that were examined and rejected.

## The extraction rule

> Greenfield indirection must earn its keep. A new shared module is justified
> only by **two or more real consumers** *and* a clean surface that does not leak
> per-caller parameters. Single-consumer helpers stay module-local.

This rule did most of the work. Applied honestly it rejects more than it accepts,
and it is why `lua/util/` is 13 small files rather than a grab-bag.

The corollary that matters as much: **narrow the extraction to the part that is
actually identical.** `close_legend` was byte-identical in two modules while the
*open* configs differed fundamentally — one editor-centered, one anchored to a
telescope results window, with different borders. `util.overlay` therefore owns
the `(win, buf)` handle and teardown only, and takes a caller-computed window
config. Unifying the open path would have re-leaked exactly the parameters the
extraction was meant to remove.

## What lives in `lua/util/`

| Module | Why it exists |
| --- | --- |
| `git.lua` | The `vim.system():wait()` + exit-code guard + `-C <cwd>` plumbing, hand-rolled with subtly inconsistent error handling across five modules. `root()` now guards the empty-string toplevel one caller used to return unguarded |
| `path.lua` | `buf_start_dir(buf)` — buffer name to a directory safe for git operations, with the dir-buffer / `isdirectory` / parent / cwd ladder |
| `overlay.lua` | Floating-window handle owning its `(win, buf)` lifetime and valid-guarded teardown |
| `picker_legend.lua` | The legend-strip-under-a-telescope-picker machinery. See [telescope-pickers.md](telescope-pickers.md) |
| `inline_diff.lua` | Byte-level common-affix diff, lifted out of the gitsigns word-diff painter so the prefix/suffix arithmetic is testable alone |
| `pool.lua` | Bounded-concurrency task pool for async fan-out. Knows nothing about git; shared by the picker's submodule recursion and the ignore-filter oracle |
| `state.lua` | Guarded whole-file read and atomic write shared by the persisted-model, model-library-cache, review-base and lock-drift stores |
| `fs.lua` | The single "list every file under the cwd" command shared by both file pickers |
| `ft.lua` | The markdown-family filetype set, so adding a member is one edit |
| `hl.lua` | The theme-aware muted-color recipe shared by the nvim-tree decorators |
| `largefile.lua` | One threshold for "too large for synchronous whole-buffer work" (5000 lines or 512 KB), so the treesitter guard and its callers agree |
| `markdown.lua` | Frontmatter and fence parsing. Extracted for the paragraph gutter and the glow preview; the preview became a cmux panel that parses nothing, so the gutter is the only consumer left |
| `project.lua` | "Is this directory an independent project root?", asked about the same tree with different markers by two callers |

Module-scoped extractions that did not warrant `lua/util/`:
`lua/config/git_status_codes.lua` (the porcelain dominant-letter rule and the
letter → highlight mapping, previously duplicated verbatim within one file),
`lua/config/nvim_tree_hl_decorator.lua` (a factory for the tree's
grey/blue/teal decorators), and `lua/config/lock_drift.lua` (the lazy-lock drift
warning, moved out of `init.lua` so its ref-resolution ladder is unit-testable).

## Dropped mid-flight

Evidence beat the plan three times, and saying so is the point:

- **`util/extmark` was never created.** Its entire justification was "gitsigns
  gains a `pcall` guard that `lsp_refs` already has". Gitsigns already
  `pcall`-wrapped every `set_extmark`. The premise was false, so the extraction
  would have been pure indirection.
- **`build_server_config` was dropped.** The `lsp.lua` mason-lspconfig loop was
  already a clean seven-line capability merge, not the hotspot the catalog
  claimed.
- **The naming "sweep" was folded into each phase.** Every extracted function was
  named deliberately at extraction time. A blanket rename of working code is
  churn with no payoff.

Two extractions were flagged as *improving* behavior rather than preserving it,
because smuggling that in silently would have broken the behavior-frozen
contract: `util.git.root`'s empty-toplevel guard, and `gitsigns.apply_base`
gaining `util.path.buf_start_dir`'s guards.

One module from the refactor is gone. `config/markdown_rewrap.lua` — the
`<leader>w` prose/fence/table rewrap subsystem split out of `options.lua` —
was deleted when markdown moved to soft-wrap and per-project `.editorconfig`
style. `render-markdown.nvim` went the same way, replaced by the preview pane — first
`glow` in a Neovim terminal buffer, now a
[cmux markdown panel](markdown-preview.md).

## The behavior contract

The refactor's contract was a 90-feature inventory across 11 module clusters,
produced by a 13-agent analysis pass: every user-visible behavior, with its
entry point, and whether a test pinned it. 38 high-priority gaps — behaviors a
refactor could silently break that nothing asserted — were closed *before* the
corresponding module was touched.

That document is archived rather than maintained. Its line references drifted
almost immediately, and the config has grown well past 90 features. The living
equivalents are the test suite (914 examples; a behavior worth keeping has a spec)
and `../keybindings.md` (everything reachable from a key). If you need a
behavior contract before a risky change, write the characterization tests — that
is what the inventory existed to motivate.

## Do not re-propose

These were flagged by a review pass, examined against the code, and rejected. A
future review will flag them again.

- **Splitting `ai_models.lua`** (1008 lines). It is cohesive around one modal, and
  its header comments are load-bearing design records.
- **A highlight-color utility.** Two sites, barely overlapping logic, one line of
  hand-rolled `#%06x` each.
- **A buffer-local keymap helper.** Three lines with divergent signatures
  (mode-implicit vs explicit, silent default). Idiomatic as-is; revisit at a third
  site.
- **A cursor-position utility.** Already extracted as a module-local in
  `lsp_refs.lua`. Nothing to dedup.
- **telescope_smart's "status/diff serialization race across pipelines"**, the
  gitsigns `file_new_vs_base` sync-spawn and `GitSignsUpdate` double-fetch
  performance flags, and the gitsigns buffer-loop "triplication".
- **`ai_models`' `start_pull` module-state reset as "coupling"**, the picker
  legend's `VimResized`-after-`BufLeave` "leak", and a notify on `ai.lua`'s
  model-persist write failure.
- **Dropping `shfmt` for zsh, or pinning `stylua` through mason.** shfmt parses
  zsh as bash, which suits the bash-compatible scripts it meets; zsh-only syntax
  fails visibly on save. stylua must be on the shell `PATH` for `make lint` and
  `make fmt`, where mason's bin dir is not, and a mason copy would shadow it
  inside Neovim. Both are commented in `lua/config/formatters.lua`.
- **A central repo registry.** `util.git`'s root cache, `git_head`'s watched set
  and the `review_base` map each have one owner and together already form an
  implicit registry; only liveness was unowned, and buffer-lifecycle eviction now
  owns it. See [git-at-scale.md](git-at-scale.md).
- **Resolving the wikilinks root through `util.git.root`.** That resolver is
  git-toplevel-only and returns nil for a vault with no repo. The two answer
  different questions and coincide only on `.git`, so `wikilinks.lua` keeps its
  own `WIKI_MARKERS`.
- **Deduplicating the 2000 ms bound, the status argv, or the ripgrep argument
  literals.** Coincidental similarity; unifying would couple unrelated modules.
- **Unifying the two `relpath` variants.** One is a defensive prefix-match, the
  other a bare substring. Not semantically identical; unifying would over- or
  under-engineer one of them.

## Facts worth carrying forward

- **`plenary.curl` raises inside a luv callback** on any curl failure unless
  `opts.on_error` is passed — a `pcall` around the call cannot catch it. On the
  sync path `on_error`'s return is discarded and the request yields an empty table
  with no `.status`. `opts.timeout` is sync-only; in callback mode bound it with
  `raw = { "--max-time", "N" }`.
- **`util.git.run` returns `lines, ok, timed_out`.** A timeout is `code == 124`
  and `signal == 9` from `vim.system():wait(ms)`. The old nil-return branch
  survives only for SIGKILL-proof processes. `review_base` relies on the
  distinction: a timed-out validation returns the stored base unvalidated and
  retries after a 10 s per-root backoff, and only a definitive failure prunes it.
  The backoff is deliberately not reset with the cache; it tracks git
  responsiveness, not store contents.
- **`config.ai` owns `DEFAULT_MODEL`** and `ai_models` reads it. That is the
  require direction that already existed (`ai_models` requires `ai`), so keep the
  export on that side or a cycle appears.
- **`ai_models`' `CURATED_FIM` is keyed by exact installable name**, not by
  family. Family keys let an installed instruct tag inherit the base tags'
  `fim = true` and skip the `<CR>` `/api/show` gate.
- **`util.state.write_atomic` returns a boolean** — `os.rename` does not raise.
  `review_base.write_state` gates its cache write-through on that return.
- **A latent quirk, left unfixed:** `statusline.refresh()`'s async callback guards
  only on buffer validity, so a wiped-then-recreated buffer number can briefly
  show another buffer's branch. Cosmetic, self-heals on the next refresh. Worth a
  guard token if that code is ever touched.
