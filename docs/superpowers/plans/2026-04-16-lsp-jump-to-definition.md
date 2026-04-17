# LSP Jump-to-Definition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `gd` jump-to-definition plus basic diagnostics across all treesitter-supported languages, using Neovim 0.11+ native LSP APIs and mason.nvim for server install.

**Architecture:** Single new lazy.nvim plugin spec at `lua/plugins/lsp.lua`. Mason installs LSP binaries, mason-lspconfig drives `ensure_installed`. Each server is registered with `vim.lsp.config()` (filetypes scope attach) and activated with `vim.lsp.enable()`. A single `LspAttach` autocmd sets buffer-local keymaps.

**Tech Stack:** Neovim 0.11+, lazy.nvim, mason.nvim, mason-lspconfig.nvim, native `vim.lsp.config` / `vim.lsp.enable` / `vim.diagnostic`.

**Spec:** `docs/superpowers/specs/2026-04-16-lsp-jump-to-definition-design.md`

---

## File Structure

**Create:**
- `lua/plugins/lsp.lua` — lazy.nvim spec. Sets up Mason, registers all LSP servers, wires `LspAttach` keymaps.

**Modify:** none. `init.lua` already calls `require("lazy").setup("plugins")` which auto-discovers the new file.

The plan is a single-file plugin spec, so tasks are structured by concern within that file (skeleton → keymaps autocmd → servers) rather than by separate files. Each task produces a self-contained, testable state and gets its own commit.

**Testing note:** This is Neovim configuration. There is no unit test framework set up in this repo, and spinning one up for 12 LSP wire-ups is disproportionate. Each task uses manual verification steps (open a buffer, check `:LspInfo` / `:Mason` / run a keymap) with explicit expected output. Treat the verification step as the "test" gate — do not commit until it passes.

---

### Task 1: Create plugin skeleton with Mason installed

**Files:**
- Create: `lua/plugins/lsp.lua`

- [ ] **Step 1: Write the initial spec**

Create `lua/plugins/lsp.lua` with only Mason wired up. No servers yet. This isolates "Mason installs cleanly" from "servers attach correctly".

```lua
-- LSP stack: native vim.lsp.config (Neovim 0.11+) + mason.nvim for binaries.
-- Servers are registered and enabled in a later step; this file currently only
-- bootstraps Mason so `:Mason` opens the installer UI.
return {
  {
    "mason-org/mason.nvim",
    lazy = false,
    build = ":MasonUpdate",
    config = function()
      require("mason").setup()
    end,
  },
}
```

- [ ] **Step 2: Verify Mason loads**

Run: `nvim --headless "+Lazy! sync" +qa`
Expected: exits 0, no errors.

Then run: `nvim +Mason` interactively.
Expected: Mason UI opens showing a list of installable packages. Quit with `q`.

- [ ] **Step 3: Commit**

```bash
git add lua/plugins/lsp.lua
git commit -m "Add mason.nvim for LSP server installs"
```

---

### Task 2: Add mason-lspconfig with ensure_installed list

**Files:**
- Modify: `lua/plugins/lsp.lua`

- [ ] **Step 1: Extend the spec with mason-lspconfig**

Replace the contents of `lua/plugins/lsp.lua` with:

```lua
-- LSP stack: native vim.lsp.config (Neovim 0.11+) + mason.nvim for binaries.
-- mason-lspconfig provides the `ensure_installed` bridge so every server in
-- the list is auto-installed on first start. Servers are registered/enabled
-- in a later step.
local servers = {
  "ts_ls",
  "pyright",
  "gopls",
  "rust_analyzer",
  "lua_ls",
  "bashls",
  "jsonls",
  "yamlls",
  "taplo",
  "html",
  "cssls",
  "marksman",
}

return {
  {
    "mason-org/mason.nvim",
    lazy = false,
    build = ":MasonUpdate",
    config = function()
      require("mason").setup()
    end,
  },
  {
    "mason-org/mason-lspconfig.nvim",
    lazy = false,
    dependencies = { "mason-org/mason.nvim" },
    config = function()
      require("mason-lspconfig").setup({
        ensure_installed = servers,
        automatic_installation = false,
      })
    end,
  },
}
```

