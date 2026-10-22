# Python navigation

Reading a Python project that is split across many files and classes comes
down to three questions: where is this defined, what actually runs when it is
called, and who calls it. This page is how the config answers each one, and
what it does so that the answer does not depend on how Neovim was started.

The pieces: `lua/config/python_lsp.lua` (the server and its per-project
wiring), `lua/config/python_env.lua` (the interpreter),
`lua/config/python_root.lua` (the root), the navigation verbs in
`lua/config/tagstack.lua`, all wired from `lua/plugins/lsp.lua`.

## Keys

| Keys | What it answers |
|---|---|
| `gd` | where is this defined: the `.py` source |
| `gD` | where is it declared: the `.pyi` stub when one exists (Python buffers only) |
| `gri` | what actually runs: overrides of a method, subclasses of a class, implementers of a Protocol |
| `grr` | every reference |
| `grc` / `grC` | who calls this function / what it calls |
| `grt` | the definition of the value's type |
| `<C-t>` | back one hop, after any of the above |
| `K` | hover: signature and docstring |
| `<leader>uh` | toggle inlay hints: return types and argument names |

All of them push one frame on the definition stack, so `<C-t>` comes back from
any of them ([navigation-stack.md](navigation-stack.md)). One result jumps and
several open the quickfix list (`grr` always opens the list).

Reading through an interface is three keys. On `repo.save(item)` where `repo`
is typed as an abstract `Repo`, `gd` lands on `Repo.save`, the abstract method.
Every editor does this, because go-to-definition resolves on the declared type
and the declared type is `Repo`. `gri` from the same spot lists the concrete
`save` methods. `grc` on one of them lists who calls it.

## The server

The type server is **basedpyright**, pinned in `mason-tool-versions.lock`. It is
pyright with the open-source half of Pylance put back. The deciding difference:
plain pyright answers no `textDocument/implementation` request at all (`-32601`
"Unhandled method"), so `gri` did nothing in Python, and from an abstract method
there was nowhere to go. basedpyright's implementation search finds subclass
overrides and also classes that satisfy a `Protocol` without inheriting from it.
It also sends semantic tokens and inlay hints, and it bundles docstrings for the
builtins written in C (`len`, `str.split`), so `K` documents them directly.

Because it is the same engine, import resolution, `pyrightconfig.json`,
`[tool.pyright]` and the per-project rule picker all carry over
([python-diagnostics.md](python-diagnostics.md)). basedpyright also reads
`[tool.basedpyright]`.

The server name is set in one place (`M.server` in `lua/config/python_lsp.lua`).
The rule picker, the `K` docs provider and the statusline all key on it.

Two settings differ from basedpyright's defaults:

- `typeCheckingMode = "standard"`, pyright's default. basedpyright's own
  default, `"recommended"`, enables many rules pyright leaves off. A project
  config file replaces this setting, and one that sets no mode brings
  `"recommended"` back. That gets a warning on attach and a local fix,
  `:PythonQuiet`
  ([python-diagnostics.md](python-diagnostics.md#projects-with-their-own-pyright-config)).
- inlay hints show return types and call-argument names only. A type on every
  assignment and generic arguments are noise. They stay off until `<leader>uh`.

**Exactly one type server attaches.** Neovim merges definition, implementation
and reference answers from every attached client, so a second one would turn
every `gd` into a two-entry list of the same place. pyright is excluded from
mason-lspconfig's `automatic_enable`, since a machine that ran the old pin still
has it installed. ruff still attaches for lint and fixes. It answers none of the
navigation requests, and its hover is switched off so `K` does not grow an empty
"ruff" section.

## Interpreter

The server is told which interpreter to use (`python.pythonPath`) instead of
taking whatever `python` Neovim inherited. Before this change, the same `gd`
landed in different places depending on the shell Neovim was started from:
third-party imports resolved against another environment's packages, fell back
to stubs, or did not resolve at all.

`config.python_env` looks, in order:

1. for `.venv` or `venv` (with a `pyvenv.cfg`) in the root, then in each parent
   up to the repository root. A uv workspace keeps one `.venv` at the top.
2. at an activated `$VIRTUAL_ENV`, but only if it sits inside the repository.
   One pointing at another project is worse than no answer.
3. for the pyenv version named by the nearest `.python-version`, resolved to an
   absolute path (uv writes bare minor versions like `3.12`).

If nothing matches, `pythonPath` is left unset, so the server falls back to
`python` on PATH. The `K` docs adapter uses the same lookup for its root alone.

The **statusline** shows what the server is using, next to the filetype:

| Segment | Meaning |
|---|---|
| ` py:.venv ` | the venv at the root (path relative to the root) |
| ` py:~/src/ws/.venv ` | a venv above the root (a member with its own type-checker config) |
| ` py:pyenv 3.12.10 ` | a pyenv interpreter from `.python-version` |
| ` py:PATH ` | nothing found; the server uses `python` on PATH |

If a jump looks wrong, check this segment first.

## Roots

Neovim starts one server per root, and the root decides two things. The server
only searches files under the root for references and implementations. And it
reads its config file (`pyrightconfig.json` or a `[tool.pyright]` /
`[tool.basedpyright]` section) **only from the root**.

lspconfig's default roots at the nearest `pyproject.toml`. In a uv workspace,
where every member has one, that gave each member its own server, which saw
only its own files and missed the workspace venv. `config.python_root` searches
upward from the buffer, staying inside the repository (a submodule counts as its
own), and picks the first rule that matches:

1. the nearest directory that configures the type checker. Rooting anywhere else
   would silently drop that config.
2. the nearest `pyproject.toml` with a lockfile beside it (`uv.lock`,
   `poetry.lock`, `pdm.lock`, `Pipfile.lock`). A uv workspace has its single
   `uv.lock` at the top and none in its members, while poetry and pdm projects,
   and independent projects sharing a repo, each have their own. So the nearest
   lockfile marks the project boundary in both layouts. (Zed takes the
   *outermost* lockfile instead, which would root an independent nested project
   at whatever sits above it.)
3. the nearest `pyproject.toml`.

If none matches, lspconfig's own markers apply (`setup.py`, `setup.cfg`,
`requirements.txt`, `Pipfile`, `.git`).

## Staying current

File watching is off for every server in this config, so the server never hears
about changes made outside the editor. Two kinds of change make Python
navigation go stale, and both restart the server automatically:

- **A branch switch.** The `User HeadChanged` event from `lua/config/git_head.lua`
  restarts every Python type server rooted inside that repository.
- **The environment changed.** On `FocusGained`, a server restarts if its
  venv's `site-packages` changed (packages installed or removed, which is what
  `uv sync` does), or if it started without a venv and one now exists.

