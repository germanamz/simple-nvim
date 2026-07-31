-- Pins config.js_toolchain: which formatter and which linter a JS/TS project
-- actually configures. The bug it exists to prevent is prettier running with no
-- project config and imposing its own singleQuote:false default on a repo whose
-- style rules live in ESLint.
local toolchain = require("config.js_toolchain")

describe("config.js_toolchain.resolve", function()
  local root

  before_each(function()
    toolchain._clear()
    root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    -- Seals the walk at `root` (a .git directory is an unconditional boundary,
    -- checked after markers). Without this, "nothing configured" cases climb
    -- past the fixture into the real filesystem, where a stray ancestor
    -- .prettierrc or package.json would flip the result.
    vim.fn.mkdir(root .. "/.git", "p")
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
    toolchain._clear()
  end)

  -- Write `contents` to `<root>/<relpath>`, creating parent directories.
  local function write(relpath, contents)
    local path = root .. "/" .. relpath
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "w"))
    f:write(contents)
    f:close()
  end

  -- A named (but unloaded) buffer at <root>/<relpath>, the shape conform passes.
  local function buf_at(relpath)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, root .. "/" .. relpath)
    return bufnr
  end

  local function resolve(relpath)
    local bufnr = buf_at(relpath)
    local result = toolchain.resolve(bufnr)
    vim.api.nvim_buf_delete(bufnr, { force = true })
    return result
  end

  it("returns both slots nil when nothing is configured", function()
    write("src/a.ts", "")
    local r = resolve("src/a.ts")
    assert.is_nil(r.formatter)
    assert.is_nil(r.linter)
  end)

  it("resolves prettier from a .prettierrc at the project root", function()
    write(".prettierrc", '{"singleQuote": true}\n')
    write("src/a.ts", "")
    assert.are.equal("prettier", resolve("src/a.ts").formatter)
  end)

  it("resolves prettier from a prettier key in package.json", function()
    write("package.json", '{"name":"x","prettier":{"singleQuote":true}}\n')
    write("src/a.ts", "")
    assert.are.equal("prettier", resolve("src/a.ts").formatter)
  end)

  it("resolves eslint for both slots from a flat config", function()
    write("eslint.config.mjs", "export default [];\n")
    write("src/a.ts", "")
    local r = resolve("src/a.ts")
    assert.are.equal("eslint", r.formatter)
    assert.are.equal("eslint", r.linter)
  end)

  it("prefers biome over prettier inside one directory", function()
    write("biome.json", "{}\n")
    write(".prettierrc", "{}\n")
    write("src/a.ts", "")
    assert.are.equal("biome", resolve("src/a.ts").formatter)
  end)

  it("lets a nearer prettier config beat a higher-priority biome further up", function()
    write("biome.json", "{}\n")
    write("packages/ui/.prettierrc", "{}\n")
    write("packages/ui/src/a.ts", "")
    assert.are.equal("prettier", resolve("packages/ui/src/a.ts").formatter)
  end)

  it("fills the two slots independently in one walk", function()
    write("prettier.config.mjs", "export default {};\n")
    write("eslint.config.mjs", "export default [];\n")
    write("src/a.ts", "")
    local r = resolve("src/a.ts")
    assert.are.equal("prettier", r.formatter)
    assert.are.equal("eslint", r.linter)
  end)

  -- The marker sets are deliberately asymmetric: conform's biome formatter
  -- accepts .biome.json, the biome language server does not.
  it("gives .biome.json the formatter slot but not the linter slot", function()
    write(".biome.json", "{}\n")
    write("eslint.config.mjs", "export default [];\n")
    write("src/a.ts", "")
    local r = resolve("src/a.ts")
    assert.are.equal("biome", r.formatter)
    assert.are.equal("eslint", r.linter)
  end)

  -- Without .oxlintrc.jsonc in the linter set, this repo would resolve linter
  -- eslint, run eslint_d AND have the oxlint server attach: duplicate diagnostics.
  it("recognises .oxlintrc.jsonc for the linter slot", function()
    write(".oxlintrc.jsonc", "{}\n")
    write("eslint.config.mjs", "export default [];\n")
    write("src/a.ts", "")
    assert.are.equal("oxlint", resolve("src/a.ts").linter)
  end)

  it("matches an oxlint mention anywhere in package.json's text", function()
    write("package.json", '{"name":"x","oxlint":{}}\n')
    write("src/a.ts", "")
    assert.are.equal("oxlint", resolve("src/a.ts").linter)
  end)

  it("matches a biomejs mention anywhere in package.json's text", function()
    write("package.json", '{"name":"x","biomejs":{}}\n')
    write("src/a.ts", "")
    assert.are.equal("biome", resolve("src/a.ts").linter)
  end)

  -- The two cases above are satisfied by a top-level key lookup as well as by
  -- the raw text scan these rows actually use, so on their own they cannot tell
  -- the two implementations apart — and a real project's package.json has
  -- neither key. The dependency line is the shape that matters, and it is the
  -- shape lspconfig's own root_markers_with_field matches: reverting either row
  -- to pkg_keys fails only here.
  it("matches @biomejs/biome in devDependencies, not just a top-level key", function()
    write("package.json", '{"name":"x","devDependencies":{"@biomejs/biome":"^2.5.5"}}\n')
    write("src/a.ts", "")
    assert.are.equal("biome", resolve("src/a.ts").linter)
  end)

  it("matches oxlint in devDependencies, not just a top-level key", function()
    write("package.json", '{"name":"x","devDependencies":{"oxlint":"^1.75.0"}}\n')
    write("src/a.ts", "")
    assert.are.equal("oxlint", resolve("src/a.ts").linter)
  end)

  -- The oxlint row's vite_lint branch, which mirrors lspconfig/lsp/oxlint.lua:
  -- a vite.config.ts naming both vite-plus and a lint field IS an oxlint
  -- config. Without an eslint config alongside, deleting the branch would show
  -- up as nil rather than as the wrong tool; with one, it shows up as the
  -- duplicate-diagnostics failure the branch exists to prevent.
  it("resolves oxlint from a Vite+ config that opts into linting", function()
    write(
      "vite.config.ts",
      "import { defineConfig } from 'vite-plus';\nexport default defineConfig({ lint: {} });\n"
    )
    write("eslint.config.mjs", "export default [];\n")
    write("src/a.ts", "")
    assert.are.equal("oxlint", resolve("src/a.ts").linter)
  end)

  it("ignores a vite.config.ts that is not a Vite+ lint config", function()
    write(
      "vite.config.ts",
      "import { defineConfig } from 'vite';\nexport default defineConfig({});\n"
    )
    write("eslint.config.mjs", "export default [];\n")
    write("src/a.ts", "")
    assert.are.equal("eslint", resolve("src/a.ts").linter)
  end)

  it("stops at a .git directory even without package.json", function()
    write("outer/.prettierrc", "{}\n")
    vim.fn.mkdir(root .. "/outer/repo/.git", "p")
    write("outer/repo/src/a.ts", "")
    assert.is_nil(resolve("outer/repo/src/a.ts").formatter)
  end)

  it("stops at a submodule that is an independent package", function()
    write("super/.prettierrc", "{}\n")
    write("super/sub/.git", "gitdir: ../.git/modules/sub\n")
    write("super/sub/package.json", '{"name":"sub"}\n')
    write("super/sub/src/a.ts", "")
    assert.is_nil(resolve("super/sub/src/a.ts").formatter)
  end)

  it("keeps inheriting through a submodule that is a vendored subtree", function()
    write("super/.prettierrc", "{}\n")
    write("super/posts/.git", "gitdir: ../.git/modules/posts\n")
    write("super/posts/src/a.ts", "")
    assert.are.equal("prettier", resolve("super/posts/src/a.ts").formatter)
  end)

  it("reports the directory of the first marker hit as root", function()
    write("packages/ui/.prettierrc", "{}\n")
    write("packages/ui/src/a.ts", "")
    -- Buffer names carry the symlink-resolved path (tempname() lands under
    -- /var → /private/var on macOS), so compare through vim.fn.resolve().
    assert.are.equal(vim.fn.resolve(root) .. "/packages/ui", resolve("packages/ui/src/a.ts").root)
  end)

  -- The single-marker case above cannot distinguish `result.root = result.root
  -- or cur` from plain last-wins assignment, or from "root is always the
  -- formatter's directory" — the formatter marker below is nearer than the
  -- linter marker, at a different directory, so only "first hit wins" reports
  -- packages/ui.
  it("reports the nearer directory as root when the formatter matches first", function()
    write("eslint.config.mjs", "export default [];\n")
    write("packages/ui/.prettierrc", "{}\n")
    write("packages/ui/src/a.ts", "")
    local r = resolve("packages/ui/src/a.ts")
    assert.are.equal("prettier", r.formatter)
    assert.are.equal("eslint", r.linter)
    assert.are.equal(vim.fn.resolve(root) .. "/packages/ui", r.root)
  end)

  -- Mirror of the above with the slots swapped: the linter marker is nearer,
  -- the formatter marker further up. Root still tracks the nearer hit, not
  -- whichever slot happens to be the formatter.
  it("reports the nearer directory as root when the linter matches first", function()
    write("dprint.json", "{}\n")
    write("packages/ui/.oxlintrc.json", "{}\n")
    write("packages/ui/src/a.ts", "")
    local r = resolve("packages/ui/src/a.ts")
    assert.are.equal("dprint", r.formatter)
    assert.are.equal("oxlint", r.linter)
    assert.are.equal(vim.fn.resolve(root) .. "/packages/ui", r.root)
  end)

  it("degrades to not-detected on a malformed package.json", function()
    write("package.json", "{ this is not json\n")
    write("src/a.ts", "")
    local r
    local ok = pcall(function()
      r = resolve("src/a.ts")
    end)
    assert.is_true(ok)
    assert.is_nil(r.formatter)
  end)

  -- "Does not raise" alone is satisfied by a resolver that returns all-nil for
  -- everything. The contract is that a buffer with no file resolves from the
  -- cwd — vim.fn.getcwd(), the window-local one config.dir_cache's DirChanged
  -- invalidation actually covers.
  it("resolves an unnamed buffer from cwd", function()
    write(".prettierrc", "{}\n")
    vim.fn.mkdir(root .. "/src", "p")
    local previous = vim.fn.getcwd()
    local bufnr = vim.api.nvim_create_buf(false, true)
    local ok, r = pcall(function()
      vim.cmd.lcd({ args = { root .. "/src" }, mods = { silent = true } })
      return toolchain.resolve(bufnr)
    end)
    vim.cmd.lcd({ args = { previous }, mods = { silent = true } })
    vim.api.nvim_buf_delete(bufnr, { force = true })
    assert.is_true(ok, tostring(r))
    assert.are.equal("prettier", r.formatter)
  end)

  it("treats bufnr 0 as the current buffer", function()
    write(".prettierrc", "{}\n")
    write("src/a.ts", "")
    local bufnr = buf_at("src/a.ts")
    local r
    vim.api.nvim_buf_call(bufnr, function()
      r = toolchain.resolve(0)
    end)
    vim.api.nvim_buf_delete(bufnr, { force = true })
    assert.are.equal("prettier", r.formatter)
  end)

  -- entries() returns nil for a directory that exists and can be traversed but
  -- cannot be listed. That used to read as "no markers here" and the walk
  -- climbed straight past it — to /, where a stray ~/.prettierrc governs the
  -- buffer, which is the exact failure the boundary rule exists to prevent.
  it("stops at a directory it cannot read rather than climbing past it", function()
    write(".prettierrc", "{}\n")
    write("blocked/src/a.ts", "")
    vim.fn.setfperm(root .. "/blocked", "--x--x--x")
    -- root ignores the mode bits entirely, so there would be nothing to assert.
    if vim.uv.fs_scandir(root .. "/blocked") then
      vim.fn.setfperm(root .. "/blocked", "rwxr-xr-x")
      pending("directory permissions are not enforced for this user")
      return
    end
    local ok, r = pcall(resolve, "blocked/src/a.ts")
    vim.fn.setfperm(root .. "/blocked", "rwxr-xr-x")
    assert.is_true(ok, tostring(r))
    assert.is_nil(r.formatter)
  end)

  it("memoizes per directory until cleared", function()
    write("src/a.ts", "")
    assert.is_nil(resolve("src/a.ts").formatter)

    -- Adding a config mid-session is invisible until the cache is dropped.
    write(".prettierrc", "{}\n")
    assert.is_nil(resolve("src/a.ts").formatter)

    toolchain._clear()
    assert.are.equal("prettier", resolve("src/a.ts").formatter)
  end)
end)

describe("config.js_toolchain.marker_basenames", function()
  it("includes package.json and markers from both tables", function()
    local names = toolchain.marker_basenames()
    local set = {}
    for _, n in ipairs(names) do
      set[n] = true
    end
    assert.is_true(set["package.json"])
    assert.is_true(set["biome.json"])
    assert.is_true(set[".prettierrc"])
    assert.is_true(set["eslint.config.mjs"])
    assert.is_true(set[".oxlintrc.jsonc"])
    -- The oxlint LINTER rule's vite_lint branch adds this basename outside the
    -- rule's own `files` list; deleting that branch would pass every other
    -- assertion here while silently breaking Task 3's BufWritePost pattern for
    -- a Vite+ lint config.
    assert.is_true(set["vite.config.ts"])
  end)

  it("has no duplicates", function()
    local seen, names = {}, toolchain.marker_basenames()
    for _, n in ipairs(names) do
      assert.is_nil(seen[n], "duplicate basename: " .. n)
      seen[n] = true
    end
  end)
end)
