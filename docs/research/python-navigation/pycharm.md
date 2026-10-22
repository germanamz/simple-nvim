# PyCharm: Python code navigation and readability in large multi-file projects (state as of October 2026)

> A research note from October 2026, one of the sources for [the Python navigation research](README.md). It describes other editors and tools as of that date, and this config as it was before the switch to basedpyright.

Scope note: current docs are the PyCharm 2026.2 Help (the type engine page is dated 14 October 2026). Shortcuts below are the Windows/Linux default keymap as the docs print them. Several jetbrains.com pages (blog posts) returned HTTP 403 to the fetcher, so some 2026 release facts come from aggregator summaries; those are labeled.

## 1. Navigation features and their semantics (and why the index makes them feel exact)

### Takeaway
PyCharm's navigation is a set of separate, precisely scoped actions: declaration (Ctrl+B), type declaration (Ctrl+Shift+B), implementation(s) (Ctrl+Alt+B), super method/base class (Ctrl+U), Find Usages (Alt+F7) with scopes and clustering, and Type/Call hierarchies (Ctrl+H / Ctrl+Alt+H). All of them run on IntelliJ Platform indexes built ahead of time over the whole project plus the interpreter's libraries, so "who subclasses / overrides this" is an index lookup, not an on-demand analysis. That is the main reason for the "always finds the right implementation" reputation. The docs describe these features generically. I found no documentation of their behavior for Protocols, mixins, dynamic attributes or re-exports.

