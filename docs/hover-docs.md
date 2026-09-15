# Documentation in the `K` hover

In C, C++ and Python buffers, `K` shows the language server's hover and, when
that hover carries no documentation, appends a short excerpt from an offline
DevDocs bundle to the same float. This document covers why the servers leave
that gap, how the excerpt is found and cut, and what was tried and rejected.

## The gap

`K` on `realloc` in a C buffer used to show clangd's signature, return type and
parameters, and nothing about what the function does. The same gap shows up in
two more places. Each case below was checked against the real servers on
2026-09-15:

| Buffer | Symbol | What the server's hover carries |
| ------ | ------ | ------------------------------- |
| C, clangd | `realloc`, `memcpy` | Signature only. The macOS SDK headers have no doc comments, and the fortified `memcpy` hovers as a macro expansion. |
| C++, clangd + libc++ | `std::vector::push_back`, `std::to_string` | Signature only. libc++ headers have no doc comments either. |
| Python, pyright | `len`, `print`, `str.split` | Signature only. typeshed stubs have no docstrings, and C-implemented builtins have no `.py` source for pyright to fall back on. |
| Python, pyright | `os.path.join` | **Has** a docstring, because pyright reads it from `posixpath.py`. |
| Go, Rust, TS, Lua, Zig | anything | Already has doc comments, so these filetypes keep core's `K`. |

The text does exist: cppreference, the POSIX and Linux man pages, and the Python
library reference. DevDocs publishes all three as offline bundles.

## Who does what

| Module | Responsibility |
| ------ | -------------- |
| `lua/config/docs/hover.lua` | The `K` driver. Sends the hover request, checks whether the server already said enough, asks the provider for names, and opens **one** float. Also answers `gK`'s DevDocs URL step. |
| `lua/config/docs/brief/c.lua` | Names a C/C++ symbol through clangd's `textDocument/symbolInfo`. Never reads a bundle. |
| `lua/config/docs/brief/python.lua` | Names a Python symbol through pyright's `textDocument/declaration`. Never reads a bundle. |
| `lua/config/docs/devdocs.lua` | The on-disk store: index lookup, page excerpts, HTML→markdown, `:DocsInstall`. |
| `lua/config/docs/devdocs_split.lua` | Splits a downloaded `db.json` into one file per page, run as its own `nvim --clean -l` process. |
| `lua/plugins/lsp.lua` | Maps `K` in `LspAttach`, only when the buffer's filetype has a provider. |
| `lua/config/docs/init.lua` | Registers `:DocsInstall`, and adds the DevDocs step to `gK`'s URL cascade. |

A provider only **names** the symbol, as an ordered list of `{ slug, name, hint }`
candidates. Every rule about which name to try, and in what order, lives in one
file per language, and nothing about page markup leaks into those files.

## What happens on `K`

1. The driver records the buffer, window, cursor and `changedtick`, builds
   position params once per client, and sends `textDocument/hover` through
   `buf_request_all`. Results are filtered the way core filters them: errors
   are logged, empty contents are dropped, and "No information available" /
   "Empty hover response" are reported as core reports them.
2. **Prose check.** The result from the provider's own server (`clangd` or
   `pyright`) is checked for documentation. If it has some, the hover opens
   unchanged.
3. Otherwise the provider returns candidates. The first candidate whose bundle
   is installed and whose name the index knows becomes the excerpt. A candidate
   whose bundle is **not** installed is remembered, and if nothing installed
   answers, the float says `No docs installed — :DocsInstall <slugs>`.
4. The float is composed as the hover, a `---` rule, an italic label
   (`cppreference · std::vector::push_back`, `man · read(3p)`,
   `python 3.10 · len()`), the excerpt, and `gK: full page` when the excerpt
   was cut. It opens through `vim.lsp.util.open_floating_preview` with
   `focus_id = "textDocument/hover"`, so a second `K` focuses it exactly as
   core's does. The hovered range is highlighted until the float closes, as in
   core.
5. If the buffer, window, cursor or `changedtick` changed while waiting, nothing
   opens.
6. **Deadline.** If the excerpt takes longer than `DEADLINE_MS` (1500 ms), the
   hover opens without it. The late excerpt still lands in the cache, so the
   next press has it.

Everything on the excerpt side runs under `pcall`. An exception warns once per
session (`docs: hover excerpt failed: …`) and the hover opens alone, so `K`
never shows less than core's hover.

