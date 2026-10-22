# Python language servers for Neovim (state as of 2026-10-21)

> A research note from October 2026, one of the sources for [the Python navigation research](README.md). It describes other editors and tools as of that date, and this config as it was before the switch to basedpyright.

Scope: pyright, basedpyright, Astral's ty (`ty server`), Meta's Pyrefly (`pyrefly lsp`), Zuban (`zuban server`), jedi-language-server, python-lsp-server (pylsp), and ruff server. I took the capability data straight from each server's source code (the ServerCapabilities it returns from initialize) on its default branch as of 2026-10-21. Versions and dates come from the GitHub releases API, PyPI, and mason-registry, all queried the same day. File paths are written as plain text on purpose: they name files in upstream repos, not in this config.

## Maturity, latest version/date, license, implementation language

### Takeaway
pyright, basedpyright, Pyrefly (1.x since May 2026), pylsp and ruff are stable releases. ty is still a beta on 0.0.x versions, though it ships several releases a week. Zuban is pre-1.0 and is the only one under AGPL-3.0 (a commercial license is also offered). jedi-language-server is officially in maintenance mode and points users to Zuban. The four servers with type-checker engines are pyright and basedpyright (TypeScript on Node) and ty, Pyrefly and Zuban (Rust). Jedi-ls and pylsp are pure Python and wrap Jedi.

