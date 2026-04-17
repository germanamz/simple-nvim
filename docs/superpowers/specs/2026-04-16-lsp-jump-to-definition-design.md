# LSP: Jump-to-Definition + Diagnostics

Date: 2026-04-16
Status: Approved (design)

## Goal

Add `gd` jump-to-definition and basic diagnostics for every language currently installed via nvim-treesitter. Use Neovim 0.11+ native LSP APIs (`vim.lsp.config` / `vim.lsp.enable`) with mason.nvim managing server binaries.

## Scope

**In scope**
- `gd` → `vim.lsp.buf.definition()` (buffer-local, set on `LspAttach`)
- Diagnostic navigation (`]d` / `[d`) and float (`<leader>e`)
- Server auto-install via mason-lspconfig `ensure_installed`
- Per-filetype attach (native behavior through each server's `filetypes`)

**Out of scope**
- Hover, rename, references, code actions, completion
- Formatters, linters as LSP (none added here)
- Inlay hints, signature help

## Non-goals / YAGNI

- No `nvim-lspconfig` plugin — Neovim 0.11 ships `vim.lsp.config` natively
- No completion plugin (cmp/blink) — not in scope
- No keymap for hover/rename — user asked for minimal

## Architecture

Single new plugin spec file: `lua/plugins/lsp.lua`.

**Plugins**
1. `mason-org/mason.nvim` — installs LSP server binaries into `stdpath("data")/mason`
2. `mason-org/mason-lspconfig.nvim` — bridges mason with server names; drives `ensure_installed`

**Setup flow**
1. `mason.setup()` runs first (dependency of mason-lspconfig)
2. `mason-lspconfig.setup({ ensure_installed = {...} })` auto-installs missing servers
3. For each server name, call `vim.lsp.config(name, {...})` with filetypes + any per-server overrides, then `vim.lsp.enable(name)`
4. A single `LspAttach` autocmd sets buffer-local keymaps

## Servers

Mapped from current treesitter parsers to their LSP equivalents.

| Language | Server | Notes |
|---|---|---|
| TS/JS/TSX/JSX | `ts_ls` | filetypes: typescript, typescriptreact, javascript, javascriptreact |
| Python | `pyright` | |
| Go | `gopls` | |
| Rust | `rust_analyzer` | |
| Lua | `lua_ls` | configure `Lua.workspace.library` = `vim.api.nvim_get_runtime_file("", true)` for nvim API awareness |
| Bash | `bashls` | |
| JSON / JSONC | `jsonls` | |
| YAML | `yamlls` | |
| TOML | `taplo` | |
| HTML | `html` | |
| CSS | `cssls` | |
| Markdown | `marksman` | |

Server attach is gated by each server's `filetypes` list. Opening a non-matching buffer does not start the server. This is native LSP spec behavior — no custom gating logic needed.

## Keymaps

Set buffer-local inside the `LspAttach` autocmd callback:

| Keys | Action |
|---|---|
| `gd` | `vim.lsp.buf.definition()` |
| `]d` | `vim.diagnostic.goto_next()` (or 0.11 default `]d`) |
| `[d` | `vim.diagnostic.goto_prev()` |
| `<leader>e` | `vim.diagnostic.open_float()` |

`gd` is set buffer-local so it overrides netrw's `gd` only where LSP is attached. Netrw behavior preserved elsewhere.

## Diagnostics UI

Use Neovim defaults: signs + virtual text on, underline on. No `vim.diagnostic.config()` override unless a follow-up asks.

## File layout

```
lua/plugins/lsp.lua   (new)
```

No changes to `init.lua`, `options.lua`, or existing plugin specs. lazy.nvim auto-discovers the new file.

## Testing / verification

Manual:
1. Open a `.ts` file in a TS project → `:LspInfo` shows `ts_ls` attached → `gd` jumps to symbol definition.
2. Open `init.lua` → `lua_ls` attached, `vim` global recognized (no diagnostic).
3. Open a `.txt` file → no LSP attached.
4. Introduce a syntax error in `.ts` → sign + virtual text appears → `]d` jumps to it → `<leader>e` opens float.
5. `:Mason` shows all 12 servers installed after first start.

## Open decisions

None. All resolved in brainstorm.

## Risks

- Mason install on first start takes time and needs network. Acceptable one-time cost.
- `ts_ls` resolves definitions through `tsconfig.json` / `package.json`; behavior depends on project state. Not a config issue.
