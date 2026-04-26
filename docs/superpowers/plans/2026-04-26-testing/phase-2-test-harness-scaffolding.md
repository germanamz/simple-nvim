# Phase 2: Test harness scaffolding

**Prerequisites:** Phase 1 complete.
**Can run in parallel with:** nothing. Phases 3, 4, 5 depend on this.
**Estimated tasks:** 6

## Inherits From

After Phase 1, the codebase has:
- `.tool-versions`, `mason-tool-versions.lock`, `tests/parser-revisions.lua` pinning all external versions.
- `init.lua` gated on `NVIM_BOOTSTRAP`. Setting `NVIM_BOOTSTRAP=0` skips plugin loading.
- `lua/plugins/lsp.lua` and `lua/plugins/treesitter.lua` install at pinned versions/revisions.
- `Makefile` with `warm`, `update`, `lint`, `fmt` targets. `lint`/`fmt` run stylua on `lua` and `init.lua` (no `tests/` yet).
- `scripts/warm-cache.sh` and `scripts/update-pins.sh` orchestrate the determinism layer.
- `~/.local/share/nvim` is assumed pre-warmed (`make warm` has been run).

## Goal

Create the test harness: init scripts, helpers, build targets, placeholder specs, and stylua config. Phases 3–5 add real specs into the directories created here. After this phase, `make test`, `make test-unit`, `make test-smoke`, `make test-e2e`, `make test-lsp` all run and pass against placeholder specs.

## Context

- Design spec sections: "Repo layout", "Helpers in detail", "Local parity — Makefile".
- The phase docs for 3, 4, 5, 6 (in this same plans dir) describe the specs that will populate the directories created here. The harness must support all of them.

## Tasks

### Task 1: init scripts (`tests/minimal_init.lua`, `tests/full_init.lua`)

`tests/minimal_init.lua`:

```lua
-- Minimal harness for unit tests: plenary only, plus the project's lua/ on rtp.
-- Runs against a pre-warmed cache (`make warm` first).
vim.env.NVIM_BOOTSTRAP = "0"

local data = vim.fn.stdpath("data")
vim.opt.rtp:prepend(data .. "/lazy/plenary.nvim")

local config_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(config_dir)

package.path = config_dir .. "/tests/?.lua;" .. config_dir .. "/tests/?/init.lua;" .. package.path
```

`tests/full_init.lua`:

```lua
-- Full harness for smoke + e2e tests: loads the real init.lua against a
-- pre-warmed cache. Plugin install skipped via NVIM_BOOTSTRAP=0; lazy still
-- resolves plugin specs from the cache for `:Lazy` introspection.
vim.env.NVIM_BOOTSTRAP = "0"

local config_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.runtimepath:prepend(config_dir)
package.path = config_dir .. "/tests/?.lua;" .. config_dir .. "/tests/?/init.lua;" .. package.path

dofile(config_dir .. "/init.lua")

require("lazy").setup("plugins", {
  install = { missing = false },
  change_detection = { enabled = false },
})

vim.opt.rtp:prepend(vim.fn.stdpath("data") .. "/lazy/plenary.nvim")
```

**Acceptance:** `nvim --headless -u tests/minimal_init.lua +qa` exits 0. `nvim --headless -u tests/full_init.lua +qa` exits 0 against a warm cache.

### Task 2: `nvim_env.lua` and `wait.lua` helpers

`tests/helpers/nvim_env.lua`:

```lua
local M = {}

function M.setup_isolated_env()
  local root = vim.fn.tempname() .. "-nvim-test"
  vim.fn.mkdir(root, "p")
  for _, sub in ipairs({ "home", "config", "data", "state", "cache" }) do
    vim.fn.mkdir(root .. "/" .. sub, "p")
  end
  vim.fn.mkdir(root .. "/data/nvim", "p")
  local host_lazy = vim.fn.expand("~/.local/share/nvim/lazy")
  local link_path = root .. "/data/nvim/lazy"
  -- Idempotent: remove any pre-existing symlink/dir before re-creating.
  if vim.uv.fs_lstat(link_path) then
    vim.fn.delete(link_path, "rf")
  end
  local ok, err = vim.uv.fs_symlink(host_lazy, link_path)
  if not ok then error("failed to symlink lazy cache: " .. tostring(err)) end

  vim.env.HOME = root .. "/home"
  vim.env.XDG_CONFIG_HOME = root .. "/config"
  vim.env.XDG_DATA_HOME = root .. "/data"
  vim.env.XDG_STATE_HOME = root .. "/state"
  vim.env.XDG_CACHE_HOME = root .. "/cache"
  vim.env.NVIM_BOOTSTRAP = "0"
  vim.env.TZ = "UTC"
  return root
end

function M.teardown(root)
  if root and vim.fn.isdirectory(root) == 1 then
    vim.fn.delete(root, "rf")
  end
end

return M
```

`tests/helpers/wait.lua`:

```lua
local M = {}

local DEFAULT_TIMEOUT = 1500
local INTERVAL = 20

function M.wait_for(predicate, timeout, message)
  timeout = timeout or DEFAULT_TIMEOUT
  message = message or "predicate did not become true"
  local ok = vim.wait(timeout, predicate, INTERVAL)
  if not ok then
    error("wait_for timed out after " .. timeout .. "ms: " .. message, 2)
  end
end

function M.wait_for_buffer(opts)
  M.wait_for(function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[buf].filetype == opts.filetype then return true end
    end
    return false
  end, opts.timeout, "buffer with filetype=" .. tostring(opts.filetype) .. " never appeared")
end

function M.wait_for_event(pattern, timeout)
  local fired = false
  local id = vim.api.nvim_create_autocmd("User", {
    pattern = pattern,
    once = true,
    callback = function() fired = true end,
  })
  M.wait_for(function() return fired end, timeout, "event " .. pattern .. " never fired")
  pcall(vim.api.nvim_del_autocmd, id)
end

return M
```

**Acceptance:** Both `require()` cleanly. `setup_isolated_env()` returns a path containing `home/`, `config/`, `data/nvim/lazy` (symlink). `wait_for(function() return true end)` returns immediately. `wait_for(function() return false end, 100)` errors with a clear timeout message.

### Task 3: `keymap_probe.lua` and `git_fixture.lua` helpers

`tests/helpers/keymap_probe.lua`:

```lua
local M = {}

function M.resolve(mode, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, mode)) do
    if m.lhs == lhs then
      return { callback = m.callback, rhs = m.rhs, buffer = vim.api.nvim_get_current_buf() }
    end
  end
  for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
    if m.lhs == lhs then
      return { callback = m.callback, rhs = m.rhs, buffer = nil }
    end
  end
  return nil
end

return M
```

`<leader>` is stored expanded in the maps table (default space). Callers pass the expanded form (e.g., `" ff"` for `<leader>ff`).

`tests/helpers/git_fixture.lua`:

```lua
local M = {}

local FIXED_DATE = "2026-04-26T12:00:00Z"

local function run(cwd, ...)
  local args = vim.list_extend({ "git", "-C", cwd }, { ... })
  local out = vim.fn.systemlist(args)
  if vim.v.shell_error ~= 0 then
    error("git failed in " .. cwd .. ": " .. table.concat({ ... }, " ") .. "\n" .. table.concat(out, "\n"))
  end
  return out
end

local function commit(cwd, message)
  vim.fn.setenv("GIT_AUTHOR_DATE", FIXED_DATE)
  vim.fn.setenv("GIT_COMMITTER_DATE", FIXED_DATE)
  vim.fn.setenv("GIT_AUTHOR_NAME", "Test User")
  vim.fn.setenv("GIT_AUTHOR_EMAIL", "test@example.invalid")
  vim.fn.setenv("GIT_COMMITTER_NAME", "Test User")
  vim.fn.setenv("GIT_COMMITTER_EMAIL", "test@example.invalid")
  run(cwd, "add", "-A")
  run(cwd, "commit", "-m", message, "--no-gpg-sign", "--allow-empty")
end

local function write_file(cwd, path, content)
  local full = cwd .. "/" .. path
  vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
  local f = assert(io.open(full, "w"))
  f:write(content)
  f:close()
end

-- Recipe:
-- {
--   commits = { { files = { ["a.lua"] = "..." }, message = "init" }, ... },
--   staged = { ["x.lua"] = "..." },
--   modified = { ["y.lua"] = "..." },   -- modify already-committed file
--   untracked = { ["z.lua"] = "..." },
--   base_branch = "main",
-- }
function M.repo(opts)
  opts = opts or {}
  local root = vim.fn.tempname() .. "-fixture-repo"
  vim.fn.mkdir(root, "p")
  run(root, "init", "-q", "--initial-branch=" .. (opts.base_branch or "main"))
  run(root, "config", "user.email", "test@example.invalid")
  run(root, "config", "user.name", "Test User")
  run(root, "config", "commit.gpgsign", "false")

  for _, c in ipairs(opts.commits or {}) do
    for path, content in pairs(c.files or {}) do
      write_file(root, path, content)
    end
    commit(root, c.message or "commit")
  end

  for path, content in pairs(opts.staged or {}) do
    write_file(root, path, content)
    run(root, "add", path)
  end

  for path, content in pairs(opts.modified or {}) do
    write_file(root, path, content)
  end

  for path, content in pairs(opts.untracked or {}) do
    write_file(root, path, content)
  end

  return root
end

function M.with_remote(repo, name)
  name = name or "origin"
  local clone = vim.fn.tempname() .. "-fixture-remote"
  run(repo, "clone", "--bare", "--quiet", repo, clone)
  run(repo, "remote", "add", name, clone)
  run(repo, "fetch", "-q", name)
  return clone
end

return M
```