### Cited Findings
- **pyright**: latest is 1.1.414, released 2026-09-09 (1.1.413 came out the same day and 1.1.412 on 2026-08-12) — [GitHub release](https://github.com/microsoft/pyright/releases/tag/1.1.414). The server is written in TypeScript (packages/pyright-internal/src/languageServerBase.ts) — [source](https://github.com/microsoft/pyright/blob/main/packages/pyright-internal/src/languageServerBase.ts). License is MIT — [pydevtools handbook](https://pydevtools.com/handbook/explanation/what-is-a-python-language-server.md). The repo was still active on 2026-10-21 (last push), even though the latest tag is from September — [repo](https://github.com/microsoft/pyright).
- **basedpyright**: v1.40.2, released 2026-10-04 (v1.40.0 on 2026-09-07) — [GitHub release](https://github.com/DetachHead/basedpyright/releases/tag/v1.40.2). It is a community fork of pyright, written in TypeScript, MIT licensed, and distributed on PyPI — [Posit](https://opensource.posit.co/blog/2026-03-31_python-type-checkers/); [pydevtools](https://pydevtools.com/handbook/explanation/what-is-a-python-language-server.md). Posit called it "more mature" than the Rust newcomers — [Posit](https://opensource.posit.co/blog/2026-03-31_python-type-checkers/).
- **ty** (Astral): 0.0.90, released 2026-10-20. Releases are very frequent: 0.0.88 on 2026-10-15, 0.0.89 on 2026-10-16, 0.0.90 on 2026-10-20 — [GitHub release](https://github.com/astral-sh/ty/releases/tag/0.0.90); [CHANGELOG](https://github.com/astral-sh/ty/blob/main/CHANGELOG.md). The README says "ty is currently in beta". It also says ty uses `0.0.x` versioning, has no stable API yet, and tracks stability on a "Stable" milestone — [README](https://github.com/astral-sh/ty/blob/main/README.md). The PyPI classifier is "Development Status :: 4 - Beta" — [PyPI](https://pypi.org/project/ty/). The beta was announced 2025-12-16, with "a Stable release next year" as the goal — [Astral blog](https://astral.sh/blog/ty). License is MIT. The code is Rust and lives in the ruff monorepo under crates/ty_server — [source](https://github.com/astral-sh/ruff/blob/main/crates/ty_server/src/capabilities.rs). OpenAI announced it would acquire Astral on 2026-03-19 and has said it will keep supporting uv, Ruff and ty — [SiliconANGLE](https://siliconangle.com/2026/03/19/openai-acquires-open-source-python-tooling-startup-astral/); [Simon Willison](https://simonwillison.net/2026/Mar/19/openai-acquiring-astral).
- **Pyrefly** (Meta): 1.4.0, released 2026-10-15. Dev prereleases (1.4.0-dev.N) ship between stable releases — [GitHub release](https://github.com/facebook/pyrefly/releases/tag/1.4.0). v1.0 shipped on 2026-05-12, and the announcement says it "has reached stable version 1 status" — [Pyrefly v1.0 blog](https://pyrefly.org/blog/v1.0/). The PyPI classifier is "Development Status :: 5 - Production/Stable" — [PyPI](https://pypi.org/project/pyrefly/). License MIT, written in Rust — [repo](https://github.com/facebook/pyrefly). Positron ships Pyrefly as its default Python language server — [Posit](https://opensource.posit.co/blog/2026-03-31_python-type-checkers/).
- **Zuban** (David Halter, the author of Jedi): v0.10.1, released 2026-10-11 (v0.10.0 on 2026-09-18) — [GitHub release](https://github.com/zubanls/zuban/releases/tag/v0.10.1). It is dual-licensed under AGPL-3.0 and a commercial license — [README](https://github.com/zubanls/zuban/blob/master/README.md). The PyPI classifier still says "Development Status :: 1 - Planning", which looks stale — [PyPI](https://pypi.org/project/zuban/). Written in Rust — [docs](https://docs.zubanls.com/). Posit rated it the "least mature" of the four it evaluated — [Posit](https://opensource.posit.co/blog/2026-03-31_python-type-checkers/).
- **jedi-language-server**: v0.47.0, released 2026-05-31 (v0.46.0 on 2025-10-25) — [GitHub release](https://github.com/pappasam/jedi-language-server/releases/tag/v0.47.0). The README says: "MAINTENANCE MODE: we suggest that new users consider the successor to Jedi: ... Zuban" — [README](https://github.com/pappasam/jedi-language-server/blob/main/README.md). MIT, Python. Jedi itself is at 0.20.1 (2026-10-12) — [PyPI jedi](https://pypi.org/project/jedi/).
- **python-lsp-server (pylsp)**: 1.15.0 was uploaded to PyPI on 2026-07-27. The latest GitHub release is v1.14.0 (2025-12-06) — [PyPI](https://pypi.org/project/python-lsp-server/1.15.0/); [GitHub release](https://github.com/python-lsp/python-lsp-server/releases/tag/v1.14.0). It is maintained by the Spyder team and the community, MIT licensed, and works as a plugin host that wraps Jedi, pyflakes, pycodestyle, Ruff and others — [pydevtools](https://pydevtools.com/handbook/explanation/what-is-a-python-language-server.md).
- **ruff server**: Ruff 0.17.1, released 2026-10-15 — [GitHub release](https://github.com/astral-sh/ruff/releases/tag/0.17.1). nvim-lspconfig notes that the server has been in beta since Ruff v0.4.5 and stable since v0.5.3 — [nvim-lspconfig lsp/ruff.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/ruff.lua). MIT, Rust.

### Inferences
- ty's release cadence (several per week) and its 0.0.x "no stable API" policy mean any pinned version will be out of date within days. Re-check every ty finding in these notes before acting on it.
- AGPL-3.0 has no practical effect on running Zuban locally as an editor server. It matters if someone wanted to bundle or redistribute it, which is why Posit (a bundler) called out the license.

### Gaps
- The GitHub API reports pyright's and basedpyright's license as "NOASSERTION". I did not open their LICENSE files and instead relied on pydevtools and Posit for "MIT".
- I could not find a published date or criteria for when ty will go stable beyond "next year" (i.e. 2026). As of 2026-10-21 it is still beta.

## Speed and memory on large codebases (benchmarks and methodology)

### Takeaway
The four Rust or Rust-engine servers are one to two orders of magnitude faster than pyright on cold, full-project checks. Pyright is also the most memory-hungry; numpy is the one data point (over 3 GB against about 1 GB for Pyrefly). Nearly every number comes from a vendor, though, and only a few measure the LSP case (incremental re-check after an edit, startup, first completion). I found no independent benchmark of LSP memory use on a large multi-file project covering all of these servers.

### Cited Findings
- **Astral's ty beta post (2025-12-16), vendor.** On home-assistant, CLI, "without caching": ty is about 10x to 60x faster than mypy and Pyright. For the editor case, after editing "a load-bearing file in the PyTorch repository", ty recomputed diagnostics in 4.7 ms, Pyright in 386 ms and Pyrefly in 2.38 s. The chart labels ty's figure as 4.5 ms, a small inconsistency. Hardware is not stated — [Astral blog](https://astral.sh/blog/ty).
- **Pyrefly team, "Speed and Memory Usage" (2026-04-10), vendor.** Versions: Pyrefly 0.60.0, ty 0.0.29, Pyright 1.1.408, mypy 1.19.1. Setup: 53 open-source packages on a MacBook M4 with 64 GB RAM, 5 runs after a warmup, no caching, default settings (mypy in strict mode), measuring wall-clock time and peak memory for CLI runs only, with no LSP timing. Selected results (Pyright / Pyrefly / ty / mypy):
  - numpy: 70.9 s / 4.8 s / 30.6 s / 8.0 s
  - pandas: 144.4 s / 1.9 s / 1.5 s / 13.9 s
  - scipy: 151.3 s / 4.8 s / 2.8 s / 20.0 s
  - homeassistant: 51.3 s / 2.2 s / 2.2 s / mypy crashed

  On memory, the only figures given are for numpy: Pyright used "over 3 GB" and Pyrefly 1 GB. Pyrefly used less memory than ty on 31 of the 53 packages. The authors note that ty's numpy time is likely a bug — [Pyrefly blog](https://pyrefly.org/blog/speed-and-memory-comparison/).
- **Pyrefly v1.0 (2026-05-12), vendor.** Claims incremental editor updates are "up to 125x faster" than at beta. After an edit, PyTorch diagnostics update in 19 ms, down from 2.4 s, measured on an M4 MacBook Pro. A full PyTorch check is 34% faster than at beta. The team runs a daily benchmark of 53 packages that tracks time and peak memory — [Pyrefly v1.0 blog](https://pyrefly.org/blog/v1.0/). A search snippet also says the v1.1 post reports v1.1 as 27% faster than v1.0 on Astral's ty_benchmark suite, a CLI measure. I did not open that page — [Pyrefly v1.1 blog](https://pyrefly.org/blog/v1.1/).
- **Posit / Positron evaluation (2026-03-31), a third party that was choosing a server to bundle.** Measured in "a relatively small repository". Startup is the time to answer `initialize`; first completion is the time to answer the first `textDocument/completion`; each figure averages 5 runs. Results (startup / first completion):
  - Pyrefly: 5.8 s / 190 ms
  - ty: 2.2 s / 88 ms
  - basedpyright: 3.1 s / 112 ms
  - Zuban: N/A / 97 ms (startup "requires a multi-step manual startup")

  The study did not measure memory or navigation accuracy — [Posit](https://opensource.posit.co/blog/2026-03-31_python-type-checkers/).
- **Zuban, self-reported.** Claims to be "20–200× faster than Mypy" and to use "roughly half the memory and CPU compared to Ty and Pyrefly", with no methodology given — [Zuban docs](https://docs.zubanls.com/). It currently "runs on a single core", with multi-core support planned — [Zuban features](https://docs.zubanls.com/en/latest/features.html). Its comparison page says Pyrefly's "file based invalidation ... can make LSP usage really slow in some cases in big codebases", and that Zuban uses "substantially less memory than Pyright" — [Zuban comparison](https://docs.zubanls.com/en/latest/comparison.html). Halter also writes that Jedi's slowness was "the main reason why I decided to start building Zuban" — [Zuban comparison](https://docs.zubanls.com/en/latest/comparison.html).
- **Secondhand and community data, low confidence.** A June 2026 run by Tim Hopper (pydevtools), relayed by an aggregator, found ty about 17x, Pyrefly about 14x and Zuban about 10–12x faster than mypy on a medium codebase, all on one laptop — [Pyrastra summary](https://pyrastra.com/posts/python-type-checker-rust-revolution-ty-pyrefly-2026/). A 2026-10-14 spike on a 253-file project measured cold runs of about 119 s for mypy, 11.8 s for Zuban 0.10.1 and 0.9 s for Pyrefly 1.3.2, with false positives from both new tools. I saw this only in a search summary and did not open the issue — [GitHub issue](https://github.com/MarcusJellinghaus/mcp-tools-py/issues/247).
- **Typing-spec conformance, from one blog.** Search snippet only (March 2026): Pyright 97.8%, Zuban 96.4%, Pyrefly 87.8%, ty 53.2% — [bswen](https://docs.bswen.com/blog/2026-03-17-python-type-checker-conformance-comparison/).
- **Pyrefly's indexing cap.** The server indexes at most 2000 workspace user files by default (`--workspace-indexing-limit`, default 2000 outside Meta's internal build). The source notes that "indexing files is a performance-intensive task" — [pyrefly lsp.rs](https://github.com/facebook/pyrefly/blob/main/pyrefly/lib/commands/lsp.rs).

### Inferences
- For incremental, in-editor latency on a big repo, ty has the strongest vendor-published numbers (millisecond re-checks on PyTorch). Pyrefly says v1.0 closed most of that gap (19 ms). Pyright and basedpyright run in Node and are consistently slower and heavier on cold checks. basedpyright shares pyright's engine, so its performance is presumably close to pyright's, but I found no basedpyright-specific numbers.
- Pyrefly's 2000-file indexing cap probably means references, rename and call/type hierarchy can miss results in workspaces above that size unless the limit is raised. This is inferred from the flag description; I found no doc confirming it.
- The ty conformance figure (53.2%) is from March 2026. ty has shipped about 60 releases since then, so the figure is probably outdated.

### Gaps
- I found no independent, methodology-documented benchmark of LSP memory (RSS after indexing a large multi-file project) that covers pyright, basedpyright, ty, Pyrefly and Zuban together. Anyone who needs this should measure it on their own codebase.
- I found no current benchmarks for jedi-language-server or pylsp. The only signal is qualitative: Jedi's slowness on large projects, per Zuban's author.

## Which LSP requests each server implements (capability matrix)

### Takeaway
ty, Pyrefly and basedpyright have the broadest navigation coverage. ty and Pyrefly are the only ones that implement `typeHierarchy`, and ty, Pyrefly and Zuban are the only ones that implement `selectionRange`. Plain pyright lacks `implementation`, inlay hints, semantic tokens, folding and selection ranges; those are Pylance-only features that basedpyright partly re-implements. Zuban covers almost everything except call and type hierarchy. jedi-ls and pylsp cover only the basics. ruff server does no navigation at all.

### Cited Findings
Matrix: Y = advertised in the server's ServerCapabilities; N = not advertised; (cond) = conditional. Sources are listed under the table.

| Request | pyright 1.1.414 | basedpyright 1.40.2 | ty 0.0.90 | Pyrefly 1.4.0 | Zuban 0.10.1 | jedi-ls 0.47.0 | pylsp 1.15.0 | ruff 0.17.1 |
|---|---|---|---|---|---|---|---|---|
| definition | Y | Y | Y | Y | Y | Y | Y | N |
| declaration | Y | Y | Y | Y | Y | Y | N | N |
| typeDefinition | Y | Y | Y | Y | Y | Y | Y | N |
| implementation | N | Y (since v1.34.0) | Y (since 0.0.64) | Y | Y | N | N | N |
| references | Y | Y | Y | Y (cond: indexing on, the default) | Y | Y | Y | N |
| documentHighlight | Y | Y | Y | Y | Y | Y | Y | N |
| callHierarchy | Y | Y | Y (since 0.0.41) | Y (cond: indexing) | N ("TODO") | N | N | N |
| typeHierarchy | N | N | Y (since 0.0.20) | Y (cond: indexing) | N | N | N | N |
| documentSymbol | Y | Y | Y | Y | Y | Y | Y | N |
| workspaceSymbol | Y | Y | Y | Y | Y | Y | N | N |
| hover | Y | Y | Y | Y | Y | Y (cond: `hover.enable`) | Y | Y (noqa rule docs only) |
| signatureHelp | Y | Y | Y | Y | Y | Y | Y | N |
| inlayHint | N | Y | Y | Y | Y (cond: inlay mode not Off) | N | N | N |
| semanticTokens | N | Y (full) | Y | Y (cond: client must declare `augmentsSyntaxTokens`) | Y | Y (opt-in `semanticTokens.enable`) | N | N |
| codeLens | N | N | N | Y | N | N | Y | N |
| rename | Y | Y | Y | Y (cond: indexing) | Y | Y | Y | N |
| foldingRange | N | N | Y | Y | Y | N | Y | N |
| selectionRange | N | N | Y | Y | Y | N | N | N |

Sources and notes by column:

- **pyright**: capability block in [languageServerBase.ts](https://github.com/microsoft/pyright/blob/main/packages/pyright-internal/src/languageServerBase.ts). It has no `implementationProvider`, `inlayHintProvider`, `semanticTokensProvider`, `foldingRangeProvider`, `selectionRangeProvider`, `typeHierarchyProvider` or `codeLensProvider`.
- **basedpyright**:
  - Capability block in [languageServerBase.ts](https://github.com/DetachHead/basedpyright/blob/main/packages/pyright-internal/src/languageServerBase.ts). It adds `implementationProvider`, `inlayHintProvider` and `semanticTokensProvider` (full) on top of pyright's block.
  - Go to implementation shipped in v1.34.0 (2025-11-19, PRs #1636 and #1649) — [release notes](https://github.com/DetachHead/basedpyright/releases/tag/v1.34.0).
  - The Pylance features it re-implements are listed on [basedpyright docs](https://docs.basedpyright.com/latest/benefits-over-pyright/pylance-features/).
  - Folding range is still an open request — [issue #308](https://github.com/DetachHead/basedpyright/issues/308). So is a class-hierarchy or override view — [issue #355](https://github.com/DetachHead/basedpyright/issues/355).
- **ty**:
  - Capabilities in [crates/ty_server/src/capabilities.rs](https://github.com/astral-sh/ruff/blob/main/crates/ty_server/src/capabilities.rs).
  - The docs' feature table lists codeLens, documentColor, documentLink and `workspace/willRenameFiles` (issue #1560) as unsupported, and leaves formatting to Ruff — [ty LSP docs](https://docs.astral.sh/ty/features/language-server/).
  - When features landed: type hierarchy in 0.0.20 (2026-03-02), call hierarchy in 0.0.41 (2026-05-31), `textDocument/implementation` in 0.0.64 (2026-07-27) — [CHANGELOG](https://github.com/astral-sh/ty/blob/main/CHANGELOG.md).
- **Pyrefly**:
  - Capabilities in [pyrefly/lib/lsp/non_wasm/server.rs](https://github.com/facebook/pyrefly/blob/main/pyrefly/lib/lsp/non_wasm/server.rs). references, rename, callHierarchy and typeHierarchy are only advertised when the indexing mode is not `None`. The default mode is `LazyNonBlockingBackground` — [lsp.rs](https://github.com/facebook/pyrefly/blob/main/pyrefly/lib/commands/lsp.rs).
  - Semantic tokens are advertised only if the client declares `augmentsSyntaxTokens`, because "we currently only return partial tokens" — [server.rs](https://github.com/facebook/pyrefly/blob/main/pyrefly/lib/lsp/non_wasm/server.rs).
  - Feature status tracker — [issue #2207](https://github.com/facebook/pyrefly/issues/2207). Feature docs — [Pyrefly IDE features](https://pyrefly.org/en/docs/IDE-features/).
- **Zuban**:
  - Capabilities in [crates/zubanls/src/capabilities.rs](https://github.com/zubanls/zuban/blob/master/crates/zubanls/src/capabilities.rs). `call_hierarchy_provider: None, // TODO` and `type_hierarchy_provider: None`.
  - The docs list callHierarchy, typeHierarchy and willRenameFiles as unsupported (issue #488) and formatting as out of scope — [Zuban features](https://docs.zubanls.com/en/latest/features.html).
  - A `disable_language_services` config nulls out every navigation provider — [capabilities.rs](https://github.com/zubanls/zuban/blob/master/crates/zubanls/src/capabilities.rs).
- **jedi-language-server**:
  - `@SERVER.feature` registrations in [server.py](https://github.com/pappasam/jedi-language-server/blob/main/jedi_language_server/server.py): completion, signatureHelp, declaration, definition, typeDefinition, documentHighlight, references, documentSymbol, workspaceSymbol, rename, and codeAction (refactor inline and extract).
  - Hover is registered only if `hover.enable` is set; semantic tokens only if `semanticTokens.enable` is set. The README sample config shows `semanticTokens.enable: false` — [README](https://github.com/pappasam/jedi-language-server/blob/main/README.md).
- **pylsp**: capability dict in [pylsp/python_lsp.py](https://github.com/python-lsp/python-lsp-server/blob/develop/pylsp/python_lsp.py). It includes codeAction, codeLens, completion, formatting, range formatting, documentHighlight, documentSymbol, definition, typeDefinition, hover, references, rename, foldingRange and signatureHelp. It has no declaration, implementation, workspaceSymbol, callHierarchy, typeHierarchy, inlayHint, semanticTokens or selectionRange. Behaviour depends on plugins.
- **ruff server**:
  - Capabilities in [crates/ruff_server/src/server.rs](https://github.com/astral-sh/ruff/blob/main/crates/ruff_server/src/server.rs): codeAction, formatting, range formatting, diagnostics (pull), executeCommand, hover, and notebook sync.
  - Hover is only "the rule documentation when focusing over a NoQA code in the comment" — [Ruff editor features](https://docs.astral.sh/ruff/editors/features/).
  - The Ruff features page does not list definition, completion, references or rename — [Ruff editor features](https://docs.astral.sh/ruff/editors/features/). pydevtools describes it as lint/format-only and meant to run alongside a type-checking server — [pydevtools](https://pydevtools.com/handbook/explanation/what-is-a-python-language-server.md).

### Inferences
- ruff server answers none of definition, declaration, typeDefinition, implementation, references, documentHighlight, call or type hierarchy, documentSymbol, workspaceSymbol, signatureHelp, inlayHint, semanticTokens, rename, foldingRange or selectionRange. Its hover is irrelevant to code (noqa codes only). Navigation therefore always needs a second server.
- In Neovim 0.11, calling `vim.lsp.buf.implementation()` with only pyright attached produces an "unsupported method" warning, because `get_locations` warns when no client supports the method — [Neovim buf.lua (0.11)](https://github.com/neovim/neovim/blob/release-0.11/runtime/lua/vim/lsp/buf.lua). This is the most common reason to choose basedpyright over pyright in Neovim.
- Neovim 0.11 has client-side APIs for every row of the matrix, including `vim.lsp.buf.typehierarchy()`, `incoming_calls()`, `implementation()` and `declaration()` — [buf.lua (0.11)](https://github.com/neovim/neovim/blob/release-0.11/runtime/lua/vim/lsp/buf.lua).

### Gaps
- The matrix shows what each server advertises, not how good its results are. I found no cross-server accuracy test of references or rename on a large project.
- Capabilities were read from default-branch source on 2026-10-21. For ty and Pyrefly, main can be a few days ahead of the latest tag (ty 0.0.90 and Pyrefly 1.4.0 are both from the past week).
- pylsp plugins (pylsp-rope, python-lsp-ruff, etc.) can add capabilities through `pylsp_experimental_capabilities`. I did not survey them.

## Go to implementation, re-exports, stubs vs source, decorators/properties, dataclasses and frameworks, editable installs

### Takeaway
basedpyright is the only server with evidence (its own test suite) that go-to-implementation returns structural Protocol implementers, meaning classes that satisfy a Protocol without inheriting from it. It also has ABC tests. ty and Pyrefly return nominal subclasses and method overrides only. Zuban advertises the request but does not document what it returns. pyright, jedi-ls and pylsp lack the request entirely. For stubs, pyright, basedpyright, ty and Pyrefly all send "definition" to source (.py) when it exists and "declaration" (pyright, basedpyright, ty) or "type definition" (Pyrefly) to the stub. Pyright, basedpyright and Pyrefly all require path-based .pth editable installs; import-hook editables break navigation.

### Cited Findings
- **basedpyright go to implementation.**
  - The provider "finds all of the overrides of a symbol specified by a location within a file" — [implementationProvider.ts](https://github.com/DetachHead/basedpyright/blob/main/packages/pyright-internal/src/languageService/implementationProvider.ts).
  - The test suite includes findAllImplementations.abc, .attribute, .baseAny, .classes, .protocol and .protocolFuncCall — [repo tree](https://github.com/DetachHead/basedpyright/tree/main/packages/pyright-internal/src/tests/fourslash).
  - In the protocol test, the Protocol method `SupportsFoo.foo` resolves to `C.foo`, a non-inheriting but compatible class. `DifferentFoo.foo`, whose signature is incompatible, is excluded — [findAllImplementations.protocol.fourslash.ts](https://github.com/DetachHead/basedpyright/blob/main/packages/pyright-internal/src/tests/fourslash/findAllImplementations.protocol.fourslash.ts).
  - ty's issue tracker cites this as the reference behaviour: "basedpyright supports structural Protocol implementations ... including compatible classes that do not inherit from the Protocol while excluding incompatible implementations" — [ty#4142](https://github.com/astral-sh/ty/issues/4142).
- **ty go to implementation.** Since 0.0.64 (2026-07-27), the algorithm is:
  - Find class roots: the receiver type for attribute access, or the containing class for a method declaration.
  - For each root, collect "the method definition selected by normal MRO lookup" plus "same-named methods defined directly on known transitive subclasses" — [ruff PR #25410](https://github.com/astral-sh/ruff/pull/25410).
  - The docs describe it as "Find known implementations of a class or class member, including subclasses and method overrides" — [ty LSP docs](https://docs.astral.sh/ty/features/language-server/).
  - Issue #4142 (opened 2026-07-30, still open) says it "currently follows nominal inheritance only. A class that structurally satisfies a Protocol is omitted", and a regression test documents that limitation — [ty#4142](https://github.com/astral-sh/ty/issues/4142).
- **Pyrefly go to implementation.**
  - The docs say: "On a method, navigate to all reimplementations" — [Pyrefly IDE features](https://pyrefly.org/en/docs/IDE-features/).
  - ty#4142 says that "Pyrefly's implementation search ... only finds explicit subclasses, matching ty's current limitation", citing pyrefly 1.1.1 lsp.rs — [ty#4142](https://github.com/astral-sh/ty/issues/4142).
  - Pyrefly's tracker marks "Implement missing members (protocol, abc)" (a code action, not navigation) and "Class Hierarchy" as not done — [pyrefly#2207](https://github.com/facebook/pyrefly/issues/2207).
- **Zuban** lists `implementation` as supported but does not describe its semantics — [Zuban features](https://docs.zubanls.com/en/latest/features.html).
- **pyright** lacks go-to-implementation; basedpyright documents it as a Pylance feature that it re-implemented — [basedpyright Pylance features](https://docs.basedpyright.com/latest/benefits-over-pyright/pylance-features/).
- **Stub vs source in pyright and basedpyright.** `onDefinition` uses `DefinitionFilter.PreferSource`, and `onDeclaration` uses `DefinitionFilter.PreferStubs`, whenever the client advertises go-to-declaration capability — [pyright languageServerBase.ts](https://github.com/microsoft/pyright/blob/main/packages/pyright-internal/src/languageServerBase.ts). Neovim 0.11 advertises `textDocument.declaration` (linkSupport) — [protocol.lua (0.11)](https://github.com/neovim/neovim/blob/release-0.11/runtime/lua/vim/lsp/protocol.lua).
- **Stub vs source in ty.** History from the [CHANGELOG](https://github.com/astral-sh/ty/blob/main/CHANGELOG.md):
  - "Prefer the runtime definition, not the stub definition, on a go-to-definition request for a class or function" (alpha.16).
  - "Enable goto definition to jump to the runtime definition in the standard library ... rather than ... typeshed" (alpha.18).
  - "Follow aliases when attempting to map a definition in a stub file to its 'real' runtime definition" (around 0.0.40).

  The docs describe Go to Declaration as "the declaration site of a symbol, which can differ from its definition (could be in a stub file)" — [ty LSP docs](https://docs.astral.sh/ty/features/language-server/).
- **Stub vs source in Pyrefly.**
  - Definition: "If there is both a .pyi and .py file, we will jump to the .py".
  - Type definition goes to the .pyi.
  - Declaration "stops at imports".

  Source: [Pyrefly IDE features](https://pyrefly.org/en/docs/IDE-features/). Import resolution looks for a -stubs package first, then .pyi files or regular packages, then .py files — [Pyrefly import resolution](https://pyrefly.org/en/docs/import-resolution/).
- **Stub vs source in Zuban.** The docs mention "Correct resolution of relative, absolute, and stub-only (.pyi) imports" but say nothing about mapping stubs to source — [Zuban features](https://docs.zubanls.com/en/latest/features.html).
- **Re-exports in ty.** From the [CHANGELOG](https://github.com/astral-sh/ty/blob/main/CHANGELOG.md):
  - "Consider from thispackage import y a re-export of y in __init__.pyi" (alpha.27).
  - "Make implicit submodule imports re-exported" (alpha.28).
  - "Fix Go To-Definition for self-imported submodules" (0.0.36).
  - "Limit wildcard exports using literal __all__" (0.0.85).
  - "Return all attribute definitions for goto definition, rather than just the last definition in the given scope" (0.0.30).
- **Re-exports in Pyrefly.** The tracker marks "Completions: Import suggestions for explicit re-exports" as done — [pyrefly#2207](https://github.com/facebook/pyrefly/issues/2207).
- **Properties and decorators in ty.** Call hierarchy dispatches `@property` by access kind: a read matches the getter, a write matches the setter, and `del` matches the deleter. The PR contrasts this with Pyright, which "lumps every read/write/del under getter+setter+deleter". It also resolves aliased-import call sites, which Pyright misses — [ruff PR #25338](https://github.com/astral-sh/ruff/pull/25338). The changelog shows 35 decorator-related and 14 property-related entries through 0.0.86 — [CHANGELOG](https://github.com/astral-sh/ty/blob/main/CHANGELOG.md).
- **Framework support in ty.**
  - First-class Pydantic and Django support is part of the beta-to-stable plan — [Astral blog](https://astral.sh/blog/ty).
  - The changelog has 29 Pydantic entries from 0.0.4 to 0.0.88, e.g. "Report assignments to individually frozen Pydantic fields" (0.0.88), and 15 `dataclass_transform` entries, e.g. "Support slots_default in dataclass_transform" (0.0.85).
  - Pytest fixtures gained go-to-definition in 0.0.75 and find-references in 0.0.76.
  - I found no Django or SQLAlchemy changelog entries.

  Source: [CHANGELOG](https://github.com/astral-sh/ty/blob/main/CHANGELOG.md).
- **Framework support in Pyrefly.** Built-in Django and Pydantic support covering "model validation, field types, and autocomplete on model fields" — [Pyrefly v1.0 blog](https://pyrefly.org/blog/v1.0/).
- **Framework support in Zuban.** "Django models are supported"; "Pytest fixtures are supported"; "General plugin support is not planned; however, targeted plugins for popular libraries, such as Django and pytest". Pydantic is not mentioned — [Zuban features](https://docs.zubanls.com/en/latest/features.html).
- **Editable installs in pyright and basedpyright.** If an editable install uses import hooks, "Pyright will be unable to find the corresponding source files". Path-based .pth files fix this: setuptools compat or strict mode, uv's backend (the default), Hatchling (unless `dev-mode-exact`), and PDM (unless `editable-backend = "editables"`) — [basedpyright import resolution](https://docs.basedpyright.com/latest/usage/import-resolution/).
- **Editable installs in Pyrefly.** Same requirement for path-based .pth files: import hooks "require running Python code", so Pyrefly can't find the source — [Pyrefly import resolution](https://pyrefly.org/en/docs/import-resolution/). "Detect editable installs and auto re-analyze on changes" is still open — [pyrefly#2207](https://github.com/facebook/pyrefly/issues/2207).
- **Community anecdote** (one user, date unknown): Pyrefly's go-to-definition was "completely unusable for deeply nested classes", and the user switched to basedpyright — [V2EX](https://www.v2ex.com/t/1170555).

### Inferences
- In a codebase that leans on `typing.Protocol` for dependency inversion, basedpyright is currently the only option whose "go to implementation" from a Protocol method lands on concrete non-inheriting implementers. ty and Pyrefly give the same answer as basedpyright when the code uses explicit inheritance (ABCs, or classes that subclass the Protocol). basedpyright's ABC test suggests it handles abstract-to-concrete navigation explicitly.
- In Neovim, `gd` (definition) going to the .py source and `gD` (declaration) going to the stub is consistent across pyright, basedpyright, ty and Pyrefly. Pyrefly differs in that its "declaration" stops at the import statement, and the stub is reached through type definition.

### Gaps
- I found no documentation of how ty, Zuban, jedi-ls or pylsp follow definitions through a package's __init__.py re-export chain (whether they land on the import line or the original definition). Pyrefly's "declaration stops at imports" implies its definition follows through, but no doc states it.
- I found no server documentation on navigating through decorators (e.g. whether go-to-definition on a decorated function lands on the wrapper or the wrapped function), apart from ty's property handling in call hierarchy.
- SQLAlchemy model navigation and Django support in pyright, basedpyright and ty are not documented in the sources I read. Pyright-family servers are generally said to rely on PEP 681 `dataclass_transform`, which Pydantic and SQLAlchemy 2.x use, and on django-stubs, but I did not verify that in this session.
- ty's handling of editable installs (.pth vs import hooks) is not covered on its modules page.

## Type inference differences that affect navigation; untyped codebases

### Takeaway
Navigation on attribute access (`obj.method` going to the right class) depends on the inferred receiver type, so inference policy matters more than raw speed. By default, pyright and basedpyright infer return types and do call-site return-type inference for fully unannotated functions. Pyrefly infers return types (`infer-return-types = "checked"`) and infers empty-container element types from their first use. ty follows the "gradual guarantee": unannotated parameters and, by default, unannotated returns are `Unknown`, and opt-in return-type inference only arrived in 0.0.89 (2026-10-16). Zuban's default mode infers return types and checks untyped functions. Jedi does no static type checking and infers dynamically.

### Cited Findings
- **pyright.** It infers unannotated return types as the union of all `return` statements. When all parameters are unannotated it re-infers the return type at each call site ("call-site return type inference"), with a small recursion limit. Unannotated parameters take their type from a same-named base-class method or from default values, otherwise `Unknown`. `[]` infers as `list[Unknown]` unless another path assigns a non-empty list — [pyright type-inference.md](https://github.com/microsoft/pyright/blob/main/docs/type-inference.md).
- **ty.**
  - Follows "the gradual guarantee, which holds that adding or removing annotations on working code should never introduce new errors". "Where a concrete type is missing, ty infers Unknown", including for unannotated returns and parameters — [pydevtools untyped-code explainer](https://pydevtools.com/handbook/explanation/how-mypy-ty-and-pyrefly-handle-untyped-code.md) (undated).
  - ty 0.0.89 (2026-10-16): "Added support for return type inference for unannotated functions and methods ... currently disabled by default. Enable it with the `analysis.return-type-inference` setting" — [CHANGELOG](https://github.com/astral-sh/ty/blob/main/CHANGELOG.md).
  - Posit observed ty "stayed silent on an unannotated append("foo") call that Pyrefly flagged" — [Posit](https://opensource.posit.co/blog/2026-03-31_python-type-checkers/).
  - Recent changes that affect subclass navigation: "Inherit annotations for unannotated subclass defaults" (0.0.85) and "Preserve inherited annotations for unannotated subclass attributes when a base has type Any or Unknown" (0.0.88) — [CHANGELOG](https://github.com/astral-sh/ty/blob/main/CHANGELOG.md).
- **Pyrefly.**
  - `infer-return-types` (default `"checked"`) controls whether an analyzed function's return "propagates a real type or Any". An unannotated parameter is `Unknown`. `infer-with-first-use` (default `true`) makes `[]` take its element type from later use. With no config file, the `basic` preset skips unannotated bodies — [pydevtools untyped-code explainer](https://pydevtools.com/handbook/explanation/how-mypy-ty-and-pyrefly-handle-untyped-code.md).
  - The Pyrefly team (2026-02-25) describes first-use container inference as its default ("same as mypy") and says Pyright and ty infer `Any` element types — [Pyrefly container inference blog](https://pyrefly.org/blog/container-inference-comparison/).
  - `pyrefly infer` can write draft annotations into an untyped codebase — [Pyrefly v1.0 blog](https://pyrefly.org/blog/v1.0/).
  - Posit chose Pyrefly partly for "inference that catches bugs without full annotation" — [Posit](https://opensource.posit.co/blog/2026-03-31_python-type-checkers/).
- **Zuban.** Default mode sets `check_untyped_defs = true` and `untyped_function_return_mode = "inferred"` (mypy's default is `"any"`), and enables `untyped_strict_optional`. Mypy-compatible mode instead "behaves just like Mypy". The language server picks the mode from config: `[tool.zuban]` means default mode, `[tool.mypy]` or mypy.ini means mypy mode — [Zuban usage](https://docs.zubanls.com/en/latest/usage.html). Zuban's author criticises Pyright, which "assigns Any in cases of circular references, which can silently result in untyped code" — [Zuban comparison](https://docs.zubanls.com/en/latest/comparison.html).
- **Jedi.** "Unlike the other tools listed, it does not perform static type checking" — [Zuban comparison](https://docs.zubanls.com/en/latest/comparison.html).

### Inferences
- In a largely unannotated codebase, `obj = make_thing(); obj.method()` will probably resolve go-to-definition and hover better on pyright or basedpyright (call-site return inference) and on Pyrefly (return inference on by default) than on ty with default settings, where `make_thing()` returns `Unknown` and there is nothing to navigate from. ty users with untyped code should test `analysis.return-type-inference = true` (0.0.89+), though it is new and labelled experimental-feedback.
- If a mypy config is present, Zuban will auto-select mypy mode. Mypy mode does not infer returns of untyped functions by default (`"any"`), so navigation through untyped code may be weaker in that mode.

### Gaps
- I found no direct measurement of navigation success rate (e.g. the percentage of go-to-definition requests on attribute accesses that resolve) on untyped code for any server.
- The pydevtools untyped-code explainer is undated. Its ty description predates the 0.0.89 opt-in return inference.

## Environment detection and monorepo/workspace support

### Takeaway
ty and Pyrefly auto-detect the most: an active venv or conda environment, then a project .venv, then `python` on PATH. ty also has uv workspace discovery and multi-root support in a single server. basedpyright auto-detects .venv, which pyright does not document, and supports pyright's `executionEnvironments` and `extraPaths` with glob support. Pyrefly resolves a config per file, which suits monorepos. Zuban documents only an explicit `pythonExecutable` and `mypy_path`/`PYTHONPATH`. In Neovim, the simplest reliable approach for all of them is to start nvim with the project venv activated, or to set the interpreter explicitly.

### Cited Findings
- **ty environment discovery.** Explicit `environment.python` or `--python` wins. Otherwise ty checks, in order:
  1. `VIRTUAL_ENV`
  2. an active non-base conda environment
  3. .venv in the project root
  4. an active base conda environment
  5. python3 or python on PATH

  `uv run` activates the venv, so ty detects it. First-party search paths are the project root plus ./src, ./<project-name> (if ./<project-name>/<project-name> exists) and ./python, when those are not packages themselves. `environment.root` overrides this. `PYTHONPATH` entries go after `extra-paths` and before site-packages — [ty modules docs](https://docs.astral.sh/ty/modules/).
- **ty monorepo and uv support.** From the [CHANGELOG](https://github.com/astral-sh/ty/blob/main/CHANGELOG.md):
  - "Support multiple workspace folders in a single ty LSP server instance" (0.0.15, 2026-02-04).
  - "Discover uv workspace roots" (0.0.64).
  - "Refresh uv workspace metadata when dependencies change" (0.0.78).
  - "Select projects for external files using import search paths" (0.0.84).
  - "Refresh Python settings when virtual environments change" (0.0.85).

  The init option `experimental.useUv` (`"off"`, `"scripts"`, `"on"`; requires uv 0.12.3 or later) enables an experimental uv integration — [ty editor settings](https://docs.astral.sh/ty/reference/editor-settings/).
- **Pyrefly environment discovery.** "Environment Autoconfiguration" checks, in order:
  1. CLI flags.
  2. An active venv or conda environment (venv wins over conda).
  3. Config-file settings: `python-interpreter-path`, `python-interpreter-find-command`, `fallback-python-interpreter-name` or `conda-environment`.
  4. A pyvenv.cfg in .venv, venv or env, searched from the project root and then up through ancestor directories.
  5. `which python3` and `which python`.

  Config discovery walks upward looking for pyrefly.toml, pyproject.toml, setup.py, mypy.ini and similar files. In an unconfigured project, `[tool.mypy]` and `[tool.pyright]` sections are migrated in memory. `sub-config` entries with `matches` globs allow per-path overrides. The language server "finds a configuration separately for each source file because one session can serve multiple projects" — [Pyrefly configuration](https://pyrefly.org/en/docs/configuration/).
- **Pyrefly in Neovim.** "Pyrefly will only work within Neovim if the virtual environment is activated when you start Neovim." In VS Code, only the primary folder of a multi-root workspace is used — [Pyrefly IDE docs](https://pyrefly.org/en/docs/IDE/).
- **basedpyright and pyright environment discovery.** Interpreter priority:
  1. `venvPath` plus `venv` (discouraged).
  2. `python.pythonPath`.
  3. Automatic .venv at the project root, documented as a basedpyright improvement.
  4. `python` on PATH.

  Workspace code resolution goes: execution environment root, then its `extraPaths`, then the local src directory if no execution environment is configured. Each execution environment has its own root and `extraPaths`; an execution environment's `extraPaths` overrides the default list rather than merging. `extraPaths` support globs, e.g. `libs/*/src` — [basedpyright import resolution](https://docs.basedpyright.com/latest/usage/import-resolution/). basedpyright v1.28.5 (2025-04-09) added "Allow .venv autodetection when config file missing" — [release notes](https://github.com/DetachHead/basedpyright/releases/tag/v1.28.5).
- **pyright and basedpyright in nvim-lspconfig.** Both configs set root markers (pyrightconfig.json, pyproject.toml, setup.py, setup.cfg, requirements.txt, Pipfile, .git). Both add a `:LspPyrightSetPythonPath` command that pushes `python.pythonPath` through `workspace/didChangeConfiguration` — [lsp/pyright.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/pyright.lua); [lsp/basedpyright.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/basedpyright.lua).
- **Zuban environment discovery.** The only documented interpreter setting is the `pythonExecutable` LSP option. Zuban "tries to find the best possible path itself", and it can be overridden with `mypy_path` in `[tool.zuban]` or with `PYTHONPATH`/`MYPYPATH`. The docs do not mention `VIRTUAL_ENV` or .venv detection — [Zuban usage](https://docs.zubanls.com/en/latest/usage.html). Posit found Zuban's "analysis is tied to one Python installation and applies only to saved files", and that third-party completions "require stubs rather than installed packages" (as of March 2026) — [Posit](https://opensource.posit.co/blog/2026-03-31_python-type-checkers/).
- **jedi-language-server.** Init options include `workspace.environmentPath` (path to the venv's python), `workspace.extraPaths`, `workspace.symbols.ignoreFolders` (default list includes .venv and venv) and `workspace.symbols.maxSymbols` (default 20). maxSymbols is a hard cap on workspace-symbol results — [README](https://github.com/pappasam/jedi-language-server/blob/main/README.md).

### Inferences
- For uv users in Neovim, ty has the most hands-off setup (VIRTUAL_ENV or .venv detection plus uv workspace root discovery). basedpyright works out of the box if the venv is at ./.venv. Pyright needs `venvPath`/`venv` or `pythonPath`, or nvim started inside the activated venv.
- For a monorepo with several sub-projects, each with its own pyproject or config, Pyrefly's per-file config resolution and ty's multi-project handling map naturally onto one server per Neovim root. With pyright or basedpyright you would hand-write `executionEnvironments` in a single root config. Neovim's `root_markers` (pyproject.toml before .git) will usually root each sub-project separately, which spawns one client per sub-project unless `root_dir` is customised. That last point is Neovim behaviour I am inferring, not something I verified in this session.

### Gaps
- I did not find documentation of how ty handles poetry (non-.venv in-project venvs) or pyenv-only setups beyond "python on PATH".
- I did not research pylsp environment configuration (handled by its Jedi plugin settings).
- Zuban's monorepo and multi-root behaviour is undocumented.

## Neovim integration (nvim-lspconfig, mason.nvim, Neovim-specific issues)

### Takeaway
All eight servers have an nvim-lspconfig `lsp/<name>.lua` config, under the requested names pyright, basedpyright, ty, pyrefly, zuban, jedi_language_server, pylsp and ruff. All eight are installable through mason.nvim. Every config uses the 0.11 `vim.lsp.config`/`vim.lsp.enable` style. Neovim 0.11 merges and concatenates results from multiple clients, which is the main source of friction when running two servers.

### Cited Findings
- **nvim-lspconfig configs.** All eight exist on master as of commit 77b7432 (2026-10-20). A pylyzer config also exists. The `cmd` for each:
  - pyright: `{'pyright-langserver','--stdio'}`
  - basedpyright: `{'basedpyright-langserver','--stdio'}`
  - ty: `{'ty','server'}`
  - pyrefly: `{'pyrefly','lsp'}`
  - zuban: `{'zuban','server'}`
  - jedi_language_server: `{'jedi-language-server'}`
  - pylsp: `{'pylsp'}`
  - ruff: `{'ruff','server'}`

  Sources: [lsp/ty.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/ty.lua); [lsp/pyrefly.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/pyrefly.lua); [lsp/zuban.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/zuban.lua); [lsp/basedpyright.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/basedpyright.lua); [lsp/pyright.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/pyright.lua); [lsp/ruff.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/ruff.lua); [lsp/jedi_language_server.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/jedi_language_server.lua); [lsp/pylsp.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/pylsp.lua).
- **Defaults in the lspconfig configs.**
  - ty root markers: ty.toml, pyproject.toml, setup.py, setup.cfg, requirements.txt, .git.
  - pyrefly root markers: pyrefly.toml first, then pyproject.toml and the rest. The config adds an `on_exit` notification, and its brief still says Pyrefly "is still in development".
  - basedpyright defaults to `diagnosticMode = 'openFilesOnly'`, `autoSearchPaths = true` and `disableTaggedHints = true`. It adds `:LspPyrightOrganizeImports` and `:LspPyrightSetPythonPath`.
  - pyright also sets `disableTaggedHints = true`. The comment explains that pyright's unreachable, unreferenced and deprecated hint diagnostics "are usually too noisy (neovim/neovim#30444)" in Neovim.

  Sources: [lsp/pyright.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/pyright.lua); [lsp/basedpyright.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/basedpyright.lua); [lsp/pyrefly.lua](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/pyrefly.lua).
- **mason-registry** (each package maps to the lspconfig name in parentheses):
  - pyright 1.1.414 (npm) → `pyright`
  - basedpyright 1.40.2 (PyPI) → `basedpyright`
  - ty 0.0.90 (PyPI) → `ty`
  - pyrefly 1.4.0 (PyPI) → `pyrefly`
  - zuban 0.10.1 (PyPI) → `zuban`
  - jedi-language-server 0.47.0 (PyPI) → `jedi_language_server`
  - python-lsp-server 1.15.0 (PyPI, `extra=all`) → `pylsp`
  - ruff 0.17.1 (GitHub binary) → `ruff`

  Sources: [mason-registry packages](https://github.com/mason-org/mason-registry/tree/main/packages), e.g. [ty](https://github.com/mason-org/mason-registry/blob/main/packages/ty/package.yaml) and [pyrefly](https://github.com/mason-org/mason-registry/blob/main/packages/pyrefly/package.yaml).
- **Server-specific Neovim notes.**
  - Pyrefly: "native Neovim support through lspconfig on Neovim 0.11+"; "Installing a binary with Mason will take precedence over other system installations"; the venv must be activated before starting Neovim — [Pyrefly IDE docs](https://pyrefly.org/en/docs/IDE/).
  - Pyrefly semantic tokens need the client to declare `augmentsSyntaxTokens` — [server.rs](https://github.com/facebook/pyrefly/blob/main/pyrefly/lib/lsp/non_wasm/server.rs). Neovim 0.11 declares `augmentsSyntaxTokens = true` — [protocol.lua (0.11)](https://github.com/neovim/neovim/blob/release-0.11/runtime/lua/vim/lsp/protocol.lua).
  - ty's docs recommend nvim-lspconfig with `vim.lsp.enable('ty')` on 0.11+. This comes from a search summary of [ty editors docs](https://docs.astral.sh/ty/editors/). ty's implementation PR was "E2E [tested] in VSCode and Neovim" — [ruff PR #25410](https://github.com/astral-sh/ruff/pull/25410).
- **Neovim 0.11 multi-client behaviour.** All from [runtime/lua/vim/lsp/buf.lua (release-0.11)](https://github.com/neovim/neovim/blob/release-0.11/runtime/lua/vim/lsp/buf.lua):
  - Location requests (definition, declaration, type definition, implementation) go to every attached client that supports the method, and all results are concatenated. If there is exactly one item, Neovim jumps; otherwise it opens a quickfix or location list.
  - `hover()` concatenates the results of all clients under a `# <client name>` header when more than one client answers.
  - `rename()` runs prepareRename and rename on each rename-capable client in turn: after one client's rename handler completes, it calls `try_use_client(next(clients, idx))`. `vim.lsp.buf.rename` takes `filter` and `name` options to restrict which clients are used.

### Inferences
- With two navigation-capable servers attached, such as basedpyright and ty, `gd` will almost always produce a two-entry quickfix list (the same location, once from each server) instead of jumping directly. Hover will show two stacked blocks. Rename may run twice, giving a second prompt or a second set of edits. A two-server setup therefore needs per-capability disabling on one side (see the next section).
- This repo's own config uses a single `servers` table plus one `LspAttach` autocmd (per CLAUDE.md). That is the natural place for a name-based capability strip, e.g. `if client.name == 'ruff' then client.server_capabilities.hoverProvider = false end`.

### Gaps
- I did not verify whether the Neovim releases in use (0.11.x or 0.12) changed the multi-client concatenation or rename iteration. Neovim master's protocol.lua adds a `typeHierarchy` client-capability block that release-0.11 lacks, so behaviour differs across versions.
- I found no Neovim-specific bug reports for ty, Zuban or basedpyright beyond the tagged-hints noise. I did not search the issue trackers exhaustively.

## Practical combinations (2025–2026) and pitfalls of running two servers

### Takeaway
The consensus pattern is one type-aware server plus ruff server for lint, format and organize-imports, with ruff's hover turned off. The 2026 choices for the type-aware server are:
- **basedpyright**: mature, best Protocol-aware go-to-implementation, but no type hierarchy, folding or selection range.
- **ty**: fastest incremental updates and the widest LSP surface, but beta with weaker inference of untyped code by default.
- **Pyrefly**: stable 1.x, aggressive inference, built-in Django/Pydantic support, but nominal-only implementations and a 2000-file indexing cap.

Running two type-aware servers (e.g. ty for navigation and basedpyright for diagnostics) works, but only if each one is made to answer a disjoint set of capabilities. ty and Pyrefly both ship explicit switches for this. pyright and basedpyright do not, so you strip capabilities client-side.

### Cited Findings
- **Most-cited setup.** "Most Python setups run two servers at once: one for types and one for lint and format", i.e. pyright, basedpyright or ty plus `ruff server`. For open-source stacks pydevtools suggests "Basedpyright plus ruff server" — [pydevtools](https://pydevtools.com/handbook/explanation/what-is-a-python-language-server.md).
- **Ruff's official Neovim guidance.** When running alongside Pyright, disable Ruff's hover in an `LspAttach` autocmd with `client.server_capabilities.hoverProvider = false`. To make Ruff the sole linter and import organizer, set pyright's `disableOrganizeImports = true` and `python.analysis.ignore = { '*' }` — [Ruff editor setup](https://docs.astral.sh/ruff/editors/setup/).
- **ty's switches for side-by-side use** — [ty editor settings](https://docs.astral.sh/ty/reference/editor-settings/):
  - `disableLanguageServices` (default false) is for when "you want to use ty exclusively for type checking and want to use another language server".
  - `diagnosticMode = "off"` keeps completion, hover and definition but disables diagnostics; it was added in 0.0.6 — [CHANGELOG](https://github.com/astral-sh/ty/blob/main/CHANGELOG.md).
  - `showSyntaxErrors = false` avoids duplicate syntax errors.
- **Pyrefly's switches** — [Pyrefly IDE docs](https://pyrefly.org/en/docs/IDE/):
  - `disableLanguageServices`: "Pyrefly will not provide IDE services like completions, hover, definition".
  - `disableTypeErrors`: a "Workspace kill switch for Pyrefly type-error diagnostics".
  - For other editors, Pyrefly advises: "To avoid conflicts, you should disable other Python language servers".
- **Zuban's switch.** Zuban has a `disable_language_services` config that nulls out all navigation providers, leaving diagnostics — [capabilities.rs](https://github.com/zubanls/zuban/blob/master/crates/zubanls/src/capabilities.rs). Its user-facing setting name is not documented in the pages I read.
- **Posit's March 2026 assessment.** Pyrefly had the best hover docs. ty was "fast and clean". basedpyright "surfaces many warnings by default". Zuban was least mature, and a rename once broke stdlib code. Positron chose Pyrefly but said it was "not a runaway winner" — [Posit](https://opensource.posit.co/blog/2026-03-31_python-type-checkers/).
- **Zuban author's view of ty** (opinion, from a competitor): "I would personally not recommend using Ty until they pass big parts of the conformance tests" — [Zuban comparison](https://docs.zubanls.com/en/latest/comparison.html).
- **Community setup guide** (aggregator, opinion): priority basedpyright, then pyright, then ty ("experimental"). Pair with ruff, but keep a type server enabled because ruff does not type-check — [search summary of community setup guide](https://cdn.jsdelivr.net/npm/oh-my-opencode@4.18.2/dist/skills/lsp-setup/references/python/README.md).
- **Two servers in Neovim 0.11.** Definition results from all clients are merged, and more than one item opens a list instead of jumping. Hover is concatenated per client. Rename iterates every rename-capable client — [buf.lua (0.11)](https://github.com/neovim/neovim/blob/release-0.11/runtime/lua/vim/lsp/buf.lua).

### Inferences
These are synthesis for the config decision, not sourced recommendations.
- **Lowest-friction default:** basedpyright plus ruff, with ruff's `hoverProvider` disabled. It is stable, has Protocol-aware `implementation`, and lspconfig ships sane Neovim defaults (openFilesOnly, tagged hints off). Its missing typeHierarchy, foldingRange and selectionRange are minor in Neovim, where treesitter provides folding and incremental selection.
- **Speed and navigation-breadth option:** ty plus ruff (both from Astral, one toolchain with uv). It has typeHierarchy and callHierarchy and the best incremental latency. The costs are beta churn, nominal-only implementations, and `Unknown` returns in untyped code unless `analysis.return-type-inference` is enabled.
- **Two type-aware servers** only make sense when one covers what the other lacks. Example: ty for navigation and hierarchy (`diagnosticMode = "off"`) plus basedpyright for diagnostics and Protocol implementations, with these client-side strips on basedpyright in `LspAttach`:
  - `definitionProvider`, `declarationProvider`, `typeDefinitionProvider`, `referencesProvider`, `hoverProvider`, `renameProvider`, `documentHighlightProvider`, `inlayHintProvider` and `semanticTokensProvider` set to false or nil.
  - Keep its `implementationProvider`, or route only `vim.lsp.buf.implementation` to it with `on_list` or a client filter.

  This doubles memory use and indexing work. I found no community write-up that documents this exact split, so treat it as untested.
- **Pyrefly plus ruff** is the pick for Django/Pydantic-heavy or largely untyped code. Raise the indexing limit on monorepos with more than 2000 files, since references, rename and hierarchy depend on indexing.
- **Avoid for new setups:** jedi-language-server (maintenance mode, no implementation, hierarchy or inlay hints, 20-symbol workspace cap by default) and pylsp (plugin host with the same navigation gaps). Zuban is promising for mypy-compatible shops, but it lacks call and type hierarchy, has AGPL licensing, and Posit rated it immature in March 2026.

### Gaps
- I found no first-party or well-documented community write-up from 2025–2026 that recommends a specific two-type-server split (e.g. "pyrefly for navigation + pyright for diagnostics") and reports how it went in Neovim. The "community recommendations" above are thin: one handbook, one aggregator guide, one V2EX anecdote and one vendor (Posit).
- I did not verify whether basedpyright can turn off diagnostics entirely while keeping navigation, other than with Ruff's suggested `python.analysis.ignore = {'*'}` for pyright. Whether `ignore` also degrades navigation into the ignored files is not documented in the sources I read.
