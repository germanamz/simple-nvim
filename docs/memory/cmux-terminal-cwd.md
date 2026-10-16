---
type: memory
title: "Cmux terminal cwd"
kind: reference
description: "<leader>tt/tv/th (config.cmux_terminal) — new-split has no cwd flag but socket surface.split takes working_directory; typed --command input is unreliable (a shell startup prompt eats a char); how to probe a new cmux shell safely."
---

# Cmux terminal cwd

Shipped on main 2026-09-24 (9bcc308): `config.cmux_terminal`, `<leader>tt` tab / `tv` split right / `th` split below, in the buffer's folder or the nvim-tree node's folder.

- `cmux new-surface --working-directory <dir>` works for tabs; lands in the caller workspace's focused pane.
- `cmux new-split` has NO cwd flag, but `cmux rpc surface.split '{"direction","surface_id","working_directory","focus"}'` honors `working_directory` (verified live 2026-09, path with a space included). cmux source: `ControlSurfaceSplitInputs.swift`.
- Do NOT fall back to `--command "cd …"` / `initial_input`: a new shell can open on a startup question (a shell framework's "update? [Y/n]" prompt), which swallows the first typed char (`pwd` → `wd`, `echo` → `cho`).
- Probing a fresh surface: `tree` gives no cwd and `tty` can stay empty for a not-yet-rendered workspace; `cmux rpc surface.read_text '{"surface_id":…}'` shows the screen. Split beside YOUR OWN surface with `focus:false`, close by UUID (`close-surface` prints a renumbered ref — that's fine).
- Live-testing with `focus:true` was skipped: it could switch the user's visible workspace mid-typing. See [[cmux-send-targeting-hazards]], [[cmux-browser-from-nvim]].
