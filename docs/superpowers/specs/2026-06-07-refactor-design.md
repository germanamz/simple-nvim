# Refactor Design — simplify, decompose, extract

**Date:** 2026-06-07
**Status:** Stage 1 complete; Stage 2 pending approval
**Repo:** personal Neovim 0.11+ config (`~/.config/nvim`)
**Companion:** `2026-06-07-feature-inventory.md` (the 90-feature contract)

## Goal

Improve performance, code quality, and maintainability of the config **without
changing behavior**, by:

1. **Simplifying functions** — collapse near-duplicate handlers, drop dead
   branches, prefer data over control flow.
2. **Decomposing high-complexity sections** into well-named sub-functions.
3. **Extracting genuinely reusable logic** into shared modules.
4. **Improving variable/function naming.**

The existing 4-tier test suite (unit + smoke + e2e + e2e-lsp, ~3.4k LOC) is the
**golden net**: it was built (`2026-04-26-testing-design.md`) precisely to make
this refactor safe. Every change must keep it green.

## Baseline (2026-06-07)

Full suite is **green**: unit + smoke (41) + e2e (20). NOTE: smoke/e2e spawn a
real headless nvim that writes swap/parser/git files under `$TMPDIR`; under a
restrictive command sandbox those writes are denied (`E303`, `not writable`) and
the suite reports false failures. **Run nvim tests with the sandbox disabled.**
Pure-lua `make test-unit` is sandbox-safe.

## Principles (how we cut)

- **Behavior is frozen.** Refactor only. Any behavior change is called out
  explicitly and gated separately (a few extractions *improve* behavior — e.g.
  giving gitsigns the `pcall`-on-stale-buffer guard lsp_refs already has; those
  are flagged below, not smuggled in).
- **Test before touch.** A module gets its high-priority coverage gaps closed
  (characterization tests against current behavior) *before* it is refactored.
- **Greenfield indirection must earn its keep.** No `lua/util/` exists today. A
  new shared module is justified only by ≥2 real consumers *and* a clean surface
  that doesn't leak per-caller params. Single-consumer helpers stay module-local.
- **Small, reviewable increments.** One concern per change; suite green after
  each; multiple Stage-2 passes per module are expected. Quality over velocity.

## Extraction catalog (common logic)

Produced by per-module analysis → cross-module synthesis → **adversarial
critique**. The critique rejected 3 of 9 proposed clusters as over-abstraction
and narrowed 4 others. Verdicts below are the critic's, kept verbatim in intent.

### ✅ DO — `lua/util/git.lua`  (SOLID, high value, low risk)

Thin git-shellout layer. The `systemlist`+`shell_error`+first-line idiom is
copy-pasted across **5 modules** with subtly inconsistent error handling —
`telescope_smart.git_root_at` can return an empty-string root, while
`review_base.git_root` and `statusline.git_branch` guard against it. Unifying
fixes a real latent bug class *and* removes ~40-60 lines.

- API (thin only — do NOT fold porcelain parsing in): `run(args, {cwd}) -> {lines, ok}`,
  `first_line(args,{cwd})`, `root(start)`, `branch(root)`, `resolve(root,ref) -> bool`,
  `file_in_ref(root,ref,relpath) -> bool`. Centralizes the `-C` flag + error semantics.
- Call sites: `telescope_smart.lua:39-51,146,182`, `review_base.lua:45-58,60-66,148-177`,
  `statusline.lua:8-14`, `gitsigns.lua:107,119`.

### ✅ DO — `lua/config/git_status_codes.lua`  (SOLID, low risk, intra-module)

The dominant-letter porcelain rule `(x~=' ' and x~='?') and x or y` is duplicated
**verbatim** at `telescope_smart.lua:95` and `:155`, plus the letter→hl mapping is
re-expressed as count buckets at `:156-166` and `:196-204`. Pure string functions;
extracting makes the git-status grammar directly unit-testable and kills the drift
hazard. Single-module → lives under `lua/config/`, not `lua/util/`.

- API: `dominant_letter(x,y)`, `hl_for_letter(letter)`, `classify_base(char)`,
  `code_to_display(code) -> {text, highlights}`.