Each restart is reported with a one-line notification. `<leader>lr` remains the
manual restart for anything else, such as editing `pyrightconfig.json`.

## Reading aids

basedpyright's semantic tokens are painted over tree-sitter's
([token-emphasis.md](superpowers/token-emphasis.md) has the two-layer rules).
For Python they fix what tree-sitter can only guess:

- `os.path` reads as a module, not as a field.
- A name bound to a constant (`ALL_CAPS` or `Final`) keeps the constant colour
  everywhere it is used.
- Parameters keep the parameter colour throughout the body.

Declaration names stay bold, because basedpyright marks them with the
`declaration` modifier the emphasis rules already handle.

Docstrings are captured as `@string.documentation`. They are drawn in the same
dimmed tier as doc comments, so a docstring under every `def` reads as a caption
rather than a paragraph.

## When `gd` still lands somewhere odd

| Symptom | Likely cause | Fix |
|---|---|---|
| lands in a `.pyi` stub | no source in the interpreter the server uses | check the statusline segment. `gd` prefers source and falls back to the stub only when there is none: a C extension, a stub-only package, or a package missing from that environment |
| opens the site-packages copy of your own package | an editable install that uses an import hook (setuptools' default on a flat layout), which static analysis cannot follow | `[tool.uv] config-settings = { editable_mode = "compat" }`, or a path-based backend (`uv_build`, hatchling) |
| does nothing on `obj.method()` | `obj`'s type is unknown (unannotated parameter or factory) | annotate it; no server can navigate an unknown type |
| stops at `Foo = _impl.Foo` | an assignment is a variable, not a re-export | `from ._impl import Foo as Foo` |
| the decorated function shows the wrong signature | an untyped decorator (`Callable -> Callable`) erases it | type the decorator with `ParamSpec` |
| a list with the same place twice | a second navigation server attached | `:LspInfo`; see "Exactly one type server" above |

## Limits

- **No type hierarchy.** basedpyright does not implement it (upstream issue
  #355). `gri` on a class name lists its subclasses, which covers most uses.
- **`grr` on an override does not list calls made through the base type.** Run
  `grr` (or `grc`) on the base method to find every caller of an interface.
- **Implementation search scans the whole project.** It is noticeably slower
  than `gd` on a very large one.
- **No PyCharm-style "overridden / implements" markers in the gutter.** They
  could be built from document symbols plus one implementation request per
  symbol. Nothing does that yet.

## Tests

- Unit: `tests/spec/unit/python_env_spec.lua`,
  `tests/spec/unit/python_root_spec.lua`, `tests/spec/unit/python_lsp_spec.lua`,
  and the call-hierarchy cases in `tests/spec/unit/tagstack_spec.lua`.
- Smoke: `tests/spec/smoke/lsp_filetypes_spec.lua` pins the single type server
  and its wiring.
- Real server: `tests/spec/e2e-lsp/python_navigation_spec.lua` checks the full
  flow against basedpyright: an ABC, a Protocol implemented without
  inheritance, a venv, the statusline, `grc`. Pointed at plain pyright it fails
  with the original symptom ("Unhandled method textDocument/implementation").
  It self-skips unless mason's bin dir is on PATH:

  ```sh
  PATH="$HOME/.local/share/nvim/mason/bin:$PATH" make test-lsp
  ```
