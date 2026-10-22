# Neovim ecosystem for Python code navigation and readability (as of 2026-10-21)

> A research note from October 2026, one of the sources for [the Python navigation research](README.md). It describes other editors and tools as of that date, and this config as it was before the switch to basedpyright.

Method note: the Neovim behaviour below was read from the v0.12.5 runtime docs (news.txt, news-0.11.txt, lsp.txt, deprecated.txt, treesitter.txt) and cross-checked against upstream source. Plugin maintenance data comes from the GitHub REST API (archived flag, pushed_at) and each repo's commit and release Atom feeds, all fetched on 2026-10-21. Distribution behaviour comes from their current source files on GitHub, not from their docs sites. File paths inside upstream repos are written as plain text, not inline code, so this vault's doctor does not treat them as local paths.

## Q1. What Neovim 0.11 and 0.12 provide natively for navigation and readability

### Takeaway
Neovim 0.12 is the current stable line: 0.12.0 shipped 2026-03-29 and 0.12.6 on 2026-10-09. Stock Neovim covers most navigation verbs: `gr*` default keymaps, call hierarchy and type hierarchy into quickfix, LSP folding, inlay hints, semantic tokens, document highlight, a reimplemented codelens, and LSP or treesitter incremental selection. There is still no built-in breadcrumbs/winbar, sticky context, symbol outline sidebar, peek window or reference counter, so plugins still have to fill those gaps. Several features are opt-in: codelens, inlay hints, linked editing, inline completion, document highlight (needs your own autocmd) and LSP folding (needs foldexpr set).