### The prose check

`_has_prose` removes the lines a server's template always produces, and reports
documentation if any non-blank line survives outside code fences.

- **clangd:** `### kind`, `provided by`, `→ type`, `Parameters:`,
  `Template parameters:`, `- item`, `Type:`, `Value =`, `Size:`, `Offset:`,
  `Padding:`, `Passed`, and `---`.
- **pyright:** only code fences and `---`.

**Any other server counts as having prose.** A template change or an unknown
server therefore degrades to today's hover, never to docs bolted onto a hover
that already had some.

## Naming the symbol

### C and C++ (`brief/c.lua`)

clangd's `symbolInfo` is a clangd extension, and it carries exactly what is
needed: the name, the qualified container (`std::vector::`, already without
libc++'s inline `__1`), and the declaration's location.

- **Ordering.** The entry whose name equals the word under the cursor goes
  first. The fortified `memcpy` answers as `__builtin___memcpy_chk` *and* the
  `memcpy` macro, builtin first. `__`-prefixed names are implementation
  internals and are skipped.
- **Project gate.** If any entry is declared under the buffer's git root (or
  the buffer's directory outside a repo), there are no candidates. A kilo-style
  `abAppend`, or a project function that happens to be called `open`, never
  gets library text.
- **C lookup order:** `{c, name}`, then `{man, "name (3p)"}`, `{man, "name (2)"}`,
  `{man, "name (3)"}`. The `c` bundle is ISO C only, so `read`, `write`,
  `tcsetattr` and `ioctl` come from the man bundle. There the POSIX `3p` page
  wins, because on a Mac the standard's wording is closer to the truth than
  Linux's.
- **C++:** a `std::` container gives `{cpp, container .. name}`. An empty
  container (a C function called unqualified) tries `{cpp, "std::" .. name}`
  and then the C order. Any other namespace (`fmt::`) gets nothing.
- **Disambiguation.** Some names have several pages; `std::to_string` has one
  under `string/basic_string` and two under `utility/` for `<stacktrace>`. The
  candidate carries the declaring header's basename as `hint` (`vector.h` gives
  `vector`, `<string>` gives `string`), and `devdocs.pick` prefers the entry
  whose path has that segment.

### Python (`brief/python.lua`)

- **Gate.** pyright's declaration must land in a `.pyi` under a
  `/typeshed…/stdlib/` directory. Third-party packages ship real source, which
  pyright already reads docstrings from.
- **Module** comes from the path after `stdlib/`: `os/path.pyi` gives `os.path`,
  `json/__init__.pyi` gives `json`.
- **Qualified name** comes from an upward indentation scan of the stub from the
  declaration line. The first line above at a smaller indent is the enclosing
  block: a `class` names a scope, while an `if sys.version_info` only moves the
  threshold. Stubs carry no docstrings or multi-line strings, which is what
  makes the scan exact, and it needs no `python` treesitter parser.
- **Names**, each tried with `()` and then bare (DevDocs spells callables
  `len()` and attributes `sys.maxsize`):
  1. stub-derived: `str.split` for `builtins`, otherwise `<module>.<qualname>`
  2. the dotted word under the cursor, which covers typeshed declaring `os.path`
     in `posixpath.pyi`
- **Bundle.** The project interpreter (the same one the `gK` Python adapter
  resolves, via its `_interpreter`) is asked its version once per session.
  `python~X.Y` is used if installed. Otherwise the nearest installed
  `python~*` is used, the newer on a tie, with its version showing in the
  label. Otherwise the exact slug is used, so the install hint names the
  version the project runs.

## The store

```
<stdpath("data")>/devdocs/<slug>/index.json   { entries = { {name, path, type} } }
<stdpath("data")>/devdocs/<slug>/pages/<path>.html
<stdpath("data")>/devdocs/<slug>/meta.json    { slug, installed_at }
```

Each slug's index is decoded once per session into name → entries. Excerpts are
memoized per page and line cap, including misses.

### `:DocsInstall`

`:DocsInstall c cpp man python~3.12` installs bundles; with no argument it lists
what is installed and when. It completes `c`, `cpp`, `man` and
`python~3.8`…`python~3.14`, and accepts any slug that is one safe path segment.

An install:

