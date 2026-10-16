---
type: memory
title: "Hover docs via DevDocs"
kind: project
description: "K in C/C++/Python appends offline DevDocs excerpts when the LSP hover has no docs (branch feat/hover-docs, 2026-09-15); user decisions, bundle facts, and refuted alternatives not to re-propose."
---

# Hover docs via DevDocs

Shipped 2026-09-15 on main, commits 7b016de..f6d7552 (pushed):
`config.docs.hover` (K driver, mapped in LspAttach for c/cpp/python only),
`config.docs.devdocs` (store, excerpts, `:DocsInstall`),
`config.docs.brief.{c,python}` (name the symbol via clangd
`textDocument/symbolInfo` / pyright `declaration`). `docs/hover-docs.md` was
rewritten in implementation voice and committed; `docs/hover-docs-plan.md` stays
untracked ([[spec-docs-in-repo-not-scratchpad]]). Bundles install under
~/.local/share/nvim/devdocs.

**User decisions:** excerpt goes INSIDE the K float; DevDocs for ALL three
languages (the user's call, replacing a first draft of local man/pydoc); C looks
in the `c` bundle, then the `man` bundle preferring POSIX `3p`; bundles only via
explicit `:DocsInstall` — K never touches the network.

**Facts that cost probing:** macOS SDK and libc++ headers carry no doc comments,
so clangd hovers are template-only; pyright shows docstrings only when .py
source exists (`os.path.join` yes, `len`/`print` no). DevDocs `c` is ISO C only
(no read/write/tcsetattr/ioctl); the `man` bundle (143 MB, Linux man-pages +
POSIX 3p) has them, with index names spelled `read (3p)`. clangd symbolInfo
`containerName..name` matches DevDocs cpp names exactly (`std::vector::push_back`);
`std::to_string` has 3 pages, disambiguated by the declaring header's basename.
Python index names are `len()`, `str.split()`, `os.path.join()` (pyright routes
os.path to posixpath.pyi, so the buffer's dotted word is the fallback).
Single-page GETs to documents.devdocs.io stalled for 20s; db.json needs curl --retry.

**Refuted, don't re-propose:** local man/pydoc as K's source; cppman (network on
cache miss); fetching pages on demand; appending to core's hover float after it
opens; wrapping client.request; decoding db.json at lookup time (it is split at
install in `nvim --clean -l`); mapping K on every LSP buffer; opening the hover
first and growing the float.

**Known cosmetic residue:** a truncated excerpt can end on a lead-in line
("Otherwise,"); cppreference inline revision markers lose a space
("contract)(since C99)"). Related: [[nvim-e2e-no-edit-lsp-filetypes]].