### ◑ DO, NARROWLY — `lua/util/overlay.lua`  (scope to teardown only)

`close_legend` is **byte-identical** in `review_base.lua:113-121` and
`telescope_smart.lua:295-303` — that's the real dup (~15 lines). But the *open*
configs differ fundamentally: review_base's float is rounded-border + editor-centered;
telescope's is borderless + anchored to the results window. **Do NOT** unify the
open path or bake in position/border defaults — that re-leaks the params. Ship a
tiny handle owning `(win,buf)` state with `:close()` and a `:open(buf, win_config)`
that forwards a caller-computed config.

### ◑ DO, NARROWLY — `lua/util/extmark.lua`  (share clear + pcall paint; exclude the rest)

`Ns.new(name)`, `ns:clear(bufnr)`, and **pcall-wrapped** `ns:line_bg(...)` /
`ns:inline(...)`, shared by **gitsigns + lsp_refs only**. The payoff is policy
uniformity: `lsp_refs.lua:92` wraps `set_extmark` in `pcall`; `gitsigns.lua:139-213`
does **not** — a latent stale-buffer crash. Exclude `cursor_on_mark` (lsp_refs-specific)
and the telescope legend (uses the older `nvim_buf_add_highlight`).

### ◑ DO, NARROWLY — `lua/util/path.lua`  (extract `buf_start_dir` only)

`statusline.lua:21-30` and `gitsigns.lua:9` both turn a buffer name into a git
start-dir, but statusline has the fuller edge-case ladder (dir-buffer, isdirectory,
parent, cwd). Extract `buf_start_dir(buf)` — this *improves* gitsigns (gains the
guards). **Leave the two `relpath` variants alone**: telescope's `:111-121` is a
defensive prefix-match; gitsigns' `:115` is a bare `sub(#root+2)` substring — not
semantically identical, unifying would over/under-engineer one of them.

### ◑ DO LOCALLY — statusline refresh loop (no util)

`statusline.lua:107-117` (VimEnter) and `:119-130` (ReviewBaseChanged) are
near-identical buffer-iterate-then-`redrawstatus` loops. Fold into one **module-local**
zero-arg `refresh_all_buffers()`. Never promote to a shared util (single owner).

### ❌ SKIP (over-abstraction per critique)

- **highlight color util** — only 2 sites (`options.lua:56-64`, `markdown_paragraphs.lua:22-52`),
  logic barely overlaps; hand-rolled `#%06x` is one line each. Leave inline.
- **buf-local keymap helper** — `lsp.lua:92-94` vs `gitsigns.lua:31-33` are 3 lines
  with divergent signatures (mode-implicit vs explicit, silent default). Idiomatic
  as-is; revisit at a 3rd site.
- **cursor pos0 helper** — already extracted as the local `cursor_rc` in `lsp_refs.lua:27-30`.
  Nothing to dedup; do NOT create `lua/util/cursor.lua`.

## Complexity hotspot catalog (decompose in place)

The "promote high-cyclomatic sections to named sub-functions" targets. Ranked by
payoff. Each is an in-place decomposition (no new public surface).

| # | Location | Symbol | Decomposition |
|---|---|---|---|
| H1 | `markdown_paragraphs.lua:174-329` | `compute` (~155 LOC state machine, ~10 branches) | extract `advance_heading(path,counters,hl)`, `classify_block_start(line)`, `render_markers(blocks,headings)` |
| H2 | `gitsigns.lua:123-222` | `mark_hunks` (4 jobs) | extract `inline_diff_ranges(old,new)` (the byte-loop `:188-216`), `paint_new_vs_base()`, `paint_hunks()` |
| H3 | `telescope_smart.lua:128-215` | `_git_changes` (2 git concepts, dup classification) | `parse_worktree_status()` + `parse_committed_history()` over shared `git_status_codes.dominant_letter` |
| H4 | `telescope_smart.lua:364-478` | `open_legend` (~114 LOC) | split `build_legend_segments(counts,base)` (pure) / `render_legend_text(segs)` / `create_legend_window(...)` |
| H5 | `options.lua:179-274` | `<leader>w` markdown rewrap callback | move the whole prose/fence/table rewrap subsystem (`format_code_block`, `parse_fence`) out of `options.lua` into its own `config/markdown_rewrap.lua` |
| H6 | `review_base.lua:179-286` | `pick` (107 LOC) + select handler (5 early-returns `:245-274`) | extract `apply_selection(root, selection, on_done)`, `build_branch_entry(...)` |
| H7 | `lsp_refs.lua:32-109` | `request` (LSP cb + dedup + paint) | extract `dedup_refs(result, uri)`, `paint_refs(bufnr, positions)` |
| H8 | `lsp.lua:141-167` | mason-lspconfig server-setup loop + capabilities merge | extract `build_server_config(name, cfg)` |

