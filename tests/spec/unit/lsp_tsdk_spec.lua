-- Pins config.lsp_tsdk: picking the TypeScript library ts_ls should run.
--
-- typescript-language-server only searches UPWARD from its root_dir for
-- node_modules/typescript/lib. lspconfig roots ts_ls at the nearest package
-- manager lockfile — the pnpm *workspace* root — but pnpm installs typescript
-- in the leaf package, BELOW that root. Nothing is found, so ts_ls silently
-- falls back to its own bundled TypeScript, which is routinely a different
-- major version than the project's (mason ships 6.x; projects pin 5.x). These
-- specs pin the downward-reaching search that fixes it.
local tsdk = require("config.lsp_tsdk")

--- Build a directory tree under a fresh tempdir.
--- `layout` maps a relative dir -> true (mkdir) so specs read as trees.
local function tree(dirs)
  local root = vim.fn.tempname()
  for _, d in ipairs(dirs) do
    vim.fn.mkdir(root .. "/" .. d, "p")
  end
  return root
end

--- Materialize a fake typescript install at `<dir>/<module_folder>`.
--- Returns the path in realpath form: resolve() compares against the buffer's
--- name, which the API reports realpath'd (/private/var/… on macOS), so that is
--- the form callers get back.
--- @param version string|nil written into the install's package.json so
---   version_of() can read it back (all three MODULE_FOLDERS end in
---   `typescript/lib`, so the manifest is always one level up).
local function install_ts(root, dir, module_folder, version)
  local lib = root .. "/" .. dir .. "/" .. (module_folder or "node_modules/typescript/lib")
  vim.fn.mkdir(lib, "p")
  local f = assert(io.open(lib .. "/tsserver.js", "w"))
  f:write("// fake tsserver\n")
  f:close()
  local mf = assert(io.open(lib .. "/../package.json", "w"))
  mf:write(('{ "name": "typescript", "version": "%s" }\n'):format(version or "5.9.3"))
  mf:close()
  return assert(vim.uv.fs_realpath(lib)) .. "/tsserver.js"
end

describe("config.lsp_tsdk.resolve", function()
  it("finds the leaf package's typescript in a pnpm monorepo", function()
    -- web/ (pnpm-lock root, no typescript) -> apps/site/ (typescript here)
    local root = tree({ "web/apps/site/src" })
    local want = install_ts(root, "web/apps/site")
    local got = tsdk.resolve(root .. "/web/apps/site/src", root .. "/web")
    assert.are.equal(want, got)
    vim.fn.delete(root, "rf")
  end)

  it("finds typescript at the root of a plain single-package repo", function()
    local root = tree({ "repo/src" })
    local want = install_ts(root, "repo")
    local got = tsdk.resolve(root .. "/repo/src", root .. "/repo")
    assert.are.equal(want, got)
    vim.fn.delete(root, "rf")
  end)

  it("prefers the nearest install when both leaf and root have one", function()
    local root = tree({ "web/apps/site/src" })
    install_ts(root, "web")
    local want = install_ts(root, "web/apps/site")
    local got = tsdk.resolve(root .. "/web/apps/site/src", root .. "/web")
    assert.are.equal(want, got)
    vim.fn.delete(root, "rf")
  end)

  it("returns nil when nothing is installed, leaving ts_ls its own fallback", function()
    local root = tree({ "web/apps/site/src" })
    assert.is_nil(tsdk.resolve(root .. "/web/apps/site/src", root .. "/web"))
    vim.fn.delete(root, "rf")
  end)

  it("never escapes above root_dir", function()
    -- A stray typescript in a parent (e.g. ~/node_modules) must not be adopted:
    -- ts_ls's own upward walk already does that, and in a 200-submodule
    -- superproject it would pick a version unrelated to the project.
    local root = tree({ "web/apps/site/src" })
    install_ts(root, ".")
    assert.is_nil(tsdk.resolve(root .. "/web/apps/site/src", root .. "/web"))
    vim.fn.delete(root, "rf")
  end)

  it("accepts a yarn PnP sdk install", function()
    local root = tree({ "repo/src" })
    local want = install_ts(root, "repo", ".yarn/sdks/typescript/lib")
    assert.are.equal(want, tsdk.resolve(root .. "/repo/src", root .. "/repo"))
    vim.fn.delete(root, "rf")
  end)

  it("ignores a typescript dir with no tsserver.js (broken/partial install)", function()
    local root = tree({ "repo/src", "repo/node_modules/typescript/lib" })
    assert.is_nil(tsdk.resolve(root .. "/repo/src", root .. "/repo"))
    vim.fn.delete(root, "rf")
  end)

  it("still checks root_dir when the start dir is outside it", function()
    local root = tree({ "repo/src", "elsewhere" })
    local want = install_ts(root, "repo")
    assert.are.equal(want, tsdk.resolve(root .. "/elsewhere", root .. "/repo"))
    vim.fn.delete(root, "rf")
  end)
end)

