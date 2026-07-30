-- Make ts_ls run the *project's* TypeScript instead of its bundled one.
--
-- The bug this fixes
-- ------------------
-- typescript-language-server picks its TypeScript library with an UPWARD-only
-- walk from root_dir (`findPathToModule` over `MODULE_FOLDERS` =
-- node_modules/typescript/lib, .vscode/pnpify/…, .yarn/sdks/…). lspconfig roots
-- ts_ls at the nearest package-manager *lockfile* — for pnpm that is the
-- workspace root — but pnpm's isolated node_modules installs `typescript` in
-- the leaf package (apps/site/node_modules/typescript, a symlink into
-- .pnpm/…), which sits BELOW the lockfile root and is therefore never on the
-- upward path. The search falls off the top of the tree and ts_ls silently uses
-- its own bundled TypeScript.
--
-- That bundled copy is whatever mason's typescript-language-server pinned — in
-- practice a different *major* version than the project (mason ships 6.x while
-- projects pin 5.x). The editor then disagrees with `tsc`: a shared base config
-- (`extends: "@repo/tsconfig/base.json"`) written for 5.x draws TS5107
-- deprecation errors under a 6.x server on options the project builds cleanly
-- with. Superprojects make it worse, not different: every submodule pins its
-- own TypeScript, so the more submodules the likelier any given buffer is being
-- checked by the wrong compiler.
--
-- The fix: resolve the library from the BUFFER's directory upward (which
-- reaches the leaf package) and hand ts_ls the answer as
-- `initializationOptions.tsserver.path`, the option its own
-- `getUserSettingVersion()` honors ahead of everything else.
--
-- Wiring (lua/plugins/lsp.lua): `root_dir` is wrapped rather than replaced —
-- lspconfig's own resolver keeps deciding the root (including its deno
-- exclusion), we only observe the (bufnr, dir) pair it settles on, because that
-- is the one moment both are in hand. The answer is memoized under the root and
-- drained by `before_init`, which runs immediately afterwards for that client.
--
-- Scope note: tsserver hosts one TypeScript per process and Neovim starts one
-- client per root_dir, so a monorepo whose packages pin different versions runs
-- just one of them for every package under that root. Which one is decided by
-- the LAST resolution written before that client's before_init runs — not by the
-- first file opened. Client creation is deferred, so opening files one at a time
-- (waiting for each attach) makes that the first buffer, while a concurrent open
-- (`nvim -p a b`, session restore, a telescope/quickfix multi-open) resolves
-- every buffer before any client starts and the last one wins. `<leader>lr`
-- re-resolves from the current buffer, but it also detaches every sibling buffer
-- under that root and they do not re-attach on their own — so exactly one
-- package under a mixed-version root can be correct at a time.
local M = {}

-- Same candidates typescript-language-server looks for, in its order.
local MODULE_FOLDERS = {
  "node_modules/typescript/lib",
  ".vscode/pnpify/typescript/lib",
  ".yarn/sdks/typescript/lib",
}

-- root_dir -> tsserver.js path, filled by wrap_root_dir, read by before_init.
local memo = {}

local function tsserver_in(dir)
  for _, folder in ipairs(MODULE_FOLDERS) do
    local candidate = vim.fs.joinpath(dir, folder, "tsserver.js")
    -- Existence, not just the directory: a half-installed or dangling-symlink
    -- node_modules/typescript would otherwise point tsserver at nothing.
    if vim.uv.fs_stat(candidate) then
      return candidate
    end
  end
  -- Explicit: falling off the end propagates ZERO values, not nil, which makes
  -- `tostring(resolve(...))` raise "value expected" and quietly turns any
  -- `assert.is_nil(resolve(...))` into a no-argument call that cannot fail.
  return nil
end

