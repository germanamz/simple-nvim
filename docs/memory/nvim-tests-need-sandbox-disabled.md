---
type: memory
title: "Nvim tests need sandbox disabled"
kind: project
description: "make test-smoke/test-e2e fail under the Claude sandbox; run nvim tests with the sandbox disabled"
---

# Nvim tests need sandbox disabled

The smoke and e2e tiers (`make test-smoke`, `make test-e2e`, anything spawning a real headless nvim subprocess) FAIL under the default Claude Bash sandbox. The isolated test nvim writes swap files, treesitter parsers, and git fixtures under `$TMPDIR` real paths inside the sandbox's temp dir, which fall outside the sandbox write allowlist (it covers a sibling path, not the per-user temp dir). Symptoms: `E303: Unable to open swap file`, checkhealth `ERROR is not writable`, and spurious git-status assertion mismatches in telescope_spec.

**Why:** sandbox write-denials, not config or test regressions — the suite is fully green (unit + smoke 41 + e2e 20) when run normally.

**How to apply:** run `make test`, `make test-smoke`, `make test-e2e`, `make test-lsp` (and single-spec `PlenaryBustedFile` runs) with `dangerouslyDisableSandbox: true`. Pure-lua `make test-unit` runs fine inside the sandbox. The e2e suite is the refactor golden net — see [[nvim-refactor-stage-plan]].