### Cited Findings
**Release status**
- Nvim 0.12.0 was published 2026-03-29, then 0.12.1 (2026-04-06), 0.12.2 and 0.12.3 (2026-06-10), 0.12.4 (2026-07-05), 0.12.5 (2026-08-23) and 0.12.6 (2026-10-09). The last 0.11 release is 0.11.7 (2026-03-29). Dates are the feed's "updated" timestamps — [neovim releases feed](https://github.com/neovim/neovim/releases); [v0.12.0](https://github.com/neovim/neovim/releases/tag/v0.12.0)
- The nvim-treesitter `main` branch now requires "Neovim 0.12.0 or later (nightly)". The `master` branch "is locked but will remain available for backward compatibility with Nvim 0.11" — [nvim-treesitter README (main)](https://github.com/nvim-treesitter/nvim-treesitter/blob/main/README.md). LazyVim 15.15.0 (2026-04-02) records: "`nvim-treesitter` no longer support nvim-0.11, so pin when needed" — [LazyVim CHANGELOG](https://github.com/LazyVim/LazyVim/blob/main/CHANGELOG.md)

**Default keymaps (global, created at startup)**
- 0.11 added: `grn` → `vim.lsp.buf.rename()`, `grr` → `references()`, `gri` → `implementation()`, `gO` → `document_symbol()`, `gra` (Normal and Visual) → `code_action()`, and Insert/Select `CTRL-S` → `signature_help()`. It also added a "Go to definition" item to the mouse popup menu, plus `[d`/`]d` with a count, `[D`/`]D`, and unimpaired-style `[q ]q [l ]l [t ]t [a ]a [b ]b` — [news-0.11.txt (DEFAULTS)](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/news-0.11.txt)
- 0.12 added `grt` → `vim.lsp.buf.type_definition()` and `grx` → `vim.lsp.codelens.run()` — [news.txt 0.12 (DEFAULTS)](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/news.txt)
- `:h lsp-defaults` in 0.12 lists the full global set: gra, gri, grn, grr, grt, grx, gO and i_CTRL-S. `v_an`/`v_in` fall back to `vim.lsp.buf.selection_range()` when treesitter is not active, and `gx` handles `textDocument/documentLink` — [lsp.txt lsp-defaults](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/lsp.txt)
- Buffer-local defaults on attach: 'tagfunc' = `vim.lsp.tagfunc()`, so `CTRL-]`, `CTRL-W ]`, `CTRL-W }` and `:tjump` go through LSP definition. `K` → hover unless 'keywordprg' or a `K` map is set. 'omnifunc' and 'formatexpr' are also set, and document colors are on — [lsp.txt](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/lsp.txt)
- There is no default `gd`/`gD` LSP mapping; `CTRL-]` via tagfunc is the built-in route to definition. Of the distributions checked, LazyVim and NvChad map `gd` themselves and kickstart maps `grd` — [lsp.txt](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/lsp.txt)

**Navigation functions**
- `vim.lsp.buf.document_symbol()` fills the location list; `workspace_symbol()` fills quickfix — [lsp.txt](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/lsp.txt)
- `vim.lsp.buf.incoming_calls()` / `outgoing_calls()` list call sites in quickfix and use `inputlist()` when the symbol resolves to several items. `vim.lsp.buf.typehierarchy("subtypes"|"supertypes")` lists into quickfix and picks with `vim.ui.select()` — [lsp.txt](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/lsp.txt)
- Since 0.11, references, declaration, definition, type_definition, implementation and hover merge results from multiple clients and no longer go through the global `vim.lsp.handlers` — [news-0.11.txt (BREAKING/LSP)](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/news-0.11.txt)
- The location functions take `vim.lsp.LocationOpts`, including `on_list`, `loclist` and `reuse_win` (jump to an existing window if the buffer is already shown) — [lsp.txt](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/lsp.txt)
- `vim.lsp.with()` is deprecated: "Pass configuration to equivalent functions in vim.lsp.buf.*". `vim.lsp.handlers` "does not support client-to-server response handlers" — [deprecated.txt](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/deprecated.txt)

**Readability features**
- LSP folding arrived in 0.11 with `vim.lsp.foldexpr()`, used as `foldmethod=expr` plus `foldexpr=v:lua.vim.lsp.foldexpr()`. The doc's own example defaults to `vim.treesitter.foldexpr()` and switches per window in `LspAttach` when the client supports `textDocument/foldingRange`. `vim.lsp.foldtext()` shows the server's collapsedText — [news-0.11.txt](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/news-0.11.txt); [lsp.txt vim.lsp.foldexpr()](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/lsp.txt)
- Inlay hints are toggled with `vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled())` and are not on by default. The quickstart lists codelens, linked_editing_range, inlay_hint and inline_completion as "disabled by default, you can enable them manually" — [lsp.txt](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/lsp.txt)
- Semantic highlighting is applied "when available" on top of treesitter; it does not replace it. 0.12 renamed `vim.lsp.semantic_tokens.start()/stop()` to `enable()`, and added `textDocument/semanticTokens/range` and multiline token support — [lsp.txt lsp-semantic-highlight](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/lsp.txt); [news.txt 0.12](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/news.txt)
- Document highlight is not automatic. `:h vim.lsp.buf.document_highlight()` shows wiring it to `CursorHold`/`CursorHoldI` and clearing with `clear_references()` — [lsp.txt](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/lsp.txt)
- 0.11: hover rendering improved, hover highlights the hovered range with `LspReferenceTarget`, `signature_help()` cycles signatures with `<C-s>` and supports multiple clients, and the new 'winborder' option sets the default float border — [news-0.11.txt](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/news-0.11.txt)
- Hover options (`vim.lsp.buf.hover.Opts`) include `border`, `max_width`, `focusable` and `anchor_bias`. Calling hover twice (`KK`) focuses the float — [lsp.txt](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/lsp.txt)
- 0.12 'winborder' gained a "bold" style and custom border styles, and the new 'pumborder' option borders the popup menu — [news.txt 0.12](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/news.txt)
- 0.12 reimplemented `textDocument/codeLens`: lenses display as virtual lines, `workspace/codeLens/refresh` is supported, and `vim.lsp.codelens.enable()` toggles them — [news.txt 0.12](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/news.txt); [lsp.txt lsp-codelens](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/lsp.txt)
- 0.12 incremental selection: `an` selects the [count]th parent node and `in` goes inward, via treesitter, falling back to LSP `selectionRange` — [treesitter.txt](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/treesitter.txt); [news.txt 0.12](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/news.txt)
- 0.12 also brings `textDocument/documentColor`, linked editing, onTypeFormatting, inlineCompletion, pull diagnostics and `workspace/diagnostic` (`vim.lsp.buf.workspace_diagnostics()`). Related diagnostic info appears in `open_float()`, where `gf` jumps to it — [news.txt 0.12](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/news.txt)

**Client management (0.11 / 0.12)**
- 0.11 added `vim.lsp.config()` (plus `lsp/<name>.lua` files on the runtimepath) and `vim.lsp.enable()` — [news-0.11.txt](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/news-0.11.txt)
- 0.12 added:
  - the `:lsp` command (`:lsp enable|disable|restart|stop`)
  - `workspace_required` (no single-file mode)
  - priority control for `root_markers`
  - `vim.lsp.enable()` starting and stopping clients and detaching non-applicable ones
  - `vim.lsp.is_enabled()` and `vim.lsp.get_configs()`
  - `:checkhealth vim.lsp` per-buffer feature attachment
  - `reuse_client` now receiving the target buffer

  Sources: [news.txt 0.12](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/news.txt); [lsp.txt :lsp](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/lsp.txt)
- `root_markers`: "The list order decides priority. To indicate 'equal priority', specify names in a nested list". The search stops at the first directory containing the marker, and that directory becomes the workspace folder — [lsp.txt lsp-root_markers](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/lsp.txt)
- The default `reuse_client` "re-uses a client if name and root_dir matches" — [lsp.txt](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/lsp.txt)
- 0.12 ships a built-in plugin manager, `vim.pack`. The default 'statusline' now shows `vim.diagnostic.status()` and `vim.ui.progress_status()` but no code context — [news.txt 0.12](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/news.txt)

### Inferences
- Natively you get "list" UIs (quickfix, loclist, inputlist, vim.ui.select) for references, implementations, call hierarchy and type hierarchy. The IDE-like pieces are absent upstream: tree-shaped call hierarchy, outline sidebar, breadcrumbs, sticky scope header, peek float, reference counts. That is where plugins add value.
- No 0.12 news entry or lsp.txt section describes a built-in winbar/breadcrumb or outline. I searched the 0.12 news and lsp.txt and found none, so "not built in" is an inference from absence.
- `grx` and the reimplemented codelens only help if the Python server emits code lenses. ty explicitly does not, and pyright/basedpyright do not advertise codeLensProvider (see Q2). For Python, codelens is effectively dead weight.

### Gaps
- The 0.11.0 release date (2025-03) is from prior knowledge. The GitHub API rate limit blocked re-verifying it.
- I did not test 'winborder' interplay with plugin floats.

## Q2. How the major distributions configure Python (server choice, ruff, venv, dap, neotest, navigation plugins)

### Takeaway
- **LazyVim** (v16.0.1, 2026-09-08): defaults to pyright, with a one-variable switch to basedpyright; ty is not offered. It runs ruff alongside with ruff's hover disabled and adds venv-selector, dap-python and neotest-python. Inlay hints and LSP folding are on, codelens is off. Navigation polish is optional extras: aerial, outline, navic, treesitter-context, and the snacks or telescope picker.
- **AstroCommunity**: its python pack defaults to basedpyright plus black and isort. ruff and ty subpacks exist.
- **kickstart.nvim**: has moved to `vim.pack` (0.12) and leaves pyright commented out.
- **NvChad v2.5**: configures no Python server and disables semantic tokens for every server.

### Cited Findings
#### Server capability matrix (what each Python server can do for navigation)
- pyright's static `initialize` capabilities are: definition, declaration, typeDefinition, references, documentSymbol, workspaceSymbol, hover, documentHighlight, rename, completion, signatureHelp, codeAction, executeCommand and callHierarchy. There is no implementationProvider, inlayHintProvider, semanticTokensProvider, typeHierarchyProvider, foldingRange or codeLens — [pyright languageServerBase.ts](https://github.com/microsoft/pyright/blob/main/packages/pyright-internal/src/languageServerBase.ts)
- basedpyright's capabilities add implementationProvider, inlayHintProvider, semanticTokensProvider and documentOnTypeFormattingProvider. Still no typeHierarchy, foldingRange or codeLens — [basedpyright languageServerBase.ts](https://github.com/DetachHead/basedpyright/blob/main/packages/pyright-internal/src/languageServerBase.ts)
- The latest basedpyright is v1.40.2 (pyright 1.1.414), 2026-10-04 — [basedpyright releases](https://github.com/DetachHead/basedpyright/releases)
- ty supports, per its feature table:
  - callHierarchy and typeHierarchy
  - declaration, definition and typeDefinition
  - implementation ("Find known implementations of a class or class member, including subclasses and method overrides")
  - references, documentSymbol and workspace symbol
  - documentHighlight, foldingRange, inlayHint, semanticTokens and selectionRange
  - rename and workspace diagnostics

  Not supported: codeLens, documentLink, documentColor and willRenameFiles. Formatting is left to ruff — [ty language-server docs](https://github.com/astral-sh/ty/blob/main/docs/features/language-server.md)
- ty is "currently in beta", uses 0.0.x versioning and "does not yet have a stable API" — [ty README](https://github.com/astral-sh/ty/blob/main/README.md). The latest release is 0.0.90 (2026-10-20) — [ty releases](https://github.com/astral-sh/ty/releases)
- ty's docs recommend nvim-lspconfig plus `vim.lsp.enable('ty')` on Neovim 0.11+ — [docs.astral.sh/ty/editors](https://docs.astral.sh/ty/editors/)
- Pyrefly is at v1.4.0 (2026-10-15) — [pyrefly releases](https://github.com/facebook/pyrefly/releases). A third-party guide recommends Pyrefly "for most Python projects today" and calls ty less settled. This is opinion — [pydevtools: ty vs Pyrefly](https://pydevtools.com/handbook/explanation/ty-vs-pyrefly/)
- nvim-lspconfig ships `vim.lsp.Config` files for pyright, basedpyright, ty, pyrefly, zuban, pylsp and ruff (lsp/<name>.lua on master) — [nvim-lspconfig lsp/](https://github.com/neovim/nvim-lspconfig/tree/master/lsp)
  - pyright and basedpyright: root_markers `pyrightconfig.json, pyproject.toml, setup.py, setup.cfg, requirements.txt, Pipfile, .git`; `diagnosticMode = 'openFilesOnly'`; `disableTaggedHints = true`; buffer commands `:LspPyrightOrganizeImports` and `:LspPyrightSetPythonPath` — [lsp/pyright.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/pyright.lua); [lsp/basedpyright.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/basedpyright.lua)
  - ty: `cmd = {'ty','server'}`, root_markers `ty.toml, pyproject.toml, setup.py, setup.cfg, requirements.txt, .git` — [lsp/ty.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/ty.lua)
  - ruff: `cmd = {'ruff','server'}`, root_markers `pyproject.toml, ruff.toml, .ruff.toml, .git` — [lsp/ruff.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/ruff.lua)

#### LazyVim
- LazyVim v16.0.1 was released 2026-09-08 and v16.0.0 on 2026-05-27. v16's breaking change concerns refactoring.nvim only, and it adds nvim-0.13 version checks — [LazyVim CHANGELOG](https://github.com/LazyVim/LazyVim/blob/main/CHANGELOG.md)
- 15.x requires Neovim >= 0.11.2. It configures LSP "with the native `vim.lsp.config`", moved to mason v2 and nvim-treesitter `main`, replaced treesitter incremental selection with flash.nvim, and uses "LSP based folding when available" — [LazyVim NEWS.md](https://github.com/LazyVim/LazyVim/blob/main/NEWS.md)
- lang.python extra — [extras/lang/python.lua](https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/plugins/extras/lang/python.lua):
  - `vim.g.lazyvim_python_lsp = "pyright"` is the default; set it to "basedpyright" to switch. `vim.g.lazyvim_python_ruff = "ruff"` (or "ruff_lsp"). It enables only the chosen server and ruff.
  - ruff gets `cmd_env RUFF_TRACE=messages`, `logLevel = "error"`, and `hoverProvider = false` ("Disable hover in favor of Pyright").
  - Treesitter adds ninja and rst.
  - neotest-python adapter.
  - nvim-dap-python with `setup("debugpy-adapter")`, keys `<leader>dPt` (test method) and `<leader>dPc` (test class). mason-nvim-dap's python handler is neutralised.
  - venv-selector.nvim with `cmd = "VenvSelect"`, `ft = "python"`, key `<leader>cv`, and `notify_user_on_venv_activation = true`.
  - The extra is recommended when root has pyproject.toml, setup.py, setup.cfg, requirements.txt, Pipfile or pyrightconfig.json.
  - No ty option exists in the current source.
- Core LSP defaults — [plugins/lsp/init.lua](https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/plugins/lsp/init.lua):
  - `inlay_hints.enabled = true` (vue excluded), `codelens.enabled = false`, and `folds.enabled = true`, which sets `foldexpr = v:lua.vim.lsp.foldexpr()` when a server supports foldingRange.
  - Global server keys: `gd` definition, `gr` references, `gI` implementation, `gy` type definition, `gD` declaration, `K` hover, `gK`/`<c-k>` signature help, `<leader>cc`/`<leader>cC` codelens run/refresh, `<leader>cr` rename, `<leader>co` organize imports (auto-added when the server offers it), `<leader>cR` rename file.
  - `]]`/`[[` and `<a-n>`/`<a-p>` jump between document-highlight references via `Snacks.words`.
- The snacks picker extra overrides `gd/gr/gI/gy` with `Snacks.picker.lsp_*`, adds `<leader>ss` (lsp_symbols with a kind filter) and `<leader>sS` (workspace symbols), and adds **`gai` / `gao`** for incoming and outgoing calls (gated on `callHierarchy/*`) — [extras/editor/snacks_picker.lua](https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/plugins/extras/editor/snacks_picker.lua)
- The telescope extra maps `gd` → `lsp_definitions({reuse_win=true})`, `gr` → `Telescope lsp_references`, `gI`/`gy` with `reuse_win`, and uses `lsp_document_symbols` / `lsp_dynamic_workspace_symbols` with a kind filter — [extras/editor/telescope.lua](https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/plugins/extras/editor/telescope.lua)
- Default editor plugins include trouble.nvim with `<leader>cs` → `Trouble symbols toggle` — [plugins/editor.lua](https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/plugins/editor.lua)
- Optional navigation extras:
  - editor.aerial: `attach_mode = "global"`, backends `{ "lsp", "treesitter", "markdown", "man" }`, guides — [aerial.lua](https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/plugins/extras/editor/aerial.lua)
  - editor.outline: outline.nvim on `<leader>cs`, displacing Trouble symbols — [outline.lua](https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/plugins/extras/editor/outline.lua)
  - editor.navic: attaches on `textDocument/documentSymbol`, lualine component, `depth_limit = 5`, `lazy_update_context = true` — [navic.lua](https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/plugins/extras/editor/navic.lua)
  - ui.treesitter-context: `mode = "cursor"`, `max_lines = 3`, toggle `<leader>ut` — [treesitter-context.lua](https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/plugins/extras/ui/treesitter-context.lua)
- 14.x made fzf-lua and blink.cmp defaults and added snacks.scope, snacks.dim, snacks.zen, snacks.indent and snacks.scroll — [LazyVim NEWS.md](https://github.com/LazyVim/LazyVim/blob/main/NEWS.md)

#### AstroNvim / AstroCommunity
- AstroNvim v6.1.1 was released 2026-10-16 and astrocommunity v20.0.0 on 2026-04-02 (releases feeds) — [AstroNvim releases](https://github.com/AstroNvim/AstroNvim/releases); [astrocommunity releases](https://github.com/AstroNvim/astrocommunity/releases)
- `astrocommunity.pack.python` imports `python.base`, `python.basedpyright`, `python.black` and `python.isort` — [pack/python/init.lua](https://github.com/AstroNvim/astrocommunity/blob/main/lua/astrocommunity/pack/python/init.lua). The README documents subpacks basedpyright, ruff, isort and black — [pack/python/README.md](https://github.com/AstroNvim/astrocommunity/blob/main/lua/astrocommunity/pack/python/README.md)
- The base subpack provides:
  - treesitter python and toml
  - debugpy via mason-tool-installer, with the mason-nvim-dap python handler neutralised
  - venv-selector.nvim, enabled only if `fd`/`fdfind`/`fd-find` is executable, on `<Leader>lv`
  - nvim-dap-python using `exepath("debugpy-adapter")`, falling back to `python`
  - neotest-python

  Source: [pack/python/base.lua](https://github.com/AstroNvim/astrocommunity/blob/main/lua/astrocommunity/pack/python/base.lua)
- The basedpyright subpack:
  - `before_init` sets `settings.python.pythonPath = vim.fn.exepath "python"`
  - `typeCheckingMode = "basic"`, `autoImportCompletions = true`
  - downgrades unused import/function/variable to information
  - silences reportGeneralTypeIssues, reportOptionalMemberAccess, reportOptionalSubscript and reportPrivateImportUsage

  Source: [pack/python/basedpyright](https://github.com/AstroNvim/astrocommunity/blob/main/lua/astrocommunity/pack/python/basedpyright/init.lua)
- The ruff subpack disables ruff hover (`on_attach` sets `hoverProvider = false`) and uses conform with `ruff_fix`, `ruff_organize_imports` and `ruff_format` — [pack/python/ruff](https://github.com/AstroNvim/astrocommunity/blob/main/lua/astrocommunity/pack/python/ruff/init.lua)
- A ty subpack exists (`config = { ty = {} }` plus a mason install) but is not listed in the README — [pack/python/ty](https://github.com/AstroNvim/astrocommunity/blob/main/lua/astrocommunity/pack/python/ty/init.lua)

#### kickstart.nvim
- kickstart now installs plugins with the built-in `vim.pack` (`vim.pack.add { gh 'folke/which-key.nvim' }` …). It points readers to echasnovski's 2026-03-13 vim.pack guide and adjusts mini.ai mappings "to avoid conflicts with the built-in incremental selection mappings on Neovim>=0.12". This implies Neovim 0.12 is the target — [kickstart init.lua](https://github.com/nvim-lua/kickstart.nvim/blob/master/init.lua)
- LSP setup:
  - mason, mason-lspconfig and mason-tool-installer, then `vim.lsp.config(name, server)` and `vim.lsp.enable(name)`. The `servers` table has `-- pyright = {},` commented out, and the conform python formatter line (`isort`, `black`) is commented.
  - A Telescope `LspAttach` group overrides `grr` → `lsp_references`, `gri` → `lsp_implementations`, `grd` → `lsp_definitions`, `gO` → `lsp_document_symbols`, `gW` → `lsp_dynamic_workspace_symbols` and `grt` → `lsp_type_definitions`. It also maps `grn`, `gra` and `grD` (declaration).
  - Document highlight on `CursorHold`/`CursorHoldI`, cleared on `CursorMoved`, guarded by `client:supports_method('textDocument/documentHighlight')`.
  - `<leader>th` toggles inlay hints when supported.

  Source: [kickstart init.lua](https://github.com/nvim-lua/kickstart.nvim/blob/master/init.lua)

#### NvChad
- NvChad v2.5 `nvchad.configs.lspconfig.defaults()` sets an `LspAttach` handler that maps `gD`, `gd`, `<leader>wa`/`<leader>wr`/`<leader>wl` (workspace folders), `<leader>D` (type definition) and `<leader>ra` (NvRenamer). `on_init` **removes semanticTokensProvider for every client**. It uses `vim.lsp.config("*", …)` and enables only lua_ls — [NvChad lspconfig.lua (v2.5)](https://github.com/NvChad/NvChad/blob/v2.5/lua/nvchad/configs/lspconfig.lua)
- The NvChad starter enables only `html` and `cssls`; Python is left to the user — [NvChad starter configs/lspconfig.lua](https://github.com/NvChad/starter/blob/main/lua/configs/lspconfig.lua)
- venv-selector documents an NvChad statusline module, so venv display is an add-on there — [venv-selector USAGE.md](https://github.com/linux-cultist/venv-selector.nvim/blob/main/docs/USAGE.md)

### Inferences
- With pyright (LazyVim's default), the default `gri`/`gI` implementation keymap has nothing to call: pyright advertises no implementationProvider. You also get no inlay hints, no LSP semantic tokens and no LSP folds, so LazyVim's "inlay_hints/folds enabled" does nothing for Python on pyright.
- basedpyright gives implementation, inlay hints and semantic tokens. ty adds type hierarchy and folding but is beta (0.0.x). For a "read big codebases" goal, basedpyright is the conservative choice, and ty is the one to trial for type hierarchy and speed.
- Every distribution that pairs ruff with a type-checking server disables ruff's hover. Ruff's own docs recommend the same (see Q5). This is the consensus pattern to copy.
- None of the distributions enables a reference counter, peek window or call-tree plugin by default. Breadcrumbs, outline and sticky context are opt-in extras in LazyVim and absent from kickstart and NvChad defaults.

### Gaps
- I did not fetch the lazyvim.org/extras/lang/python page itself, only the source it is generated from.
- I did not check whether LazyVim has a separate ty or pyrefly extra under another name. A grep of the python extra shows none.
- AstroNvim core's own LSP keymaps (astrolsp defaults) were not inspected.
- NvChad's ui plugin (base46/ui) may add breadcrumbs or other UI. Not checked.

## Q3. Plugins for navigating big codebases: what exists, what it does, maintenance and 0.11+ compatibility

### Takeaway
The most active choices as of Oct 2026, with an issue or release in 2026:
- **Outline sidebar**: aerial.nvim (v4.0.0, 2026-05, needs 0.11+) or outline.nvim (commit 2026-10).
- **Breadcrumbs**: dropbar.nvim (needs 0.11+, active), or nvim-navic as a statusline/winbar component.
- **Sticky context**: nvim-treesitter-context (commit 2026-10).
- **Symbols and call hierarchy in a picker**: Telescope `lsp_incoming_calls`/`lsp_outgoing_calls`, fzf-lua (adds `lsp_type_sub/super` and `lsp_finder`), snacks.picker (`lsp_incoming_calls`), or namu.nvim (0.11+, call in/out/both, very active).
- **Peek**: glance.nvim (commit 2026-09).
- **Reference counts**: symbol-usage.nvim (commit 2026-04).

Archived or stale: barbecue.nvim (archived), symbols-outline.nvim (archived), lsp-lens.nvim (last commit 2023-12), litee-calltree.nvim (last commit 2024-10, relies on handler overrides 0.11 no longer honours), portal.nvim (2024-04). trouble.nvim has had no commit since 2025-10-31.

### Cited Findings
#### Maintenance table (GitHub API + Atom feeds, fetched 2026-10-21)
| Plugin | Archived? | Last commit (default branch) | Latest release | Stated min Neovim | Source |
|---|---|---|---|---|---|
| linux-cultist/venv-selector.nvim | no | 2026-05-20 | none (branches) | >= 0.11 | [repo](https://github.com/linux-cultist/venv-selector.nvim) |
| stevearc/aerial.nvim | no | 2026-06-02 | v4.0.0 (2026-05-24) | 0.11+ | [repo](https://github.com/stevearc/aerial.nvim) |
| hedyhli/outline.nvim | no | 2026-10-10 | v1.2.0 (2026-01-31) | 0.7+ (0.8+ recommended) | [repo](https://github.com/hedyhli/outline.nvim) |
| folke/trouble.nvim | no | 2025-10-31 | v3.7.1 (2025-02-12) | >= 0.9.2 | [repo](https://github.com/folke/trouble.nvim) |
| bassamsdata/namu.nvim | no | 2026-10-01 | v0.7.0 (2026-09-28) | 0.11+ (vim.pack install needs 0.12) | [repo](https://github.com/bassamsdata/namu.nvim) |
| Bekaboo/dropbar.nvim | no | 2026-09-25 | v14.2.1 (2025-08-02) | >= 0.11.0 | [repo](https://github.com/Bekaboo/dropbar.nvim) |
| SmiteshP/nvim-navic | no | 2026-09-02 | none | >= 0.7.0 | [repo](https://github.com/SmiteshP/nvim-navic) |
| utilyre/barbecue.nvim | **ARCHIVED** | last push 2024-08-20 | – | – | [repo](https://github.com/utilyre/barbecue.nvim) |
| nvimdev/lspsaga.nvim | no | 2026-07-16 | none | n/a (docs site © 2024) | [repo](https://github.com/nvimdev/lspsaga.nvim) |
| nvim-treesitter/nvim-treesitter-context | no | 2026-10-09 | v1.0.0 (2025-05-29) | >= 0.9.0 (README) | [repo](https://github.com/nvim-treesitter/nvim-treesitter-context) |
| DNLHC/glance.nvim | no | 2026-09-03 | none | >= 0.9.0 | [repo](https://github.com/DNLHC/glance.nvim) |
| rmagatti/goto-preview | no | 2025-12-26 | v1.1.0 (2024-06-27) | >= 0.10 | [repo](https://github.com/rmagatti/goto-preview) |
| Wansmer/symbol-usage.nvim | no | 2026-04-06 | none | >= 0.9.0 | [repo](https://github.com/Wansmer/symbol-usage.nvim) |
| VidocqH/lsp-lens.nvim | no (stale) | 2023-12-07 | none | >= 0.8 | [repo](https://github.com/VidocqH/lsp-lens.nvim) |
| ldelossa/litee-calltree.nvim | no (stale) | 2024-10-02 | none | – | [repo](https://github.com/ldelossa/litee-calltree.nvim) |
| cbochs/portal.nvim | no (stale) | 2024-04-01 | v0.10.0 (2024-04-01) | >= 0.8 | [repo](https://github.com/cbochs/portal.nvim) |
| LeonHeidelbach/trailblazer.nvim | no | 2025-02-04 | none | >= 0.8.0 | [repo](https://github.com/LeonHeidelbach/trailblazer.nvim) |
| folke/snacks.nvim | no | 2026-05-25 | v2.31.0 (2026-03-20) | – | [repo](https://github.com/folke/snacks.nvim) |
| ibhagwan/fzf-lua | no | 2026-10-21 | 0.7 (2025-04-12) | – | [repo](https://github.com/ibhagwan/fzf-lua) |
| nvim-telescope/telescope.nvim | no | 2026-08-17 | v0.2.2 (2026-02-16) | – | [repo](https://github.com/nvim-telescope/telescope.nvim) |
| mfussenegger/nvim-dap-python | no | 2025-12-20 | none | – | [repo](https://github.com/mfussenegger/nvim-dap-python) |
| nvim-neotest/neotest-python | no | 2026-07-15 | none | – | [repo](https://github.com/nvim-neotest/neotest-python) |
| simrat39/symbols-outline.nvim | **ARCHIVED** | last push 2024-01-03 | – | – | [repo](https://github.com/simrat39/symbols-outline.nvim) |

#### Virtualenv
- venv-selector.nvim:
  - The "Regexp-branch merged into `main`" happened on 2025-08-27; the old behaviour lives on the `v1` branch, which is "no longer actively updated".
  - Since 2025-09-30 it requires Neovim 0.11 and expects LSP servers "to be configured by the user via `vim.lsp.config`".
  - 2026-02-16 brought an LSP gate against concurrent stop/start races, per-project venv memory across multiple projects, and PEP-723 `uv` support.
  - It requires `fd`/`fdfind`.
  - Picker backends: telescope, fzf-lua, snacks, mini-pick and vim.ui.select. Commands: `:VenvSelect`, `:VenvSelectLog`, `:VenvSelectCache`.

  Source: [venv-selector README](https://github.com/linux-cultist/venv-selector.nvim)
- venv-selector API: `require("venv-selector").python()`, `.venv()`, `.source()`, `.activate_from_path(path, "venv")`, `.deactivate()` and `.stop_lsp_servers()` — [venv-selector API.md](https://github.com/linux-cultist/venv-selector.nvim/blob/main/docs/API.md)
- On selection it "only extends the config for the lsp server with additional python settings" (`python.pythonPath`, `venv`, `venvPath`) and sets `VIRTUAL_ENV`/`CONDA_PREFIX` for terminals. It is tested with basedpyright, pyright, ty, jedi_language_server, pyrefly, zuban, pylsp and ruff — [venv-selector USAGE.md](https://github.com/linux-cultist/venv-selector.nvim/blob/main/docs/USAGE.md)

#### Symbol outline
- aerial.nvim:
  - needs 0.11+, with older nvim-0.x branches for older versions
  - default `backends = { "treesitter", "lsp", "markdown", "asciidoc", "man" }`: it prefers treesitter and falls back to LSP
  - python is a supported treesitter language

  Source: [aerial README](https://github.com/stevearc/aerial.nvim)
- outline.nvim:
  - the maintained successor of the archived symbols-outline.nvim
  - providers: LSP, CoC, markdown, norg, man, plus an external treesitter provider
  - per-filetype symbol filters, e.g. the README example `python = { 'Function', 'Class' }`

  Source: [outline.nvim README](https://github.com/hedyhli/outline.nvim)
- trouble.nvim v3 has an outline mode (`Trouble symbols toggle`, which can be pinned to the right). Its modes include `lsp_incoming_calls`, `lsp_outgoing_calls`, `lsp_references`, `lsp_definitions`, `lsp_implementations`, `lsp_type_definitions`, `lsp_declarations` and a combined `lsp` mode, in a tree view — [trouble README](https://github.com/folke/trouble.nvim)
- namu.nvim offers:
  - symbol pickers with live preview, tree guides and jump labels (`;`)
  - a persistent sidebar and favorites
  - `:Namu workspace`, `:Namu watchtower` (symbols across open buffers), `:Namu call in|out|both`, `:Namu treesitter` and `:Namu ctags`

  It requires Neovim 0.11+ — [namu README](https://github.com/bassamsdata/namu.nvim)

#### Breadcrumbs
- dropbar.nvim is an "IDE-like … winbar … with drop-down menus and multiple backends" (LSP, treesitter, path, markdown). It has a pick mode (`require('dropbar.api').pick`), needs Neovim >= 0.11.0, and does not require nvim-lspconfig or nvim-treesitter — [dropbar README](https://github.com/Bekaboo/dropbar.nvim)
- nvim-navic is a statusline/winbar component fed by `documentSymbol`. You place `require'nvim-navic'.get_location()` yourself — [nvim-navic README](https://github.com/SmiteshP/nvim-navic)
- barbecue.nvim (navic-based winbar) is archived — [GitHub API](https://api.github.com/repos/utilyre/barbecue.nvim)
- lspsaga modules include Breadcrumbs (symbols_in_winbar), Callhierarchy (`:Lspsaga incoming_calls` / `outgoing_calls` with a float or normal layout), Finder, Definition (peek), Hover, Implement, Outline, Rename and Beacon. The docs site footer reads © 2024 — [lspsaga docs](https://nvimdev.github.io/lspsaga/); [callhierarchy](https://nvimdev.github.io/lspsaga/callhierarchy/)

#### Sticky context
- nvim-treesitter-context needs the language parsers installed and lists python as supported. Language support "is strictly community maintained and can break". `require("treesitter-context").go_to_context(vim.v.count1)` jumps up to the context — [nvim-treesitter-context README](https://github.com/nvim-treesitter/nvim-treesitter-context)

#### Peek
- glance.nvim provides a VS Code-style peek list plus preview for references, definitions, type definitions and implementations (`:Glance references|implementations|…`), and `register_method()` for custom LSP methods — [glance README](https://github.com/DNLHC/glance.nvim)
- goto-preview opens floating previews for definition, type definition, implementation, declaration and references (`gpd`/`gpt`/`gpi`/`gpD`/`gpr`). References can go to telescope, fzf_lua, snacks, mini_pick or default, and it needs Neovim >= 0.10 — [goto-preview README](https://github.com/rmagatti/goto-preview)

#### Pickers (LSP)
- Telescope builtins: `lsp_references`, `lsp_incoming_calls`, `lsp_outgoing_calls`, `lsp_definitions`, `lsp_type_definitions`, `lsp_implementations`, `lsp_document_symbols`, `lsp_workspace_symbols` and `lsp_dynamic_workspace_symbols`. There is no type-hierarchy picker — [telescope.txt](https://github.com/nvim-telescope/telescope.nvim/blob/master/doc/telescope.txt)
- Telescope's location pickers call `vim.lsp.buf_request_all` and append every client's results into one list. There is no de-duplication step, and options include `reuse_win`, `jump_type` and `include_declaration` (default true for references). Call pickers use `buf_request` for `textDocument/prepareCallHierarchy` — [telescope __lsp.lua](https://github.com/nvim-telescope/telescope.nvim/blob/master/lua/telescope/builtin/__lsp.lua)
- fzf-lua: `lsp_references`, `lsp_definitions`, `lsp_declarations`, `lsp_typedefs`, `lsp_implementations`, `lsp_document_symbols`, `lsp_workspace_symbols`, `lsp_live_workspace_symbols`, `lsp_incoming_calls`, `lsp_outgoing_calls`, **`lsp_type_sub`, `lsp_type_super`**, and `lsp_finder` ("All LSP locations, combined view") — [fzf-lua README](https://github.com/ibhagwan/fzf-lua)
- snacks.picker: `lsp_config`, `lsp_declarations`, `lsp_definitions`, `lsp_implementations`, `lsp_incoming_calls`, `lsp_outgoing_calls`, `lsp_references`, `lsp_symbols`, `lsp_type_definitions` and `lsp_workspace_symbols` — [snacks picker docs](https://github.com/folke/snacks.nvim/blob/main/docs/picker.md). `snacks.words` will "Auto-show LSP references and quickly navigate between them" — [snacks words docs](https://github.com/folke/snacks.nvim/blob/main/docs/words.md)

#### Call hierarchy trees
- litee-calltree.nvim offers "an explorable tree of incoming or outgoing calls". Setup hooks `vim.lsp.handlers['callHierarchy/incomingCalls'] = vim.lsp.with(...)` — [litee-calltree README](https://github.com/ldelossa/litee-calltree.nvim). Neovim deprecates `vim.lsp.with()` and says `vim.lsp.handlers` no longer supports client-to-server response handlers — [deprecated.txt](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/deprecated.txt)

#### Jump-list helpers
- portal.nvim tunnels through the jumplist, changelist, quickfix, harpoon and grapple — [portal README](https://github.com/cbochs/portal.nvim)
- trailblazer.nvim provides stack-based trail marks — [trailblazer README](https://github.com/LeonHeidelbach/trailblazer.nvim)
- Both have been stale since 2024 and 2025-02 respectively (table above).

### Inferences
- litee-calltree overrides `vim.lsp.handlers` for callHierarchy, and 0.11+ no longer routes client-to-server responses through those handlers. It is therefore very likely a no-op on 0.11/0.12, though I did not test this. For a call tree, use trouble's `lsp_incoming_calls` tree, lspsaga's callhierarchy, or namu's `call both`. For flat lists, Telescope, fzf-lua or snacks pickers work.
- For a Telescope-based config like the target one, the minimal well-maintained stack is:
  - Telescope LSP pickers, including `lsp_incoming_calls`/`lsp_outgoing_calls`
  - native `vim.lsp.buf.typehierarchy()` into quickfix, since Telescope has no type-hierarchy picker
  - aerial.nvim or outline.nvim for the outline
  - dropbar.nvim for breadcrumbs
  - nvim-treesitter-context, which the target config already has installed
  - glance.nvim for peek
  - symbol-usage.nvim for counts
- trouble.nvim is not archived, but a year without commits is a yellow flag. aerial or outline cover the outline need with more recent activity.
- lspsaga is still being committed to (2026-07), but its docs date from 2024 and its "implement" module is keyed to interface symbols (see Q4). It is a large all-in-one, so it fits poorly with a picker-centric hand-rolled config. That last point is opinion.

### Gaps
- No dotfyle.com trend data was collected. The fetch was not attempted within budget.
- No r/neovim threads were found by search (see Q5 for what turned up). Community-popularity claims are therefore not included.
- I did not verify that aerial, outline or dropbar work with nvim-treesitter's `main` branch parsers specifically. They use core `vim.treesitter`, so they likely do (inference).
- "Code reading" plugins (reading or flow modes) were not researched beyond LazyVim's snacks.dim, snacks.zen and snacks.scope listing — [LazyVim NEWS.md](https://github.com/LazyVim/LazyVim/blob/main/NEWS.md). I found no dedicated "code reading mode" plugin.
- The minimum Neovim for snacks, fzf-lua and telescope was not checked.

## Q4. PyCharm-style "overridden/implements" gutter markers and "N references/implementations" lenses for Python

### Takeaway
No Neovim plugin I could find emulates PyCharm's override/implements gutter icons for Python. Reference and implementation counts are available: symbol-usage.nvim shows JetBrains-style "N references / definitions / implementations" virtual text via plain LSP requests, so it works without server codeLens. Implementation counts need a server with implementationProvider: basedpyright or ty, not pyright. lspsaga's "implement" module shows implementation counts only for interface types.

### Cited Findings
- symbol-usage.nvim "display[s] references, definitions, and implementations of document symbols with a view like JetBrains Idea". Text goes above the line, at end of line or near textwidth, and it "Works with LSP servers even client do not support `textDocument/codeLens`". Known limitations: nothing above the first line, and some servers mis-kind closures — [symbol-usage README](https://github.com/Wansmer/symbol-usage.nvim)
- lsp-lens.nvim "display[s] reference and definition info upon functions like JB's IDEA", but its last commit was 2023-12-07 — [lsp-lens README](https://github.com/VidocqH/lsp-lens.nvim); [commits feed](https://github.com/VidocqH/lsp-lens.nvim/commits/main)
- lspsaga Implement: "When buffer has instances of the interface type, Lspsaga will show extra information". It shows a sign and/or end-of-line virtual text, requires `symbols_in_winbar.enable = true`, and has `:Lspsaga finder imp` — [lspsaga implement](https://nvimdev.github.io/lspsaga/implement/)
- The closest gutter-marker analogue found is gosigns.nvim, which is Go-only: signs on interfaces and implementing structs. No Python equivalent turned up — [gosigns.nvim listing](https://erock-neovimcraft-1772360401.pgs.sh/plugin/Yu-Leo/gosigns.nvim)
- The ingredients exist server-side:
  - ty's implementation covers "subclasses and method overrides", and ty supports typeHierarchy — [ty LS docs](https://github.com/astral-sh/ty/blob/main/docs/features/language-server.md)
  - basedpyright advertises implementationProvider but not typeHierarchyProvider — [basedpyright languageServerBase.ts](https://github.com/DetachHead/basedpyright/blob/main/packages/pyright-internal/src/languageServerBase.ts)
  - Neovim exposes `vim.lsp.buf.typehierarchy()` — [lsp.txt](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/lsp.txt)
- None of pyright, basedpyright or ty emits code lenses: ty lists codeLens as not supported, and the pyright/basedpyright static capabilities have no codeLensProvider. Neovim 0.12's improved codelens (virtual lines, `grx`) therefore does not give Python reference counts — [ty LS docs](https://github.com/astral-sh/ty/blob/main/docs/features/language-server.md); [pyright languageServerBase.ts](https://github.com/microsoft/pyright/blob/main/packages/pyright-internal/src/languageServerBase.ts); [news.txt 0.12](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/news.txt)

### Inferences
- An "overrides ↑ / overridden ↓" gutter for Python would have to be hand-built:
  - For each method in `documentSymbol`, query `typeHierarchy/supertypes` (ty) or walk class bases and check for same-named methods to get "overrides".
  - Use `textDocument/implementation` (basedpyright/ty) to get "overridden by".
  - Place signs or extmarks in the sign column.

  This is a design suggestion, not an existing plugin.
- symbol-usage.nvim with basedpyright gives the "N usages" lens. Its implementations count will be zero or missing on pyright, which has no implementationProvider.
- lspsaga's implement module targets LSP SymbolKind Interface. Python servers report classes as Class, so it likely shows nothing for Python. This is unverified.

### Gaps
- I did not run symbol-usage.nvim against basedpyright or ty to confirm counts, or to measure performance on large files: it issues one references request per symbol.
- The search for a Python override-marker plugin was one query plus my own knowledge. A niche plugin could exist that I missed.

## Q5. Neovim-specific pitfalls for Python LSP navigation

### Takeaway
Most "navigation is broken" reports trace to a few causes:
- **Root detection**: root_markers order makes the nearest pyproject.toml win, which gives one client per package in monorepos.
- **Interpreter/venv**: pyright falls back to `python` on PATH, while basedpyright auto-detects `.venv`. Editable installs that use import hooks are invisible to the server.
- **Overlapping servers**: Neovim and Telescope merge results from every client, so two navigation-capable servers produce duplicates. Ruff's hover should be disabled.
- **Wrong server for the verb**: `gri` on pyright gets no result.
- **Stubs**: `gd` lands in a .pyi when no source is resolvable.

### Cited Findings
**Root detection and client instances**
- Both lspconfig pyright and basedpyright default root_markers to the flat list pyrightconfig.json, pyproject.toml, setup.py, setup.cfg, requirements.txt, Pipfile, .git — [lsp/pyright.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/pyright.lua); [lsp/basedpyright.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/basedpyright.lua)
- In 0.12 a flat list's order is priority. For each item, Neovim searches upward and "stops at the first directory containing that marker". Nested lists mean equal priority — [lsp.txt lsp-root_markers](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/lsp.txt)
- Clients are reused only "if name and root_dir matches" (default `reuse_client`) — [lsp.txt](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/lsp.txt)
- An nvim-lspconfig change put pyrightconfig.json ahead of pyproject.toml. With a base pyproject.toml at a monorepo root and pyrightconfig.json files in subpackages, the subpackages were not being detected as roots. Known only via a search-result summary of a mirror's commit log, not fetched directly — [nvim-lspconfig pyright.lua log (mirror)](https://git.sudomsg.com/mirror/nvim-lspconfig/log/lsp/pyright.lua?showmsg=1). The current file does list pyrightconfig.json first — [lsp/pyright.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/pyright.lua)
- Older Neovim Discourse reports show "only one pyright instance with the root_dir of the first file", or an existing server attaching to a buffer from another project. Both are pre-0.11-era and known only via search summaries — [Pyright + monorepo](https://neovim.discourse.group/t/pyright-monorepo/4088); [don't start new pyright server if root dir changed](https://neovim.discourse.group/t/lsp-dont-start-new-pyright-server-if-the-root-dir-has-changed/3800)
- `workspace_required` (0.12) stops single-file mode. The doc warns: "Without a workspace, cross-file features (navigation, hover) may or may not work" — [lsp.txt](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/lsp.txt)
- Pyright resolves local imports from the execution-environment root (or the workspace root), then `extraPaths` (which now accept globs), then a local `src` directory if no execution environment is configured — [pyright import-resolution.md](https://github.com/microsoft/pyright/blob/main/docs/import-resolution.md)

**Interpreter and venv**
- Pyright picks its environment in this order: `venvPath`+`venv` (not recommended), then `python.pythonPath`, then the default `python` interpreter — [pyright import-resolution.md](https://github.com/microsoft/pyright/blob/main/docs/import-resolution.md)
- basedpyright adds: "If a virtual environment exists in a `.venv` folder at the project root, its python interpreter is used as the default value for `python.pythonPath`" — [basedpyright import-resolution.md](https://github.com/DetachHead/basedpyright/blob/main/docs/usage/import-resolution.md)
- Ways to point the server at a venv:
  - lspconfig adds `:LspPyrightSetPythonPath`, which sends `workspace/didChangeConfiguration` — [lsp/pyright.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/pyright.lua)
  - AstroCommunity sets `pythonPath = vim.fn.exepath "python"` in `before_init` — [astrocommunity basedpyright](https://github.com/AstroNvim/astrocommunity/blob/main/lua/astrocommunity/pack/python/basedpyright/init.lua)
  - venv-selector injects `python.pythonPath`, `venv` and `venvPath` per project — [venv-selector USAGE.md](https://github.com/linux-cultist/venv-selector.nvim/blob/main/docs/USAGE.md)
- Editable installs that use import hooks cannot be resolved: "Pyright will be unable to find the corresponding source files". uv's build backend uses `.pth` by default. Hatchling only uses hooks with `dev-mode-exact = true`, PDM only with `editable-backend = "editables"`, and setuptools needs compat or strict mode — [basedpyright import-resolution.md](https://github.com/DetachHead/basedpyright/blob/main/docs/usage/import-resolution.md)

**Duplicate results and overlapping servers**
- Since 0.11, references, definition, type_definition, implementation and hover merge results from all attached clients — [news-0.11.txt](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/news-0.11.txt)
- Telescope's `list_or_jump` uses `buf_request_all` and `list_extend`s every client's locations with no de-dupe — [telescope __lsp.lua](https://github.com/nvim-telescope/telescope.nvim/blob/master/lua/telescope/builtin/__lsp.lua)
- Ruff's docs: "If you're using Ruff alongside another language server (like Pyright), you may want to defer to that language server for certain capabilities, like textDocument/hover". They show an `LspAttach` that sets `client.server_capabilities.hoverProvider = false` for ruff — [ruff editors setup](https://github.com/astral-sh/ruff/blob/main/docs/editors/setup.md). LazyVim and AstroCommunity do the same — [LazyVim python.lua](https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/plugins/extras/lang/python.lua); [astrocommunity ruff](https://github.com/AstroNvim/astrocommunity/blob/main/lua/astrocommunity/pack/python/ruff/init.lua)
- LazyVim enables exactly one of pyright, basedpyright, ruff and ruff_lsp per role: the chosen type-checking server plus ruff — [LazyVim python.lua](https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/plugins/extras/lang/python.lua)

**.pyi stubs vs source on go-to-definition**
- Pyright sets `hasGoToDeclarationCapability = !!capabilities.textDocument?.declaration`. If set, `textDocument/definition` uses `DefinitionFilter.PreferSource` and `textDocument/declaration` uses `PreferStubs`; otherwise both return All — [pyright languageServerBase.ts](https://github.com/microsoft/pyright/blob/main/packages/pyright-internal/src/languageServerBase.ts)
- The filter keeps only non-stub results for definition, and only .pyi for declaration, "unless filtering would produce an empty list" — [pyright definitionProvider.ts](https://github.com/microsoft/pyright/blob/main/packages/pyright-internal/src/languageService/definitionProvider.ts)
- Neovim's client capabilities include `textDocument.declaration = { linkSupport = true }` — [protocol.lua](https://github.com/neovim/neovim/blob/v0.12.5/runtime/lua/vim/lsp/protocol.lua)
- ty documents "Go to Declaration … could be in a stub file" separately from Go to Definition — [ty LS docs](https://github.com/astral-sh/ty/blob/main/docs/features/language-server.md)

**Capability mismatches and noise**
- pyright has no implementationProvider, so `gri`, `gI`, Telescope `lsp_implementations` and glance `implementations` find nothing on pyright. basedpyright and ty support implementation — [pyright languageServerBase.ts](https://github.com/microsoft/pyright/blob/main/packages/pyright-internal/src/languageServerBase.ts); [basedpyright languageServerBase.ts](https://github.com/DetachHead/basedpyright/blob/main/packages/pyright-internal/src/languageServerBase.ts); [ty LS docs](https://github.com/astral-sh/ty/blob/main/docs/features/language-server.md)
- Pyright's tagged hint diagnostics (unreachable, unreferenced, deprecated code) "are usually too noisy" in Neovim, so lspconfig disables them by default (`disableTaggedHints = true`) — [lsp/pyright.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/pyright.lua)
- `diagnosticMode = 'openFilesOnly'` is lspconfig's default for pyright and basedpyright — [lsp/basedpyright.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/basedpyright.lua)

**Performance in big workspaces**
- `workspace/didChangeWatchedFiles` is enabled by default except on Linux. "If you see poor performance in big workspaces, run `:checkhealth vim.lsp` and look for 'file watching'"; the doc shows how to drop the capability via `vim.lsp.config('*', …)` — [lsp.txt lsp-defaults](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/lsp.txt)
- Opinion: one handbook says basedpyright is "an order of magnitude slower than the Rust-based checkers" (ty, pyrefly). A Helix user saw the reverse CPU behaviour with Pyrefly. Both are anecdotal, from a search summary — [pydevtools basedpyright](https://pydevtools.com/handbook/reference/basedpyright.md); [ty vs Pyrefly](https://pydevtools.com/handbook/explanation/ty-vs-pyrefly/)

**Plugin and treesitter compatibility**
- nvim-treesitter `main` requires 0.12. On 0.11 you must pin `master` — [nvim-treesitter README](https://github.com/nvim-treesitter/nvim-treesitter/blob/main/README.md)
- Plugins that customise `vim.lsp.handlers` or use `vim.lsp.with()` are on deprecated paths — [deprecated.txt](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/deprecated.txt)
- NvChad strips semantic tokens from all clients, so basedpyright/ty semantic highlighting silently disappears there — [NvChad lspconfig.lua](https://github.com/NvChad/NvChad/blob/v2.5/lua/nvchad/configs/lspconfig.lua)

### Inferences
- **Monorepo with per-package pyproject.toml**: with the default flat root_markers, opening files in packages A and B starts two pyright clients, each rooted at its package. Each indexes only its own root plus resolvable imports, so references from package B into A's code are found only from B's client view. Fixes:
  - override `root_markers` (e.g. `{ 'pyrightconfig.json', '.git' }`, or a `root_dir` function returning the repo root) and put a root pyrightconfig.json / `[tool.pyright]` with `executionEnvironments` or `extraPaths`; or
  - accept per-package clients deliberately.

  The 0.12 nested-list syntax `{ { 'pyproject.toml', 'setup.py' }, '.git' }` does not solve this, because the nearest pyproject.toml still wins.
- **Duplicates**: never run two navigation-capable Python servers on the same buffer (pyright + basedpyright, basedpyright + ty, pyright + pylsp/jedi) unless you strip definition, references and hover capabilities from one. With Telescope, duplicates show up as doubled entries. The native `vim.lsp.buf.*` merge also lists both servers' results; whether native de-dupes was not verified.
- **gd lands in .pyi**: under Neovim, pyright already prefers source for `gd` and stubs for `gD`. A .pyi landing therefore means no source was resolvable. The usual causes are no venv or the wrong interpreter (stdlib or packages resolved only via bundled typeshed), a stub-only package, or an editable install via import hooks. Fix the interpreter (venv-selector, `.venv` with basedpyright, or `:LspPyrightSetPythonPath`) rather than adding plugins.
- **Server-to-verb mapping** for a reading-focused config:
  - definition, references and call hierarchy work on all three servers
  - implementation needs basedpyright or ty
  - type hierarchy needs ty, or a hand-rolled walk
  - inlay hints and semantic tokens need basedpyright or ty
  - LSP folds need ty; otherwise keep `vim.treesitter.foldexpr()`

### Gaps
- I did not verify whether `vim.lsp.buf.references()` de-duplicates identical locations from multiple clients.
- I found no 2025–2026 r/neovim threads on Python navigation pitfalls (searches returned none). The Discourse threads cited are older and were seen only through search summaries.
- I did not test how pyright/basedpyright behave with multiple `workspaceFolders` in a single client. Neovim supports adding them (`vim.lsp.buf.add_workspace_folder`, mapped by NvChad to `<leader>wa`), but whether pyright indexes extra folders for references was not verified.
- Whether ty or pyrefly honour `python.pythonPath` from `didChangeConfiguration` the way pyright does is only implied by venv-selector's "tested with" list, not by server docs.