**Acceptance:** Each `require`s cleanly. `git_fixture.repo({ commits = {{ files = { ["a.lua"]="x" }}} })` returns a path with `a.lua` committed at the fixed date. Two consecutive calls with the same recipe produce identical commit SHAs.

### Task 4: extend `Makefile` with test targets + `stylua.toml`

Append to the `Makefile`:

```makefile
.PHONY: test test-unit test-smoke test-e2e test-lsp

test: test-unit test-smoke test-e2e

test-unit:
	@nvim --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/spec/unit { minimal_init = 'tests/minimal_init.lua' }"

test-smoke:
	@nvim --headless -u tests/full_init.lua \
		-c "PlenaryBustedDirectory tests/spec/smoke { minimal_init = 'tests/full_init.lua' }"

test-e2e:
	@nvim --headless -u tests/full_init.lua \
		-c "PlenaryBustedDirectory tests/spec/e2e { minimal_init = 'tests/full_init.lua' }"

test-lsp:
	@nvim --headless -u tests/full_init.lua \
		-c "PlenaryBustedDirectory tests/spec/e2e-lsp { minimal_init = 'tests/full_init.lua' }"
```

Update existing `lint` and `fmt` targets to include `tests/`:

```makefile
lint:
	@stylua --check lua init.lua tests

fmt:
	@stylua lua init.lua tests
```

Create `stylua.toml` at repo root:

```toml
column_width = 100
line_endings = "Unix"
indent_type = "Spaces"
indent_width = 2
quote_style = "AutoPreferDouble"
call_parentheses = "Always"
```

**Acceptance:** All `make test-*` exit 0 (against the placeholders from Task 5). `make lint` exits 0 against `lua/`, `init.lua`, `tests/`.

### Task 5: placeholder specs (4 dirs)

Create `tests/spec/unit/_placeholder_spec.lua`, `tests/spec/smoke/_placeholder_spec.lua`, `tests/spec/e2e/_placeholder_spec.lua`, `tests/spec/e2e-lsp/_placeholder_spec.lua`. Each:

```lua
-- Placeholder spec to keep PlenaryBustedDirectory a no-op until real specs land.
-- Removed in Phase {N}: see docs/superpowers/plans/2026-04-26-testing/.
describe("placeholder", function()
  it("is a no-op", function()
    assert.is_true(true)
  end)
end)
```

Replace `{N}` per file: unit → 3, smoke → 4, e2e → 5, e2e-lsp → 6.

**Acceptance:** All four placeholders run and pass under their respective `make test-*` targets.

### Task 6: `tests/README.md`

Create `tests/README.md` documenting:

1. One-time setup: `make warm` populates the deterministic cache.
2. Running all tests: `make test` (unit + smoke + e2e). `make test-lsp` runs the slow LSP lane.
3. Running a single layer: `make test-unit`, `make test-smoke`, `make test-e2e`, `make test-lsp`.
4. Running a single spec file:
   ```
   nvim --headless -u tests/full_init.lua \
     -c "PlenaryBustedFile tests/spec/<dir>/<file>_spec.lua"
   ```
5. Updating pins: `make update`, then review and commit the diff.
6. Layout: what each `tests/spec/<dir>/` is for; how `tests/helpers/` is organized.
7. Note that `_placeholder_spec.lua` files are bridge code removed by phases 3–6.

**Acceptance:** Commands documented all work as written.

## User-visible behaviors that must still work

- All Phase 1 acceptance behaviors (NVIM_BOOTSTRAP gate, `make warm`/`update`, `nvim` daily use).
- `make test`, `make test-unit`, `make test-smoke`, `make test-e2e`, `make test-lsp` all succeed against placeholders.
- `make lint` passes on `lua/`, `init.lua`, and `tests/`.

## Verification

```bash
make warm
make test
make lint
nvim --headless -u tests/minimal_init.lua +qa
nvim --headless -u tests/full_init.lua +qa
```

## Changes Introduced

**New files:**
- `tests/minimal_init.lua`, `tests/full_init.lua`
- `tests/helpers/nvim_env.lua`, `tests/helpers/wait.lua`, `tests/helpers/keymap_probe.lua`, `tests/helpers/git_fixture.lua`
- `tests/spec/unit/_placeholder_spec.lua`, `tests/spec/smoke/_placeholder_spec.lua`, `tests/spec/e2e/_placeholder_spec.lua`, `tests/spec/e2e-lsp/_placeholder_spec.lua`
- `tests/README.md`
- `stylua.toml`

**Modified files:**
- `Makefile` — adds `test`, `test-unit`, `test-smoke`, `test-e2e`, `test-lsp`; widens `lint`/`fmt` to include `tests/`.

**Bridge code (with removal targets):**
- `tests/spec/unit/_placeholder_spec.lua` — Phase 3.
- `tests/spec/smoke/_placeholder_spec.lua` — Phase 4.
- `tests/spec/e2e/_placeholder_spec.lua` — Phase 5.
- `tests/spec/e2e-lsp/_placeholder_spec.lua` — Phase 6.

**No new env vars, no new dependencies.**
