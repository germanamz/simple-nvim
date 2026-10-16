---
type: memory
title: "Nvim tagstack API traps"
kind: project
description: "Neovim tagstack gotchas found building config.tagstack — :tag is unusable for LSP frames, settagstack resets curidx, and quickfix <CR> interception is the wrong push mechanism."
---

# Nvim tagstack API traps

Three non-obvious Neovim tagstack facts, verified empirically against 0.12.5 while
building `lua/config/tagstack.lua` (the `<C-t>` definition stack, shipped
2026-08-27; design in `docs/navigation-stack.md`).

**`:tag` cannot navigate forward for LSP-pushed frames.** A tagstack entry stores
`{tagname, from}` — where you came FROM — never where the jump landed. Going
forward means re-resolving `tagname` through a tags file, so with none on disk it
is `E433: No tags file`, always. Reach any frame in either direction with
`settagstack(win, {curidx = j + 1}, 'r')` then `:1pop` instead; that also
collapses back/forward into one mechanism.

**`settagstack` discards a `curidx` passed alongside `items`.** The docs' "current
index is set to one after the length after the modification" wins: dropping one of
three frames while asking for `curidx = 2` yields 3. A **curidx-only** write does
work, so mutating the stack takes two calls — items first, then position.

**Intercepting the quickfix `<CR>` to defer a push is structurally wrong.** It
over-fires (the window stays open, so browsing N results pushes N identical
frames; at the 20-frame cap, 25 references evict every real hop) and under-fires
(`]q`/`[q` are Neovim 0.11+ defaults for `:cnext`/`:cprev`, and they plus `:cc`,
`:cfirst`, `<C-w><CR>` never touch a buffer-local mapping). There is no single
"user chose an entry" event; push once when the list opens.

Also: `vim.lsp.buf.references` (`buf.lua:868`) is its own implementation and never
pushes a tagstack frame at all — unlike `definition`/`implementation`/
`type_definition`, which share `get_locations` and push only on a single result
with no `on_list`. Related: [[nvim-lsp-semantic-tokens-outrank-treesitter]].
