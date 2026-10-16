---
type: memory
title: "Qwen FIM blocked by Ollama templates"
kind: project
description: "No Qwen3-era model can replace qwen2.5-coder:7b-base for minuet FIM — Ollama ships them with no template layer, so /v1/completions 400s."
---

# Qwen FIM blocked by Ollama templates

Checked 2026-08-21: Qwen HAS shipped newer coders (Qwen3-Coder 480B/30B Jul 2025;
Qwen3-Coder-Next 80B-A3B, Base checkpoint 2026-02-01) but **none can replace
`qwen2.5-coder:7b-base`** as the minuet FIM default. "Qwen3.5-Coder" does not
exist — articles claiming a 72B version are fabricated.

**The blocker is Ollama packaging, not Qwen training.** FIM tokens are present in
every Qwen3-era tokenizer (`<|fim_prefix|>`=151659 …), but the Ollama manifests for
`qwen3-coder:30b`, `qwen3-coder-next`, `qwen3.5`, `qwen3.6` carry only three layers
— model, license, params — with **no `application/vnd.ollama.image.template` layer**.
Ollama grants `CapabilityInsert` only when a template references `suffix`
(`server/images.go:251-253`); `routes.go:448-451` then demands it whenever
`req.Suffix != ""`, which minuet sets unconditionally. Result: **HTTP 400 "does not
support insert" on every keystroke** — no ghost text at all, not merely dirty FIM.
`qwen2.5-coder:7b-base` carries the 117-byte template with the `.Suffix` branch.
Tracked upstream at ollama#12387 (open since 2025-09-23, no PR). No future Qwen
release fixes this.

Also: there has been **no Qwen coder under 30B since Sept 2024** — qwen2.5-coder is
still the only official Qwen code family with small dense *base* checkpoints.
Hand-patching a FIM template onto qwen3-coder was tried (ollama#11621) and came out
*worse* than the 7B base (eos is `<|im_end|>`, so raw FIM never stops cleanly).
Qwen3.5 fails worse — silently: patched template returns HTTP 200 with empty text
because the infill lands in the `thinking` field.

Measured locally: `qwen2.5-coder:7b-base` warm TTFT 169–210ms, RSS
6.18GB. A 0.8B Qwen3.5 was *slower* (310ms). `qwen3-coder:30b` = 17.28GiB resident
(MoE saves compute, not memory); `qwen3-coder-next` = 51.7GB, too large to load on a laptop.

**Why:** prevents re-running this research, and stops "newer model = better" from
overriding the FIM-base constraint that drives the whole minuet setup.

**How to apply:** keep `M.DEFAULT_MODEL = "qwen2.5-coder:7b-base"` in
`lua/config/ai.lua`. Tune only *within* the qwen2.5-coder base ladder
(`3b-base`/`1.5b-base` for lower TTFT, `14b-base` for quality). Never add a
qwen3-era entry to the CATALOG in `lua/config/ai_models.lua` with `fim = true` —
the existing `qwen3-coder` entry has that bug. Only lead worth an A/B: JetBrains
Mellum2-12B-A2.5B-Base (2.5B active, but not in Ollama's library, StarCoder-style
`<fim_prefix>` spelling, and below Qwen2.5-7B on HumanEval). Related:
[[nvim-leak-audit-2026-07]].
