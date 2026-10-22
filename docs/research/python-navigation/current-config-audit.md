# Current config audit: what this Neovim config does for reading and navigating Python

> A snapshot of the config at commit `2a7527e`, before the switch to basedpyright, written for [the Python navigation research](README.md). Line numbers in its links refer to that commit. For the config as it is now, see [python-navigation.md](../../python-navigation.md).

Scope: read-only audit of the repo (`init.lua`, `lua/plugins/*.lua`, `lua/config/*.lua`, `docs/`, `tests/`, lock files), the installed plugin sources under nvim's `stdpath("data")/lazy/`, the mason-installed pyright package, and the Neovim runtime (`$VIMRUNTIME`). Source links are repo-relative paths with line numbers. `stdpath("data")/...` means the installed copy; `$VIMRUNTIME/...` means the Neovim runtime that ships with the installed binary.

**Empirical probe (used in several sections below).** To check what pyright actually supports instead of guessing, I ran a headless `nvim --clean` against the mason-installed `pyright-langserver` (1.1.409). It used lspconfig's default settings and `didChangeWatchedFiles` turned off, the same as this config. The test project was a throwaway 3-file scratch project outside the repo: `app/base.py` defines `class Repo(ABC)` with `@abstractmethod def save`, `app/impl.py` defines `class SqlRepo(Repo)` overriding `save`, and `app/main.py` has `def run(r: Repo): r.save(1)` and `run(SqlRepo())`. I printed the server capabilities, `client:supports_method(...)`, and the raw replies. Nothing in the repo was touched. Below, "Probe" refers to this run.

## Q1. Which Python language servers are configured, how, with what settings, and which root markers decide the workspace?

### Takeaway
**pyright** (mason pin 1.1.409) is the only Python server that the config declares itself. It sets no `settings`; every `python.analysis.*` value comes from nvim-lspconfig's `lsp/pyright.lua` defaults (`autoSearchPaths`, `useLibraryCodeForTypes`, `diagnosticMode="openFilesOnly"`), plus per-project `diagnosticSeverityOverrides` injected in `before_init`. **ruff** and **dprint** also attach to Python buffers, because mason-lspconfig's `automatic_enable` is left at its default `true`. Neither one adds navigation. The root is resolved by lspconfig's **ordered** `root_markers` (`pyrightconfig.json` > `pyproject.toml` > `setup.py` > `setup.cfg` > `requirements.txt` > `Pipfile` > `.git`), and Neovim starts one pyright client per root.

### Cited Findings
- The servers table declares `pyright = { filetypes = { "python" } }` with the comment "No `settings` here on purpose": rule severities are treated as a property of the project and injected per project. It notes that `typeCheckingMode = "basic"` does nothing for the Pydantic case. — [lua/plugins/lsp.lua:20-28](../../../lua/plugins/lsp.lua)
- `servers.pyright.before_init = require("config.pyright_rules").before_init`. This is the hook that runs after `root_dir` is resolved and before the client is created. It must mutate `config.settings` and must not reassign it. — [lua/plugins/lsp.lua:408-414](../../../lua/plugins/lsp.lua)
- `before_init` only folds the stored per-root rules into `settings.python.analysis.diagnosticSeverityOverrides`. It touches nothing else in `python.analysis`. — [lua/config/pyright_rules.lua:254-280](../../../lua/config/pyright_rules.lua)
- Every server in the table, pyright included, is registered with blink.cmp completion capabilities, `config.lsp_fs_sync` file-operation capabilities, and `workspace.didChangeWatchedFiles.dynamicRegistration = false`. Each also gets an `on_init` wrapper, then `vim.lsp.config(name, cfg)` and `vim.lsp.enable(name)`. — [lua/plugins/lsp.lua:453-475](../../../lua/plugins/lsp.lua)
- File watching is turned off for every server to avoid recursive FSEvents walks. The stated trade-off is that servers no longer auto-refresh on changes made outside the editor; `<leader>lr`, `<leader>r` and `config.file_reload` are the manual escape hatches. — [lua/plugins/lsp.lua:439-452](../../../lua/plugins/lsp.lua)
- The `:PyrightRules` user command and the `<leader>ld` picker are the only Python-specific UI. — [lua/plugins/lsp.lua:416-422](../../../lua/plugins/lsp.lua), [lua/plugins/lsp.lua:244-255](../../../lua/plugins/lsp.lua)
- Implicit defaults come from the installed nvim-lspconfig `lsp/pyright.lua`:
  - `cmd = { 'pyright-langserver', '--stdio' }`
  - `root_markers = { 'pyrightconfig.json', 'pyproject.toml', 'setup.py', 'setup.cfg', 'requirements.txt', 'Pipfile', '.git' }`
  - `settings.python.analysis = { autoSearchPaths = true, useLibraryCodeForTypes = true, diagnosticMode = 'openFilesOnly' }`
  - an `on_attach` that creates the buffer commands `:LspPyrightOrganizeImports` and `:LspPyrightSetPythonPath`

  — `stdpath("data")/lazy/nvim-lspconfig/lsp/pyright.lua:24-67`
- The installed nvim-lspconfig checkout is at commit `3371bf298c1f…` (committed 2026-06-25), matching the lock. — [lazy-lock.json:19](../../../lazy-lock.json); `git log -1` in `stdpath("data")/lazy/nvim-lspconfig`
- A grep of `lua/`, `init.lua`, `ftplugin/` and `after/` finds no `typeCheckingMode`, `extraPaths`, `stubPath`, `pythonPath`, `venvPath`, `venv`, `autoImportCompletions` or `inlayHints` settings anywhere. Pyright therefore runs in its default `standard` mode. The docs call `standard` "pyright's default". — [docs/python-diagnostics.md:60-66](../../python-diagnostics.md)
- Root-marker semantics in Neovim 0.12: "The list order decides priority… search stops at the first directory containing that marker". Equal priority needs a nested list, and lspconfig's pyright list is flat. So a `pyrightconfig.json` in any ancestor beats a nearer `pyproject.toml`, and `.git` is only the last resort. — `$VIMRUNTIME/lua/vim/lsp.lua:203-219`
- The config itself notes that pyright "roots at the nearest pyproject.toml / setup.py, which in a repo of several packages is BELOW the repo top". It also notes that Neovim starts one client per `root_dir`, because `reuse_client` requires exact workspace-folder equality. — [lua/config/pyright_rules.lua:18-23](../../../lua/config/pyright_rules.lua), [lua/config/pyright_rules.lua:525-529](../../../lua/config/pyright_rules.lua)
- The pyright `root_dir` is not wrapped or clamped. `config.lsp_root`'s repo-boundary clamp is applied to ts_ls only. — [lua/plugins/lsp.lua:394-406](../../../lua/plugins/lsp.lua), [lua/config/lsp_root.lua:1-35](../../../lua/config/lsp_root.lua)
- Ruff and dprint attach too. "`mason-lspconfig`'s `automatic_enable` defaults to `true`, so `ruff` and `dprint` attach to Python buffers alongside pyright even though neither is declared in the `servers` table." — [docs/python-diagnostics.md:157-162](../../python-diagnostics.md)
  - The setup call passes only `ensure_installed = {}` and `automatic_installation = false`. — [lua/plugins/lsp.lua:367-370](../../../lua/plugins/lsp.lua)
  - The plugin default is `automatic_enable = true`, and `enable_server` calls `vim.lsp.enable` for every mason-installed package that maps to an lspconfig name. — `stdpath("data")/lazy/mason-lspconfig.nvim/lua/mason-lspconfig/settings.lua:26`, `.../features/automatic_enable.lua:8-51`
  - Mason has `pyright`, `ruff` and `dprint` packages installed.
