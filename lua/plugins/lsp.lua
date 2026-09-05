-- LSP stack: native vim.lsp.config (Neovim 0.11+) + mason.nvim for binaries.
--   • Mason installs server binaries into stdpath("data")/mason.
--   • mason-lspconfig drives ensure_installed.
--   • vim.lsp.config(name, {...}) registers each server; vim.lsp.enable(name)
--     activates it. The server's `filetypes` list gates attach per buffer, so
--     a server only starts when a matching filetype is opened.
local ft_util = require("util.ft")

local servers = {
  -- disableAutomaticTypingAcquisition: tsserver otherwise forks a fourth node
  -- process (typingsInstaller.js) per client to fetch @types for untyped JS
  -- dependencies. Measured ~67 MiB of a ~720 MiB client, and every project here
  -- declares its @types explicitly, so ATA only buys completions for untyped JS
  -- deps — which is what it forfeits. Matters most because clients are never
  -- reaped (docs/lsp-typescript-version.md): the cost is per live root.
  ts_ls = {
    filetypes = { "typescript", "typescriptreact", "javascript", "javascriptreact" },
    init_options = { hostInfo = "neovim", disableAutomaticTypingAcquisition = true },
  },
  -- No `settings` here on purpose. Pyright's per-rule severities are a property
  -- of the PROJECT, not of this config: a codebase that annotates but does not
  -- follow the annotations (Pydantic being the canonical case) needs specific
  -- rules dialed down, while a strict codebase must keep them. So the severities
  -- are picked per project and injected by config.pyright_rules' before_init,
  -- wired in the config() block below. Note the usual advice — typeCheckingMode
  -- = "basic" — does nothing for that case: the rules involved are "error" in
  -- basic, standard AND strict alike. See docs/python-diagnostics.md.
  pyright = { filetypes = { "python" } },
  gopls = { filetypes = { "go", "gomod" } },
  -- experimental.localDocs asks rust-analyzer to return a `local` file:// path
  -- alongside the docs.rs URL in its `experimental/externalDocs` reply, so a
  -- crate whose docs have been built by `cargo doc` opens from disk. config.docs
  -- stats the path before preferring it, and falls back to the web URL when the
  -- docs were never generated. rust-analyzer is the only server that implements
  -- this request at all (gopls, pyright, ts_ls, clangd and lua_ls all answer
  -- -32601), and it is the only way to get URLs that follow re-exports to the
  -- defining crate and honor a crate's #![doc(html_root_url)].
  rust_analyzer = {
    filetypes = { "rust" },
    capabilities = { experimental = { localDocs = true } },
  },
  clangd = { filetypes = { "c", "cpp", "objc", "objcpp", "cuda", "proto" } },
  -- zls (zigtools/zls). Narrowed from lspconfig's own { "zig", "zir" }: Neovim
  -- has no `zir` filetype, so that name can never match a buffer.
  --
  -- One row covers both Zig source and Zig object notation, because Neovim maps
  -- .zig AND .zon to ft=zig — so this is also the server serving build.zig.zon,
  -- which zls does understand.
  --
  -- No `settings`. zls publishes `zig ast-check` diagnostics on its own, which
  -- is why there is no nvim-lint pass for Zig (see lua/plugins/nvim-lint.lua and
  -- docs/zig.md); build-on-save is left off because it runs the project's build
  -- steps on every write.
  --
  -- The mason pin is version-coupled in a way the other pins are not: zls links
  -- the Zig compiler frontend it was built against, so zls 0.16.x expects zig
  -- 0.16.x, and the `zig` that conform's zigfmt runs comes off PATH (Homebrew
  -- here), not from mason. Bumping the compiler therefore means bumping the
  -- "zls" line in mason-tool-versions.lock in the same breath, or the editor
  -- quietly parses one language version while the toolchain builds another.
  zls = { filetypes = { "zig" } },
  lua_ls = {
    filetypes = { "lua" },
    settings = {
      Lua = {
        runtime = { version = "LuaJIT" },
        diagnostics = { globals = { "vim" } },
        -- No static workspace.library: lazydev (lua/plugins/lazydev.lua)
        -- injects runtime + plugin definitions on demand per require().
        workspace = { checkThirdParty = false },
        telemetry = { enable = false },
      },
    },
  },
  bashls = { filetypes = { "sh", "bash" } },
  jsonls = { filetypes = { "json", "jsonc" } },
  yamlls = { filetypes = { "yaml" } },
  taplo = { filetypes = { "toml" } },
  -- terraform-ls (HashiCorp). Bundled filetypes already gate to terraform +
  -- terraform-vars (.tf / .tfvars); listed explicitly to match the per-server
  -- convention. Its bundled on_attach enables codelens ("N references" virtual
  -- lines) — inconsistent with this config's quiet UI (diagnostic virtual_text
  -- off, inlay hints opt-in), so override it with a no-op (the deep-merge lets
  -- our on_attach win) to keep terraform buffers as quiet as every other ft.
  terraformls = {
    filetypes = { "terraform", "terraform-vars" },
    on_attach = function() end,
  },
  html = { filetypes = { "html" } },
  cssls = { filetypes = { "css", "scss", "less" } },
  -- graphql-language-service-cli (`graphql-lsp`). Gated to the graphql filetype
  -- only: nvim-lspconfig's default list also attaches it to every tsx/jsx
  -- buffer (for embedded gql`...` tags), which would spin up a second server on
  -- all React files. workspace_required = true makes the server start only when
  -- its root_dir resolves — i.e. a graphql config exists (.graphqlrc* /
  -- graphql.config.*); without one it needs a schema to be useful, so we skip
  -- spawning a no-op node process on every stray .graphql buffer.
  graphql = { filetypes = { "graphql" }, workspace_required = true },
  marksman = { filetypes = { "markdown" } },
  -- Tilt's language server (tilt-dev/starlark-lsp) is `tilt lsp start`, a
  -- subcommand of the tilt binary itself, and this row deliberately runs the
  -- `tilt` already on PATH rather than a mason-installed one (mason does carry a
  -- `tilt` package). The server knows the builtins of the tilt it ships in, so
  -- the one that runs your `tilt up` is the one that should complete and
  -- document your Tiltfile — and mason prepends its bin dir to nvim's PATH, so
  -- a second tilt there would also shadow the real one in every :terminal.
  -- Without tilt on PATH core just skips the server (a line in lsp.log; no
  -- notification), so the row is harmless on a machine without it.
  -- lspconfig's defaults do the rest: filetypes { tiltfile } (core detects
  -- Tiltfile / Tiltfile.local / *.tiltfile), root at `.git`. See docs/tiltfile.md.
  tilt_ls = { filetypes = { "tiltfile" } },
  -- mdx_analyzer wraps tsserver, needs typescript lib. Falls back to
  -- mason's bundled typescript when the workspace has no node_modules.
  -- workspace.didChangeWatchedFiles.dynamicRegistration is disabled because
  -- the server registers a `**/*.{mdx}` watcher pattern, which Neovim 0.12's
  -- vim.glob rejects ("Invalid glob"), crashing the server on startup.
  mdx_analyzer = {
    filetypes = { "mdx" },
    capabilities = {
      workspace = {
        didChangeWatchedFiles = { dynamicRegistration = false },
      },
    },
    init_options = {
      typescript = {
        tsdk = vim.fn.stdpath("data")
          .. "/mason/packages/typescript-language-server/node_modules/typescript/lib",
      },
    },
  },
  -- biome and oxlint are the linter half of config.js_toolchain. Both are Rust,
  -- start in milliseconds and idle at a few MB, which is why they get language
  -- servers while ESLint (Node, one process per root) goes through a single
  -- shared eslint_d daemon in lua/plugins/nvim-lint.lua instead.
  --
  -- workspace_required is NOT set here: both servers already set it themselves
  -- (lspconfig/lsp/biome.lua, lspconfig/lsp/oxlint.lua). What they do NOT do is
  -- respect our repo boundary or our linter priority, so their root_dir is
  -- wrapped below.
  --
  -- biome ships a much wider default filetype list (json/jsonc/css/graphql on
  -- top of the four below) and it is narrowed here for the same reason the
  -- graphql row above is narrowed off tsx/jsx: those filetypes already have a
  -- server. json/jsonc are jsonls' (:38), css is cssls' (:52), graphql is the
  -- graphql server's (:60) — so a biome repo got two servers and duplicate
  -- diagnostics on every file of those kinds. It bought nothing either, because
  -- biome would only have contributed DIAGNOSTICS there: formatting for
  -- json/jsonc/css stays on unconditional prettier (config.formatters). The
  -- cost is real but small and bounded: in a biome repo you no longer see
  -- biome's own JSON/CSS rules in the editor, though they still fire in that
  -- repo's CI.
  --
  -- This is a STATIC per-server filetype list, NOT the conditional "stand tool
  -- Y down because tool X owns this project" that docs/js-toolchain.md
  -- deliberately rejects — jsonls and cssls stay attached unconditionally, so
  -- no file anywhere loses its linter. Narrowing which filetypes a server ever
  -- claims and suppressing a server based on what another tool is doing are
  -- different things; only the second one can open a coverage hole.
  biome = {
    filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact" },
  },
  oxlint = {
    filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact" },
  },
}

