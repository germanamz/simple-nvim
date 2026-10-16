---
type: memory
title: "Nvim typeahead batching vs expr maps"
kind: project
description: "feedkeys bursts lie about insert-mode expr maps: a normal char followed by a mapped key in typeahead gets batched, and the NEXT expr mapping is evaluated before the char lands; plus <C-u> only deletes chars typed since insert started."
---

# Nvim typeahead batching vs expr maps

Learned 2026-09-03 building the comment-continuation `<CR>` map (config.comments.cr).

**What happens:** `nvim_feedkeys("A<CR><CR>x<Esc>", "mx")` where the first
`<CR>` expr map returns `"\r "` (newline + space). Insert mode's `insertchar()`
batches consecutive normal chars: when it goes to insert the space it
`vpeekc()`s the typeahead, sees `<CR>`, and resolves that mapping — evaluating
the expr callback — BEFORE the space is in the buffer. The second callback
therefore sees the stale line (bare `//` instead of `// `). A single special
key result (`"\r"` alone) does not trigger it. Real typing never queues both
keys (PTY-verified: `// Doc.`, `//`, `x` came out right); macros and pasted
bursts do.

**Why:** `insertchar()`'s "grab pending input at once" optimisation peeks
through `vgetorpeek()`, which applies mappings on peek.

**How to apply:**
- In specs, split such flows into two insert sessions (`feed("A<CR><Esc>")`
  then `feed("A<CR>x<Esc>")`) or put a `<Cmd>lua ...<CR>` between the keys.
- Prefer expr maps that return a single special key; if a normal char must
  follow, document the macro/burst caveat.
- `<C-u>` in insert mode deletes only the characters *entered since insert
  started* when there are any (after an auto-inserted leader there are none,
  so it clears to the indent; after a typed space it deletes just the space).
  `<C-w>` takes trailing whitespace plus one word and stops at the indent,
  which is what clearing a `// ` leader needs.
- Enter after a bare leader (`//`, `#`, `--`) gives a bare leader again in
  every filetype, `b:#` or not; Neovim only copies the whitespace that was
  there. See [[nvim-headless-no-insert-in-prompt]], [[nvim-pty-probe-key-timing]].