describe("config.lsp_tsdk.resolve arity", function()
  it("returns exactly one value (nil) on a miss, not zero values", function()
    -- Falling off the end of a Lua function propagates NO values, which makes
    -- `tostring(resolve(...))` raise "value expected" and silently weakens
    -- `assert.is_nil` at every call site.
    local root = tree({ "repo/src" })
    assert.are.equal(1, select("#", tsdk.resolve(root .. "/repo/src", root .. "/repo")))
    assert.are.equal(1, select("#", tsdk.resolve(root .. "/elsewhere", root .. "/repo")))
    assert.are.equal("nil", tostring(tsdk.resolve(root .. "/repo/src", root .. "/repo")))
    vim.fn.delete(root, "rf")
  end)
end)

describe("config.lsp_tsdk before_init wiring", function()
  before_each(function()
    tsdk._reset()
  end)

  it("injects the remembered tsserver path as initializationOptions", function()
    tsdk.remember("/r", "/r/node_modules/typescript/lib/tsserver.js")
    local params = { initializationOptions = { hostInfo = "neovim" } }
    tsdk.before_init(params, { root_dir = "/r" })
    assert.are.same({
      hostInfo = "neovim",
      tsserver = { path = "/r/node_modules/typescript/lib/tsserver.js" },
    }, params.initializationOptions)
  end)

  it("leaves initializationOptions untouched when nothing was resolved", function()
    local params = { initializationOptions = { hostInfo = "neovim" } }
    tsdk.before_init(params, { root_dir = "/unknown" })
    assert.are.same({ hostInfo = "neovim" }, params.initializationOptions)
  end)

  it("keys the memo by root_dir so sibling roots do not cross-contaminate", function()
    tsdk.remember("/a", "/a/ts/tsserver.js")
    tsdk.remember("/b", "/b/ts/tsserver.js")
    local pa = { initializationOptions = {} }
    tsdk.before_init(pa, { root_dir = "/a" })
    assert.are.equal("/a/ts/tsserver.js", pa.initializationOptions.tsserver.path)
    local pb = { initializationOptions = {} }
    tsdk.before_init(pb, { root_dir = "/b" })
    assert.are.equal("/b/ts/tsserver.js", pb.initializationOptions.tsserver.path)
  end)

  it("tolerates params with no initializationOptions", function()
    tsdk.remember("/r", "/r/ts/tsserver.js")
    local params = {}
    tsdk.before_init(params, { root_dir = "/r" })
    assert.are.equal("/r/ts/tsserver.js", params.initializationOptions.tsserver.path)
  end)
end)

--- Give `dir` a tsconfig.json so package_root can find it.
local function tsconfig(root, dir)
  local d = root .. "/" .. dir
  vim.fn.mkdir(d, "p")
  local f = assert(io.open(d .. "/tsconfig.json", "w"))
  f:write("{}\n")
  f:close()
  return assert(vim.uv.fs_realpath(d))
end