- lspconfig's ruff defaults are `cmd = { 'ruff', 'server' }`, `root_markers = { 'pyproject.toml', 'ruff.toml', '.ruff.toml', '.git' }` and `settings = {}`. — `stdpath("data")/lazy/nvim-lspconfig/lsp/ruff.lua:30-35`
- dprint's default filetypes include `python`. Its root markers are only dprint config files. — `stdpath("data")/lazy/nvim-lspconfig/lsp/dprint.lua:10-24`
- Pyright registers `textDocument/diagnostic` dynamically, so diagnostics are *pulled*. — [docs/python-diagnostics.md:168-177](../../python-diagnostics.md); Probe: `DYNAMIC: textDocument/diagnostic`.
- Pyright's `onDefinition` uses `DefinitionFilter.PreferSource` when the client advertises the go-to-declaration capability, and `DefinitionFilter.All` otherwise. The filter keeps non-stub results when both stub and source results exist. — mason `pyright/dist/pyright-internal.js` (minified; `onDefinition` / `DefinitionFilter` definitions). Neovim advertises `textDocument.declaration`. — `$VIMRUNTIME/lua/vim/lsp/protocol.lua:508`
- Python formatting is separate from the LSP. conform uses `black` when `pyproject.toml` has `[tool.black]`, otherwise `ruff_format`. — [lua/config/formatters.lua:15-52](../../../lua/config/formatters.lua), [lua/config/formatters.lua:180](../../../lua/config/formatters.lua)

### Inferences
- The effective pyright config is lspconfig defaults plus severity overrides only. Import resolution, search paths, stub paths and interpreter are all pyright's own defaults (see Q2), which is the main lever this config leaves unused.
- Ordered root markers mean a monorepo with `pyproject.toml` per package gets one pyright process per package. Find-references and workspace symbols are then limited to that package's workspace. If sibling packages are installed non-editable into the venv, go-to-definition into a sibling can land in the site-packages copy instead of the workspace source.
- With file watching off, pyright never learns about files changed outside the editor: branch switches, codegen, `git pull`, a `uv sync` that installs packages. Until `<leader>lr` / `<leader>lR`, navigation can point at stale locations or fail to resolve new modules.
- ruff and dprint are not in the `servers` table, so they bypass the config's capability wrapper (blink caps, no_watch, fs_sync `on_init`). This is minor for navigation, but they are attached with lspconfig and mason-lspconfig defaults only.

### Gaps
- I did not start the user's full config to dump the merged `vim.lsp.config.pyright` at runtime. The effective settings above come from reading the merge sources, not from a live dump.
- Whether ruff's server answers any navigation requests was not probed. Its lspconfig file and the config treat it as diagnostics and formatting only.

## Q2. How is the Python interpreter / virtualenv detected for the language server?

### Takeaway
**For pyright, it isn't.** No `python.pythonPath`, `venvPath` or `venv` is set, and there is no venv-selector plugin. Pyright falls back to running `python3`, then `python`, from **Neovim's process PATH**, so the right venv is used only if it was activated in the shell before launching nvim. The only manual fix is lspconfig's non-persistent `:LspPyrightSetPythonPath <path>`. The config does contain a careful interpreter-resolution ladder (`.venv`/`venv` → `$VIRTUAL_ENV` under the root → `.python-version` via pyenv → `python3`), but it is used **only by the docs features** (`gK` / `K` excerpts) and is not wired into pyright.

### Cited Findings
- No interpreter or venv settings appear anywhere in the LSP wiring. The pyright row has no settings, and `before_init` writes only `diagnosticSeverityOverrides`. — [lua/plugins/lsp.lua:20-28](../../../lua/plugins/lsp.lua), [lua/config/pyright_rules.lua:264-280](../../../lua/config/pyright_rules.lua)
- lspconfig provides `:LspPyrightSetPythonPath` (nargs=1, file completion). It deep-extends `client.settings.python` with `pythonPath` and sends `workspace/didChangeConfiguration`. It is per-client and is not persisted. — `stdpath("data")/lazy/nvim-lspconfig/lsp/pyright.lua:7-22`, `:62-66`
- Pyright's default interpreter lookup, when nothing is configured, is `_executePythonInterpreter`: try `python3` (non-Windows), else `python`, resolved from the process environment. `venvPath` / `venv` are read only from config. The bundle has no `.venv` auto-discovery string. — mason `pyright/dist/pyright-internal.js` (minified; `_executePythonInterpreter`, config parser `venvPath`/`venv` handling)
- The probe confirmed pyright picked up the PATH interpreter's version: logMessage "Assuming Python version 3.x… ". — Probe
- The docs adapter's own comment warns that `python3` on PATH can be a pyenv shim. That shim "re-reads `.python-version` relative to the process CWD", which is Neovim's cwd, not the project's. — [lua/config/docs/adapters/python.lua:265-276](../../../lua/config/docs/adapters/python.lua)
- The docs adapter's interpreter ladder:
  - `venv_dir(root)` checks `<root>/.venv` and `<root>/venv` for `pyvenv.cfg`.
  - It then accepts `$VIRTUAL_ENV` only if it is under the project root.
  - `interpreter(ctx)` falls back to `.python-version` via the pyenv versions dir, then to `exepath("python3")`.
  - Results are cached per root.

  — [lua/config/docs/adapters/python.lua:240-308](../../../lua/config/docs/adapters/python.lua)
