---
type: memory
title: "LSP semantic tokens outrank treesitter"
kind: reference
description: "LSP semantic tokens (prio 125) overpaint treesitter (100), so token-level highlight tweaks must be wired twice; extmark attrs OR together, so bold can't be un-set by a higher layer."
---

# LSP semantic tokens outrank treesitter

Any highlight tweak keyed on a **treesitter capture** must be made a second time
on the **LSP semantic-token** groups, or the server silently overpaints it. LSP
semantic tokens render at priority **125**, treesitter at **100**. gopls, ts_ls
and lua_ls all send them in this config (gopls does despite its
`semanticTokens` setting defaulting off — check, don't assume).

The groups are applied language-suffixed (`@lsp.type.function.go`) and resolve up
the `@`-hierarchy, so `@lsp.type.function` → `@function`. Two consequences that
break the obvious implementation:

- Bolding `@function` bolds **call sites too**, because the server paints
  `@lsp.type.function` on uses as well as declarations.
- `@lsp.type.comment` covers a whole doc comment, flattening any
  `@comment` vs `@comment.documentation` distinction. Fix by clearing it:
  `nvim_set_hl(0, "@lsp.type.comment", {})` — a defined-but-empty group
  contributes no attributes.

The declaration/use discriminator is the LSP **modifier**, and servers disagree,
so wire both: gopls sends `definition`, ts_ls sends `declaration`, and **lua_ls
sends neither**.

**The law that makes the lua_ls case work:** extmark attributes **OR together
across layers** — a higher-priority `bold = false` cannot clear a lower-priority
`bold`. So a server sending no defining modifier costs nothing; treesitter's bold
survives through the LSP layer. Design for that and the wiring degrades instead
of failing closed.

Also: `nvim_get_hl(0, { name = g, link = false })` returns the *effective*
definition and round-trips back into `nvim_set_hl`, which is how you add `bold`
to a theme group without hardcoding its colour. Snapshot the "use" group
**before** boldening the declaration group — an undefined `@function.call`
resolves up to `@function` and would pick the new bold straight back up.

**Styling a capture is never local to it.** `@function` and `@type.definition`
are family ROOTS, and three things reach a root and inherit whatever you put
there: an undefined `@a.b` resolving UP the `@`-hierarchy (`@function.macro`,
which lands on Rust macro *uses*); a theme link (github-theme points
`@lsp.type.class` at `@function`); and Neovim's own defaults (`@lsp.type
.typeParameter` → `@type.definition`, so every generic `T` inherits it). Order
the pass **compute all plain weights → style → re-pin**, and handle the two
mechanisms differently: *discover* links by scanning `nvim_get_hl(0, {})` for
`link ==` your target (skip the groups you create yourself, or the second run
undoes its own work), and *list* hierarchy children, since an undefined group
does not exist to be scanned for. Membership in that same map is what separates
"undefined, falls through" from "defined-but-empty on purpose" — the latter
blocks the hierarchy deliberately and must be left alone.

Shipped as `config.syntax_emphasis` (see docs/superpowers/token-emphasis.md).

Related: [[nvim-ephemeral-extmark-no-line-hl]], [[docs/superpowers/refactoring]].
