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

  it("recognises an oxlint key in package.json for the linter slot", function()
    write("package.json", '{"name":"x","oxlint":{}}\n')
    write("src/a.ts", "")
    assert.are.equal("oxlint", resolve("src/a.ts").linter)
  end)

  it("recognises a biomejs key in package.json for the linter slot", function()
    write("package.json", '{"name":"x","biomejs":{}}\n')
    write("src/a.ts", "")
    assert.are.equal("biome", resolve("src/a.ts").linter)
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

  it("degrades to not-detected on a malformed package.json", function()
    write("package.json", "{ this is not json\n")
    write("src/a.ts", "")
    local ok, r = pcall(toolchain.resolve, buf_at("src/a.ts"))
    assert.is_true(ok)
    assert.is_nil(r.formatter)
  end)

  it("resolves an unnamed buffer from cwd without raising", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    local ok = pcall(toolchain.resolve, bufnr)
    vim.api.nvim_buf_delete(bufnr, { force = true })
    assert.is_true(ok)
  end)

  it("treats bufnr 0 as the current buffer", function()
    local ok = pcall(toolchain.resolve, 0)
    assert.is_true(ok)
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
  end)

  it("has no duplicates", function()
    local seen, names = {}, toolchain.marker_basenames()
    for _, n in ipairs(names) do
      assert.is_nil(seen[n], "duplicate basename: " .. n)
      seen[n] = true
    end
  end)
end)