describe("config.lsp_tsdk.package_root", function()
  it("finds the nearest dir owning a tsconfig, bounded at the root", function()
    local root = tree({ "web/apps/a1/src" })
    local want = tsconfig(root, "web/apps/a1")
    assert.are.equal(want, tsdk.package_root(root .. "/web/apps/a1/src", root .. "/web"))
    vim.fn.delete(root, "rf")
  end)

  it("accepts jsconfig.json", function()
    local root = tree({ "web/apps/a1/src" })
    local d = root .. "/web/apps/a1"
    local f = assert(io.open(d .. "/jsconfig.json", "w"))
    f:write("{}\n")
    f:close()
    assert.are.equal(
      assert(vim.uv.fs_realpath(d)),
      tsdk.package_root(root .. "/web/apps/a1/src", root .. "/web")
    )
    vim.fn.delete(root, "rf")
  end)

  it("returns nil when no package below the root owns one", function()
    local root = tree({ "web/apps/a1/src" })
    tsconfig(root, "web")
    assert.is_nil(tsdk.package_root(root .. "/web/apps/a1/src", root .. "/web"))
    vim.fn.delete(root, "rf")
  end)

  it("returns nil when nothing owns one at all", function()
    local root = tree({ "web/apps/a1/src" })
    assert.is_nil(tsdk.package_root(root .. "/web/apps/a1/src", root .. "/web"))
    vim.fn.delete(root, "rf")
  end)
end)

describe("config.lsp_tsdk divergent-package split", function()
  before_each(function()
    tsdk._reset()
  end)

  --- Simulate a live client for `ws` already running `path`.
  local function live(ws, path)
    tsdk.remember(ws, path)
    tsdk.before_init({ initializationOptions = {} }, { root_dir = ws })
  end

  local function route(root, ws, rel)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, root .. "/" .. rel)
    local seen
    tsdk.wrap_root_dir(function(_, on_dir)
      on_dir(ws)
    end)(buf, function(d)
      seen = d
    end)
    vim.api.nvim_buf_delete(buf, { force = true })
    return seen
  end

  it("routes a package pinning a different MAJOR to its own root", function()
    local root = tree({ "web/apps/a1/src", "web/apps/a2/src" })
    local a1 = install_ts(root, "web/apps/a1", nil, "5.9.3")
    local a2 = install_ts(root, "web/apps/a2", nil, "6.0.3")
    local ws = root .. "/web"
    local pkg = tsconfig(root, "web/apps/a2")
    live(ws, a1)

    assert.are.equal(pkg, route(root, ws, "web/apps/a2/src/index.ts"))
    -- and the split client is told to run a2's own TypeScript
    local params = { initializationOptions = {} }
    tsdk.before_init(params, { root_dir = pkg })
    assert.are.equal(a2, params.initializationOptions.tsserver.path)
    vim.fn.delete(root, "rf")
  end)

  it("does NOT split on a minor/patch difference", function()
    -- Measured: splitting ~/projects/expenses (5.6.2 vs 5.5.4) costs +508 MB of
    -- resident tsserver and changes no diagnostic. Major-only on purpose.
    local root = tree({ "web/apps/a1/src", "web/apps/a2/src" })
    local a1 = install_ts(root, "web/apps/a1", nil, "5.6.2")
    install_ts(root, "web/apps/a2", nil, "5.5.4")
    local ws = root .. "/web"
    tsconfig(root, "web/apps/a2")
    live(ws, a1)
    assert.are.equal(ws, route(root, ws, "web/apps/a2/src/index.ts"))
    vim.fn.delete(root, "rf")
  end)

  it("does NOT split a package that owns no tsconfig to split to", function()
    local root = tree({ "web/apps/a1/src", "web/apps/a2/src" })
    local a1 = install_ts(root, "web/apps/a1", nil, "5.9.3")
    install_ts(root, "web/apps/a2", nil, "6.0.3")
    local ws = root .. "/web"
    live(ws, a1)
    assert.are.equal(ws, route(root, ws, "web/apps/a2/src/index.ts"))
    vim.fn.delete(root, "rf")
  end)

  it("does NOT split before any client for the root has initialized", function()
    local root = tree({ "web/apps/a2/src" })
    install_ts(root, "web/apps/a2", nil, "6.0.3")
    local ws = root .. "/web"
    tsconfig(root, "web/apps/a2")
    assert.are.equal(ws, route(root, ws, "web/apps/a2/src/index.ts"))
    vim.fn.delete(root, "rf")
  end)

  it("does NOT split when the live client resolved its own library", function()
    -- sent[ws] == false: we do not know what version it runs, so there is
    -- nothing to compare majors against. D's warning covers this shape.
    local root = tree({ "web/apps/a2/src" })
    install_ts(root, "web/apps/a2", nil, "6.0.3")
    local ws = root .. "/web"
    tsconfig(root, "web/apps/a2")
    tsdk.before_init({ initializationOptions = {} }, { root_dir = ws })
    assert.are.equal(ws, route(root, ws, "web/apps/a2/src/index.ts"))
    vim.fn.delete(root, "rf")
  end)

  it("does NOT split a package that pins nothing", function()
    local root = tree({ "web/apps/a1/src", "web/apps/a3/src" })
    local a1 = install_ts(root, "web/apps/a1", nil, "5.9.3")
    local ws = root .. "/web"
    tsconfig(root, "web/apps/a3")
    live(ws, a1)
    assert.are.equal(ws, route(root, ws, "web/apps/a3/src/index.ts"))
    vim.fn.delete(root, "rf")
  end)

  it("still prefers the nearest install with a workspace manifest present", function()
    -- The regression the previous suite would have missed: no spec tree carried a
    -- workspace manifest, so a glob-driven implementation could override a
    -- nearer install and every existing spec stayed green. Pinned explicitly.
    local root = tree({ "web/apps/a1/src" })
    install_ts(root, "web", nil, "5.4.0")
    local a1 = install_ts(root, "web/apps/a1", nil, "5.9.3")
    local mf = assert(io.open(root .. "/web/pnpm-workspace.yaml", "w"))
    mf:write('packages:\n  - "apps/*"\n')
    mf:close()
    assert.are.equal(a1, tsdk.resolve(root .. "/web/apps/a1/src", root .. "/web"))
    vim.fn.delete(root, "rf")
  end)