1. Stages into `<slug>.tmp`.
2. Downloads `index.json` and `db.json` from `documents.devdocs.io` with
   `curl -fsSL --retry 3 --retry-all-errors`. A GET there stalled once with zero
   bytes and succeeded on a retry.
3. Splits `db.json` in `nvim --clean -l devdocs_split.lua`. Decoding the man
   bundle's 143 MB in the editor would freeze it. The script checks **every**
   page path before writing any: an absolute path, `..`, `.` or a backslash
   fails the whole install, because the paths came off the network.
4. Writes `meta.json`, deletes `db.json`, moves any previous bundle aside to
   `<slug>.old`, renames `.tmp` into place, and deletes `.old`.

On any failure the tmp dir is removed, the previous bundle is untouched, and the
error names the step (curl or split stderr, without the Lua traceback).

Sizes seen on 2026-09-15:

| Slug | db.json | On disk |
| ---- | ------- | ------- |
| `c` | 5 MB | 6 MB |
| `cpp` | 45 MB | 52 MB (5,658 pages) |
| `man` | 143 MB | — |
| `python~3.10` | 16 MB | — |

Nothing refreshes a bundle automatically; re-running `:DocsInstall` does.

## Cutting an excerpt

`_blocks` converts HTML into paragraphs, headings and code blocks, for exactly
the markup these three families use:

