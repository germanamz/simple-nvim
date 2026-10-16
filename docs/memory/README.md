# Memory

What coding agents have learned working on this config, one fact per file.
Every session starts with this index (it is pinned in `tusk.toml`), so add a
line here for each new memory. `CLAUDE.md` has the rules for writing one.

- [[nvim-tests-need-sandbox-disabled|Nvim tests need sandbox disabled]] — make test-smoke/test-e2e fail under Claude Code's sandbox (swap/parser/git writes); run with sandbox off.
- [[nvim-test-lsp-needs-mason-path|Nvim test-lsp needs mason PATH]] — plain make test-lsp self-skips as pending (exit 0); prepend ~/.local/share/nvim/mason/bin to PATH to exercise the real server.
- [[nvim-e2e-single-file-needs-minimal-init|Nvim e2e single file needs minimal_init]] — run one e2e spec via `PlenaryBustedDirectory <file> { minimal_init='tests/full_init.lua' }` (PlenaryBustedFile ignores the opts) or only bundled parsers attach.
- [[nvim-pty-probe-for-blink|Nvim pty probe for blink]] — verify blink menus/snippets in a real TUI via Python pty + --listen/--remote-expr; needs a draining reader thread or RPC deadlocks; `[` trigger vs mini.pairs finding.
- [[nvim-headless-no-insert-in-prompt|Nvim headless can't insert in prompt]] — headless e2e can't enter insert, and CursorMoved never fires in a script context (input is never drained); use nvim_exec_autocmds, or a PTY + --remote-send for real keys.
- [[nvim-headless-mini-operator-hang|Nvim headless mini operator hang]] — feedkeys for mini.surround/mini.ai operator+textobject keystrokes hangs in a -c luafile script; drive find_textobject (Lua API) instead of keys.
- [[nvim-float-winbar-row-trap|Nvim float winbar row trap]] — relative='win' floats render below the winbar (row=0 = first text row); headless position APIs report frame-relative and "prove" a bogus +1 offset.
- [[nvim-headless-window-height|Nvim headless window height]] — headless windows are ~43 rows, so scroll-dependent e2e specs must shrink vim.o.lines or winrestview's topline silently clamps.
- [[nvim-e2e-no-edit-lsp-filetypes|Nvim e2e: don't :edit LSP filetypes]] — :edit after the first isolated env hits a stale lsp.log path; API buffers avoid it but never attach a REAL server (use bufadd+bufload in one it); fake servers need :noautocmd filetype.
- [[nvim-refactor-stage-plan|Nvim refactor stage plan]] — staged quality refactor of the nvim config: goals, user decisions, P1→P8 phase order.
- [[multi-submodule-perf-changes|Multi-submodule perf changes]] — branch perf/multi-submodule: async pickers, LSP watchers off (no auto-refresh; use <leader>lr), large-file TS guard, git.root memo.
- [[multi-submodule-plan|Multi-submodule plan]] — staged plan (P1–P8 + full-recursion stage) for full multi-submodule support; branch feat/multi-submodule, P1+P2 done.
- [[claudecode-automode-no-ide-events|Claudecode auto-mode fires no IDE events]] — auto-accept edits write straight to disk, no openDiff/openFile; editor-follow needs a PostToolUse hook, not a plugin. Dropped claudecode.nvim.
- [[nvim-tree-ignore-filter|Nvim-tree ignore filter]] — builtin git OFF (kill-switch fix); ignore-hiding is config.ignore_filter (static set + async check-ignore oracle). Disabling builtin git exposed a latent SmartCodesRefreshed cwd-trailing-slash bug.
- [[nvim-tree-decorator-gotchas|Nvim-tree decorator gotchas]] — custom decorators get metatable-less api-node CLONES (fields only, no node methods → is_dotfile crash); decorators-list order = overlap winner (last wins). Grey/blue/teal ignore/dotfolder/symlink trio.
- [[spec-docs-in-repo-not-scratchpad|Spec docs in repo not scratchpad]] — specs/plans go in docs/ but stay UNCOMMITTED; docs of how things currently work do get committed (rewrite spec voice first).
- [[nvim-principles-review-2026-07|Nvim principles review 2026-07]] — 41-finding quality pass (util/pool, util/state, decorator factory, 12 bug fixes) + the refuted proposals NOT to re-propose.
- [[plenary-curl-error-semantics|Plenary curl error semantics]] — plenary.curl raises inside a luv callback (pcall can't catch) unless opts.on_error is passed; timeout is sync-only, use raw --max-time async.
- [[nvim-leak-audit-2026-07|Nvim leak audit 2026-07]] — 96%-CPU/400GB report: VSZ red herring, no config runaway confirmed, minuet→Ollama is the one pinned burner; capture playbook in docs/leak-diagnostics.md.
- [[smart-files-submodule-perf-2026-07|Smart-files submodule perf 2026-07]] — <leader><leader> slow-open on repos with hundreds of submodules is `git submodule status --recursive` (~7s); fix via cheap .gitmodules discovery (~20×); design+P1 plan in docs/.
- [[nvim-tree-workspace-branch-status|Nvim-tree workspace branch status]] — superproject + per-submodule branch/status in nvim-tree via config.repo_status (RepoStatusChanged event) + config.nvim_tree_submodule (after-decorator, resolves only when visible).
- [[nvim-tree-git-perf-tiered|Nvim-tree git perf tiered]] — branch perf/nvim-tree-git: util.git.index_key state-cache + config.submodule_status kills the per-focus scan storm across hundreds of submodules; Tier 0 --ignore-submodules=dirty surfaces bumped submodules.
- [[ts-ls-wrong-typescript-pnpm|Ts_ls ran wrong TypeScript in pnpm monorepos]] — upward-only lib search + lockfile root missed pnpm's leaf install → mason's bundled TS, a major ahead of the project's; fixed via config.lsp_tsdk.
- [[lsp-stale-on-tree-delete-rename|Lsp stale on tree delete/rename]] — watchers-off starves gopls of fs changes → error storms; shipped as config/lsp_fs_sync.lua, documented in docs/lsp-fs-sync.md.
- [[js-toolchain-detection-plan|Js toolchain detection]] — shipped 2026-07-31: per-project formatter/linter dispatch; the "gate on configured, not on handles-this-file" rule, prettierd's own bundled prettier, and the two `make sync` no-ops.
- [[gitsigns-base-is-blame-revision|Gitsigns base is the blame revision]] — a global review base made submodule buffers blame the latest committer; per-buffer bases via nvim_buf_call in config.gitsigns_base.
- [[nvim-ephemeral-extmark-no-line-hl|Ephemeral extmarks ignore line_hl_group]] — accepted without error, never painted; use persistent marks keyed on changedtick+filetype, and pty-probe with a control row.
- [[nvim-lsp-semantic-tokens-outrank-treesitter|LSP semantic tokens outrank treesitter]] — prio 125 vs 100, so capture-level tweaks need wiring twice; servers disagree on definition/declaration, and extmark attrs OR together.
- [[cmux-browser-from-nvim|Cmux browser from nvim]] — nvim runs inside cmux; `cmux browser open|goto` puts docs URLs in an in-app pane (store surface UUID, detect via CMUX_SURFACE_ID).
- [[processes-that-outlive-nvim|Processes that outlive nvim]] — the config leaks nothing; prettierd is per-cwd with no idle timeout, eslint_d idle-exits; stale cmux port badges are a cmux bug.
- [[nvim-pty-probe-key-timing|Nvim pty probe key timing]] — one key per os.write (~0.8s apart) or bursts fake "motion ignored" bugs; one case per process; keys-in/file-out beats --remote-expr.
- [[minuet-stale-ghost-text|Minuet stale ghost text — FIXED]] — no changedtick check (virtualtext.lua:252) + throttle drops keystrokes (:288); shipped config.minuet_guard + throttle=0, unreported upstream.
- [[qwen-fim-ollama-template-blocker|Qwen FIM blocked by Ollama templates]] — no Qwen3-era tag can replace qwen2.5-coder:7b-base; missing template layer → /v1/completions 400s.
- [[minuet-multicursor-accept|Minuet multicursor accept — FIXED]] — AI accept hit one cursor because multicursor replays the REDO RECORD, not getreg("."); fixed via nvim_paste, insert-mode only.
- [[multicursor-autopairs-conflict|Multicursor autopairs conflict]] — multicursor replays inserts from getreg("."); mini.pairs + <CR> inside the pair truncates it, fixed by neutralising openers in the keymap layer.
- [[pyright-per-project-dead-ends|Pyright per-project dead ends]] — shipped `<leader>ld` rule picker; the REFUTED alternatives (typeCheckingMode=basic, "hint", publishDiagnostics hooks, neoconf, exrc, reassigning config.settings) not to re-propose.
- [[nvim-tagstack-api-traps|Nvim tagstack API traps]] — :tag is E433 for LSP frames (stores origin only); settagstack resets curidx unless written alone; quickfix <CR> interception over- AND under-fires.
- [[nvim-virtual-lines-and-headless-lies|Virt_lines traps + two more headless lies]] — virt_lines silently do not render on closed folds or when ephemeral; headless composites relative='win' floats at the origin; state() is "oS" with no UI.
- [[nvim-hidden-buffer-edit-traps|Nvim hidden-buffer edit traps]] — no BufModifiedSet/TextChanged on hidden-buffer API edits, nvim_buf_attach refuses unloaded buffers, buffer names are realpath'd; nvim-tree FolderCreated passes the whole target path.
- [[nvim-typeahead-batching-expr-maps|Nvim typeahead batching vs expr maps]] — feedkeys bursts evaluate the NEXT insert expr map before a preceding normal char lands (insertchar peek); split flows into two insert sessions; <C-u> deletes only chars typed this session, <C-w> clears a leader to the indent.
- [[nvim-checktime-reload-traps|Nvim checktime/reload traps]] — autoread needs a check nothing runs; bare :checktime skips hidden buffers; FileChangedShell suppressed under autocmd_busy (headless lies); :checktime's Ex try context unwinds User consumers.
- [[agent-comment-channels-2026-09|Agent comment channels]] — what can carry nvim→agent review comments: ACP needs stdio subprocess, Claude's IDE ws has only 3 prose-less methods, mcp__ide__ custom tools, cmux send.
- [[cmux-send-targeting-hazards|Cmux send targeting hazards]] — rpc paste/send_text ignore surfaceId (hit the ACTIVE surface); address by id not ref; no backslash escape, real newline = Enter.
- [[nvim-exec-autocmds-wrong-buffer|Nvim_exec_autocmds fires on the wrong buffer]] — {buffer=b} sets <abuf> but never makes b current, so runtime ftplugins setlocal onto the buffer you're standing in; wrap in nvim_buf_call.
- [[clang-format-fallback-style|Clang-format fallback style]] — --fallback-style rejects inline YAML, so the no-config style is a gated --style; conform function-override + prepend_args mechanics.
- [[hover-docs-devdocs|Hover docs via DevDocs]] — K in C/C++/Python appends offline DevDocs excerpts (shipped on main 2026-09-15, docs/hover-docs.md); bundle facts + refuted alternatives.
- [[cmux-terminal-cwd|Cmux terminal cwd]] — <leader>tt/tv/th: new-split has no cwd flag but rpc surface.split takes working_directory; typed --command is eaten by a shell startup prompt; safe probing.
- [[nvim-tempname-vs-getcwd-symlink|Tempname vs getcwd symlink]] — tempname() is /tmp/... but getcwd() after chdir is /private/tmp/...; build spec paths from getcwd() or cwd-relative predicates silently fail open.
- [[nvim-zig-format-flake|Zig format-on-save flake]] — the zigfmt e2e can time out under full `make test` load; re-run the spec alone before calling it a regression.