-- Buffer-local LSP keymaps. `]d` / `[d` come free from Neovim 0.11 defaults,
-- so only the non-default mappings are declared here.
--
-- TypeScript note: plain `textDocument/definition` on an imported symbol lands
-- on the import binding, not the real source. ts_ls exposes a custom command
-- `_typescript.goToSourceDefinition` that follows imports through to the
-- defining file; we prefer it for ts_ls buffers and fall back to the standard
-- definition if it returns nothing. Both halves live in config.tagstack, which
-- captures the return position BEFORE the request — `show_document`, which this
-- used to call, captures it when the reply lands, so a cursor that moved while
-- tsserver was thinking left `<C-t>` pointing at the wrong place.

-- A named group so these top-level autocmds are replaced (not stacked) if this
-- spec is ever re-evaluated (:Lazy reload, a test clearing package.loaded).
local lsp_group = vim.api.nvim_create_augroup("lsp_user", { clear = true })

-- Sort diagnostics by severity so the highest-severity one wins the single sign
-- slot (equal sign priorities otherwise let a Warning mask an Error on a shared
-- line) and the cursor float lists errors first.
--
-- Theme the gutter signs with nerd-font glyphs (severity-keyed text) so the sign
-- column reads at a glance instead of the default letters. virtual_text stays
-- off on purpose: messages surface in the CursorHold float below, not inline, to
-- keep the quiet UI uncluttered.
vim.diagnostic.config({
  severity_sort = true,
  signs = {
    text = {
      [vim.diagnostic.severity.ERROR] = "",
      [vim.diagnostic.severity.WARN] = "",
      [vim.diagnostic.severity.INFO] = "",
      [vim.diagnostic.severity.HINT] = "",
    },
  },
})