Lower-priority hotspots (statusline `M.setup`, treesitter `config`, nvim-tree
autocmds, `format_prefix`) are folded into their module's pass, not separately phased.

## Test coverage & gaps

The suite already covers the load-bearing paths (the 4 logic-heavy modules each
have specs). Stage-1 analysis found **38 high-priority gaps** — behaviors a
refactor could silently break that nothing currently asserts. They are closed
*before* the corresponding module is refactored. Highest-value clusters:

- **telescope_smart**: mixed-state picker (staged/modified/untracked/committed) end-to-end
  select+open; legend counts render + update + close; review-base `b`-prefix on set/switch/clear.
- **gitsigns**: per-hunk-type background colors; word-diff char alignment (`abc`→`axc`);
  toggle-off-then-on cache-settle polling; new-vs-base full-buffer paint + toggle.
- **review_base**: pick → clear / valid branch / invalid branch (no close, no set);
  state persists across restart.
- **markdown_paragraphs**: ¶ recount on edit; insert H3 between siblings; type-transition
  without blank lines.
- **options/markdown_rewrap**: rewrap preserves frontmatter/fence/table, wraps prose,
  restores cursor; indented fence; per-language fence dispatch.
- **lsp_refs**: multi-file refs (only same-buffer marked); failed/`nil` response; stale
  response after buffer switch.

Full per-feature coverage status lives with the inventory doc.

## Proposed Stage-2 phasing

Extraction-first where an extraction unblocks several module cleanups, then
per-module decomposition. Each phase: close that phase's gap tests → refactor →
suite green → review.

- **P1 — `lua/util/git.lua`** + migrate all 5 call sites. (Highest leverage; fixes
  the empty-root bug.) Pin git-root/branch behavior first.
- **P2 — telescope_smart**: `git_status_codes.lua` extraction (H3 prep) → `_git_changes`
  (H3) → `open_legend` (H4). Largest/most-complex module; multiple passes.
- **P3 — gitsigns**: `inline_diff_ranges` + paint split (H2); adopt `util/extmark` (gains pcall).
- **P4 — markdown_paragraphs**: `compute` decomposition (H1).
- **P5 — review_base**: `pick`/`apply_selection` (H6); adopt `util/overlay` + `util/git`.
- **P6 — options**: split markdown rewrap into `config/markdown_rewrap.lua` (H5).
- **P7 — lsp stack**: `lsp_refs.request` (H7), `lsp` server-config builder (H8).
- **P8 — statusline + sweep**: local `refresh_all_buffers`; adopt `util/git`,
  `util/path.buf_start_dir`; naming pass across touched modules.

## Non-goals

- No new features, no plugin swaps, no dependency bumps.
- No reformatting churn beyond what a refactor touches (stylua stays the arbiter).
- No coverage tooling, no CI changes (the testing design already owns CI).
- The `_G.*` globals (`gitsigns_toggle_hunks`, `lsp_refs_status`, etc.) stay global
  — they are the statusline/keymap contract; renaming is out of scope.

## Risks

- **Async-dependent gitsigns tests** (toggle cache-settle, word-diff) are timing
  sensitive; characterization tests must use the existing `wait.*` helpers, no sleeps.
- **`util/git` migration touches 5 modules at once** — do it as its own phase with
  the suite green between each call-site swap, not a big-bang.
- **telescope_smart is 614 LOC** with intertwined caching + telescope patching;
  budget multiple small passes, re-run the full e2e telescope spec each time.