-- Both ends of the containment test must be in the same symlink form or the
-- walk gives up immediately. They routinely are not: nvim_buf_set_name reports
-- the realpath (/private/var/… on macOS) while root_dir keeps whatever
-- vim.fs.root walked (/var/…), and symlinked package/worktree dirs are the norm
-- in the very monorepos this module exists for.
local function real(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

--- Path of the tsserver.js that should serve files under `start_dir`, or nil.
---
--- Searches `start_dir` upward and stops after `root_dir`. The bound matters:
--- ts_ls already walks above the root on its own, and in a superproject a stray
--- ~/node_modules/typescript is unrelated to the project — better to return nil
--- and leave ts_ls its documented fallback than to pin a random version.
---@param start_dir string
---@param root_dir string|nil
---@return string|nil
function M.resolve(start_dir, root_dir)
  local root = root_dir and real(root_dir) or nil
  local dir = real(start_dir)

  if root then
    -- `start_dir` outside the root (unnamed buffer falling back to a cwd
    -- elsewhere) still deserves the root's own install.
    if not (dir == root or vim.startswith(dir, root .. "/")) then
      return tsserver_in(root)
    end
    for d in vim.fs.parents(vim.fs.joinpath(dir, "x")) do
      local hit = tsserver_in(d)
      if hit then
        return hit
      end
      if d == root then
        return nil
      end
    end
    return nil
  end

  return tsserver_in(dir)
end

--- Record the library resolved for a client root, for `before_init` to pick up.
function M.remember(root_dir, tsserver_path)
  memo[root_dir] = tsserver_path
end

-- What `before_init` actually sent, per root: a path, or `false` when we injected
-- nothing and ts_ls resolved its own library. Distinct from `memo`, which is the
-- pending handoff — this is the record of what the live client is running, and it
-- is what tells a later-attaching buffer whether it is being checked by the
-- compiler its own package pins.
local sent = {}

-- tsserver.js path -> version string, or false when unreadable. All three
-- MODULE_FOLDERS end in `typescript/lib`, so the manifest is one level up.
local versions = {}

--- Version of the TypeScript install owning `tsserver_path`, or nil.
---@param tsserver_path string|nil
---@return string|nil
function M.version_of(tsserver_path)
  if not tsserver_path then
    return nil
  end
  local hit = versions[tsserver_path]
  if hit ~= nil then
    return hit or nil
  end
  local manifest = vim.fs.normalize(vim.fs.joinpath(tsserver_path, "..", "..", "package.json"))
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(manifest), "\n"))
  end)
  local version = ok and type(data) == "table" and data.version or nil
  versions[tsserver_path] = version or false
  return version
end

-- Major only, and the same threshold the split uses — the two must agree or the
-- warning nags about drift the split deliberately treats as benign (measured on
-- ~/projects/expenses: 5.6.2 vs 5.5.4 changes no diagnostic and splitting it
-- costs +508 MB). A major gap is where the compilers genuinely disagree: a false
-- TS2503 under one and a swallowed real one under the other, both measured.
---@param version string|nil
---@return string|nil
local function major(version)
  return version and version:match("^(%d+)") or nil
end

--- Is this buffer being served by a TypeScript whose MAJOR differs from the one
--- its own package pins? Returns { want, got, own } or nil.
---
--- Compared by version, never by path: pnpm gives every package its own symlink
--- into the store, so identical versions have different resolved paths and a path
--- comparison would fire on every healthy monorepo.
---@param bufnr integer
---@param root_dir string|nil
function M.mismatch(bufnr, root_dir)
  local ledger = sent[root_dir]
  if ledger == nil then -- no client for this root has initialized yet
    return nil
  end
  local own = M.resolve(require("util.path").buf_start_dir(bufnr), root_dir)
  local want = M.version_of(own)
  if not want then -- this package pins nothing; nothing to be wrong about
    return nil
  end
  local got = ledger and M.version_of(ledger) or nil
  -- `got == nil` means the live client resolved its own library and we cannot
  -- name its version — still worth reporting, since this package pins one.
  if got and major(got) == major(want) then
    return nil
  end
  return { want = want, got = got, own = own }
end

--- Nearest directory at or above `start_dir` that owns a tsconfig/jsconfig,
--- searched strictly BELOW `root_dir` — the client root a divergent package can
--- be split out to. nil when there is nothing below the root to split to.
---@param start_dir string
---@param root_dir string|nil
---@return string|nil
function M.package_root(start_dir, root_dir)
  local root = root_dir and real(root_dir) or nil
  local dir = real(start_dir)
  if not root or not (dir == root or vim.startswith(dir, root .. "/")) then
    return nil
  end
  for d in vim.fs.parents(vim.fs.joinpath(dir, "x")) do
    if d == root then
      return nil -- reached the workspace root without finding a nearer package
    end
    for _, marker in ipairs({ "tsconfig.json", "jsconfig.json" }) do
      if vim.uv.fs_stat(vim.fs.joinpath(d, marker)) then
        return d
      end
    end
  end
  return nil