### Cited Findings
**Declaration / type / implementation / super**
- Go to Declaration is Ctrl+B or Ctrl+Click. Ctrl+Click also previews the declaration in a tooltip. Go to Type Declaration is Ctrl+Shift+B or Ctrl+Shift+Click. Go to Implementation is Ctrl+Alt+B. "To navigate to the base class or abstract method, press Ctrl+U" (the docs do not use the name "Go to Super Method" here). Gutter icons and "Inheritors" inlay hints are documented as alternative ways to reach implementations and overrides — [PyCharm 2026.2 Help: Source code navigation](https://www.jetbrains.com/help/pycharm/navigating-through-the-source-code.html); [Navigate to super method/implementation](https://www.jetbrains.com/help/pycharm/navigating-to-super-method-or-implementation.html)
- Python tutorial example: with the caret on the method `feeds` of a `Cat` instance, Ctrl+B jumps to the declaration in the parent class `Mammalia` (the inherited method is resolved through the MRO). Ctrl+Alt+B on a class declaration lists the classes that implement it. "If there is only one superclass/subclass, or method, then such a navigation is done silently." With several targets, PyCharm shows a chooser. Pinning a navigation or search popup sends all occurrences to the Find tool window — [PyCharm 2025.2 Help: tutorial "Navigating to a declaration or implementation"](https://www.jetbrains.com/help/pycharm/2025.2/part-2-navigating-to-a-declaration-or-implementation.html) (the same flow appears in tutorial versions from 2021.1 to 2025.2)
- Other caret navigation: Back/Forward (Ctrl+Alt+Left/Right), Last edited location (Ctrl+Shift+Backspace), method-to-method jumps (Alt+Up/Down), optional method separators, the Structure tool window (Alt+7), and next/previous problem (F2/Shift+F2) — [Source code navigation](https://www.jetbrains.com/help/pycharm/navigating-through-the-source-code.html)

**Find Usages**
- Alt+F7 opens the Find tool window. Results can be grouped by files, packages, directories and so on. The Find Usages dialog (Ctrl+Alt+Shift+F7) sets the scope, including predefined scopes such as "Project Test Files" and custom scopes (for example, to exclude tests). "Usage clustering" groups usages "based on their structural similarity" (Show similar usages). For methods, the preview pane can show a call hierarchy, and for fields it can show data flow. The Show Usages popup (Ctrl+Alt+F7) lists the first 100 usages and loads more in pages of 100. Highlight usages in file is Ctrl+Shift+F7, with F3/Shift+F3 to cycle — [PyCharm 2026.2 Help: Find usages](https://www.jetbrains.com/help/pycharm/find-highlight-usages.html)
- The fetched page did not document read/write-access grouping, import grouping or "usage type" grouping for Python (see Gaps).

**Hierarchies**
- Type Hierarchy (Ctrl+H) shows parent and child classes, with toolbar toggles for supertypes and subtypes. Call Hierarchy (Ctrl+Alt+H) shows callers or callees in tabs. Call-hierarchy scopes are Project, Test, All (project and libraries), This class, or a custom scope. Hierarchy tabs can be pinned. Node colors indicate the scope a file belongs to (tests are green by default) — [PyCharm 2026.2 Help: hierarchy](https://www.jetbrains.com/help/pycharm/viewing-structure-and-hierarchy-of-the-source-code.html)
- The fetched hierarchy page did not describe a separate Method Hierarchy view for Python (it exists in IntelliJ for Java) — same source.

**Index architecture (why it "always finds" things)**
- On the IntelliJ Platform, "Stub indexes are built over serialized stub trees". A stub tree "contains only externally visible declarations and is serialized in a compact binary format", and querying a stub index returns PSI elements directly. Indexing runs in the background ("dumb mode"), and while it runs, index-dependent features are unavailable. "For bigger projects, building and providing pre-built shared project indexes can be beneficial." — [IntelliJ Platform SDK: Indexing and PSI Stubs](https://plugins.jetbrains.com/docs/intellij/indexing-and-psi-stubs.html)
- PyCharm's built-in type engine "analyzes code using type hints (PEP 484), type comments, stubs, and docstrings, plus PyCharm's own inference for unannotated code" — [PyCharm 2026.2 Help: Type engine](https://www.jetbrains.com/help/pycharm/python-type-engine.html)
- Search Everywhere, Go to Symbol/Class/File, the Navigation bar, Recent Locations and Quick Definition are not covered on the pages fetched here. Of those pages, the source code navigation page links to "Recent files and changes" and "File navigation" — [Source code navigation](https://www.jetbrains.com/help/pycharm/navigating-through-the-source-code.html)

### Inferences
- "Always finds the right implementation" mostly comes from three properties: (a) a precomputed, whole-project-plus-libraries declaration index, so Ctrl+Alt+B, gutter markers and Type Hierarchy are lookups rather than scans; (b) its own inference that also uses docstrings and unannotated code, so `obj.method` often resolves to a concrete class even without annotations; (c) separate actions for "declaration", "implementations" and "super", so the user asks for the exact relation. LSP servers answer each request lazily. Upstream Pyright does not implement `textDocument/implementation` or type hierarchy at all (see Q2), so "go to definition" on an abstract method lands on the ABC and the user cannot get from there to the overrides.
- PyCharm's inheritor search is almost certainly nominal: it finds explicit subclasses, including ABC subclasses and mixin users. Classes that satisfy a `typing.Protocol` only structurally should not show up as "implementations". I found no doc or YouTrack issue confirming this either way (see Gaps).
- Find Usages scopes (Project vs Test vs Libraries) and file colors are the documented mechanism for "test vs production" separation. Neovim's quickfix references have no equivalent unless a picker filters by path.

### Gaps
- I did not find or fetch a current help page for: Search Everywhere (double Shift), Go to Class/Symbol/File, the Navigation bar, Recent Locations (Ctrl+Shift+E), the File Structure popup (Ctrl+F12) or Quick Definition (Ctrl+Shift+I). These shortcuts come from background knowledge and were not verified this session.
- No source found on how PyCharm navigation treats `typing.Protocol` implementers, decorators that wrap functions, `@property`, `__getattr__`-style dynamic attributes or `__init__.py` re-exports / `__all__`. Background knowledge (unverified): PyCharm resolves through re-exports to the original definition and marks unresolvable dynamic attributes as "unresolved reference" warnings rather than guessing.
- The PyCharm 2026.2 Find Usages page does not mention read/write-access or import-usage grouping for Python. The IntelliJ "Group by usage type" option exists in other IDEs, but I did not confirm it for Python.
- Method Hierarchy (Ctrl+Shift+H) for Python was not confirmed by any fetched source.

## 2. Gutter icons ("overrides"/"is overridden"/"implements") and how much Neovim + LSP can reproduce

### Takeaway
PyCharm draws inheritance gutter markers (overriding/overridden, implementing/implemented, plus a stub/implementation asterisk) and "Inheritors"/"Usages" code-vision hints. These come straight from its indexes. Neovim 0.11+/0.12 has client support for every LSP request needed to emulate them (`implementation`, `typeHierarchy`, call hierarchy, code lens). The bottleneck is the Python server. Upstream Pyright (the server this config uses) advertises none of implementation, typeHierarchy, codeLens, inlayHint or semanticTokens. basedpyright added implementation in v1.34.0, Pyrefly supports implementation, call hierarchy and type hierarchy, and ty supports implementation, call hierarchy and type hierarchy (supertypes) but no code lens.

### Cited Findings
**PyCharm side**
- "The editor shows gutter icons for implemented/implementing and overridden/overriding methods". Clicking one lets you "select an ascendant or descendant class from the list" — [Navigate to super method/implementation](https://www.jetbrains.com/help/pycharm/navigating-to-super-method-or-implementation.html)
- Hovering an arrow icon shows "the list of child classes or overriding methods" (down arrow) or parent classes (up arrow). Clicking it navigates — [tutorial part 2 (2025.2)](https://www.jetbrains.com/help/pycharm/2025.2/part-2-navigating-to-a-declaration-or-implementation.html)
- Stub linkage: elements that have stubs show an asterisk in the gutter, and clicking it moves between the `.pyi` stub and the implementation — [PyCharm Help: Stubs](https://www.jetbrains.com/help/pycharm/stubs.html)
- Code vision hints (2026.2): Usages ("how often a class or method is used", click to jump), Inheritors ("number of descendants of a class or interface", click to choose), LSP Code Lens (shows code lens from LSP servers), Code author (git), Python Web Structure, and an AI "Generate Documentation" hint — [PyCharm 2026.2 Help: Inlay hints](https://www.jetbrains.com/help/pycharm/2026.2/inlay-hints.html)
- Each gutter icon can be toggled individually, and "technology-related icons are displayed only if the corresponding plugin is installed and enabled" — [Settings: Gutter icons](https://www.jetbrains.com/help/pycharm/settings-gutter-icons.html)

**Neovim client side (verified from the Neovim runtime's `:help lsp`)**
- Global default keymaps: `gri` → `vim.lsp.buf.implementation()`, `grr` → references, `grt` → type_definition, `grx` → `vim.lsp.codelens.run()`, `gO` → document_symbol, plus `gra` and `grn`. `vim.lsp.buf.typehierarchy({kind})` takes `"subtypes"|"supertypes"`. `incoming_calls()` and `outgoing_calls()` list results in quickfix — [Neovim docs: lsp](https://neovim.io/doc/user/lsp.html) (read from the runtime's `doc/lsp.txt`, because the web page could not be fetched)

**Server side**
- Local probe (upstream pyright 1.1.409, the version this config pinned then, started via `vim.lsp.start` in headless Neovim). Advertised: `callHierarchyProvider`, `declarationProvider`, `typeDefinitionProvider`. NOT advertised: `implementationProvider`, `typeHierarchyProvider`, `codeLensProvider`, `inlayHintProvider`, `semanticTokensProvider`, `foldingRangeProvider`. A raw `textDocument/implementation` request returned error -32601 "Unhandled method textDocument/implementation" — first-hand experiment, no URL. This is consistent with a 2021 maintainer statement that it is "not supported by pyright" — [Neovim Discourse (2021)](https://neovim.discourse.group/t/pyright-go-to-implementation-not-working/1336)
- basedpyright 1.34.0 (based on pyright 1.1.407, about Nov 2025): "implement `textDocument/implementation` aka 'Go to Implementations'". The same release fixed "semantic highlighting of decorators/properties" — [newreleases.io: basedpyright 1.34.0](https://newreleases.io/project/pypi/basedpyright/release/1.34.0)
- Pyrefly IDE features: Go to implementation ("On a method, navigate to all reimplementations"), Find references, Call hierarchy (incoming and outgoing), Type hierarchy ("all subclasses and superclasses"), document/workspace symbols, inlay hints (types, parameter names, return values), semantic tokens, hover with docstrings. Code lens is not listed — [Pyrefly docs: IDE features](https://pyrefly.org/en/docs/IDE-features/)
- A Pyrefly commit message (mirror) says find-implementation requests "rely on a retained index", and that type hierarchy runs full analysis only on candidate files. Indirect evidence: a commit message, not docs — [Pyrefly source mirror](https://fuchsia.googlesource.com/third_party/github.com/facebook/pyrefly/+/refs/heads/upstream/main)
- ty's LSP reference table lists Go to Implementation, `callHierarchy/*`, `typeHierarchy/*` (supertypes), document highlight, folding range, selection range, inlay hints and semantic highlighting. `textDocument/codeLens` is "❌ Not supported" — [ty docs: language server](https://docs.astral.sh/ty/features/language-server/)

### Inferences
- PyCharm-style "is overridden" markers can be built in Neovim with a plugin or local module that, for each class or method in `textDocument/documentSymbol`, asks `prepareTypeHierarchy` + `typeHierarchy/subtypes` (classes) or `textDocument/implementation` (methods) and places a sign or virtual text when the result is non-empty. "Overrides/implements" (the up arrow) needs `typeHierarchy/supertypes` plus a name match on the parent's members. With Pyright as the only server, none of this works. Running basedpyright, Pyrefly or ty (alone, or alongside Pyright for navigation only) is the prerequisite. Cost is one or more requests per symbol per buffer, so it should be debounced or computed lazily for visible lines. PyCharm avoids that cost with the precomputed index.
- "Usages" code vision (reference counts above definitions) can be approximated the same way with `textDocument/references` per symbol (existing plugins of the "symbol-usage" kind do this), since none of the Python servers above offer code lens.
- `vim.lsp.buf.typehierarchy("subtypes")` plus `gri` give the Ctrl+H / Ctrl+Alt+B equivalents, but in quickfix rather than a tree. A tree UI needs a plugin.

### Gaps
- Whether basedpyright (latest 1.37.x per search snippets) supports `typeHierarchy` was not confirmed.
- Whether ty's type hierarchy supports subtypes (the table says "(supertypes)") is unclear. It may mean subtypes are not implemented.
- Specific Neovim plugins that already draw PyCharm-style inheritance gutter icons were not researched (outside this note's scope).

## 3. Import resolution and the project model (interpreter, roots, stubs, frameworks)

### Takeaway
PyCharm resolves imports from an explicit project model: a project interpreter (whose site-packages become indexed library roots), content roots, and directories marked "Sources" ("the starting point for resolving imports"). Stubs work with a stub/implementation gutter link, user stub directories can be added as source roots or interpreter paths, and `-stubs` packages are supported. PyCharm's own stubs and typeshed date back to 2017 docs. How Ctrl+B chooses between `.pyi` and `.py` is not stated in current docs. Pyrefly documents the policy explicitly: definition goes to `.py`, type definition to `.pyi`.

### Cited Findings
- Content root: "a folder that contains the files that make up your project". A project has at least one, and several are allowed. Sources roots: PyCharm "uses the source roots as the starting point for resolving imports" and parses, inspects and indexes them. Excluded folders are ignored for analysis, search and parsing. Resource and Template roots are Pro-only. Directories are marked via Mark Directory As in the Project tool window — [PyCharm 2026.2 Help: Content roots](https://www.jetbrains.com/help/pycharm/content-root.html)
- Stubs: PyCharm supports `.pyi` files. For your own code, create a stub with the same name next to the implementation. For third-party packages, make a directory, mark it as a Source Root, mirror the package hierarchy, and add the stubs there. To reuse stubs across projects, add the directory under the interpreter's "Interpreter paths", where it becomes a library root. PEP 561 `-stubs` packages can be installed from the package installer — [PyCharm Help: Stubs](https://www.jetbrains.com/help/pycharm/stubs.html)
- Older (2017.2): PyCharm was moving to Typeshed for bundled stubs but used only a few of them (e.g. `builtins.pyi`, `typing.pyi`) at that time — [PyCharm 2017.2 Help: type hinting](https://www.jetbrains.com/help/pycharm/2017.2/type-hinting-in-pycharm.html) (dated, 2017)
- Pyrefly's explicit policy, for comparison: Go to definition jumps to `.py` "If there is both a `.pyi` and `.py` file". Go to type definition goes to the `.pyi` when the expression is a type. Go to declaration "stop[s] at imports" — [Pyrefly docs: IDE features](https://pyrefly.org/en/docs/IDE-features/)
- Built-in type engine supports local, virtualenv, Docker, Docker Compose, WSL, SSH interpreters and multi-module projects. The external (Pyrefly) engine "currently works only with local interpreters" — [PyCharm 2026.2 Help: Type engine](https://www.jetbrains.com/help/pycharm/python-type-engine.html)
- Framework support visible in fetched docs: code vision has a "Python Web Structure" hint ([Inlay hints 2026.2](https://www.jetbrains.com/help/pycharm/2026.2/inlay-hints.html)), and the Pyrefly engine is described as having "support for Django and Pydantic" ([Type engine](https://www.jetbrains.com/help/pycharm/python-type-engine.html)).

### Inferences
- PyCharm's "Mark as Sources Root" corresponds to Pyright/basedpyright `extraPaths` / `executionEnvironments` (and src-layout auto-detection). The difference is that PyCharm stores it once in `.idea/` and every feature (index, resolve, run configurations) uses it, while in Neovim each server has to be configured.
- A Neovim user who wants PyCharm's "Ctrl+B lands on the real code, not the stub" behavior should prefer a server with that documented policy (Pyrefly), or keep `grt`/type definition for the `.pyi`.

### Gaps
- No current source fetched for: namespace packages (PEP 420; background knowledge says PyCharm has a "Mark Directory as Namespace Package" option), src layout, editable installs (`pip install -e`, `.pth`/import-hook editable installs), "skeletons" for compiled/binary modules, or which `.pyi` vs `.py` Ctrl+B prefers in PyCharm.
- No fetched source details Django/Flask/FastAPI/SQLAlchemy/Pydantic navigation (e.g. Django model managers, template-to-view navigation, URL resolution). Background knowledge (unverified): these are Pro-tier features. The unified-PyCharm help page does not give a feature-by-tier table ([Unified PyCharm 2026.2](https://www.jetbrains.com/help/pycharm/2026.2/unified-pycharm.html)).

## 4. Readability features (inlay hints, docs, sticky lines, reader mode, structure)

### Takeaway
As of 2026.2, PyCharm has a rich set of Python inlay hints (parameter names with heuristics, inferred return/parameter types, generic type arguments, method-chain types, `reveal_type`, pattern-matching attribute names) plus code-vision usages/inheritors counts. It also has Quick Documentation with rendered docstrings, sticky lines (since 2024.1), reader mode with rendered doc comments for read-only and library files, and the Structure tool window. Pyrefly, ty and Pyright-family servers already provide most of the hint/hover/semantic-token data over LSP, but the PyCharm-specific heuristics (when to show a hint) would need client-side filtering.

### Cited Findings
- Parameter-name hints are shown "only if the function or method has more than one positional parameter or argument". They cover class constructor calls, non-literal arguments and `@pytest.mark.parametrize` names. There is an editable exclude list with patterns like `*.put(self, key, value)` — [Inlay hints (2026.2)](https://www.jetbrains.com/help/pycharm/2026.2/inlay-hints.html)
- Python type hints: `reveal_type` argument type, function return types, type parameter variance (`in`/`out`), parameter type annotations, generic class and generic function call type arguments, numeric type promotions. Method-chain return types are shown "only ... when methods are called at separate lines". Positional class-pattern attribute names in `match`. Ruff error code names — same source
- Code vision: usage counts, inheritor counts, LSP code lens passthrough, code author from git. Global toggle via "Toggle Inlay Hints Globally" — same source
- Quick Documentation: F1 (macOS) / Ctrl+Q. Pressing it again turns the popup into a tool window — [JetBrains Guide: Quick Documentation](https://www.jetbrains.com/pycharm/guide/tips/quick-docs/). Rendering of Epydoc/reStructuredText docstrings in the popup dates back to PyCharm 1.5 — [JetBrains blog (PyCharm 1.5 EAP)](https://blog.jetbrains.com/?p=5872%2F) (very old, about 2011)
- Reader mode configures how code and comments look in read-only files and libraries. Rendered documentation comments toggle with Ctrl+Alt+Q — [PyCharm Help: Reader mode](https://jetbrains.com/help/pycharm/reader-mode.html) (latest page found dated Oct 2024)
- Sticky lines (PyCharm 2024.1) keep "the beginnings of classes or methods" pinned at the top of the editor and are clickable — [What's New in PyCharm 2024.1](https://www.jetbrains.com/pycharm/whatsnew/2024-1/)
- With the Pyrefly type engine, quick documentation and inlay hints come from Pyrefly only if enabled under Settings | Python | Type Engine > Other Features (off by default) — [Type engine](https://www.jetbrains.com/help/pycharm/python-type-engine.html)
- Method separators and the Structure tool window (Alt+7) — [Source code navigation](https://www.jetbrains.com/help/pycharm/navigating-through-the-source-code.html)

### Inferences
- Neovim equivalents: `vim.lsp.inlay_hint.enable()` (needs a server that advertises inlay hints; upstream Pyright does not, per the probe in Q2, but basedpyright, Pyrefly and ty do per their docs), treesitter-context for sticky lines, hover (`K`) with markdown rendering for Quick Documentation, `gO`/outline plugins for Structure, and breadcrumbs via winbar plus documentSymbol. PyCharm's parameter-hint heuristics (only for 2+ positional args, an exclude list) would have to be reimplemented as a filter on the inlay-hint handler.

### Gaps
- Whether PyCharm's semantic highlighting ("Semantic highlighting" color-per-identifier, an IntelliJ editor option) applies to Python was not verified this session.
- Code folding specifics for Python (docstring folding, import block folding) were not researched.

## 5. Recent changes (2024–2026): unified distribution, external type checkers, LSP

### Takeaway
PyCharm 2025.1 merged Community and Professional into one "unified" product (free core, paid Pro). 2025.3 added LSP-based integrations for Ruff (formatting), ty, Pyright and Pyrefly under Settings | Python | Tools. 2026.1.2 (May 2026) added a "Type engine" switch that lets Pyrefly, over LSP, replace the built-in engine for type inference, type diagnostics and (optionally) quick docs and inlay hints. 2026.2 (July 2026) promoted that as a large-codebase speed feature. As of the 14 Oct 2026 docs, Pyrefly is the only external type engine, and it works with local interpreters only. PyCharm consumes LSP servers. I found no evidence that it exposes its own Python engine as an LSP server.

### Cited Findings
- 2025.1: "PyCharm is now a unified product, combining PyCharm Professional and Community Edition". Core features including Jupyter stay free, there is a 30-day Pro trial, and existing Pro licenses are unchanged — [PyCharm 2025.1 Help: Unified PyCharm](https://www.jetbrains.com/help/pycharm/2025.1/unified-pycharm.html). The 2025.1 docs said 2025.2 would be the last standalone Community release. The 2026.x docs say "With the 2025.3 release, we offer a seamless way to migrate to the unified PyCharm". The two doc versions give different timelines — [Unified PyCharm 2026.2](https://www.jetbrains.com/help/pycharm/2026.2/unified-pycharm.html)
- 2025.3: expanded LSP integration "with new tools from the Astral, Microsoft, and Meta ecosystems": Ruff formatting, ty, Pyright and Pyrefly, each enabled individually in Settings | Python | Tools — [What's New in PyCharm 2025.3](https://www.jetbrains.com/pycharm/whatsnew/2025-3/) (via search summary of that page)
- 2026.1.1 release notes list LSP-server-based symbol rename (`textDocument/rename`) — [YouTrack: PyCharm 2026.1.1 release notes](https://youtrack.jetbrains.com/articles/PY-A-233538546/PyCharm-2026.1.1-261.23567.174-build-Release-Notes) (via search snippet, not fetched)
- 2026.1.2: Pyrefly integrated "as an external type provider through the Language Server Protocol". Its speed is said to "markedly outperform the built-in type engine". It is an alternative, not a replacement, with no Docker or multi-module support — [Plushcap summary of JetBrains blog](https://www.plushcap.com/content/jetbrains/blog/jetbrains-pyrefly-lsp-integration-with-type-engine-in-pycharm-202612-the-pycharm-blog); original [JetBrains blog (403 to fetcher)](https://blog.jetbrains.com/pycharm/2026/05/pyrefly-lsp-integration-in-pycharm-2026-1-2/)
- Type engine page (2026.2, dated 14 Oct 2026): options are Built-in (default) and Pyrefly. The external engine takes over type inference and type-related diagnostics, "replacing the built-in type engine for these features". Quick docs and inlay hints come from Pyrefly only if opted in. Switch via the status-bar "Types:" widget or Settings | Python | Type Engine. The choice is persisted in `.idea/pyTypeEngine.xml`, and Pyrefly options in `.idea/pyLspTools.xml` (shareable via VCS). The external engine works with local interpreters only. Docker/Compose/WSL/SSH/multi-module support is "planned for future releases" — [PyCharm 2026.2 Help: Type engine](https://www.jetbrains.com/help/pycharm/python-type-engine.html)
- 2026.2 (July 2026): release post title highlights "Rust, uv, and Jupyter", and Pyrefly is presented as an external engine for speeding up code insight in large codebases — [What's New in PyCharm 2026.2 (blog, 403 to fetcher)](https://blog.jetbrains.com/pycharm/2026/07/what-s-new-in-pycharm-2026-2/); [jetbrains.com/pycharm/whatsnew](https://www.jetbrains.com/pycharm/whatsnew/). An aggregator (ComponentSource) reportedly quotes project load time on "the Kibana codebase" dropping from about 12 s to about 3 s. This figure is UNVERIFIED and suspicious (Kibana is mainly a TypeScript repo) — [ComponentSource PyCharm releases](https://www.componentsource.com/product/pycharm/releases)
- Known-issue lines in release notes (via search snippet): disabling the Pyrefly type engine can leave Pyrefly running as a tool, and a 2026.1.2 regression affected Pyright and Ruff diagnostics in the Python LSP plugin — [YouTrack: 2026.3 EAP 7 release notes](https://youtrack.jetbrains.com/articles/PY-A-233538638) (snippet; exact attribution unclear)
- 2026.3 is in EAP as of October 2026 (EAP 7, build 263.7031.30) — [YouTrack release notes](https://youtrack.jetbrains.com/articles/PY-A-233538638)

### Inferences
- JetBrains' direction is hybrid. The index/PSI layer (navigation, Find Usages, hierarchies, refactoring) stays in-house, and type inference is becoming pluggable through LSP, starting with Pyrefly. The type engine page lists only type-dependent features as switching engines, so navigation presumably still runs on PyCharm's own resolve and indexes. Member resolution (`obj.attr`) depends on inferred types, though, so the boundary is not clean (see Gaps).
- Pyrefly being "the" type engine is good news for Neovim: the same Rust server can run under Neovim's LSP client, which narrows the inference-quality gap.

### Gaps
- Does Ctrl+B / Find Usages use Pyrefly's types when the Pyrefly engine is on? Not stated in docs.
- No evidence found that PyCharm exposes an LSP server for its Python engine. I did not search specifically for JetBrains' non-Python LSP efforts (e.g. a Kotlin LSP).
- Whether ty and Pyright can also be a "Type engine" (not just a diagnostics "Tool") in 2026.3 EAP: not found.

## 6. Known weaknesses: indexing cost on large repos, where inference fails

### Takeaway
PyCharm's main cost is the up-front, CPU-heavy indexing ("dumb mode"), during which navigation is limited. JetBrains' own answers are shared indexes and, since 2026.1.2, the Rust-based Pyrefly engine for faster type analysis on large codebases. Remote, Docker and multi-module setups can't use that faster path yet. User-sentiment sources (forums, review-style blogs) are anecdotal and of mixed quality.

### Cited Findings
- During indexing, the IDE restricts itself to features that don't need indexes (`IndexNotReadyException`, `DumbService`). Shared prebuilt indexes are recommended for big projects — [IntelliJ Platform SDK: Indexing](https://plugins.jetbrains.com/docs/intellij/indexing-and-psi-stubs.html)
- JetBrains positions Pyrefly as the fix for slow type analysis in "complex projects" / "large codebases" (implicitly admitting the built-in engine is slow there). The Pyrefly engine is limited to local interpreters — [Type engine](https://www.jetbrains.com/help/pycharm/python-type-engine.html); [Plushcap summary](https://www.plushcap.com/content/jetbrains/blog/jetbrains-pyrefly-lsp-integration-with-type-engine-in-pycharm-202612-the-pycharm-blog)
- User sentiment (anecdotal, JetBrains support forum): the IDE is "pretty much useless" while indexing, with heavy CPU use — [JetBrains forum: "My rant on Indexing again"](https://intellij-support.jetbrains.com/hc/en-us/community/posts/360002772379?page=2)
- Review-blog sentiment (low credibility, SEO-style): once indexing finishes, PyCharm's search and navigation are "noticeably faster than VSCode's" — [tms-outsource](https://tms-outsource.com/blog/posts/vscode-vs-pycharm/). The same site claims a startup benchmark of VS Code 3.1 s vs PyCharm 14.3 s on 50K lines and an anecdote of PyCharm's rename correctly updating `from .command import command` where VS Code broke it — [tech-insider 2026](https://tech-insider.org/pycharm-vs-vscode-2026/) (self-run, unverified)

### Inferences
- Where PyCharm's inference most likely fails: structural typing (Protocol implementers are not "inheritors"), heavily dynamic code (`getattr`, metaclass- or decorator-generated attributes, plugin registries), framework magic without a dedicated plugin, and code only reachable through remote interpreters that haven't been indexed. These are also the cases where LSP servers fail, so PyCharm's edge is mainly the index-backed inheritance and usage features, not deeper dynamic analysis.
- For Neovim: the index advantage shows up mainly as (1) subtype/override discovery and (2) instant usage counts. With a server that implements `implementation` and `typeHierarchy` (basedpyright ≥1.34 for implementation, Pyrefly, ty), plus per-symbol caching in a plugin, most of the user-visible gap closes. Cold-start cost moves to the server's workspace analysis instead of IDE indexing.

### Gaps
- No credible benchmark found comparing PyCharm index time vs Pyright/basedpyright/Pyrefly/ty workspace analysis on the same large repo.
- No primary source (YouTrack issue) found documenting specific PyCharm inference failures (Protocols, descriptors, metaclasses).
- Reddit/HN sentiment was not sampled in this pass.
