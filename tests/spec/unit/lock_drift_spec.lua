local ld = require("config.lock_drift")

-- _installed_commit resolves a plugin clone's commit via plain file reads
-- (no git binary): detached HEAD directly, `ref:` HEAD through the loose ref
-- file, then packed-refs. Fixtures are plain files in a temp .git dir.
describe("config.lock_drift._installed_commit", function()
  local root

  before_each(function()
    root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/.git", "p")
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  local function write(rel, lines)
    local path = root .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(lines, path)
  end

  it("reads a detached HEAD sha directly", function()
    write(".git/HEAD", { "abc123" })
    assert.are.equal("abc123", ld._installed_commit(root))
  end)

  it("resolves a ref: HEAD through the loose ref file", function()
    write(".git/HEAD", { "ref: refs/heads/x" })
    write(".git/refs/heads/x", { "def456" })
    assert.are.equal("def456", ld._installed_commit(root))
  end)

  it("falls back to packed-refs when the loose ref is absent", function()
    write(".git/HEAD", { "ref: refs/heads/x" })
    write(".git/packed-refs", {
      "# pack-refs with: peeled fully-peeled sorted",
      "1111111 refs/heads/other",
      "abcdef0 refs/heads/x",
      "^ffffff0",
    })
    assert.are.equal("abcdef0", ld._installed_commit(root))
  end)

  it("returns nil when the ref resolves nowhere", function()
    write(".git/HEAD", { "ref: refs/heads/x" })
    assert.is_nil(ld._installed_commit(root))
  end)

  it("returns nil when .git/HEAD is missing", function()
    assert.is_nil(ld._installed_commit(root))
  end)
end)