- The adapter cache invalidates on mtime because "this project has no venv" is the answer a long session is most likely to keep believing after `uv sync`. — [lua/config/docs/adapters/python.lua:173-200](../../../lua/config/docs/adapters/python.lua)
- `config.docs.brief.python` reuses that interpreter (`adapter._interpreter`) to choose the DevDocs Python version for `K`. — [lua/config/docs/brief/python.lua:130-182](../../../lua/config/docs/brief/python.lua), [docs/hover-docs.md:134-137](../../hover-docs.md)
- No venv-selector or similar plugin is installed. The 29 locked plugins are blink.cmp, conform, diffview, friendly-snippets, github-theme, gitsigns, lazy, lazydev, mason(+lspconfig, tool-installer), mini.ai/pairs/surround, minuet-ai, multicursor, nvim-lint, nvim-lspconfig, nvim-tree, nvim-treesitter(+context), nvim-ts-autotag, nvim-web-devicons, persistence, plenary, telescope(+fzf-native) and which-key. — [lazy-lock.json:1-30](../../../lazy-lock.json)
- `vim.g.loaded_python3_provider = 0` disables only the pynvim provider. "Nothing here uses :python3/pynvim — completion is blink.cmp + pyright, formatting is conform." — [init.lua:26-30](../../../init.lua)
- Mason prepends its bin dir to Neovim's PATH, as noted in the tilt_ls comment. That dir has no Python interpreter, so it does not change pyright's `python3` lookup. — [lua/plugins/lsp.lua:100-108](../../../lua/plugins/lsp.lua)

### Inferences
- When nvim is started without the project's venv activated (from a GUI, a terminal multiplexer pane, or another project's shell), pyright resolves third-party imports against a global or pyenv interpreter. Those imports are then unresolved, or resolve to bundled typeshed stubs (the mason package ships `dist/typeshed-fallback`) or to a different version of the library. That is a plausible cause of "gd doesn't take me to the right implementation" for library symbols.
- The pieces for a fix already exist in-repo. The docs adapter's `venv_dir` / `interpreter` ladder could feed `settings.python.pythonPath` from pyright's `before_init`, the same hook and the same mutate-in-place discipline that `pyright_rules` uses. That is a design observation, not something the config does today.

### Gaps
- I did not test pyright's behaviour with a `.venv` present but not activated, to confirm empirically that it ignores it. The conclusion rests on the bundle code (no `.venv` default) and the absence of `venvPath`/`venv` settings.

## Q3. Which navigation keymaps exist, and what does each map to (including go-to-implementation)?