end)

describe("config.lsp_tsdk mismatch warning", function()
  local notes

  before_each(function()
    tsdk._reset()
    notes = {}
    tsdk._notify = function(msg, level)
      notes[#notes + 1] = { msg = msg, level = level }
    end
  end)

  after_each(function()
    tsdk._notify = nil
  end)

  --- Stand in for an attached client without starting a server.
  local function client(root)
    return { name = "ts_ls", config = { root_dir = root }, root_dir = root }
  end

  local function buf_at(path)
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(b, path)
    return b
  end

  it("reads a version out of an install's package.json", function()
    local root = tree({ "repo/src" })
    local p = install_ts(root, "repo", nil, "5.4.2")
    assert.are.equal("5.4.2", tsdk.version_of(p))
    vim.fn.delete(root, "rf")
  end)

  it("warns when the buffer's package pins a different version than was sent", function()
    local root = tree({ "web/apps/a1/src", "web/apps/a2/src" })
    local a1 = install_ts(root, "web/apps/a1", nil, "5.9.3")
    install_ts(root, "web/apps/a2", nil, "6.0.3")
    local ws = root .. "/web"

    -- the client was started from a1, so a1's 5.9.3 was sent
    tsdk.before_init({ initializationOptions = {} }, { root_dir = ws })
    tsdk.remember(ws, a1)
    tsdk.before_init({ initializationOptions = {} }, { root_dir = ws })

    local b = buf_at(root .. "/web/apps/a2/src/index.ts")
    tsdk.warn_mismatch(b, client(ws))
    assert.are.equal(1, #notes)
    assert.is_truthy(notes[1].msg:find("5.9.3", 1, true))
    assert.is_truthy(notes[1].msg:find("6.0.3", 1, true))
    assert.are.equal(vim.log.levels.WARN, notes[1].level)

    vim.api.nvim_buf_delete(b, { force = true })
    vim.fn.delete(root, "rf")
  end)

  it("stays silent on minor/patch drift, matching the split's threshold", function()
    -- ~/projects/expenses is 5.6.2 vs 5.5.4 and changes no diagnostic; the split
    -- declines it on purpose, so warning about it would be a nag the user cannot
    -- act on. The two thresholds must agree.
    local root = tree({ "web/apps/a1/src", "web/apps/a2/src" })
    local a1 = install_ts(root, "web/apps/a1", nil, "5.6.2")
    install_ts(root, "web/apps/a2", nil, "5.5.4")
    local ws = root .. "/web"
    tsdk.remember(ws, a1)
    tsdk.before_init({ initializationOptions = {} }, { root_dir = ws })

    local b = buf_at(root .. "/web/apps/a2/src/index.ts")
    tsdk.warn_mismatch(b, client(ws))
    assert.are.same({}, notes)

    vim.api.nvim_buf_delete(b, { force = true })
    vim.fn.delete(root, "rf")
  end)

  it("stays silent when two packages resolve the SAME version via different paths", function()
    -- The comparison must be by version, not path: pnpm gives each package its
    -- own symlink, so identical versions have different resolved paths and a
    -- path comparison would warn on every healthy monorepo.
    local root = tree({ "web/apps/a1/src", "web/apps/a2/src" })
    local a1 = install_ts(root, "web/apps/a1", nil, "5.9.3")
    install_ts(root, "web/apps/a2", nil, "5.9.3")
    local ws = root .. "/web"
    tsdk.remember(ws, a1)
    tsdk.before_init({ initializationOptions = {} }, { root_dir = ws })

    local b = buf_at(root .. "/web/apps/a2/src/index.ts")
    tsdk.warn_mismatch(b, client(ws))
    assert.are.same({}, notes)

    vim.api.nvim_buf_delete(b, { force = true })
    vim.fn.delete(root, "rf")
  end)

  it("warns once per (root, got, want), not once per buffer", function()
    local root = tree({ "web/apps/a1/src", "web/apps/a2/src", "web/apps/a2/lib" })
    local a1 = install_ts(root, "web/apps/a1", nil, "5.9.3")
    install_ts(root, "web/apps/a2", nil, "6.0.3")
    local ws = root .. "/web"
    tsdk.remember(ws, a1)
    tsdk.before_init({ initializationOptions = {} }, { root_dir = ws })

    for _, p in ipairs({ "apps/a2/src/index.ts", "apps/a2/lib/other.ts" }) do
      local b = buf_at(root .. "/web/" .. p)
      tsdk.warn_mismatch(b, client(ws))
      vim.api.nvim_buf_delete(b, { force = true })
    end
    assert.are.equal(1, #notes)
    vim.fn.delete(root, "rf")
  end)

  it("warns when nothing was injected but the buffer's package pins a version", function()
    -- sent[root] == false: ts_ls resolved its own library (possibly its bundled
    -- copy). A package that does pin one still deserves the heads-up.
    local root = tree({ "web/apps/a1/src" })
    install_ts(root, "web/apps/a1", nil, "5.9.3")
    local ws = root .. "/web"
    tsdk.before_init({ initializationOptions = {} }, { root_dir = ws })

    local b = buf_at(root .. "/web/apps/a1/src/index.ts")
    tsdk.warn_mismatch(b, client(ws))
    assert.are.equal(1, #notes)
    assert.is_truthy(notes[1].msg:find("5.9.3", 1, true))

    vim.api.nvim_buf_delete(b, { force = true })
    vim.fn.delete(root, "rf")
  end)

  it("stays silent before any client for the root has initialized", function()
    local root = tree({ "web/apps/a1/src" })
    install_ts(root, "web/apps/a1", nil, "5.9.3")
    local b = buf_at(root .. "/web/apps/a1/src/index.ts")
    tsdk.warn_mismatch(b, client(root .. "/web"))
    assert.are.same({}, notes)
    vim.api.nvim_buf_delete(b, { force = true })
    vim.fn.delete(root, "rf")
  end)

  it("stays silent when the buffer's package pins nothing", function()
    local root = tree({ "web/apps/a3/src" })
    local ws = root .. "/web"
    install_ts(root, "web/apps/a1", nil, "5.9.3")
    tsdk.remember(ws, root .. "/web/apps/a1/node_modules/typescript/lib/tsserver.js")
    tsdk.before_init({ initializationOptions = {} }, { root_dir = ws })

    local b = buf_at(root .. "/web/apps/a3/src/index.ts")
    tsdk.warn_mismatch(b, client(ws))
    assert.are.same({}, notes)

    vim.api.nvim_buf_delete(b, { force = true })
    vim.fn.delete(root, "rf")
  end)
end)

describe("config.lsp_tsdk.wrap_root_dir", function()
  it("passes the dir through unchanged and memoizes the resolved tsdk", function()
    tsdk._reset()
    local root = tree({ "web/apps/site/src" })
    local want = install_ts(root, "web/apps/site")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, root .. "/web/apps/site/src/index.ts")

    local base = function(_, on_dir)
      on_dir(root .. "/web")
    end
    local seen
    tsdk.wrap_root_dir(base)(buf, function(dir)
      seen = dir
    end)

    assert.are.equal(root .. "/web", seen)
    local params = { initializationOptions = {} }
    tsdk.before_init(params, { root_dir = root .. "/web" })
    assert.are.equal(want, params.initializationOptions.tsserver.path)

    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(root, "rf")
  end)

  it("clears a sibling's answer when this buffer resolves nothing", function()
    -- The memo is a handoff from root_dir to before_init, not a cache. A package
    -- with no typescript of its own must fall back to ts_ls's own resolution —
    -- not silently inherit whatever a sibling package resolved earlier in the
    -- session, which would make the compiler depend on browsing history.
    tsdk._reset()
    tsdk.remember("/r", "/r/apps/a1/node_modules/typescript/lib/tsserver.js")

    local root = tree({ "web/apps/a3/src" })
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, root .. "/web/apps/a3/src/index.ts")
    tsdk.wrap_root_dir(function(_, on_dir)
      on_dir("/r")
    end)(buf, function() end)

    local params = { initializationOptions = {} }
    tsdk.before_init(params, { root_dir = "/r" })
    assert.is_nil(params.initializationOptions.tsserver)

    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(root, "rf")
  end)

  it("records the latest resolution when several buffers share a root", function()
    -- Client creation is deferred, so with concurrent opens (nvim -p, session
    -- restore, telescope multi-open) several buffers resolve the same root
    -- before any client initializes. The LAST write is what before_init sends.
    tsdk._reset()
    local root = tree({ "web/apps/a1/src", "web/apps/a2/src" })
    install_ts(root, "web/apps/a1")
    local want = install_ts(root, "web/apps/a2")

    local base = function(_, on_dir)
      on_dir(root .. "/web")
    end
    for _, pkg in ipairs({ "a1", "a2" }) do
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, root .. "/web/apps/" .. pkg .. "/src/index.ts")
      tsdk.wrap_root_dir(base)(buf, function() end)
    end

    local params = { initializationOptions = {} }
    tsdk.before_init(params, { root_dir = root .. "/web" })
    assert.are.equal(want, params.initializationOptions.tsserver.path)
    vim.fn.delete(root, "rf")
  end)

  it("still calls on_dir when the base resolves no root", function()
    tsdk._reset()
    local called = false
    local base = function(_, on_dir)
      on_dir(nil)
    end
    tsdk.wrap_root_dir(base)(vim.api.nvim_get_current_buf(), function()
      called = true
    end)
    assert.is_true(called)
  end)
end)
