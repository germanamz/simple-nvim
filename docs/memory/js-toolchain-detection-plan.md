---
type: memory
title: "Js toolchain detection"
kind: project
description: "JS/TS formatter+linter detection — shipped 2026-07-31 on main; the design rules and the tool gotchas that cost the most to learn."
---

# Js toolchain detection

Shipped 2026-07-31, 23 commits on `main` (94621aa..HEAD). Root cause of "nvim
always writes double quotes in JS/TS": the projects had no prettier config, so
conform ran prettier bare and its `singleQuote:false` default won, while the real
rules lived in ESLint. Not a submodule bug.

Reference doc: `docs/js-toolchain.md`. Design: `docs/superpowers/specs/2026-07-30-js-toolchain-detection-design.md`.
Modules: `config/js_toolchain` (detection), `config/js_tool_version` (drift
warning), `util/project` (root predicate shared with `config/lsp_root`),
`plugins/nvim-lint` (eslint_d on save).

**The rule that governs the whole design:** gate on "is this tool CONFIGURED",
never on "will this tool HANDLE this file". Every tool scopes itself and no-ops
quietly (prettierd on a `.prettierignore`'d file, eslint_d on a flat-config
`ignores` match, biome on an excluded file all return the input unchanged). Two
tools both running is harmless; one tool stood down on another's behalf is a
silent coverage hole. Rejected on that basis: standing `cssls`/`jsonls` down in
biome projects, because a `biome.json` can disable a language and the file would
then have no linter at all. A *static* per-server filetype list is a different
question and is fine — that is why biome is narrowed to the four JS/TS filetypes.

Tool gotchas, each of which cost a review round:

- **prettierd bundles its own prettier.** 0.28.0 ships prettier 3.9.0 at
  `.../prettierd/node_modules/@fsouza/prettierd/node_modules/prettier` (nested
  under `@fsouza`), while mason's standalone prettier is 3.8.3. `--debug-info`
  prints the daemon version FIRST, so "first semver" reads 0.28.0.
- **lspconfig's `package.json` probe is a raw text scan**, not a key lookup:
  `root_markers_with_field` iterates `file:lines()` and calls `line:find(s)`, so
  `biomejs` matches the `@biomejs/biome` dependency line. conform's prettierd
  probe *is* a real key lookup. The two marker sets differ on purpose.
- **`vim.fs.root(bufnr, …)` discards the buffer name** for any non-`""` buftype
  and answers from `uv.cwd()`. Use the path form when the buffer's project is
  what you mean.
- **eslint_d caches an ESLint instance per cwd**, and flat-config lookup starts
  there — so conform and nvim-lint must pass the *same* buffer-derived cwd or
  they silently resolve different projects.

Also fixed here: `make sync` had TWO silent no-ops — `mason-tool-installer` is
lazy on BufReadPre/BufNewFile so a headless `+MasonToolsInstallSync` with no file
never loaded it (E492, exit 0), and `InstallSync` passes `force_update=false` so
it honours `debounce_hours=24` and does nothing if any nvim checked that day. Now
`scripts/mason-sync.lua` (Lazy! load + UpdateSync + a no-lockfile guard, since an
empty `ensure_installed` makes the sync loop hang forever). See
[[nvim-tests-need-sandbox-disabled]], [[ts-ls-wrong-typescript-pnpm]].
