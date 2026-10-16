---
type: memory
title: "Zig format-on-save flake"
kind: project
description: "e2e \"format on save reformats a zig buffer with zigfmt\" can time out (5s) under full `make test` load but passes alone — a timing flake, not a regression."
---

# Zig format-on-save flake

`tests/spec/e2e/format_on_save_spec.lua` "reformats a zig buffer with zigfmt when
written" timed out ("buffer was not reformatted by zigfmt on save", 5000ms wait)
once in a full `make test` on 2026-10-08, then passed 9/9 when the spec file was
run alone. The change under test (nvim-tree C filter) touched nothing near
conform/zig.

**Why:** zig fmt's cold start under full-suite load can exceed the 5s wait.

**How to apply:** if it is the only failure, re-run the spec alone (see
[[nvim-e2e-single-file-needs-minimal-init]], sandbox off per
[[nvim-tests-need-sandbox-disabled]]) before treating it as a regression.
