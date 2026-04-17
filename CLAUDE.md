# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Personal Neovim configuration targeting Neovim 0.11+. Uses lazy.nvim for plugin management with automatic bootstrapping.

## Architecture

- `init.lua` — Entry point: bootstraps lazy.nvim, sets leader keys (`<Space>` / `\`), loads options, then calls `require("lazy").setup("plugins")`
- `lua/config/options.lua` — Editor options and autocommands (indentation, search, display, diff-mode wrap fix)
- `lua/plugins/*.lua` — Each file returns a lazy.nvim plugin spec (or table of specs). lazy.nvim auto-discovers all files in this directory.

## Plugin conventions

- Treesitter uses the `main` branch API (Neovim 0.11+): no `configs.setup()`, parsers installed via `require("nvim-treesitter").install()`, highlighting started per-buffer via `vim.treesitter.start()` in a FileType autocmd.
- Telescope uses fzf-native extension (requires `make`). Single-escape closes insert mode directly.
- Diffview configured with `diff3_mixed` merge layout; `q` closes in all panels.
- LSP uses Neovim 0.11+ native API (`vim.lsp.config` / `vim.lsp.enable`) with `mason.nvim` managing server binaries. Servers are declared as a single table in `lua/plugins/lsp.lua`; each entry's `filetypes` gates per-buffer attach. Buffer-local keymaps are set from a single `LspAttach` autocmd.

## Adding a plugin

Create `lua/plugins/<name>.lua` returning a lazy.nvim spec table. lazy.nvim picks it up automatically — no imports needed.

## Editing conventions

- 2-space indentation, spaces not tabs
- All Lua files
- Leader key: `<Space>` (global), `\` (local)
