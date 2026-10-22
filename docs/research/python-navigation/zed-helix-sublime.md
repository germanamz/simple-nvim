# Python code navigation in Zed, Helix and Sublime Text (state as of October 2026)

> A research note from October 2026, one of the sources for [the Python navigation research](README.md). It describes other editors and tools as of that date, and this config as it was before the switch to basedpyright.

Scope: the defaults and recommended setups that three LSP-first editors ship for
Python: which servers run, how the interpreter/venv is found, and which UI
features help read and follow code. Versions in play at the time of writing:
Zed stable 1.24.2 (Oct 14, 2026), Helix 25.07.1 (Jul 18, 2025; still the latest
tagged release, with master moving on), and the Sublime LSP package plus its
LSP-* helper packages (main branches, Oct 2026). File names below are written
in plain text on purpose (this vault's doctor flags code-formatted paths that
are not on disk).

## Zed: default Python servers, toolchain/venv detection, and navigation UI

### Takeaway
Zed runs **basedpyright + Ruff** by default for Python (since v0.204, Sep 2025).
ty, Pyrefly, Pyright and pylsp are built in but **opt-in**: ty since late 2025,
Pyrefly since Oct 15, 2026. Venvs come from a **toolchain selector** built on
Microsoft's python-environment-tools ("pet"), chosen per pyproject-based
subproject, and the chosen interpreter is pushed to the server as
python.pythonPath. For reading code Zed has an outline modal and panel,
breadcrumbs (on), sticky scroll (off by default), inlay hints (off by default),
LSP semantic tokens (off by default; tree-sitter is the default highlighter),
go to definition, declaration, type definition and implementation,
find-all-references in an editable **multibuffer**, and (since Sep 2026) a call
hierarchy picker. No type hierarchy was found.

### Cited Findings