-- Show the diagnostic under the cursor in a floating window after the cursor
-- sits still for `updatetime` (250ms, set in options.lua). Virtual text is off
-- by default, so this is how full messages surface inline. `focus = false`
-- keeps the cursor in the buffer; `scope = "cursor"` limits the float to the
-- diagnostic on the exact cursor position, so when a line has several you can
-- move the cursor across each token to read them one at a time.
vim.api.nvim_create_autocmd("CursorHold", {
  group = lsp_group,
  callback = function(args)
    -- Skip the float window/sort/format work entirely when the cursor line
    -- carries no diagnostic (the common case) — open_float would otherwise
    -- materialize and filter the whole buffer's diagnostic set every CursorHold.
    local lnum = vim.api.nvim_win_get_cursor(0)[1] - 1
    if vim.tbl_isempty(vim.diagnostic.get(args.buf, { lnum = lnum })) then
      return
    end
    vim.diagnostic.open_float(nil, { focus = false, scope = "cursor" })
  end,
})

vim.api.nvim_create_autocmd("LspAttach", {
  group = lsp_group,
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    local tagstack = require("config.tagstack")
    local function map(lhs, rhs, desc)
      vim.keymap.set("n", lhs, rhs, { buffer = args.buf, silent = true, desc = desc })
    end

    local ft = vim.bo[args.buf].filetype
    if client and client.name == "ts_ls" then
      map("gd", function()
        require("config.tagstack").ts_source_definition(client, args.buf)
      end, "Goto source definition (ts_ls)")
      -- tsserver hosts ONE TypeScript per process and Neovim starts one client
      -- per root_dir, so in a monorepo whose packages pin different versions this
      -- buffer may be checked by a compiler its own package never chose. That
      -- produced both a false error and a swallowed real one in testing, so say
      -- so once rather than letting the diagnostics quietly disagree with the
      -- package's own build. See lua/config/lsp_tsdk.lua.
      require("config.lsp_tsdk").warn_mismatch(args.buf, client)
    elseif client and client.name == "pyright" then
      map("gd", tagstack.definition, "Goto definition")
      -- Buffer-local and pyright-gated for the same reason the ts_ls maps above
      -- are: the picker acts on the pyright client serving THIS buffer, so the
      -- key is a no-op anywhere else and shouldn't advertise itself there.
      map("<leader>ld", require("config.pyright_rules").open, "Python diagnostic rules")
      -- Say it once per project if a pyrightconfig.json / [tool.pyright] is
      -- discarding the severities recorded for this root — otherwise the picker
      -- looks like it worked and pyright quietly ignored all of it.
      require("config.pyright_rules").warn_shadowed(
        client.config and client.config.root_dir or client.root_dir
      )
    elseif ft_util.is_markdown(ft) then
      -- Smart gd: follow a wikilink if the cursor is on one, else LSP definition.
      -- Re-asserted here so marksman's attach doesn't overwrite the FileType map.
      map("gd", require("config.wikilinks").goto_definition, "Goto wikilink / definition")
    else
      map("gd", tagstack.definition, "Goto definition")
    end

    -- `grr` / `gri` / `grt` are Neovim 0.11+ global defaults calling
    -- vim.lsp.buf.* directly, so they inherit core's tagstack behaviour: nothing
    -- at all for references (buf.lua:868 is its own implementation and never
    -- pushes), and for the other two only when the server returns exactly one
    -- location. Overriding them buffer-locally routes all three through the one
    -- writer, so `<C-t>` means the same thing after any of them.
    map("grr", tagstack.references, "References")
    map("gri", tagstack.implementation, "Implementation")
    map("grt", tagstack.type_definition, "Type definition")

    local lsp_refs = require("config.lsp_refs")
    map("]r", lsp_refs.next, "Next LSP reference")
    map("[r", lsp_refs.prev, "Prev LSP reference")

    -- Restart the LSP client(s) on this buffer and re-attach. Handy after a
    -- file rename confuses the server (e.g. ts_ls "Already included file name
    -- ... only in casing"), or to pick up a change the servers never saw now
    -- that didChangeWatchedFiles is off (:343): stopping drops the stale
    -- in-memory project.
    --
    -- Re-attach runs through config.lsp_picker, NOT the `:edit` this used to do.
    -- Reloading the buffer with `:edit` broke the keymap twice over: it REFUSES
    -- a modified buffer (E37), and the clients are stopped by the time it
    -- throws, so a restart reached for mid-edit — the usual case — left the
    -- buffer with no server at all; and it only ever re-attached THIS buffer,
    -- while the stop had detached every sibling the client served.
    --
    -- The re-READ that `:edit` was also doing is still needed and now runs as a
    -- per-buffer `:checktime` inside restart_clients: didOpen serializes buffer
    -- lines, so a restart over a buffer that never re-read hands the fresh
    -- server the same text and gets the same diagnostics back.
    map("<leader>lr", function()
      local lsp_picker = require("config.lsp_picker")
      -- last_buf: this buffer resolves last, so in a mixed-version monorepo the
      -- new client runs the TypeScript THIS package pins (see config.lsp_tsdk).
      local stopped, reattached = lsp_picker.restart_clients(
        vim.lsp.get_clients({ bufnr = args.buf }),
        { last_buf = args.buf }
      )
      vim.notify(
        stopped == 0 and "no LSP clients on this buffer"
          or ("restarted %d client%s for %d buffer%s"):format(
            stopped,
            stopped == 1 and "" or "s",
            reattached,
            reattached == 1 and "" or "s"
          )
      )
    end, "Restart LSP on buffer")

    -- Inlay hints are off by default to keep the UI quiet; offer a per-buffer
    -- toggle under the <leader>u toggle group, but only when the attached server
    -- can actually produce them (capability-gated so the map isn't a no-op).
    -- Guard `supports_method` itself: a partial client (e.g. a test stub of
    -- get_client_by_id) may not carry the method, and the callback shouldn't
    -- error out of the rest of the attach over an optional feature.
    if client and client.supports_method and client:supports_method("textDocument/inlayHint") then
      map("<leader>uh", function()
        vim.lsp.inlay_hint.enable(
          not vim.lsp.inlay_hint.is_enabled({ bufnr = args.buf }),
          { bufnr = args.buf }
        )
      end, "Toggle inlay hints")
    end
  end,
})

return {
  {
    "mason-org/mason.nvim",
    cmd = "Mason",
    build = ":MasonUpdate",
    config = function()
      require("mason").setup()
    end,
  },
  {
    -- nvim-lspconfig ships default `lsp/<name>.lua` files (including `cmd`)
    -- that vim.lsp.config merges with our per-server overrides. Without it,
    -- `vim.lsp.config("gopls", {...})` errors out because `cmd` is nil.
    "neovim/nvim-lspconfig",
    lazy = true,
  },
  {
    -- The whole LSP stack is deferred to the first real file: FileType (which
    -- triggers vim.lsp.enable's attach) fires after BufReadPre for the same
    -- buffer, so capabilities are still registered before any server attaches.
    "mason-org/mason-lspconfig.nvim",
    event = { "BufReadPre", "BufNewFile" },
    dependencies = { "mason-org/mason.nvim", "neovim/nvim-lspconfig", "saghen/blink.cmp" },
    config = function()
      -- Tool installs are owned by mason-tool-installer (reads
      -- mason-tool-versions.lock); mason-lspconfig is kept only for
      -- vim.lsp.config integration, so ensure_installed is intentionally empty.
      require("mason-lspconfig").setup({
        ensure_installed = {},
        automatic_installation = false,
      })

      -- Advertise blink.cmp's completion capabilities (snippet support,
      -- additionalTextEdits for auto-imports, documentation resolve) to every
      -- server. Listed as a dependency above so blink is loaded by now.
      --
      -- Layered on top: config.lsp_fs_sync's capabilities, so every server is
      -- told from client init which workspace file operations we send
      -- (willRename/didRename/didCreate — ts_ls only registers its rename
      -- support when the client advertises it). This is just a static table
      -- (no nvim-tree load); the event subscription that actually fires the
      -- requests lives in nvim-tree's config.
      local blink = require("blink.cmp")
      local file_ops_caps = require("config.lsp_fs_sync").capabilities()

      -- Point ts_ls at the *project's* TypeScript. Left alone it walks upward
      -- from root_dir looking for node_modules/typescript — but lspconfig roots
      -- it at the nearest lockfile (the pnpm workspace root) while pnpm installs
      -- typescript in the leaf package below that root, so the search finds
      -- nothing and ts_ls falls back to mason's bundled major version. See
      -- lua/config/lsp_tsdk.lua. The resolver is wrapped, not replaced, so
      -- lspconfig keeps owning root detection (including its deno exclusion);
      -- we only observe the (bufnr, dir) pair it settles on.
      --
      -- config.lsp_root sits INSIDE the tsdk wrapper on purpose: it clamps the
      -- root back into the repo holding the buffer (a stray lockfile above a
      -- superproject otherwise roots one client over every lockfile-less
      -- submodule), and tsdk must memoize against the CLAMPED dir because
      -- before_init looks the memo up by config.root_dir. Clamping outside the
      -- wrapper measured worse than not clamping at all.
      local tsdk = require("config.lsp_tsdk")
      local lsp_root = require("config.lsp_root")
      local base_root_dir = vim.lsp.config.ts_ls and vim.lsp.config.ts_ls.root_dir
      if type(base_root_dir) == "function" then
        servers.ts_ls.root_dir = tsdk.wrap_root_dir(lsp_root.bound(base_root_dir))
        servers.ts_ls.before_init = tsdk.before_init
      end

      -- Per-project pyright rule severities. before_init is the one hook that
      -- runs AFTER root_dir is resolved but BEFORE the client is created, which
      -- is exactly what per-root settings need — and it must MUTATE
      -- config.settings, never reassign it: client.settings is already aliased
      -- to that table by then, so a reassignment is a silent no-op. The module
      -- owns that discipline; see lua/config/pyright_rules.lua.
      servers.pyright.before_init = require("config.pyright_rules").before_init

      -- :PyrightRules mirrors <leader>ld (the picker), for people who reach for
      -- commands — same split as :AIModel / <leader>am. Global rather than
      -- buffer-local, so on a non-Python buffer it can say WHY it cannot open
      -- instead of simply not existing.
      vim.api.nvim_create_user_command("PyrightRules", function()
        require("config.pyright_rules").open()
      end, { desc = "Per-project pyright diagnostic rules" })

      -- Gate the linter servers on our own detection, so the boundary rule and the
      -- linter priority order actually apply to them. Guarded the same way ts_ls's
      -- wiring is: if lspconfig ships no resolver for a server, leave it alone.
      -- The server name doubles as the linter slot name for both of these (see
      -- the LINTER table in config.js_toolchain), so a plain list is enough;
      -- reach for a name -> tool map only if a server's slot name ever diverges
      -- from its lspconfig name.
      local js_toolchain = require("config.js_toolchain")
      for _, name in ipairs({ "biome", "oxlint" }) do
        local base = vim.lsp.config[name] and vim.lsp.config[name].root_dir
        if type(base) == "function" then
          servers[name].root_dir = js_toolchain.gate_root_dir(base, name)
        end
      end

      -- Disable workspace/didChangeWatchedFiles for every server. With no
      -- watchman/fswatch on this box, Neovim services those registrations with a
      -- recursive libuv FSEvents walk rooted at each server's workspace — in a
      -- superproject that's one walk per submodule root, and every external file
      -- event then runs an lpeg glob match on the main loop (a storm during
      -- builds / branch switches / codegen). Turning it off trades server
      -- auto-refresh on out-of-editor changes for a quiet UI thread. What covers
      -- an open buffer is config.file_reload's sweep, which re-reads it and lets
      -- vim.lsp's on_reload re-send didOpen; <leader>lr (which now re-reads too)
      -- and <leader>r remain the manual hatches, and a file the server knows
      -- about but nothing has open still needs one of those.
      --
      -- mdx_analyzer already sets this for its own reason; merged before
      -- cfg.capabilities so any explicit per-server value wins.
      local no_watch = { workspace = { didChangeWatchedFiles = { dynamicRegistration = false } } }

      -- A tree create with no server yet to ask (a fresh session, the tree
      -- open, no Go buffer) leaves gopls's package clause owed. lsp_fs_sync
      -- holds those and collects on them here, at on_init rather than
      -- LspAttach: by LspAttach the buffer that started the server has already
      -- gone out as didOpen, and gopls will not stub a file it has open. See
      -- docs/lsp-fs-sync.md.
      local fs_sync = require("config.lsp_fs_sync")
      for name, cfg in pairs(servers) do
        cfg.capabilities = blink.get_lsp_capabilities(
          vim.tbl_deep_extend("force", file_ops_caps, no_watch, cfg.capabilities or {})
        )
        local server_on_init = cfg.on_init
        cfg.on_init = function(client, ...)
          fs_sync.on_client_init(client)
          if server_on_init then
            return server_on_init(client, ...)
          end
        end
        vim.lsp.config(name, cfg)
        vim.lsp.enable(name)
      end
    end,
  },
  {
    "WhoIsSethDaniel/mason-tool-installer.nvim",
    event = { "BufReadPre", "BufNewFile" },
    dependencies = { "mason-org/mason.nvim" },
    config = function()
      local lockfile = vim.fn.stdpath("config") .. "/mason-tool-versions.lock"
      local lf = io.open(lockfile, "r")
      if not lf then
        -- Warn instead of erroring: now that this runs lazily (first file
        -- read), an error here would also poison unrelated autocmd chains —
        -- and the test harness runs against an isolated config dir where the
        -- lockfile legitimately doesn't exist.
        vim.notify("missing " .. lockfile .. "; skipping tool install checks", vim.log.levels.WARN)
        return
      end
      local raw = lf:read("*a")
      lf:close()
      local versions = vim.json.decode(raw)

      local ensure_installed = {}
      for name, version in pairs(versions) do
        ensure_installed[#ensure_installed + 1] = { name, version = version }
      end

      require("mason-tool-installer").setup({
        ensure_installed = ensure_installed,
        auto_update = false,
        run_on_start = true,
        -- Skip tool-version verification when it already ran in the last day,
        -- instead of respawning checks on every launch.
        debounce_hours = 24,
      })

      -- The plugin triggers run_on_start from a VimEnter autocmd. Loading on
      -- BufReadPre usually happens before VimEnter (file on the command line),
      -- but when the first file is opened later — after VimEnter — that
      -- autocmd can never fire, so kick the (debounced) check explicitly.
      if vim.v.vim_did_enter == 1 then
        require("mason-tool-installer").check_install(false)
      end
    end,
  },
}
