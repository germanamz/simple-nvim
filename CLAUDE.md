# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Personal Neovim configuration targeting Neovim 0.11+. Uses lazy.nvim for plugin
management with automatic bootstrapping.

## Architecture

- `init.lua` — Entry point: bootstraps lazy.nvim, sets leader keys
(`<Space>`/`\`), loads options, then calls `require("lazy").setup("plugins")`
- `lua/config/options.lua` — Editor options and autocommands (indentation,
search, display, markdown writing mode)
- `lua/plugins/*.lua` — Each file returns a lazy.nvim plugin spec (or table of
specs). lazy.nvim auto-discovers all files in this directory.
- `ftplugin/*.lua` — Filetype options for filetypes the runtime ships no
ftplugin for (e.g. `starlark`, sourced by `tiltfile`; see `docs/tiltfile.md`).

## Plugin conventions

- Treesitter uses the `main` branch API (Neovim 0.11+): no `configs.setup()`,
parsers installed via `require("nvim-treesitter").install()`, highlighting
started per-buffer via `vim.treesitter.start()` in a FileType autocmd.
Parsers are pinned in `parser-revisions.lua`; grammars nvim-treesitter does
not ship (e.g. `fga`) are registered out-of-tree in `lua/plugins/treesitter.lua`
with their queries vendored under `queries/<lang>/` (see `docs/openfga.md`).
- Telescope uses fzf-native extension (requires `make`). Pickers open in normal
mode (`initial_mode = "normal"`); press `i`/`a` to type. In insert mode `<esc>`
drops back to normal mode, `<C-c>` closes; in normal mode `<esc>` closes.
- LSP uses Neovim 0.11+ native API (`vim.lsp.config` / `vim.lsp.enable`) with
`mason.nvim` managing server binaries. Servers are declared as a single table in
`lua/plugins/lsp.lua`; each entry's `filetypes` gates per-buffer attach.
Buffer-local keymaps are set from a single `LspAttach` autocmd.

## Adding a plugin

Create `lua/plugins/<name>.lua` returning a lazy.nvim spec table. lazy.nvim
picks it up automatically — no imports needed.

## Memory and docs (tusk)

The repo is a [tusk](https://github.com/germanamz/tusk) vault: `tusk.toml`
indexes every markdown file (except this one) into a searchable graph, and the
plugin in `.claude/skills/tusk/` gives each session the `tusk_*` MCP tools and
the memory index (`docs/memory/README.md`). Claude Code's built-in auto memory
is off for this repo (`autoMemoryEnabled` in `.claude/settings.json`), so tusk
is the only memory.

- Look things up with `tusk_query` (a filter plus `semantic`) before grepping
`docs/`.
- A memory is `docs/memory/<slug>.md`, one fact per file, with frontmatter
`type: memory`, `title`, `kind` (`feedback` | `project` | `reference`) and a
one-line `description`. For feedback and project memories, follow the fact with
**Why:** and **How to apply:** lines. Link related memories with `[[slug]]`, and
add a line for each new memory to `docs/memory/README.md`. Update an existing
memory rather than adding a duplicate; delete one that turned out wrong.
- Memories and docs are public. Never name the host machine (paths outside the
repo and nvim's stdpath dirs, usernames, hardware, installed app versions) or
the projects the config is used on; describe their shape instead ("a pnpm
monorepo with TypeScript installed only in a leaf package").
- Specs and plans in `docs/` stay uncommitted; docs of how things currently work
are committed (`docs/memory/spec-docs-in-repo-not-scratchpad.md`).
- Docs name the files they describe in inline code. After you edit a file, the
plugin lists the docs that name it; fix any the change made wrong.
- Run `tusk doctor` after editing docs: it exits 1 on a dangling link or a
broken rule. Semantic search needs Ollama with `nomic-embed-text`.

## Editing conventions

- 2-space indentation, spaces not tabs
- All Lua files
- Leader key: `<Space>` (global), `\` (local)