end

-- Test seam so specs can capture the message without a real UI.
M._notify = nil

-- One warning per (root, got, want): a monorepo has many buffers per package and
-- the fact is a property of the client, not of the file you happened to open.
local warned = {}

--- Warn once that `bufnr` is being checked by the wrong TypeScript.
---@param bufnr integer
---@param client vim.lsp.Client
function M.warn_mismatch(bufnr, client)
  local root = client and (client.config and client.config.root_dir or client.root_dir)
  local m = M.mismatch(bufnr, root)
  if not m then
    return
  end
  local key = table.concat({ root, tostring(m.got), m.want }, "\0")
  if warned[key] then
    return
  end
  warned[key] = true
  -- m.own is <pkg>/node_modules/typescript/lib/tsserver.js; four levels up names
  -- the package the reader has to go and look at.
  local pkg = vim.fs.normalize(vim.fs.joinpath(m.own, "..", "..", "..", ".."))
  local msg = ("ts_ls in %s runs TypeScript %s; %s pins %s. Diagnostics here may not match its build — <leader>lr in this package switches to it."):format(
    vim.fs.basename(root or "?"),
    m.got or "its own resolved copy",
    vim.fn.fnamemodify(pkg, ":~:."),
    m.want
  )
  local notify = M._notify or vim.notify
  notify(msg, vim.log.levels.WARN)
end

-- Wrappers we handed out, so re-running the plugin spec (:Lazy reload, a test
-- clearing package.loaded) re-wraps lspconfig's resolver instead of stacking a
-- second layer on our own.
local wrapped = setmetatable({}, { __mode = "k" })

--- Did `wrap_root_dir` produce this function? config.lsp_root consults this so
--- the two wrappers cannot layer on each other across config runs.
---@param fn function|nil
---@return boolean
function M.is_wrapped(fn)
  return fn ~= nil and wrapped[fn] == true
end

--- Wrap lspconfig's `root_dir` resolver so we can see the buffer and the root
--- it chose together. The dir is passed through untouched.
---@param base fun(bufnr: integer, on_dir: fun(dir: string|nil))
function M.wrap_root_dir(base)
  if wrapped[base] then
    return base
  end
  local fn = function(bufnr, on_dir)
    base(bufnr, function(dir)
      if not dir then
        return on_dir(dir)
      end
      local start = require("util.path").buf_start_dir(bufnr)
      local own = M.resolve(start, dir)

      -- Divergent package: a client for this root is already running a
      -- different MAJOR TypeScript than this package pins, so give the package
      -- its own client rather than let one compiler check both. Driven by the
      -- ledger and this buffer's own resolution — never by enumerating workspace
      -- globs, which would override installs the globs cannot see, be defeated by
      -- a stale root devDependency, and cost ~1 s on a recursive `packages/**`
      -- tree. Splits only packages you actually open.
      local live = sent[dir]
      local own_major, live_major = major(M.version_of(own)), major(M.version_of(live or nil))
      if own_major and live_major and own_major ~= live_major then
        local pkg = M.package_root(start, dir)
        if pkg then
          M.remember(pkg, own)
          return on_dir(pkg)
        end
      end

      -- Recorded unconditionally, nil included. The memo is a handoff to
      -- before_init, not a cache: a package with no typescript of its own must
      -- fall back to ts_ls's own resolution rather than inherit whatever a
      -- sibling package resolved earlier, which would make the compiler depend
      -- on which files you happened to visit first.
      M.remember(dir, own)
      on_dir(dir)
    end)
  end
  wrapped[fn] = true
  return fn
end

--- vim.lsp `before_init`: inject the resolved library into the initialize
--- params. Absent a hit we send nothing, so ts_ls keeps its own resolution.
function M.before_init(params, config)
  local root = config and config.root_dir
  local found = memo[root]
  -- Record what this client ends up running, `false` meaning "we injected
  -- nothing, ts_ls resolved its own". warn_mismatch reads this.
  sent[root] = found or false
  if not found then
    return
  end
  params.initializationOptions = vim.tbl_deep_extend(
    "force",
    params.initializationOptions or {},
    { tsserver = { path = found } }
  )
end

-- Test seam: drop all per-session state between specs.
function M._reset()
  memo = {}
  sent = {}
  versions = {}
  warned = {}
end

return M