### Takeaway
Python buffers get:
- `gd` (LSP definition through the config's own tagstack writer)
- `grr` (references → quickfix)
- `gri` (implementation)
- `grt` (type definition)
- `]r`/`[r` (in-buffer reference hops)
- `K` (hover plus DevDocs excerpt)
- core's `grn` / `gra` / `gO` / `<C-s>` / `grx` / `an` / `in`
- `<C-t>` / `<leader>j` for going back
- Telescope `<leader>fS` (workspace symbols) and `<leader>fo` (document symbols)

There is **no** call-hierarchy or type-hierarchy mapping, no LSP `gD`, and no Telescope LSP location pickers. **`gri` is dead in Python**: pyright 1.1.409 does not implement `textDocument/implementation`. In the probe, `gd` on a method called through an ABC-typed variable went to the abstract base method, and `grr` did not list the subclass override.

### Cited Findings
- `LspAttach`, pyright branch: `map("gd", tagstack.definition, "Goto definition")`, then `map("<leader>ld", require("config.pyright_rules").open, "Python diagnostic rules")` and a once-per-project shadowing warning. — [lua/plugins/lsp.lua:244-255](../../../lua/plugins/lsp.lua)
- `LspAttach`, all LSP buffers: `map("grr", tagstack.references, "References")`, `map("gri", tagstack.implementation, "Implementation")`, `map("grt", tagstack.type_definition, "Type definition")`. These override core's defaults so that `<C-t>` behaves the same after each. — [lua/plugins/lsp.lua:264-272](../../../lua/plugins/lsp.lua)
- `map("]r", lsp_refs.next, …)` and `map("[r", lsp_refs.prev, …)` hop between `documentHighlight` occurrences in the current buffer. — [lua/plugins/lsp.lua:274-276](../../../lua/plugins/lsp.lua), [lua/config/lsp_refs.lua:1-22](../../../lua/config/lsp_refs.lua)
- `K` → `config.docs.hover.hover` when `has_provider(ft)` (C, C++, Python). This is core hover plus a DevDocs excerpt when the server's hover has no documentation. — [lua/plugins/lsp.lua:278-285](../../../lua/plugins/lsp.lua), [lua/config/docs/hover.lua:1-40](../../../lua/config/docs/hover.lua)
- `<leader>lr` restarts this buffer's clients and re-reads the buffers. `<leader>uh` toggles inlay hints **only if** `client:supports_method("textDocument/inlayHint")`. — [lua/plugins/lsp.lua:304-336](../../../lua/plugins/lsp.lua)
- `config.tagstack` behaviour:
  - All four verbs go through `M.locations(...)` with an `on_list`.
  - One result jumps; several open `botright copen` with a single tagstack frame pushed per invocation.
  - References always open the list (`always_list`).
  - An empty result notifies "no <verb> found".

  — [lua/config/tagstack.lua:288-379](../../../lua/config/tagstack.lua)
- `M.implementation` is `M.locations(vim.lsp.buf.implementation, "gri", "implementation")`. — [lua/config/tagstack.lua:373-375](../../../lua/config/tagstack.lua)
- When no attached client supports a location method, core's `get_locations` warns `lsp._unsupported_method(method)`. — `$VIMRUNTIME/lua/vim/lsp/buf.lua:216-223`
- Probe: pyright's static capabilities are callHierarchy, codeAction, completion, declaration, definition, documentHighlight, documentSymbol, executeCommand, hover, references, rename, signatureHelp, typeDefinition and workspaceSymbol; `textDocument/diagnostic` is dynamic. `supports_method` is **false** for `textDocument/implementation`, `prepareTypeHierarchy`, `inlayHint`, `semanticTokens/full`, `codeLens`, `foldingRange` and `selectionRange`. A raw `textDocument/implementation` request returned `-32601 "Unhandled method textDocument/implementation"`. — Probe; the same capability object appears in mason `pyright/dist/pyright-internal.js` (initialize result: `…signatureHelpProvider…, callHierarchyProvider:!0, workspace:{…}`)
- Probe, `gd` on `r.save(1)` where `r: Repo` (an ABC): the definition was `base.py:6`, the abstract `Repo.save`, not `SqlRepo.save` in `impl.py`. — Probe
- Probe, references on `r.save` (includeDeclaration): `main.py:6` and `base.py:6` only. The override `SqlRepo.save` in `impl.py:5` was **not** returned. — Probe
- Probe, call hierarchy: `prepareCallHierarchy` on `r.save` → `save@base.py`; `callHierarchy/incomingCalls` → `run@main.py`. Pyright does answer call hierarchy. — Probe
- Global keymaps:
  - `<C-t>` → `config.tagstack.pop(count)`. — [lua/config/options.lua:286-292](../../../lua/config/options.lua)
  - `<leader>j` → `config.tagstack_picker.open()`, a picker over the definition stack. — [lua/config/options.lua:294-297](../../../lua/config/options.lua)
  - `jumpoptions = "clean,view"`. — [lua/config/options.lua:278-284](../../../lua/config/options.lua)
- Core LSP defaults that are left as they are:
  - `grn` rename, `gra` code action (n/x), `grx` `vim.lsp.codelens.run()`, `gO` `vim.lsp.buf.document_symbol()` (location list), insert/select `<C-S>` signature help. — `$VIMRUNTIME/lua/vim/_core/defaults.lua:204-234`
  - `an` / `in` LSP selection range in x/o modes. Pyright has no selectionRange, so these do nothing in Python. — `$VIMRUNTIME/lua/vim/_core/defaults.lua:470-482`
  - Core sets `tagfunc=v:lua.vim.lsp.tagfunc`, so `<C-]>` is LSP definition. — `$VIMRUNTIME/lua/vim/lsp.lua:849-851`
- which-key relabels `gr` (group), `gra`, `grn`, `grr`, `gri`, `grt`, `grx` and `gO`. — [lua/plugins/which-key.lua:29-42](../../../lua/plugins/which-key.lua)
- Telescope LSP pickers bound: `<leader>fS` → `lsp_dynamic_workspace_symbols()` and `<leader>fo` → `lsp_document_symbols()`. Related non-LSP keys: `<leader>fd` diagnostics, `<leader>fs` grep word under cursor, `<leader>fg` live grep from the repo root. — [lua/plugins/telescope.lua:35-40](../../../lua/plugins/telescope.lua), [lua/plugins/telescope.lua:65-94](../../../lua/plugins/telescope.lua)
- A grep of `lua/`, `init.lua`, `ftplugin/` and `after/` finds no `incoming_calls`, `outgoing_calls`, `typehierarchy`, `lsp_definitions`, `lsp_references`, `lsp_implementations`, `lsp_incoming_calls` or `lsp_outgoing_calls`. Core has `vim.lsp.buf.incoming_calls()`, `outgoing_calls()` and `typehierarchy(kind)`, which list into quickfix, but no default keys for them. — `$VIMRUNTIME/lua/vim/lsp/buf.lua:1020-1044`; `$VIMRUNTIME/lua/vim/_core/defaults.lua:204-234` (no such maps)
- Structural motions:
  - `]]` / `[[` jump by treesitter section (Python included via `@local.definition.function` / `.method`). — [lua/plugins/treesitter.lua:151-156](../../../lua/plugins/treesitter.lua), [lua/config/ts_sections.lua:12-24](../../../lua/config/ts_sections.lua)
  - `[f` jumps to the enclosing context header (treesitter-context). — [lua/plugins/treesitter-context.lua:31-37](../../../lua/plugins/treesitter-context.lua)
- `gD` is not an LSP mapping. In Neovim it is Vim's built-in textual "Goto global Declaration" (searches for the keyword from line 1), and core's LSP defaults do not map it. — `$VIMRUNTIME/doc/pattern.txt:116-121`; `$VIMRUNTIME/lua/vim/_core/defaults.lua:204-234`. The cheatsheet nonetheless lists "`gD` | go to **declaration** (Nvim 0.11 default)". — [docs/keybindings.md:653](../../keybindings.md)
- The cheatsheet says `grr` "pushes the definition stack on select". The code pushes one frame when `grr` is invoked, not on selection, and explains why. — [docs/keybindings.md:654](../../keybindings.md) vs [lua/config/tagstack.lua:290-314](../../../lua/config/tagstack.lua)

### Inferences
- The complaint "the LSP sometimes does not take me to the correct implementation" maps directly onto the probe. In Python code that calls through a base class, ABC or Protocol type, `gd` lands on the declared (abstract or protocol) method. Pyright offers no `textDocument/implementation` to reach concrete overrides, and its references for the base method do not list the overrides either. In this config the only way from an interface method to its implementations is text search (`<leader>fs` / `<leader>fg`) or workspace symbols by name.
- Other likely contributors to "wrong target", from Q1 and Q2:
  - the wrong interpreter, so library imports resolve to stubs or nothing;
  - multi-package root splitting, so a sibling package resolves to its installed copy;
  - a stale index with file watching off;
  - when only a `.pyi` resolves (pyright prefers source only when both resolve), `gd` lands in a stub.
- Call hierarchy is supported by pyright (probe) but has no key or UI here. Adding it would expose existing capability rather than need a new server.
- `gri` and `<leader>uh` are wired generically. In Python one produces a warning, and the other is never mapped because pyright lacks inlay hints.

### Gaps
- I did not probe Protocol (structural) subtyping, `@overload`, dataclass/attrs, `__getattr__`, decorator-wrapped functions, or re-exports through `__init__.py`. Those are other cases where pyright's `gd` target can surprise.
- Which alternative servers (basedpyright, pyrefly, ty, zuban, jedi, pylsp) implement `textDocument/implementation` or type hierarchy is outside this local audit. Their lspconfig configs exist in the installed nvim-lspconfig (`stdpath("data")/lazy/nvim-lspconfig/lsp/{basedpyright,pyrefly,ty,zuban,jedi_language_server,pylsp,pyre,pylyzer}.lua`), but none is enabled or installed.

## Q4. Which readability features are on or off for Python?

### Takeaway
Python readability is **treesitter-only plus custom overlays**:
- **On:** treesitter highlighting, folding and indent; treesitter-context sticky headers (max 4 lines); custom block-scope guides; declaration hairlines; bold declaration names; `documentHighlight` occurrence underlines with a `⇄N` count in the statusline; hover with a DevDocs fallback; blink docs and signature-help windows.
- **Off or absent:** inlay hints (pyright has none), LSP semantic tokens (pyright has none, so `syntax_emphasis`'s `@lsp.*` work never applies to Python), code lens, breadcrumbs/winbar, symbol outline sidebar, LSP folding, and docstring-specific styling. The comment-dimming tiers target `@comment.documentation`, while Python docstrings are `@string.documentation`.

### Cited Findings
- Treesitter:
  - `python` is in the FileType pattern that calls `vim.treesitter.start`, sets `foldmethod=expr`, `foldexpr=v:lua.vim.treesitter.foldexpr()` and the nvim-treesitter `indentexpr`, and attaches `]]`/`[[`. — [lua/plugins/treesitter.lua:76-159](../../../lua/plugins/treesitter.lua)
  - A large-file guard skips all of it for big files. — [lua/plugins/treesitter.lua:125-135](../../../lua/plugins/treesitter.lua)
  - The Python parser is pinned at `v0.25.0`. — [parser-revisions.lua:34](../../../parser-revisions.lua)
  - `python.so` is installed under nvim's `site/parser`. nvim-treesitter (main) ships `queries/python/{folds,highlights,indents,injections,locals}.scm`. — `stdpath("data")/lazy/nvim-treesitter/runtime/queries/python/`
- Folding:
  - `foldlevel=99`, `foldlevelstart=99`, `foldcolumn=auto:1`. — [lua/plugins/treesitter.lua:161-168](../../../lua/plugins/treesitter.lua)
  - Pyright has no `foldingRange` (Probe), so LSP folding is unavailable anyway.
  - Cheatsheet fold keys are the core `za`/`zA`/`zo`/`zc`/`zR`/`zM`/`zj`/`zk`. — [docs/keybindings.md:574-588](../../keybindings.md)
- Sticky scroll:
  - nvim-treesitter-context is enabled with `max_lines = 4`, `multiline_threshold = 1`, `trim_scope = "outer"`, `mode = "cursor"`, `separator = "─"` and a large-file guard. — [lua/plugins/treesitter-context.lua:1-22](../../../lua/plugins/treesitter-context.lua)
  - Its Python `context.scm` covers class/function/try/with/if/elif/case/while/except/match/for/finally/else/pair. — `stdpath("data")/lazy/nvim-treesitter-context/queries/python/context.scm`
  - Toggled with `<leader>ut`. — [docs/keybindings.md:1020-1031](../../keybindings.md)
- Inlay hints:
  - Off by default, with a per-buffer toggle that is capability-gated. — [lua/plugins/lsp.lua:323-336](../../../lua/plugins/lsp.lua)
  - Pyright `supports_method("textDocument/inlayHint") == false`. — Probe
  - Result: no inlay hints in Python, and `<leader>uh` is never mapped.
- Semantic tokens:
  - Neovim enables them automatically when a server advertises `semanticTokensProvider`. Pyright does not (Probe: `semanticTokens/full` false).
  - `config.syntax_emphasis` does extensive `@lsp.type.*` / `@lsp.typemod.*` re-linking, clears `@lsp.type.comment`, and re-bolds declarations. It is designed around gopls's tokens. — [lua/config/syntax_emphasis.lua:19-35](../../../lua/config/syntax_emphasis.lua), [lua/config/syntax_emphasis.lua:77-90](../../../lua/config/syntax_emphasis.lua), [lua/config/syntax_emphasis.lua:150-169](../../../lua/config/syntax_emphasis.lua), [lua/config/syntax_emphasis.lua:186-254](../../../lua/config/syntax_emphasis.lua)
  - Wired at startup via `require("config.syntax_emphasis").setup()`. — [init.lua:60](../../../init.lua)
- Treesitter-level emphasis for Python:
  - Python `highlights.scm` captures `def` names as `@function` (line 40) and methods as `@function.method` (line 359), separate from `@function.call` (388) and `@function.method.call` (392). `__init__`/`__new__` and Capitalized calls are `@constructor` (383-401). — `stdpath("data")/lazy/nvim-treesitter/runtime/queries/python/highlights.scm`
  - Docstrings are captured as `@string.documentation` (line 85). — same file
  - `syntax_emphasis` dims only `@comment` / `@comment.documentation`. — [lua/config/syntax_emphasis.lua:150-169](../../../lua/config/syntax_emphasis.lua)
- Scope guides:
  - `config.block_guides` draws persistent dim vertical guides on every foldable block and brightens the cursor's ancestor chain. It uses a decoration provider and excludes only prose filetypes. Toggle `<leader>ub`. — [lua/config/block_guides.lua:1-15](../../../lua/config/block_guides.lua), [docs/keybindings.md:1034-1048](../../keybindings.md)
  - A spec covers Python import grouping. — [tests/spec/e2e/block_guides_spec.lua:149-151](../../../tests/spec/e2e/block_guides_spec.lua)
  - `listchars` also shows indentation. — [lua/config/options.lua:12-34](../../../lua/config/options.lua)
- Declaration hairlines: `config.decl_rules` underlines the line above each top-level declaration group, meaning "any named child of the tree ROOT", language-agnostic. Toggle `<leader>ur`. — [lua/config/decl_rules.lua:1-25](../../../lua/config/decl_rules.lua), [lua/config/decl_rules.lua:244](../../../lua/config/decl_rules.lua)
- Occurrence highlighting:
  - `config.lsp_refs` sends `textDocument/documentHighlight` on CursorHold, underlines the occurrences, and exposes `⇄N` in the statusline. — [lua/config/lsp_refs.lua:1-32](../../../lua/config/lsp_refs.lua), [lua/config/lsp_refs.lua:281-295](../../../lua/config/lsp_refs.lua)
  - Pyright supports `documentHighlight`. — Probe
- Statusline: `"%f %m%r   %{v:lua.git_branch_status()}%=%{v:lua.lsp_refs_status()}%{v:lua.gitsigns_hunks_status()} %y %l:%c %p%% "`, with a global statusline (`laststatus=3`). There is no symbol path. — [lua/config/statusline.lua:279-280](../../../lua/config/statusline.lua), [lua/config/options.lua:306](../../../lua/config/options.lua)
- Breadcrumbs/winbar: `winbar` is set only for nvim-tree and the docs reader panes, never for code buffers. No navic, dropbar or barbecue is installed. — [lua/config/nvim_tree_changed.lua:68-119](../../../lua/config/nvim_tree_changed.lua), [lua/config/docs/viewer.lua:418-419](../../../lua/config/docs/viewer.lua), [lazy-lock.json:1-30](../../../lazy-lock.json)
- Outline / symbol tree:
  - No aerial, outline.nvim, symbols-outline or trouble in the lock. — [lazy-lock.json:1-30](../../../lazy-lock.json)
  - Document symbols are reachable only via core `gO` (location list) and Telescope `<leader>fo`. — [lua/plugins/telescope.lua:88-94](../../../lua/plugins/telescope.lua)
  - The only "outline" UI in the repo belongs to the `gK` docs reader for pydoc pages, not source files. — [lua/config/docs/adapters/python.lua:727-746](../../../lua/config/docs/adapters/python.lua), [lua/config/docs/viewer.lua:1-20](../../../lua/config/docs/viewer.lua)
- Code lens / reference counts:
  - The config's stance is "quiet UI": it explicitly disables terraform-ls's codelens. — [lua/plugins/lsp.lua:79-88](../../../lua/plugins/lsp.lua)
  - Pyright has no codeLens. — Probe
  - The only reference count is the in-buffer `⇄N`. There is no project-wide "N references" display.
- Diagnostics: `virtual_text` is off; signs are severity-sorted; a CursorHold float shows the diagnostic under the cursor. — [lua/plugins/lsp.lua:183-221](../../../lua/plugins/lsp.lua)
- Hover and signature:
  - `K` is core hover (no custom border; no `winborder` set anywhere) plus a DevDocs excerpt for pyright symbols whose hover has no docs (C-implemented builtins, typeshed stubs). — [lua/plugins/lsp.lua:278-285](../../../lua/plugins/lsp.lua), [docs/hover-docs.md:3-24](../../hover-docs.md)
  - blink.cmp: documentation `auto_show = true` (200ms) and `signature = { enabled = true }`, both with rounded borders. The Python sources are `{ "snippets", "lsp", "path", "buffer" }`. — [lua/plugins/completion.lua:75](../../../lua/plugins/completion.lua), [lua/plugins/completion.lua:104-125](../../../lua/plugins/completion.lua)
- Long lines: soft-wrap is off, and long lines "unfold in place" after a cursor rest. — [docs/keybindings.md:1050-1059](../../keybindings.md), [init.lua:65](../../../init.lua)

### Inferences
- Because pyright sends no semantic tokens, Python gets none of the semantic distinctions an IDE would show. Examples: parameter vs local vs global, a class used as a type vs a constructor call, a `self.` attribute vs a module attribute, readonly or constant, decorators resolved to their targets. Only treesitter's syntactic captures apply.
- `syntax_emphasis` dims comments into two tiers but leaves Python docstrings (`@string.documentation`) at string colour. For docstring-heavy Python, the "doc block recedes" effect that the config builds for Go does not happen.
- `decl_rules` treats every top-level statement as a declaration, so in Python it also draws rules above imports and module-level assignments. This is presumably harmless but untested for Python.
- Without breadcrumbs or an outline, the only "where am I" cues in a long class are treesitter-context (up to 4 header lines) and `[f`. There is no persistent class › method path.

### Gaps
- I did not visually verify decl_rules or block_guides rendering on a real Python file.
- I did not check whether the colorscheme gives `@string.documentation` a distinct style.

## Q5. What do the repo's docs and tests say about Python, and what decisions or limitations are documented?

### Takeaway
The Python-specific docs are almost entirely about **diagnostics noise**: the per-project pyright severity picker, written for Pydantic-heavy codebases. They also cover `K`/`gK` documentation lookup. **Nothing documents Python navigation, venv handling, or why pyright was chosen over basedpyright.** The only basedpyright mention is that its `"hint"` severity is not valid in pyright. Tests cover the severity picker (unit, e2e, and real-pyright lanes), pyright hover excerpts, and blink capabilities advertised to pyright. No test exercises pyright navigation (`gd`/`grr`/`gri`) or treesitter on Python files.

### Cited Findings
- `docs/python-diagnostics.md` covers the following:
  - The `<leader>ld` / `:PyrightRules` picker; persistence in `stdpath("data")/nvim-pyright-rules.json`, keyed by realpath'd pyright root. — [docs/python-diagnostics.md:1-52](../../python-diagnostics.md)
  - Why per-rule severities and not `typeCheckingMode`: basic, standard and strict all give 12 errors on the Pydantic sample with pyright 1.1.409. — [docs/python-diagnostics.md:54-72](../../python-diagnostics.md)
  - Pyright has no plugin system and synthesizes `BaseModel.__init__` only from PEP 681. — [docs/python-diagnostics.md:74-93](../../python-diagnostics.md)
  - How the settings aliasing trap works. — [docs/python-diagnostics.md:95-124](../../python-diagnostics.md)
  - Gotchas:
    - a `pyrightconfig.json` or `[tool.pyright]` discards **all** editor settings wholesale;
    - the settings are editor-only;
    - they are whole-project only, because Neovim ignores `scopeUri`;
    - editing pyright config files needs `<leader>lr`, because file watching is off;
    - ruff and dprint are also attached.

    — [docs/python-diagnostics.md:126-162](../../python-diagnostics.md)
  - Rejected approaches: a publishDiagnostics handler (no-op, because pyright uses pull), neoconf.nvim (inert under the native API), and an exrc `vim.lsp.config` (loses the merge order). — [docs/python-diagnostics.md:164-187](../../python-diagnostics.md)
- The only basedpyright mention: "`hint` is deliberately not offered. It is a **basedpyright** extension; pyright 1.1.409 silently discards it". — [docs/python-diagnostics.md:51-52](../../python-diagnostics.md), [lua/config/pyright_rules.lua:43-46](../../../lua/config/pyright_rules.lua). `git log --grep=basedpyright` returns only `adf3dc8 feat(python): pick pyright rule severities per project`.
- `docs/hover-docs.md` makes these Python points:
  - Pyright hovers for `len` / `print` / `str.split` are signature-only, because typeshed stubs have no docstrings. — [docs/hover-docs.md:19-20](../../hover-docs.md)
  - `brief/python.lua` names the symbol through pyright's `textDocument/declaration`. — [docs/hover-docs.md:32](../../hover-docs.md)
  - The interpreter-based choice of DevDocs version. — [docs/hover-docs.md:117-137](../../hover-docs.md)
  - Rejected: a `pyvenv.cfg` → `.python-version` probe. — [docs/hover-docs.md:303-307](../../hover-docs.md)
- `docs/keybindings.md` §14 LSP lists the keys described in Q3. It contains the inaccurate `gD` row (line 653) and `grr` row (line 654). Its "Servers configured" list (ts_ls, pyright, gopls, rust_analyzer, lua_ls, bashls, jsonls, yamlls, taplo, html, cssls, marksman, mdx_analyzer) omits ruff and dprint, as well as clangd, zls, tilt_ls, terraformls, graphql, biome and oxlint. — [docs/keybindings.md:645-811](../../keybindings.md)
- `docs/section-motion.md`: `]]`/`[[` replace the runtime's Python `]]` with a treesitter section motion driven by the `locals` query. — [docs/section-motion.md:36-63](../../section-motion.md)
- `docs/navigation-stack.md` covers the `<C-t>` definition-stack design that applies to all LSP verbs, Python included. — [docs/navigation-stack.md:1-14](../../navigation-stack.md), [docs/navigation-stack.md:128-142](../../navigation-stack.md), [docs/navigation-stack.md:307-314](../../navigation-stack.md)
- README prerequisites: Node.js backs pyright, and "Python ≥ 3.8 | Needed by `pyright`". — [README.md:16](../../../README.md), [README.md:26](../../../README.md)
- Tests touching Python:
  - `tests/spec/unit/pyright_rules_spec.lua` and `tests/spec/e2e/pyright_rules_picker_spec.lua` cover the severity store and picker.
  - `tests/spec/e2e-lsp/pyright_rules_spec.lua` uses a real pyright. It self-skips when `pyright-langserver` is not on PATH, and asserts both injection at startup and a live severity change. — [tests/spec/e2e-lsp/pyright_rules_spec.lua:1-150](../../../tests/spec/e2e-lsp/pyright_rules_spec.lua)
  - `tests/spec/e2e-lsp/docs_hover_spec.lua:131-159` checks a real pyright hover on `len` carrying the DevDocs excerpt.
  - `tests/spec/smoke/completion_spec.lua:119-120` checks that blink capabilities are advertised to pyright.
  - `tests/spec/e2e/block_guides_spec.lua:149-151` covers Python import fold groups.
  - `tests/spec/unit/formatters_spec.lua` covers the black vs ruff_format choice. The docs/devdocs unit specs cover the Python adapter (fixtures under `tests/fixtures/devdocs/python~3.10/`).
- The treesitter e2e cases are lua, typescript, terraform, graphql, fga, tiltfile and zig. Python is not among them. — [tests/spec/e2e/treesitter_spec.lua:21-70](../../../tests/spec/e2e/treesitter_spec.lua)
- `tests/spec/unit/tagstack_spec.lua` tests the definition stack with plain buffers, not against pyright. — [tests/spec/unit/tagstack_spec.lua:19-210](../../../tests/spec/unit/tagstack_spec.lua)
- A repo memory notes that e2e tests opening `.py` files need `minimal_init='tests/full_init.lua'` or only bundled parsers attach. — [docs/memory/nvim-e2e-single-file-needs-minimal-init.md:25-29](../../memory/nvim-e2e-single-file-needs-minimal-init.md)

### Inferences
- Python support so far has been driven by one pain point, Pydantic diagnostic noise, plus docs lookup. Navigation in large Python codebases has had no dedicated design work. That fits the user's complaint.
- The choice of pyright over basedpyright looks like a default, not a documented decision. The repo even acknowledges that basedpyright features exist (the "hint" severity) without discussing a switch.

### Gaps
- No ADR, commit message or doc explains the language-server choice for Python. The rationale, if any, is not recorded in the repo.

## Q6. Which pinned versions matter?

### Takeaway
Pinned versions: pyright **1.1.409**, ruff **0.15.14**, dprint **0.55.2**, black **26.5.1**, nvim-lspconfig **3371bf2** (2026-06-25), and Python treesitter parser **v0.25.0**. The config targets Neovim 0.11+. basedpyright is not pinned or installed.

### Cited Findings
- Mason pins: `"black": "26.5.1"`, `"dprint": "0.55.2"`, `"pyright": "1.1.409"`, `"ruff": "0.15.14"`. There is no basedpyright, pyrefly, ty or jedi entry. — [mason-tool-versions.lock:4](../../../mason-tool-versions.lock), [mason-tool-versions.lock:8](../../../mason-tool-versions.lock), [mason-tool-versions.lock:21-22](../../../mason-tool-versions.lock)
- The installed mason pyright `package.json` reports `"version": "1.1.409"`. — mason `pyright/node_modules/pyright/package.json`
- The pins are installed by mason-tool-installer from the lockfile, with `auto_update = false`. — [lua/plugins/lsp.lua:478-518](../../../lua/plugins/lsp.lua)
- Plugin commits:
  - `nvim-lspconfig` `3371bf298c1f56efc26771ee961f461176958fb5`
  - `mason-lspconfig.nvim` `50bf3871b539…`
  - `nvim-treesitter` (main) `4916d6592ede…`
  - `nvim-treesitter-context` `b311b3081895…`
  - `telescope.nvim` `427b576c1679…`
  - `blink.cmp` `78336bc89ee5…`

  — [lazy-lock.json:2](../../../lazy-lock.json), [lazy-lock.json:10](../../../lazy-lock.json), [lazy-lock.json:19](../../../lazy-lock.json), [lazy-lock.json:21-22](../../../lazy-lock.json), [lazy-lock.json:28](../../../lazy-lock.json)
- Python parser: `python = "v0.25.0"`. — [parser-revisions.lua:34](../../../parser-revisions.lua)
- The installed nvim-lspconfig ships configs for alternative Python servers: `basedpyright.lua`, `pyrefly.lua`, `ty.lua`, `zuban.lua`, `jedi_language_server.lua`, `pylsp.lua`, `pyre.lua`, `pylyzer.lua`, and `ruff_lsp.lua` (legacy). — `stdpath("data")/lazy/nvim-lspconfig/lsp/` listing
- There is a stray `nvim-lsp-file-operations` directory under the lazy data dir that is not in `lazy-lock.json`. It is unrelated to Python, an orphan from an earlier spec. — `stdpath("data")/lazy/` listing vs [lazy-lock.json](../../../lazy-lock.json)

### Inferences
- Neovim's core already has APIs for call hierarchy and type hierarchy (`vim.lsp.buf.incoming_calls/outgoing_calls/typehierarchy`), plus inlay hints, semantic tokens, LSP folding (`vim.lsp.foldexpr`), codelens and document color. Any Python improvement limited to pyright capability is therefore a server-side limit, not a client-side one.

### Gaps
- None material.

## Q7. Concrete gaps versus a typical IDE for Python navigation

### Takeaway
Compared with an IDE, this config lacks:
- go-to-implementation for Python (server capability missing)
- override-aware references
- any call-hierarchy UI (the server supports it; nothing is bound)
- type hierarchy (server lacks it)
- venv-aware interpreter selection for the LSP
- semantic highlighting and inlay hints (server lacks them)
- breadcrumbs or symbol path
- an outline sidebar
- a project-wide reference count or code lens
- a "go to source vs stub" choice
- peek/preview windows for definitions and references
- automatic re-indexing of out-of-editor file changes

Several gaps are pyright limits (fixable only by changing or adding a server). Others are pure client-side wiring that Neovim 0.12 already supports.

### Cited Findings
- **Go to implementation** (ABC/Protocol subclasses): `gri` is bound, but pyright returns `-32601`. — Probe; [lua/plugins/lsp.lua:271](../../../lua/plugins/lsp.lua)
- **References** for an abstract method omit the overrides. — Probe
- **`gd` through a base-typed receiver** lands on the abstract or base method. — Probe
- **Call hierarchy**: pyright advertises `callHierarchyProvider` and answers `incomingCalls`. — Probe. Core has `vim.lsp.buf.incoming_calls()` / `outgoing_calls()`. — `$VIMRUNTIME/lua/vim/lsp/buf.lua:1020-1031`. No keymap or picker in the config (grep of `lua/`).
- **Type hierarchy** (supertypes/subtypes): core `vim.lsp.buf.typehierarchy(kind)` exists (`$VIMRUNTIME/lua/vim/lsp/buf.lua:1035-1044`), but pyright `supports_method("textDocument/prepareTypeHierarchy") == false`. — Probe
- **Interpreter/venv**: no `pythonPath`/`venvPath`, no auto-detection; pyright uses `python3` from PATH; the manual escape hatch is `:LspPyrightSetPythonPath`. — Q2 sources
- **Semantic tokens / inlay hints**: unsupported by pyright (Probe); inlay hints are toggle-gated on capability. — [lua/plugins/lsp.lua:323-336](../../../lua/plugins/lsp.lua)
- **Breadcrumbs / winbar symbol path**: none. The statusline has file, branch, `⇄N`, hunks, filetype and position only. — [lua/config/statusline.lua:279-280](../../../lua/config/statusline.lua)
- **Outline / symbol tree sidebar**: none. There is `gO` (location list) and `<leader>fo` (Telescope). — [lua/plugins/telescope.lua:88-94](../../../lua/plugins/telescope.lua); `$VIMRUNTIME/lua/vim/_core/defaults.lua:228-230`
- **Reference counts / code lens**: in-buffer `⇄N` only; pyright has no codeLens (Probe); the config disables codelens elsewhere on purpose ("quiet UI"). — [lua/plugins/lsp.lua:79-88](../../../lua/plugins/lsp.lua), [lua/config/lsp_refs.lua:1-22](../../../lua/config/lsp_refs.lua)
- **Source vs stub**: there is no "go to source definition" for Python, unlike ts_ls's `_typescript.goToSourceDefinition` wiring. — [lua/plugins/lsp.lua:233-236](../../../lua/plugins/lsp.lua), [lua/config/tagstack.lua:381-400](../../../lua/config/tagstack.lua). Pyright prefers source only when both source and stub resolve (pyright-internal.js `PreferSource` filter).
- **Peek/preview**: no definition or reference peek. Multi-result lists go to the plain quickfix window (`botright copen`). — [lua/config/tagstack.lua:310-314](../../../lua/config/tagstack.lua). Telescope's qflist previewer exists but is not wired to LSP location verbs. — [lua/plugins/telescope.lua:181-183](../../../lua/plugins/telescope.lua)
- **Cross-package navigation in monorepos**: one pyright per nearest `pyproject.toml`/`setup.py`, and pyright's `root_dir` is not wrapped. — [lua/config/pyright_rules.lua:525-529](../../../lua/config/pyright_rules.lua); `stdpath("data")/lazy/nvim-lspconfig/lsp/pyright.lua:28-36`. There is no `extraPaths` configuration (grep).
- **Index freshness**: `didChangeWatchedFiles` is disabled for all servers, so external changes need `<leader>lr`/`<leader>lR`. — [lua/plugins/lsp.lua:439-453](../../../lua/plugins/lsp.lua), [docs/python-diagnostics.md:152-155](../../python-diagnostics.md)
- **Selection range** (`an`/`in` expand-selection): core maps exist, but pyright lacks `selectionRange`. — Probe; `$VIMRUNTIME/lua/vim/_core/defaults.lua:470-482`
- **Docstring styling**: Python docstrings (`@string.documentation`) are not part of the comment-tier dimming. — `stdpath("data")/lazy/nvim-treesitter/runtime/queries/python/highlights.scm:85`; [lua/config/syntax_emphasis.lua:150-169](../../../lua/config/syntax_emphasis.lua)
- **Doc inaccuracies**: [docs/keybindings.md:653](../../keybindings.md) describes `gD` as an LSP declaration default, which it is not. [docs/keybindings.md:654](../../keybindings.md) describes `grr` as pushing on select, which it does not. [docs/keybindings.md:810-811](../../keybindings.md) has an incomplete server list.

### Inferences
- Gaps that only a different or additional Python server can close: implementation lookup, override-aware references, type hierarchy, semantic tokens, inlay hints, selection range, and possibly code lens.
- Gaps the client can close today with the existing pyright: a call-hierarchy UI, Telescope or peek pickers for definitions and references, breadcrumbs, an outline, venv detection fed into `settings.python.pythonPath` (reusing `config.docs.adapters.python`'s ladder), `extraPaths` or root strategy for multi-package repos, and docstring dimming.
- Changing servers would interact with existing machinery:
  - `config.pyright_rules` is keyed on client name `"pyright"` (`vim.lsp.get_clients({ name = "pyright" })`, `client.name == "pyright"`) and on pyright's settings namespace. — [lua/config/pyright_rules.lua:382](../../../lua/config/pyright_rules.lua), [lua/config/pyright_rules.lua:534](../../../lua/config/pyright_rules.lua), [lua/plugins/lsp.lua:244](../../../lua/plugins/lsp.lua)
  - The docs-hover provider table has a `pyright = {}` entry. — [lua/config/docs/hover.lua:77](../../../lua/config/docs/hover.lua)
  - `brief/python.lua` relies on pyright's `textDocument/declaration`. — [docs/hover-docs.md:32](../../hover-docs.md)

  A swap to basedpyright, for example, would need those name checks generalised, and basedpyright uses a `basedpyright.analysis` settings namespace. That namespace is not verified here.

### Gaps
- Server-to-server capability comparisons (basedpyright, pyrefly, ty, zuban, jedi, pylsp) and plugin options (outline, breadcrumbs, peek, call-hierarchy UIs) are outside this local audit and need external research.
- I did not measure performance (pyright memory or indexing time on large repos), which matters for any recommendation to switch `diagnosticMode` to `workspace` or to add servers.
