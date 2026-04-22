# Neovim Config

Personal Neovim configuration for Neovim **0.11+**. Uses `lazy.nvim` for plugin management with automatic bootstrapping, and Neovim's native LSP API (`vim.lsp.config` / `vim.lsp.enable`) backed by `mason.nvim` for server binaries.

## Prerequisites

### Required

| Tool | Why |
| --- | --- |
| **Neovim ≥ 0.11** | Native `vim.lsp.config` API and the `main` branch of `nvim-treesitter` both require it. |
| **git** | Used by `lazy.nvim` to clone plugins and by `gitsigns` / `diffview`. |
| **A C compiler** (`cc` / `clang` / `gcc`) | Treesitter parsers compile to native shared objects on install. |
| **make** | Builds the `telescope-fzf-native` extension. Without it, Telescope still works but falls back to the slower Lua sorter. |
| **ripgrep** (`rg`) | Required by Telescope's `live_grep` and `grep_string`. |
| **Node.js + npm** | Backs the JS-based LSP servers Mason installs (`ts_ls`, `pyright`, `bashls`, `jsonls`, `yamlls`, `html`, `cssls`, `marksman`, `mdx_analyzer`). |

### Optional but recommended

| Tool | Why |
| --- | --- |
| **A Nerd Font** (e.g. JetBrainsMono Nerd Font) | `nvim-web-devicons` (used by Diffview's file panel) renders glyphs that require one. Set your terminal font accordingly. |
| **fd** | Faster file discovery for Telescope. |
| **Go toolchain** | Needed at runtime by `gopls` if you edit Go files. |
| **Rust toolchain** (`rustup` / `cargo`) | Needed at runtime by `rust_analyzer` if you edit Rust files. |
| **Python ≥ 3.8** | Needed by `pyright` if you edit Python files. |

### Install on macOS (Homebrew)

```sh
brew install neovim git make ripgrep fd node go rustup-init
brew install --cask font-jetbrains-mono-nerd-font
```

### Install on Debian / Ubuntu

```sh
sudo apt update
sudo apt install -y neovim git build-essential ripgrep fd-find nodejs npm golang
# rustup: see https://rustup.rs
```

> Confirm `nvim --version` reports `≥ 0.11`. Distro packages are often older — install from [the official release](https://github.com/neovim/neovim/releases) or via a version manager if needed.

## Setup

1. Back up any existing config:

   ```sh
   mv ~/.config/nvim ~/.config/nvim.bak 2>/dev/null
   mv ~/.local/share/nvim ~/.local/share/nvim.bak 2>/dev/null
   mv ~/.local/state/nvim ~/.local/state/nvim.bak 2>/dev/null
   mv ~/.cache/nvim ~/.cache/nvim.bak 2>/dev/null
   ```

2. Clone this repo into `~/.config/nvim`:

   ```sh
   git clone <this-repo-url> ~/.config/nvim
   ```

3. Launch Neovim:

   ```sh
   nvim
   ```

   On first launch:
   - `init.lua` clones `lazy.nvim` into `~/.local/share/nvim/lazy/lazy.nvim`.
   - `lazy.nvim` installs every plugin under `lua/plugins/`.
   - `nvim-treesitter` compiles parsers (`:TSUpdate` runs automatically — wait for it to finish).
   - `mason-lspconfig` installs the LSP servers listed in `lua/plugins/lsp.lua`.

   Expect the first launch to take a few minutes. You may see transient errors while parsers and servers are still downloading; restart `nvim` once everything finishes.

4. Verify the install:

   ```vim
   :checkhealth
   :Lazy
   :Mason
   ```

   `:checkhealth` should report no errors for `nvim-treesitter`, `telescope`, and `lsp`.

## What's included

- **Plugin manager:** `lazy.nvim` (auto-bootstrapped from `init.lua`)
- **Treesitter:** `nvim-treesitter` (main branch) + `nvim-treesitter-context` for sticky scope headers
- **Fuzzy finder:** `telescope.nvim` + `telescope-fzf-native`
- **LSP:** native `vim.lsp` + `mason.nvim` + `mason-lspconfig.nvim` + `nvim-lspconfig` (defaults only)
- **Git:** `gitsigns.nvim` (signs, blame, hunk navigation, review-base diffing) + `diffview.nvim` (full diff UI, `diff3_mixed` merge layout)
- **Markdown:** `render-markdown.nvim` (in-buffer rendering for `.md` and `.mdx`)
- **Discoverability:** `which-key.nvim` (`<leader>K` shows every mapping)

## Key bindings

Leader is `<Space>`; local leader is `\`. Press `<Space>?` (Telescope keymaps) or `<Space>K` (which-key) at any time to browse every mapping. A few highlights:

| Keys | Action |
| --- | --- |
| `<Space><Space>` | Files (changed first) |
| `<Space>ff` / `<Space>fg` | Find files / live grep |
| `<Space>gd` | Diffview: working tree vs index |
| `<Space>gm` | Diffview: branch vs `origin/main` |
| `<Space>gB` | Pick a review base branch (drives gitsigns + Telescope sort) |
| `]c` / `[c` | Next / previous git hunk |
| `gd` | LSP go-to-definition (or `_typescript.goToSourceDefinition` in TS buffers) |
| `<Space>e` | Show diagnostics in a float |

## Layout

```
init.lua                 # bootstraps lazy.nvim, sets leaders, loads modules
lua/
  config/
    options.lua          # editor options + autocommands
    lsp_refs.lua         # in-file LSP reference highlighting + statusline count
    review_base.lua      # per-repo "review base" ref used by gitsigns / telescope
    telescope_smart.lua  # files picker that surfaces changed files first
  plugins/
    *.lua                # one file per plugin spec; lazy.nvim auto-discovers
```

## Adding a plugin

Drop a new file in `lua/plugins/` returning a `lazy.nvim` spec. No imports or registration needed — `require("lazy").setup("plugins")` picks it up on next launch.

```lua
-- lua/plugins/example.lua
return {
  "author/plugin",
  event = "VeryLazy",
  opts = {},
}
```