**Default servers and how they changed**
- Current main default settings for Python: `"language_servers": ["basedpyright", "ruff", "!ty", "!pyrefly", "!pyright", "!pylsp", "..."]`, plus Ruff as formatter (`code_actions_on_format` with source.organizeImports.ruff = true and formatter = language_server "ruff") and Debugpy as the debugger. — [Zed default settings (main), assets/settings/default.json](https://github.com/zed-industries/zed/blob/main/assets/settings/default.json)
- The docs say basedpyright is the primary language server "beginning with Zed v0.204.0", Ruff does formatting and linting, and ty, Pyright and PyLSP "are disabled by default and are not included by `"..."`". — [Zed docs: Python](https://zed.dev/docs/languages/python)
- July 2025: PR #35250 "python: Uplift basedpyright support into core" (merged 2025-07-29) and PR #35292 "python: Use a single workspace folder for basedpyright" (merged 2025-07-29; "Treat the new basedpyright adapter the same as pyright was treated in #35243"). — [zed PR #35292](https://github.com/zed-industries/zed/pull/35292); PR list from the GitHub search API, [zed PR #35250](https://github.com/zed-industries/zed/pull/35250)
- Sep 2025: PR #35362 "python: Replace pyright with basedpyright" (merged 2025-09-08). Its release note gives the reason: "Advantages of basedpyright over pyright include support for inlay hints, semantic highlighting, auto-import code actions, and stricter type checking." Pyright "remains available but is disabled by default". The opt-out example was `"language_servers": ["pyright", "pylsp", "!basedpyright"]`. — [zed PR #35362](https://github.com/zed-industries/zed/pull/35362)
- Oct 2025: PR #40604 "python: Only enable basedpyright and ruff by default" (merged 2025-10-18). Before it, "Though we ship with basedpyright, ruff and a few other lsps for python, we run them all at once." — [zed PR #40604](https://github.com/zed-industries/zed/pull/40604)
- Zed blog, Oct 2, 2025 (Katie Geer, Piotr Osiewicz): pyright and pylsp "aren't going away". For ty, "our plan is to pull Ty into Zed's core so you won't need to install anything… It'll start off disabled by default, but we expect to flip it on in the future." Pyrefly was then an extension and the team was "paying attention to pyrefly." — [Zed blog: Making Python in Zed fun](https://zed.dev/blog/making-python-in-zed-fun)
- ty is now a built-in adapter in crates/languages/src/python.rs (server name "ty"). The adapter looks for a ty binary inside the venv first, then on PATH. The docs show how to switch: `"language_servers": ["ty", "!basedpyright", "..."]`. — [Zed python.rs](https://github.com/zed-industries/zed/blob/main/crates/languages/src/python.rs); [Zed docs: Python](https://zed.dev/docs/languages/python)
- Oct 15, 2026: PR #44262 "Add builtin Pyrefly language server support" was merged. It is opt-in (testing steps add "pyrefly" to language_servers), Zed downloads the binary from Pyrefly's GitHub releases when none is installed, and the PR adds workspace_configuration so the selected toolchain reaches Pyrefly. Release note: "Added Pyrefly as builtin language server option". — [zed PR #44262](https://github.com/zed-industries/zed/pull/44262)
- I found no evidence that ty became the default as of Oct 2026. The docs and main default settings still list basedpyright first and "!ty". — [Zed docs: Python](https://zed.dev/docs/languages/python); [Zed default settings](https://github.com/zed-industries/zed/blob/main/assets/settings/default.json)
- Recent stable notes include "Fixed a ty language server panic when opening a Python file as a single-file project" (1.24.2, Oct 14, 2026) and "Fixed a crash during Python interpreter discovery when an executable emitted non-UTF-8 output" (1.21.0, Sep 23, 2026). — [Zed stable releases](https://zed.dev/releases/stable/0.224.0) (this URL redirected to the current stable list)

**basedpyright / Pyright configuration Zed applies**
- In Zed basedpyright defaults to typeCheckingMode "standard", "matching Pyright". It can be overridden in pyrightconfig.json or pyproject.toml, and pyrightconfig.json wins when both exist. Server settings go under `lsp`, e.g. `"diagnosticMode": "workspace"` and `"inlayHints": {"callArgumentNames": false}`. — [Zed docs: Python](https://zed.dev/docs/languages/python)
- The Pyright adapter sends initialization options python.analysis.autoSearchPaths = true, useLibraryCodeForTypes = true and autoImportCompletions = true. — [Zed python.rs](https://github.com/zed-industries/zed/blob/main/crates/languages/src/python.rs)
- When a toolchain is detected, Zed injects it as python.pythonPath, unless the user has already set pythonPath or venvPath ("If we have a detected toolchain, configure Pyright to use it - unless the user sets it themselves"). Zed also normalises flat versus nested "analysis" settings sections because "Basedpyright changed this behavior in v1.39.10". — [Zed python.rs](https://github.com/zed-industries/zed/blob/main/crates/languages/src/python.rs)
- "If a built-in language server is installed in the active venv, Zed uses that binary instead of its private copy" (debugpy too). — [Zed docs: Python](https://zed.dev/docs/languages/python)

**Toolchain (venv) detection and monorepos**
- Toolchains: Zed "will automatically infer a set of toolchains"; a best-effort default is chosen on first open. Selection is via the status bar or `toolchain: select`; "Add toolchain" adds a path manually. Selection is **per subproject**, so a monorepo can use a different toolchain in each subproject. The selected toolchain is used to launch language servers, terminals and tasks (activation scripts run in new terminals). In SSH projects the selector controls the remote host's toolchain. — [Zed docs: Toolchains](https://zed.dev/docs/toolchains)
- The selector "runs on Microsoft's python-environment-tools library", the same one VS Code uses. "Zed now runs a separate server for each toolchain." "Zed now tracks the location of manifests across your worktree" and "every file in that subproject shares the same toolchain." Caveat as of Oct 2025: "your toolchain choice may or may not persist as expected." — [Zed blog, Oct 2, 2025](https://zed.dev/blog/making-python-in-zed-fun)
- Environment priority in source: UvWorkspace, Uv, Poetry, Pipenv, VirtualEnvWrapper, Venv, VirtualEnv, PyenvVirtualEnv, Pixi, Conda, Pyenv, GlobalPaths, Homebrew ("Prioritize non-Conda environments"). Ties are also ranked by how close the venv sits to the subproject (WithinSubproject, then WithinWorktree, then NotInWorktree). A ".venv" *file* that names an environment (virtualfish convention) is honoured. Hatch, WinPython and the various global installs are recognised too. — [Zed python.rs](https://github.com/zed-industries/zed/blob/main/crates/languages/src/python.rs)
- Subproject boundaries come from a pyproject.toml "manifest provider". Zed walks up the ancestors and picks the **outermost** pyproject.toml directory that also has a workspace lockfile (uv.lock, poetry.lock, pdm.lock, Pipfile.lock), falling back to the **innermost** pyproject.toml. — [Zed python.rs](https://github.com/zed-industries/zed/blob/main/crates/languages/src/python.rs)
- The terminal's `detect_venv` searches [".env", "env", ".venv", "venv"] by default, with conda_manager "auto". — [Zed default settings](https://github.com/zed-industries/zed/blob/main/assets/settings/default.json)

**Reading and navigation UI (defaults from default.json and keymaps)**
- Inlay hints: `"inlay_hints": {"enabled": false, ...}`. They are globally off, with per-kind toggles (type, parameter, value, other) and `toggle_on_modifiers_press`. The macOS keymap binds `ctrl-:` to editor::ToggleInlayHints. — [Zed default settings](https://github.com/zed-industries/zed/blob/main/assets/settings/default.json); [Zed macOS keymap](https://github.com/zed-industries/zed/blob/main/assets/keymaps/default-macos.json)
- Since 1.21.0 (Sep 23, 2026): "Added support for running language-server actions directly from actionable inlay hints." — [Zed stable releases](https://zed.dev/releases/stable/0.224.0)
- Semantic tokens: `"semantic_tokens": "off"` by default. "combined" overlays LSP tokens on tree-sitter, and "full" uses LSP tokens only. Styling is via semantic_token_rules. — [Zed default settings](https://github.com/zed-industries/zed/blob/main/assets/settings/default.json); [Zed docs: Configuring languages](https://zed.dev/docs/configuring-languages)
- Python ships semantic-token rules mapping selfParameter and clsParameter to variable.special, ty's builtinConstant to constant.builtin, and readonly variables to constant. — [Zed python semantic_token_rules.json](https://github.com/zed-industries/zed/blob/main/crates/grammars/src/python/semantic_token_rules.json)
- PR #61735 "editor: Resolve semantic token overlaps by configured server order" was merged 2026-08-04. This matters when basedpyright and ty both emit tokens. — PR list from the GitHub search API, [zed PR #61735](https://github.com/zed-industries/zed/pull/61735)
- Outline and breadcrumbs source: `"document_symbols": "off"` means tree-sitter queries compute the outline and breadcrumbs (the default); "on" uses textDocument/documentSymbol. `document_folding_ranges` is also "off" (tree-sitter and indent folding). — [Zed default settings](https://github.com/zed-industries/zed/blob/main/assets/settings/default.json)
- Breadcrumbs: `toolbar.breadcrumbs: true` by default. — [Zed default settings](https://github.com/zed-industries/zed/blob/main/assets/settings/default.json)
- Sticky scroll: `"sticky_scroll": {"enabled": false}` by default. The editor feature came from PR #42242 (merged 2025-11-10, "Added a setting to stick scopes to the top of the editor", closes #5344). The project panel got its own sticky scroll in July 2025. — [zed PR #42242](https://github.com/zed-industries/zed/pull/42242); [Zed default settings](https://github.com/zed-industries/zed/blob/main/assets/settings/default.json)
- Outline: an `outline::Toggle` modal (cmd-shift-o; Vim `g s` / `g O`) and an Outline Panel (docked right, cmd-shift-b, with auto_reveal_entries). Project symbols: cmd-t (Vim `g S`). — [Zed macOS keymap](https://github.com/zed-industries/zed/blob/main/assets/keymaps/default-macos.json); [Zed Vim keymap](https://github.com/zed-industries/zed/blob/main/assets/keymaps/vim.json); [Zed default settings](https://github.com/zed-industries/zed/blob/main/assets/settings/default.json)
- Go-to bindings (macOS): f12 definition, alt-f12 definition in split, cmd-f12 type definition, shift-f12 implementation, alt-shift-f12 find all references, ctrl-f12 declaration. Vim mode: `gd`, `gD`, `gy`, `gI`, `gA`, plus Neovim-style `grr` (references) and `gri` (implementation), and `ctrl-w d` for definition in a split. — [Zed macOS keymap](https://github.com/zed-industries/zed/blob/main/assets/keymaps/default-macos.json); [Zed Vim keymap](https://github.com/zed-industries/zed/blob/main/assets/keymaps/vim.json)
- Multibuffers: Find All References opens a multibuffer. go to definition and go to type definition "will also open a multibuffer if there are multiple possible definitions". Multibuffers are editable, and the changes propagate to the real files. `editor: open excerpts` jumps to the underlying file. — [Zed docs: Multibuffers](https://zed.dev/docs/multibuffers)
- Call hierarchy: Zed Preview 1.19.0 (Sep 2, 2026) "Added call hierarchy support through `call hierarchy: show incoming calls` and `call hierarchy: show outgoing calls`". The macOS keymap binds `cmd-k cmd-h` to ShowIncomingCalls, and settings expose `call_hierarchy.modal_max_width`, so it is a picker/modal, not a tree panel. — [Zed Preview 1.19.0 notes](https://zed.dev/releases/preview/1.19.0); [Zed macOS keymap](https://github.com/zed-industries/zed/blob/main/assets/keymaps/default-macos.json)
- Code lens is "off" by default ("on" and "menu" exist). LSP document colors default to "inlay". — [Zed default settings](https://github.com/zed-industries/zed/blob/main/assets/settings/default.json)

### Inferences
- Zed's own stated reasons for basedpyright over Pyright are inlay hints, semantic tokens, auto-import code actions and (per the basedpyright docs) go-to-implementation. These are Pylance-only features that stock Pyright lacks. For a Neovim config that wants the same reading aids, basedpyright is the drop-in equivalent of Zed's default.
- Zed keeps tree-sitter as the default for highlighting, outline and breadcrumbs, and makes LSP semantic tokens and LSP document symbols opt-in. The likely reason is that LSP-driven highlighting and outlines are slower or noisier in large files and with several servers attached. Neovim's default does the opposite: semantic tokens are applied when the server offers them.
- The pyproject.toml "outermost with lockfile, else innermost" rule is a concrete, copyable heuristic for root detection in uv/Poetry workspaces versus independent sub-packages. In Neovim it would map to a custom `root_dir`/`root_markers` function.
- Zed's ty integration ships semantic-token rules and enables per-server ordering of overlapping tokens. Zed is preparing for multi-server Python (type checker + ty/pyrefly) but has not made it the default.

### Gaps
- The exact date and version when LSP semantic tokens first shipped in Zed was not verified from a primary page. A search summary pointed to ~v0.224 (Feb 2026) and to semantic-token fixes in 1.15.0 (Aug 12, 2026); treat as unverified.
- No Zed type hierarchy support (textDocument/prepareTypeHierarchy) was found in settings, keymaps or release notes.
- How the single-workspace-folder change (PR #35292/#35243) behaves in multi-root workspaces is not documented. Neither PR page explains user-visible effects.
- No documented Zed-specific "peek" (inline definition preview) was found. The multibuffer plays that role.

## Helix: default Python servers, keybindings, pickers, inlay hints, venv approach

### Takeaway
Helix has no release since 25.07.1 (Jul 2025). Its built-in Python server list
went pylsp only (24.07), then ruff, jedi, pylsp (25.01), then **ty, ruff, jedi,
pylsp** (25.07), and master adds **zuban** (May 2026). Pyright, basedpyright,
pyrefly and pylyzer are predefined but not in the default list. Navigation is
`g` goto mode (gd, gD, gy, gr, gi) plus space-mode symbol pickers. Since 25.07,
goto results from several servers are merged. Inlay hints exist but are off
by default. There is **no call hierarchy, type hierarchy, semantic tokens,
breadcrumbs or sticky context** in a release; PRs for call hierarchy and
breadcrumbs are open, and the semantic-tokens and sticky-context PRs were
closed. Helix itself does no venv detection. Users launch `hx` from the
project root (or with an activated venv) and rely on the server's own
discovery (ty and Ruff find .venv).

### Cited Findings
- Releases: the latest tags are 25.07.1 (2025-07-18) and 25.07 (2025-07-15). There are no later releases as of Oct 2026. — [Helix releases (GitHub API)](https://api.github.com/repos/helix-editor/helix/releases); [Helix CHANGELOG](https://github.com/helix-editor/helix/blob/master/CHANGELOG.md)
- The Python language entry on master is `language-servers = ["ty", "ruff", "jedi", "pylsp", "zuban"]` with `roots = ["pyproject.toml", "setup.py", "poetry.lock", "pyrightconfig.json"]` and shebangs ["python", "uv"]. — [Helix languages.toml (master)](https://github.com/helix-editor/helix/blob/master/languages.toml)
- History of the default list: 24.07 `["pylsp"]`, then 25.01 `["ruff", "jedi", "pylsp"]`, then 25.07.1 `["ty", "ruff", "jedi", "pylsp"]`. — [languages.toml @24.07](https://github.com/helix-editor/helix/blob/24.07/languages.toml); [@25.01](https://github.com/helix-editor/helix/blob/25.01/languages.toml); [@25.07.1](https://github.com/helix-editor/helix/blob/25.07.1/languages.toml)
- Predefined but not default: `pyright = { command = "pyright-langserver", args = ["--stdio"] }`, basedpyright (basedpyright-langserver --stdio), `pyrefly = { command = "pyrefly", args = ["lsp"] }`, pylyzer (--server). Defaults: `ty = { command = "ty", args = ["server"] }`, `ruff = { command = "ruff", args = ["server"] }`, jedi = jedi-language-server, pylsp, `zuban = { command = "zuban", args = ["server"] }`. — [Helix languages.toml (master)](https://github.com/helix-editor/helix/blob/master/languages.toml)
- ty was added by PR #13643 (merged 2025-05-29): "a new Python type checker and language server from Astral. The server requires no additional arguments". Pyrefly was added in #13713, jedi and ruff configs in #11630 (25.01), the basedpyright config in #11121 (24.07), and Pyright and pylyzer in #7897 (23.10). — [helix PR #13643](https://github.com/helix-editor/helix/pull/13643); [Helix CHANGELOG](https://github.com/helix-editor/helix/blob/master/CHANGELOG.md)
- Zuban was added by PR #15534 (merged 2026-05-25). There is an open issue: "zubanls panics because helix returns unescaped URI" (#15467). — [helix PR #15534](https://github.com/helix-editor/helix/pull/15534); [helix issue #15467](https://github.com/helix-editor/helix/issues/15467)
- 25.07 LSP changes: "Support responses from multiple language servers for LSP goto-definition (and declaration, type definition and implementation) and goto-references"; "Add a config option for limiting LSP inlay hint length"; LSP document colors. — [Helix CHANGELOG 25.07](https://github.com/helix-editor/helix/blob/master/CHANGELOG.md)
- Keymap (goto mode): `gd` definition, `gD` declaration, `gy` type definition, `gr` references, `gi` implementation. Space mode: `space k` hover, `space s` document symbol picker "(LSP or TS)" (`lsp_or_syntax_symbol_picker`), `space S` workspace symbol picker "(LSP or TS)", `space h` select references, `space r` rename. Tree-sitter motions: `]f`/`[f` functions, `]t`/`[t` classes. — [Helix keymap (master book)](https://github.com/helix-editor/helix/blob/master/book/src/keymap.md)
- Inlay hints: `[editor.lsp] display-inlay-hints` defaults to false, with `inlay-hints-length-limit` unset. "You may also have to activate them in the language server config… Inlay hints in Helix are still being improved on and may be a little bit laggy/janky." `goto-reference-include-declaration` defaults to true. — [Helix editor config (master book)](https://github.com/helix-editor/helix/blob/master/book/src/editor.md)
- Call hierarchy: PR #15216 "feat(lsp): add call hierarchy picker" (opened 2026-01-31) is still a draft or open. Its author: "ideally we would render this as a tree… but as far as I am aware we don't have the UI primitives for that". — [helix PR #15216](https://github.com/helix-editor/helix/pull/15216)
- Breadcrumbs: PR #15573 "feat: add breadcrumb navigation bar" (Apr 2026) and PR #13492 "add tree-sitter-breadcrumbs command" (May 2025) are both unmerged. — [helix PR #15573](https://github.com/helix-editor/helix/pull/15573); [helix PR #13492](https://github.com/helix-editor/helix/pull/13492)
- Sticky context: PR #6118 "Feat: Sticky Context" was closed in 2023. — [helix PR #6118](https://github.com/helix-editor/helix/pull/6118)
- Semantic tokens: PR #6102 "Semantic tokens highlighting" was closed without merging (the page still says "wants to merge"), and no semantic-token feature appears in the changelog. — [helix PR #6102](https://github.com/helix-editor/helix/pull/6102); [Helix CHANGELOG](https://github.com/helix-editor/helix/blob/master/CHANGELOG.md)
- Venv: the community wiki's "Language Server Configurations" page has Python recipes (pylsp, pylsp-mypy, pyrefly, pyright, basedpyright, ruff, python-lsp-ruff, pyright + ruff, ruff + pyright + pylyzer, ty) but no mention of venv, virtualenv or VIRTUAL_ENV anywhere on the page. — [Helix wiki: Language Server Configurations](https://github.com/helix-editor/helix/wiki/Language-Server-Configurations)
- Wiki recipes: pyright + ruff with `[language-server.pyright.config.python.analysis] typeCheckingMode = "basic"`; ty with `inlayHints.callArgumentNames = false`, `experimental.rename = true`, `experimental.autoImport = true`. Also: "ruff lacks basic features and is meant to be used alongside another LSP". — [Helix wiki](https://github.com/helix-editor/helix/wiki/Language-Server-Configurations)
- A community guide (pydevtools handbook, updated Sep 7, 2026, verified with uv 0.13) recommends `language-servers = ["ruff", "ty"]` with `formatter = { command = "ruff", args = ["format", "-"] }`. It says "Ruff and ty both auto-detect .venv directories at the project root" and "Helix must be launched from the directory containing .venv (or a parent of it)". It offers basedpyright as "a more mature type checker with broader rule coverage". — [pydevtools: Configure Helix for a uv project](https://pydevtools.com/handbook/how-to/how-to-configure-helix-for-a-uv-project/)
- Monorepo pitfall (Oct 2025, Helix 25.07.1 + ty alpha.23): ty failed to resolve Django imports in a nested sub-project. The reporter traced it to Helix switching its working directory to the repository top level. `workspace-lsp-roots = ["pyproject.toml"]` "did not solve it" and a follow-up issue was opened. — [helix issue #14641](https://github.com/helix-editor/helix/issues/14641)

### Inferences
- Helix's default list mixes a type-aware server (ty) with a Jedi-based one (jedi, pylsp) and a linter (ruff). The merged goto results from 25.07 make that combination workable: if ty misses a definition, Jedi's static-analysis answer is still shown. Neovim gives the same effect when several clients attach and `vim.lsp.buf.definition()` collects results from all of them into a list.
- Helix leaves venvs entirely to the servers. Its users therefore depend on server-side discovery: ty checks VIRTUAL_ENV, then .venv in the project root, then python on PATH. Pyright falls back to the shell's python. That fallback makes root detection and launch directory the main failure mode in monorepos.
- The open call-hierarchy PR shows that a flat picker is the minimum viable UI. Zed made the same choice. Sublime is the only one of the three with a tree view.

### Gaps
- I did not find primary documentation saying how Helix treats listed but uninstalled servers (silently skipped versus errors). `hx --health python` is the documented check; behaviour on master was not verified.
- No Helix type hierarchy PR or issue was found.
- Whether 25.07.1's `space s` already falls back to tree-sitter, or only master does, was not verified. The `lsp_or_syntax_*` names come from the master book.
- The follow-up issue to #14641 (root and working directory with nested pyproject) was not located.

## Sublime Text: LSP package, Python helper packages, venv detection and features

### Takeaway
Sublime's LSP package documents three Python options, **LSP-pyright**,
**LSP-pylsp** and **Pyrefly** (manual client config), plus **LSP-ruff**. It
makes no recommendation. **LSP-basedpyright** and **LSP-ty** are separate
helper packages that the docs page does not list. LSP-basedpyright is the one
that brings Pylance-only features (semantic highlighting, inlay hints). The
pyright-family helpers ship the richest venv discovery of the three editors:
an ordered list of `venvStrategies`, a status-bar display of which finder
matched, and a `dev_environment` preset that injects an embedding host's
sys.path (Sublime Text, Blender, GDB). The LSP package itself supports Goto
Definition, Type Definition, Declaration and Implementation, Find References,
**Call Hierarchy and Type Hierarchy (tree view)**, Goto Symbol (in Project),
inlay hints (off by default) and semantic highlighting (off by default; needs
a colour-scheme rule).

### Cited Findings
- The LSP docs' Python section lists Pyright (via LSP-pyright), Python LSP Server (via LSP-pylsp), Pyrefly (manual `{"pyrefly": {"enabled": true, "command": ["pyrefly", "lsp"], "selector": "source.python"}}`) and LSP-ruff. It says only "There are multiple options". It does not list basedpyright or ty. — [LSP docs: Language servers](https://lsp.sublimetext.io/language_servers/)
- LSP-basedpyright: "basically includes all Pyright features and some exclusive Pylance features such as semantic highlighting and inlay hints". Its settings expose `disabled_capabilities` with semanticTokensProvider and inlayHintProvider (both false, i.e. enabled). Inlay-hint defaults: callArgumentNames true, callArgumentNamesMatching false, functionReturnTypes true, genericTypes true. diagnosticMode is "openFilesOnly". — [LSP-basedpyright README](https://github.com/sublimelsp/LSP-basedpyright); [LSP-basedpyright settings](https://github.com/sublimelsp/LSP-basedpyright/blob/master/LSP-basedpyright.sublime-settings)
- LSP-pyright needs Node.js (it offers to install a local runtime). It recommends LSP-file-watcher-chokidar "to notify the server about new files". It provides "LSP-pyright: Create Pyright Configuration File". Defaults include typeCheckingMode "standard", diagnosticMode "openFilesOnly", stubPath "./typings", useLibraryCodeForTypes true, autoSearchPaths true. — [LSP-pyright README](https://github.com/sublimelsp/LSP-pyright); [LSP-pyright settings](https://github.com/sublimelsp/LSP-pyright/blob/master/LSP-pyright.sublime-settings)
- Venv: "The plugin attempts to resolve the virtual environment automatically from well-known environment variables and workspace files". Setting python.pythonPath disables this. An override needs a pyrightconfig.json with `"venvPath": ".", "venv": ".venv"`. "the venv option is only supported in the pyrightconfig.json file", while venvPath can go in the .sublime-project. — [LSP-pyright README](https://github.com/sublimelsp/LSP-pyright)
- Default `venvStrategies` order, identical in LSP-pyright and LSP-basedpyright: st_project_data, local_dot_venv, env_var_conda_prefix, env_var_virtual_env, rye, poetry, pdm, hatch, pipenv, pyenv, any_subdirectory. The status bar template shows "venv: <prompt>; py: <version>; by: <finder_name>". — [LSP-pyright settings](https://github.com/sublimelsp/LSP-pyright/blob/master/LSP-pyright.sublime-settings); [LSP-basedpyright settings](https://github.com/sublimelsp/LSP-basedpyright/blob/master/LSP-basedpyright.sublime-settings)
- How the finders work, from source:
  - local_dot_venv checks `.venv` and then `venv` in the project dir.
  - The env-var finders read CONDA_PREFIX and VIRTUAL_ENV.
  - hatch runs `hatch env find`.
  - pdm runs `pdm info --python`, only if .pdm-python exists.
  - pipenv runs `pipenv --py`.
  - poetry runs `poetry env info -p`, only if poetry.lock exists.
  - pyenv runs `pyenv which python`, cached per .python-version.
  - rye has its own finder.
  - any_subdirectory scans the project's subdirectories.

  — [LSP-pyright venv_finder.py](https://github.com/sublimelsp/LSP-pyright/blob/master/plugin/virtual_env/venv_finder.py)
- `pyright.dev_environment` (basedpyright.dev_environment in LSP-basedpyright) takes:
  - "sublime_text" (also _33, _38, _314): "`sys.path` from plugin_host will be added into python.analysis.extraPaths"
  - "blender": Blender's embedded interpreter's sys.path, obtained by invoking Blender headless
  - "gdb": the same, by invoking GDB in batch mode

  — [LSP-pyright settings](https://github.com/sublimelsp/LSP-pyright/blob/master/LSP-pyright.sublime-settings)
- LSP-ty exists: a helper that "automatically installs and updates ty", recommending LSP-file-watcher-rust. LSP-ruff exists. There is no sublimelsp/LSP-pyrefly repository (404), so Pyrefly goes through the manual client config. — [LSP-ty](https://github.com/sublimelsp/LSP-ty); [LSP-ruff](https://github.com/sublimelsp/LSP-ruff); [LSP docs: Language servers](https://lsp.sublimetext.io/language_servers/)
- LSP package commands include LSP: Goto Definition, Goto Type Definition, Goto Declaration, Goto Implementation, Find References, Find References (Output Panel), Find References (Quick Panel), Show Call Hierarchy, Show Type Hierarchy, Toggle Inlay Hints, Goto Symbol, Goto Symbol in Project, and Expand Selection. — [LSP Default.sublime-commands](https://github.com/sublimelsp/LSP/blob/main/Default.sublime-commands)
- LSP package defaults: `show_inlay_hints: false`, `semantic_highlighting: false`, `show_references_in_quick_panel: true`, `show_code_lens: "annotation"`, `document_highlight_style: "underline"`, `show_symbol_action_links: true`. — [LSP.sublime-settings](https://github.com/sublimelsp/LSP/blob/main/LSP.sublime-settings)
- Features doc:
  - Call hierarchy is shown "in a side-by-side view, which opens the location when you click on an item in the tree" and "can also be toggled to show a structured view of all outgoing calls". Type hierarchy is "similar to call hierarchy, just for super and subtypes".
  - Semantic highlighting needs "a special rule with a background color set for semantic tokens". LSP adds that rule automatically for the built-in colour schemes; custom schemes need UI: Customize Color Scheme.
  - Goto Definition "can also fall back to Sublime's built-in Goto Definition" when the server returns nothing.
  - Find References replaces Shift+F12, but LSP does not replace the built-in Ctrl+R Goto Symbol.

  — [LSP docs: Features](https://lsp.sublimetext.io/features/)

### Inferences
- Sublime's venv design treats discovery as an ordered, user-reorderable list of strategies, and its status bar shows which strategy matched. That makes interpreter problems visible, which is the main reason go-to-definition lands in the wrong place. A Neovim config can copy it with a statusline component showing the interpreter the Python client was started with (e.g. from the client's settings python.pythonPath).
- Sublime is the only one of the three with first-class call hierarchy **and** type hierarchy, shown as trees. Neovim has both natively (`vim.lsp.buf.incoming_calls/outgoing_calls/typehierarchy`), but only as quickfix-style lists, not trees.
- Pyright on its own provides neither inlay hints nor semantic tokens (they are Pylance features re-implemented by basedpyright). So every editor here pairs basedpyright with the reading aids: Zed's default, LSP-basedpyright, and the Helix wiki alternative.

### Gaps
- Sublime Text 4's native support (outside the LSP package) for breadcrumbs or sticky scroll was not researched. I found no primary source saying either exists, and the LSP package exposes neither.
- No maintainer statement recommending LSP-basedpyright over LSP-pyright (or LSP-ty) was found. The docs page is neutral.
- The LSP-ty README's feature and settings coverage (e.g. whether it enables inlay hints or semantic tokens) was not read past the configuration section.

## Go-to-definition accuracy in Python (stubs vs source, re-exports, editable installs, wrong interpreter) and mitigations

### Takeaway
Most wrong jumps have one of three causes: (1) the **server ran against the
wrong interpreter**, so site-packages are unresolved and definitions fall back
to typeshed stubs or nothing; (2) **editable installs that use import hooks**,
which static analysers cannot follow; (3) **stub versus source** semantics.
Pylance and Pyright-lineage servers send *definition* to .py source and
*declaration* to .pyi stubs, and ty documents that declaration can point into
a stub. The editors mitigate mainly by getting the interpreter right. Zed
injects the toolchain as pythonPath and runs one server per toolchain.
Sublime has ordered venv strategies with a status-bar readout. Helix relies on
launch directory and server auto-discovery, and merges multiple servers' goto
results.

### Cited Findings
- Pyright resolution order: stubPath first, then workspace code, then extraPaths in order, then for installed packages "try to resolve first using a stub package", then stdlib typeshed stubs. Library source is used for types only when useLibraryCodeForTypes is true. Interpreter choice is venvPath + venv, else python.pythonPath, else "the default Python environment (i.e. the one that is invoked when typing python in the shell)". — [Pyright docs: Import resolution](https://github.com/microsoft/pyright/blob/main/docs/import-resolution.md)
- Editable installs: "if your editable install is configured to use import hooks, Pyright will be unable to find the corresponding source files." "Notably, setuptools uses import hooks by default"; use .pth-based "compat mode" or "strict mode". Hatch only uses hooks if dev-mode-exact is true, and PDM only if editable-backend is "editables". — [Pyright docs: Import resolution](https://github.com/microsoft/pyright/blob/main/docs/import-resolution.md)
- Stub versus source: Pylance 2021.2.1: "Go-to-definition now brings you to source files (e.g. .py files), and a new "go-to-declaration" option brings you to stub files (.pyi). If either would otherwise return no result, Pylance will bring you to whichever files are available." — [Pylance release 2021.2.1](https://github.com/microsoft/pylance-release/releases/tag/2021.2.1)
- ty's language-server docs support Go to Definition, Declaration, Type Definition and Implementation, and note that Go to Declaration can point into a stub file. ty also supports call hierarchy, type hierarchy, inlay hints, semantic tokens and workspace symbols. It does not support code lens, document links or formatting (use Ruff). — [ty docs: Language server features](https://docs.astral.sh/ty/features/language-server/)
- ty environment discovery order: VIRTUAL_ENV; an active non-base Conda env; ".venv directory in the project root"; an active base Conda env; then python3/python on PATH. Override with environment.python or --python. First-party search covers the project root plus ./src, ./<project-name> and ./python; environment.root handles other layouts. PYTHONPATH entries are inserted before site-packages. — [ty docs: Module discovery](https://docs.astral.sh/ty/modules/)
- basedpyright re-implements "Go to Implementations" and "Find All Implementations", hover and go-to-definition on operators, semantic highlighting, inlay hints, import-suggestion code actions and module renaming as Pylance-parity features. — [basedpyright docs: Pylance features](https://docs.basedpyright.com/latest/benefits-over-pyright/pylance-features/)
- Zed mitigation:
  - It injects the selected toolchain as python.pythonPath unless the user set pythonPath or venvPath.
  - It prefers server binaries installed in the venv.
  - It runs "a separate server for each toolchain" so "completions, jumps, and hovers" stay accurate.
  - It defines subprojects by pyproject.toml and lockfiles.

  — [Zed python.rs](https://github.com/zed-industries/zed/blob/main/crates/languages/src/python.rs); [Zed docs: Python](https://zed.dev/docs/languages/python); [Zed blog](https://zed.dev/blog/making-python-in-zed-fun)
- Sublime mitigation:
  - Ordered venvStrategies, with the matched finder shown in the status bar.
  - dev_environment presets add embedded interpreters' sys.path to extraPaths.
  - Goto Definition falls back to Sublime's built-in symbol index when the server returns nothing.

  — [LSP-pyright settings](https://github.com/sublimelsp/LSP-pyright/blob/master/LSP-pyright.sublime-settings); [LSP docs: Features](https://lsp.sublimetext.io/features/)
- Helix mitigation: merged goto results from multiple servers (25.07), plus guidance to launch from the directory containing .venv. The monorepo working-directory issue (#14641) shows the failure mode when the root is wrong. — [Helix CHANGELOG](https://github.com/helix-editor/helix/blob/master/CHANGELOG.md); [pydevtools Helix guide](https://pydevtools.com/handbook/how-to/how-to-configure-helix-for-a-uv-project/); [helix issue #14641](https://github.com/helix-editor/helix/issues/14641)

### Inferences
- In a Neovim 0.11+ config the highest-leverage fixes match these editors' choices:
  - Resolve the interpreter per project root and pass it to basedpyright as python.pythonPath (in `before_init` or `on_new_config`), or rely on ty's VIRTUAL_ENV/.venv discovery.
  - Choose `root_dir` the way Zed's manifest provider does: outermost pyproject.toml with a workspace lockfile, else innermost pyproject.toml.
  - Show the interpreter in the statusline, as Sublime does.
  - Keep both `gd` (definition, which goes to source) and a declaration mapping (which goes to stubs) available, because Pyright-lineage servers and ty split them that way.
- Re-exports (`from .x import Y` in a package's \_\_init\_\_) were not covered by any primary source I found. With Pyright, definition generally follows the alias to the original binding, but I could not cite this.

### Gaps
- I found no primary-source discussion from Zed, Helix or Sublime maintainers specifically about re-export chains or `__all__` affecting go-to-definition.
- I found no Zed or Helix issue specifically about basedpyright or ty jumping to .pyi instead of .py; searches returned nothing relevant.
- No source confirmed whether Pyright core (as opposed to Pylance) implements the definition→source / declaration→stub split identically. The ty docs mention only the declaration→stub case.

## UI ideas from these editors and their Neovim equivalents

### Takeaway
Nearly every reading aid in these editors has a Neovim 0.11+ native or plugin
equivalent. Native: `grr`, `gri`, `gO` and `gra` in 0.11; `grt` and `grx` on
master (0.12); call and type hierarchy; inlay hints and semantic tokens via
vim.lsp.inlay_hint and vim.lsp.semantic_tokens. Plugins fill the UI gaps:
outline panel (aerial.nvim, outline.nvim), breadcrumbs (dropbar.nvim,
nvim-navic), sticky scroll (nvim-treesitter-context), a references
"multibuffer" or peek (trouble.nvim, glance.nvim), and a toolchain selector
(venv-selector.nvim).

### Cited Findings
- Neovim 0.11.0 global defaults: "grn" rename, "gra" code action, "grr" references, "gri" implementation, "gO" document_symbol. — [Neovim v0.11.0 lsp.txt](https://github.com/neovim/neovim/blob/v0.11.0/runtime/doc/lsp.txt)
- Neovim master adds "grt" → vim.lsp.buf.type_definition() and "grx" → vim.lsp.codelens.run(). `v_an`/`v_in` fall back to LSP selection_range when tree-sitter is not active. — [Neovim master lsp.txt](https://github.com/neovim/neovim/blob/master/runtime/doc/lsp.txt)
- Native APIs: vim.lsp.buf.incoming_calls(), outgoing_calls(), typehierarchy({kind}), implementation(), type_definition(), references(); vim.lsp.inlay_hint.enable(); vim.lsp.semantic_tokens.enable(). — [Neovim master lsp.txt](https://github.com/neovim/neovim/blob/master/runtime/doc/lsp.txt)
- Plugin equivalents (repo descriptions; all had commits in 2025–2026):
  - aerial.nvim, "Neovim plugin for a code outline window" (≈ Zed Outline Panel). — [aerial.nvim](https://github.com/stevearc/aerial.nvim)
  - outline.nvim, "Fancy code outline sidebar to visualize and navigate code symbols in a tree hierarchy". — [outline.nvim](https://github.com/hedyhli/outline.nvim)
  - dropbar.nvim, "IDE-like breadcrumbs, out of the box" (≈ Zed breadcrumbs). — [dropbar.nvim](https://github.com/Bekaboo/dropbar.nvim)
  - nvim-navic, "shows your current code context" in winbar or statusline. — [nvim-navic](https://github.com/SmiteshP/nvim-navic)
  - nvim-treesitter-context, "Show code context" (≈ Zed sticky_scroll). — [nvim-treesitter-context](https://github.com/nvim-treesitter/nvim-treesitter-context)
  - glance.nvim, "Peek preview window for LSP locations" (closest to Zed's references multibuffer or VS Code peek). — [glance.nvim](https://github.com/DNLHC/glance.nvim)
  - trouble.nvim, a list UI for "diagnostics, references, telescope results, quickfix and location list". Its last push was Oct 31, 2025. — [trouble.nvim](https://github.com/folke/trouble.nvim)
  - venv-selector.nvim, "Allows selection of python virtual environment from within neovim" (≈ Zed toolchain selector). — [venv-selector.nvim](https://github.com/linux-cultist/venv-selector.nvim)
- Zed's multibuffer is editable and writes back to files. — [Zed docs: Multibuffers](https://zed.dev/docs/multibuffers)

### Inferences
- An editable multibuffer has no exact native Neovim analogue. The nearest workflow is the quickfix list (`grr` populates it) plus `:cdo`/`:cfdo` for edits across files, or a peek plugin (glance.nvim) for reading. Quickfix-editing plugins exist but were not researched here.
- Zed and Helix both default to tree-sitter for outline symbols and keep LSP document symbols optional (Helix's `space s` falls back to the syntax tree when no LSP symbols are available). Tree-sitter-backed outline and breadcrumbs, with LSP as the precise source when available, match current practice.
- Defaults across the three editors converge: inlay hints off, semantic tokens off (Zed, Sublime) or unsupported (Helix), sticky scroll off (Zed) or absent, breadcrumbs on (Zed). Zed (cmd-k cmd-h) and Sublime both put call hierarchy one command away. A Neovim config following them would keep hints and sticky context opt-in or toggleable and bind call hierarchy to a key.

### Gaps
- I did not evaluate quickfix-editing plugins (e.g. quicker.nvim or nvim-bqf), the closest Neovim equivalents to Zed's editable multibuffer, so none is cited.
- I did not verify in this pass whether Neovim enables semantic tokens automatically on attach. The API exists, but the default-on wording was not located in lsp.txt. This repo's own notes on LSP semantic tokens outranking tree-sitter suggest they are active.
