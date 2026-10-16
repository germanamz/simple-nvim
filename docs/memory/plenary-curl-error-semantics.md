---
type: memory
title: "Plenary curl error semantics"
kind: reference
description: "plenary.curl raises error() inside a luv callback on curl failure unless opts.on_error is passed; opts.timeout is sync-only (use raw --max-time async)"
---

# Plenary curl error semantics

plenary.curl (curl.lua:299-328, job.lua): on any nonzero curl exit with NO
`opts.on_error`, plenary calls `error()` INSIDE a luv check callback — a pcall
around the curl.get/post call CANNOT catch it (the call returned when
job:start succeeded), so you get a raw stack trace and, on the sync path, the
full timeout spin. Passing `on_error = function(err) ... end` suppresses the
raise on BOTH paths.

**Why:** any config code calling plenary.curl against a possibly-down server
(Ollama) must pass on_error or it wedges guards/prints traces (this froze
ai_models' `active_scrape` forever pre-fix).

**How to apply:** async path — do UI work in the on_error callback via
vim.schedule (it receives `{message=...}`). Sync path — on_error's RETURN IS
DISCARDED; the request returns an EMPTY table (no `.status`), so gate on
`res.status`. `opts.timeout` only applies to the sync `job:sync` path; in
callback mode enforce bounds with `raw = { "--max-time", "N" }`. Used in
lua/config/ai_models.lua ([[docs/superpowers/refactoring]]).
