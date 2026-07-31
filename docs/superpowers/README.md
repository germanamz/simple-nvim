# Engineering record

How the larger pieces of this config were designed, what actually shipped, and
which ideas were tried and rejected. `../README.md` documents behavior for
someone *using* the config; these documents are for someone *changing* it.

Everything here has been checked against the code as of **2026-07-31**. Where a
design and the implementation diverged, the implementation wins and the
divergence is called out — those deltas are usually the most useful part.

## Contents

- **[testing.md](testing.md).** The determinism layer (five pins, one file each)
  and the four-tier test suite. Includes the harness constraints that are easy
  to rediscover the hard way, and the one planned piece that was never built.
- **[refactoring.md](refactoring.md).** Two whole-config quality passes: what was
  extracted into `lua/util/`, the rule that decides whether a shared module earns
  its keep, and the list of proposals that were examined and refuted — do not
  re-propose them.
- **[git-at-scale.md](git-at-scale.md).** Multi-submodule support: how the config
  stays responsive on superprojects with hundreds of submodules, what each
  hardening stage guarantees, and how to verify it by hand.
- **[block-guides.md](block-guides.md).** Vertical guides marking the foldable
  blocks the cursor is nested inside.
- **[nvim-tree-context.md](nvim-tree-context.md).** Sticky ancestor folders
  pinned to the top of the file tree.
- **[telescope-pickers.md](telescope-pickers.md).** The shared picker-legend
  machinery, plus the three pickers built on it: buffers flags, folder-scoped
  grep, and the LSP client picker.
- **[markdown-preview.md](markdown-preview.md).** The `glow`-backed preview pane
  that replaced in-buffer markdown decoration.
- **[theme.md](theme.md).** The move to GitHub Light high-contrast, and what the
  config still overrides on top of it.

## Where the originals went

These documents were synthesized from 19 design specs, phase plans and
verification handoffs that lived under `docs/superpowers/specs/` and
`docs/superpowers/plans/`. Those were deleted on 2026-07-31, after an audit
confirmed nothing of forward value survived only in them — the durable parts are
above, and the rest was TDD scaffolding, acceptance criteria for finished work,
and `file:line` references that had already drifted.

Git still has them:

```sh
git log --diff-filter=D -- docs/superpowers/specs docs/superpowers/plans
git show <that-commit>^:docs/superpowers/specs/2026-04-26-testing-design.md
```

Reach for them only to recover the reasoning behind a decision these documents
state as fact. If you find such a gap, fix it here rather than restoring a file.

## Reading order

If you are new to the repo, `../keybindings.md` and `../README.md` first. Then
[testing.md](testing.md) — nothing else here is safe to change without knowing
how to run the suite and why it needs the sandbox off.