Note: `servers` is a simple string list here. Task 3 reshapes it into a table keyed by server name so each entry can carry its own `filetypes` and settings.

- [ ] **Step 2: Verify auto-install triggers**

Run: `nvim --headless "+Lazy! sync" +qa`
Expected: exits 0.

Then run `nvim` interactively and wait ~30s (first run downloads binaries).
Run `:Mason` inside nvim.
Expected: all 12 servers show as installed (green check) — or are actively installing. Quit with `q`.

If servers are slow to install, check `:MasonLog`.

- [ ] **Step 3: Commit**

```bash
git add lua/plugins/lsp.lua
git commit -m "Auto-install LSP servers via mason-lspconfig"
```

---

### Task 3: Register and enable servers via vim.lsp.config

**Files:**
- Modify: `lua/plugins/lsp.lua`

- [ ] **Step 1: Add server configs and enablement**

Replace the `mason-lspconfig.nvim` block in `lua/plugins/lsp.lua` so its `config` function both runs `ensure_installed` and then registers every server. Final file contents:

```lua
-- LSP stack: native vim.lsp.config (Neovim 0.11+) + mason.nvim for binaries.
--   • Mason installs server binaries into stdpath("data")/mason.
--   • mason-lspconfig drives ensure_installed.
--   • vim.lsp.config(name, {...}) registers each server; vim.lsp.enable(name)
--     activates it. The server's `filetypes` list gates attach per buffer, so
--     a server only starts when a matching filetype is opened.
local servers = {
  ts_ls         = { filetypes = { "typescript", "typescriptreact", "javascript", "javascriptreact" } },
  pyright       = { filetypes = { "python" } },
  gopls         = { filetypes = { "go", "gomod", "gosum", "gowork" } },
  rust_analyzer = { filetypes = { "rust" } },
  lua_ls        = {
    filetypes = { "lua" },
    settings = {
      Lua = {
        runtime     = { version = "LuaJIT" },
        diagnostics = { globals = { "vim" } },
        workspace   = {
          library = vim.api.nvim_get_runtime_file("", true),
          checkThirdParty = false,
        },
        telemetry = { enable = false },
      },
    },
  },
  bashls   = { filetypes = { "sh", "bash" } },
  jsonls   = { filetypes = { "json", "jsonc" } },
  yamlls   = { filetypes = { "yaml" } },
  taplo    = { filetypes = { "toml" } },
  html     = { filetypes = { "html" } },
  cssls    = { filetypes = { "css", "scss", "less" } },
  marksman = { filetypes = { "markdown" } },
}

return {
  {
    "mason-org/mason.nvim",
    lazy = false,
    build = ":MasonUpdate",
    config = function()
      require("mason").setup()
    end,
  },
  {
    "mason-org/mason-lspconfig.nvim",
    lazy = false,
    dependencies = { "mason-org/mason.nvim" },
    config = function()
      local server_names = vim.tbl_keys(servers)

      require("mason-lspconfig").setup({
        ensure_installed = server_names,
        automatic_installation = false,
      })

      for name, opts in pairs(servers) do
        vim.lsp.config(name, opts)
        vim.lsp.enable(name)
      end
    end,
  },
}
```

- [ ] **Step 2: Verify a server attaches**

Pick any TS/JS file on your machine (or create `/tmp/claude/smoke.ts` with `const x: number = 1;`).

Run: `nvim /tmp/claude/smoke.ts` then `:LspInfo`.
Expected: `ts_ls` listed as attached with at least 1 client active.

Open `/tmp/claude/smoke.txt` (create it with any text).
Run `:LspInfo`.
Expected: "No clients attached to this buffer." — confirms filetype gating works.

- [ ] **Step 3: Commit**

```bash
git add lua/plugins/lsp.lua
git commit -m "Register and enable LSP servers with filetype gating"
```

---

### Task 4: Add LspAttach autocmd for keymaps

**Files:**
- Modify: `lua/plugins/lsp.lua`

- [ ] **Step 1: Add the autocmd inside mason-lspconfig config**

Add the following block at the top of the `mason-lspconfig.nvim` entry's `config` function (before the `local server_names = ...` line):