| HTML | Markdown |
| ---- | -------- |
| `<p>`, `<div>`, `<tr>`, `<dl>`/`<dt>`/`<dd>`, `<li>` | paragraph boundaries |
| `<code>` | backticks, with adjacent runs merged (`reserve(size() + 1)` is five `<code>` runs) |
| `<b>`, `<i>` | emphasis, but never inside a code span |
| `<pre data-language>` | a dedented fence |
| `<span class="t-li">` | cppreference's inline `1)` markers, each starting a paragraph |
| adjacent `<span class="kt">` | a space restored between them (DevDocs' highlighter emits `unsigned char` as two spans with no space) |
| entities | named and numeric, decoded |

Anything else is reduced to its text. `_render` wraps paragraphs at 80 columns,
because the float sizes itself to its longest line. It caps the excerpt at
`MAX_LINES` (25) at a block boundary, hard-cutting only a first block that is
longer than the cap (and closing its fence), and never ends on a heading with
nothing under it.

**cppreference** (`c`, `cpp`):
- The `t-dcl-begin` declaration table goes; the hover already shows the
  signature, and the table also carries "Defined in header".
- Parameter rows become `` `name` — description ``.
- The excerpt is the lead before the first `<h3>`, then the `Parameters` and
  `Return value` sections. Complexity, Exceptions, Notes, Example and See also
  are page material.

**Sphinx** (`python~X.Y`): the entry path carries an anchor
(`library/stdtypes#str.split`). The excerpt is the `<dd>` after `<dt id="anchor">`,
matched for balance, because a class's `<dd>` contains the `<dl>` of every one
of its methods.

**man** (`man`):
- Sections are `<h2>` + `<pre>`. The body indent is the most common indent;
  lines left of it are subsection titles, and paragraphs right of it are code.
  The two sources disagree: Linux pages indent the body by 7 with titles at 3,
  and POSIX pages have no subsections.
- A man page often documents a family; malloc(3) holds malloc, free, calloc,
  realloc and reallocarray. The excerpt is the NAME line, then the DESCRIPTION
  subsection titled `name()` (otherwise the paragraphs that mention `name()`,
  otherwise all of it), then RETURN VALUE narrowed the same way. PROLOG is
  skipped.

## `gK`

`gK`'s URL cascade in `docs/init.lua` has a step after the adapter URL and
before `documentLink`: `hover.docs_url` asks the buffer's provider for
candidates and opens the first installed hit's hosted page.

| Slug | URL |
| ---- | --- |
| `cpp` | `https://en.cppreference.com/w/cpp/<path>` |
| `c` | `https://en.cppreference.com/w/c/<path>` |
| `man` | `https://man7.org/linux/man-pages/<path>.html` |
| `python~X.Y` | `https://docs.python.org/X.Y/<page>.html#<anchor>` |

This is what finally gives C++ a real link. The C adapter's long-standing
objection was that cppreference paths carry an editorial category segment
(`std::sort` lives under `algorithm/`) that only a hand-maintained table could
produce. DevDocs' index is that table, maintained upstream. It lives in the
cascade rather than in the adapter's `url` because naming the symbol needs a
warm clangd (`std::vector::push_back`, not the `v.push_back` under the cursor),
and `url` is a synchronous function over a coordinate.

## Testing

| Spec | Lane | Covers |
| ---- | ---- | ------ |
| `tests/spec/unit/devdocs_spec.lua` | `make test-unit` | Store lookup and disambiguation, URLs, labels, the HTML converter, rendering and truncation, and each excerpt family against real pages. |
| `tests/spec/unit/devdocs_install_spec.lua` | `make test-unit` | `:DocsInstall` end to end over `file://` sources, with real curl and the real split process: the swap, reinstall, the unsafe-path refusal, a failed reinstall keeping the old bundle, download failure, and slug validation. |
| `tests/spec/unit/docs_brief_spec.lua` | `make test-unit` | Both providers against clangd/pyright payload shapes recorded on 2026-09-15. |
| `tests/spec/unit/docs_hover_spec.lua` | `make test-unit` | The prose check against recorded hovers, composition, and the candidate walk, including a throwing provider. |
| `tests/spec/e2e/docs_hover_spec.lua` | `make test-e2e` | An in-process fake `clangd`: the `K` mapping (C++ yes, Go no), the merged float, second-`K` focus, a documented hover left alone, the install hint, a moved cursor opening nothing, and `gK` opening cppreference. |
| `tests/spec/e2e-lsp/docs_hover_spec.lua` | `make test-lsp` | Real clangd on `realloc` and `push_back`, and real pyright on `len`. Self-skips per server. |

The fixture bundles in `tests/fixtures/devdocs/` are trimmed from the real
downloads, keeping only the entries the specs name and the markup around what
an excerpt reads. `tests/fixtures/devdocs-src/` holds the two tiny `file://`
install sources, one of them malicious.

Two harness traps shaped the specs:
- The fake-server spec sets the filetype with `:noautocmd`, because
  `/usr/bin/clangd` is on the macOS `PATH` and a `FileType` event would start
  it next to the fake.
- The real-server spec loads files with `bufadd`/`bufload`, because the LSP
  plugin lazy-loads on `BufReadPre`, and it keeps all three servers in one `it`
  (one isolated env per headless child).

## Rejected

- **Local `man` and `pydoc` as `K`'s source.** This was the first design. Both
  are installed and version-accurate, but DevDocs gives one store and one
  renderer for all three languages, and the Python library reference is richer
  than docstrings. The costs accepted are Linux/POSIX wording for calls on a
  Mac, no excerpt for macOS-only APIs (`reallocf`, `kqueue`, `dispatch_*`,
  which are in no bundle), and up to ~210 MB on disk. The `gK` reader still
  uses local `man` and `pydoc`.
- **cppman.** It fetches from cppreference/cplusplus.com on a cache miss, which
  is network on a keypress, and cppreference rejects scripted clients.
- **Fetching single pages from documents.devdocs.io on demand.** Network on a
  keypress, and a single-page GET stalled for 20 s during research.
- **Appending to core's hover float after it opens.** It edits a window core
  owns; conceal, highlighting and size are computed at open, and the float
  visibly jumps.
- **Wrapping `client.request` to rewrite hover responses**, so core's `K` would
  render them unchanged. Every other hover consumer would get delayed, altered
  responses too, including `resolve.hover_url`, which reads hover markdown for
  `gK`.
- **Decoding `db.json` at lookup time.** 45–143 MB per slug per session.
  Splitting at install makes a lookup one small file read.
- **Mapping `K` on every LSP buffer.** One code path, but it puts Go, Rust and
  TS hovers, which already work, at risk for nothing.
- **Opening the hover first and growing the float when the excerpt lands.** The
  float jumps. With the cache and the deadline, waiting is cheap.
- **`pyvenv.cfg` → `.python-version` → probe for the Python version.** This was
  in the spec. Asking the interpreter the `gK` adapter already resolves is
  always right and is one cached spawn.
- **Treesitter for the stub's qualified name.** This was in the spec. The unit
  harness does not guarantee a `python` parser, and the indentation scan is
  exact for stubs.

## Known residue

- A truncated excerpt can end on a lead-in line (cppreference's `realloc` page
  stops at "Otherwise,").
- cppreference's inline revision markers lose a space ("contract)(since C99)").