```lua
      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(args)
          local opts = { buffer = args.buf, silent = true }
          vim.keymap.set("n", "gd",         vim.lsp.buf.definition,      opts)
          vim.keymap.set("n", "]d",         vim.diagnostic.goto_next,    opts)
          vim.keymap.set("n", "[d",         vim.diagnostic.goto_prev,    opts)
          vim.keymap.set("n", "<leader>e",  vim.diagnostic.open_float,   opts)
        end,
      })
```

The autocmd must be created before `vim.lsp.enable()` fires so the first attach picks it up on fresh files. Inside the same `config` function, the order becomes: autocmd → ensure_installed → register+enable.

After editing, the `mason-lspconfig.nvim` block's `config` function should look like:

```lua
    config = function()
      vim.api.nvim_create_autocmd("LspAttach", {
        callback = function(args)
          local opts = { buffer = args.buf, silent = true }
          vim.keymap.set("n", "gd",         vim.lsp.buf.definition,      opts)
          vim.keymap.set("n", "]d",         vim.diagnostic.goto_next,    opts)
          vim.keymap.set("n", "[d",         vim.diagnostic.goto_prev,    opts)
          vim.keymap.set("n", "<leader>e",  vim.diagnostic.open_float,   opts)
        end,
      })

      local server_names = vim.tbl_keys(servers)

      require("mason-lspconfig").setup({
        ensure_installed = server_names,
        automatic_installation = false,
      })

      for name, opts in pairs(servers) do
        vim.lsp.config(name, opts)
        vim.lsp.enable(name)
      end
    end,
```

- [ ] **Step 2: Verify `gd` jumps to definition**

Create `/tmp/claude/smoke.ts`:

```ts
function greet(name: string) {
  return "hello " + name;
}

greet("world");
```

Run: `nvim /tmp/claude/smoke.ts`, wait ~1s for `ts_ls` to index, then move the cursor onto `greet` in the call on the last line and press `gd`.
Expected: cursor jumps to the `function greet` declaration on line 1.

- [ ] **Step 3: Verify diagnostic navigation and float**

Edit the file to introduce a type error:

```ts
function greet(name: string) {
  return "hello " + name;
}

greet(42);
```

Save, then in nvim press `]d`.
Expected: cursor jumps to the `42` argument and a sign/virtual-text diagnostic is visible.

Press `<leader>e`.
Expected: a floating window opens showing the full diagnostic message.

- [ ] **Step 4: Verify netrw's `gd` still works elsewhere**

Run: `nvim .` (opens netrw in the project root).
In the netrw listing, press `gd`.
Expected: netrw's "go to file" behavior (or its default unmapped behavior) — `gd` was only overridden in LSP-attached buffers, so netrw is unaffected.

- [ ] **Step 5: Commit**

```bash
git add lua/plugins/lsp.lua
git commit -m "Add LspAttach keymaps for gd and diagnostics"
```

---

### Task 5: Update CLAUDE.md with LSP conventions

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add an LSP section under "Plugin conventions"**

Open `CLAUDE.md` and add the following bullet to the "Plugin conventions" list (after the Diffview bullet):

```markdown
- LSP uses Neovim 0.11+ native API (`vim.lsp.config` / `vim.lsp.enable`) with `mason.nvim` managing server binaries. Servers are declared as a single table in `lua/plugins/lsp.lua`; each entry's `filetypes` gates per-buffer attach. Buffer-local keymaps are set from a single `LspAttach` autocmd.
```

- [ ] **Step 2: Verify the file**

Run: `grep -n "LSP uses Neovim" CLAUDE.md`
Expected: one match.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "Document LSP conventions in CLAUDE.md"
```

---

## Post-implementation verification

Run all of these at the end, in nvim:

1. `:Lazy` — three plugins listed (mason.nvim, mason-lspconfig.nvim) with no errors.
2. `:Mason` — all 12 servers marked installed.
3. `:checkhealth vim.lsp` — no errors reported.
4. Open a TS file → `:LspInfo` shows `ts_ls` attached; `gd` jumps; `]d` navigates; `<leader>e` opens float.
5. Open `init.lua` → `lua_ls` attached; no spurious diagnostic on `vim` global.
6. Open a `.txt` file → `:LspInfo` shows no clients (filetype gating).
