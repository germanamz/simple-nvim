local devdocs = require("config.docs.devdocs")

-- `:DocsInstall` end to end against file:// sources: real curl, and the real
-- `nvim --clean -l` split process. Nothing is stubbed because the parts worth
-- testing are exactly the process boundaries — exit codes, what lands on disk,
-- and what is left behind when a step fails.
local SRC = vim.fs.joinpath(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"),
  "fixtures",
  "devdocs-src"
)

describe("config.docs.devdocs.install", function()
  local root, saved

  before_each(function()
    root = vim.fn.tempname() .. "-devdocs"
    vim.fn.mkdir(root, "p")
    saved = { base = devdocs._base_url, retries = devdocs._retries, notify = vim.notify }
    devdocs._root = vim.fs.joinpath(root, "store")
    devdocs._base_url = "file://" .. SRC .. "/"
    devdocs._retries = 0
    vim.notify = function() end
    devdocs._reset()
  end)

  after_each(function()
    devdocs._root = nil
    devdocs._base_url = saved.base
    devdocs._retries = saved.retries
    vim.notify = saved.notify
    devdocs._reset()
    vim.fn.delete(root, "rf")
  end)

  ---@return boolean ok, string|nil err
  local function install(slug)
    local result
    devdocs.install(slug, function(ok, err)
      result = { ok, err }
    end)
    assert(
      vim.wait(20000, function()
        return result ~= nil
      end, 20),
      "install never finished"
    )
    return result[1], result[2]
  end

  local function exists(path)
    return vim.uv.fs_stat(path) ~= nil
  end

  it("downloads, splits and swaps a bundle into place", function()
    local ok, err = install("mini")
    assert.is_true(ok, err)
    local dir = devdocs.dir("mini")
    assert.is_true(exists(dir .. "/index.json"))
    assert.is_true(exists(dir .. "/meta.json"))
    assert.is_true(exists(dir .. "/pages/group/alpha.html"))
    assert.is_true(exists(dir .. "/pages/beta.html"))
    assert.is_false(exists(dir .. "/db.json"))
    assert.is_false(exists(dir .. ".tmp"))
    assert.same({ "mini" }, devdocs.installed_slugs())
    local ex = devdocs.excerpt("mini", devdocs.lookup("mini", "alpha"))
    -- `mini` is no known family, so there is no excerpt; the index still reads.
    assert.is_nil(ex)
    assert.equals("group/alpha", devdocs.lookup("mini", "alpha").path)
  end)

  it("replaces an installed bundle with a fresh one", function()
    assert.is_true((install("mini")))
    local stale = devdocs.dir("mini") .. "/pages/stale.html"
    vim.fn.writefile({ "old" }, stale)
    assert.is_true((install("mini")))
    assert.is_false(exists(stale))
    assert.is_true(exists(devdocs.dir("mini") .. "/pages/group/alpha.html"))
    assert.is_false(exists(devdocs.dir("mini") .. ".old"))
  end)

  -- The page paths come off the network. One that climbs out of the bundle must
  -- fail the whole install, not just be skipped, and must write nothing.
  it("refuses a bundle whose page paths escape it", function()
    local ok, err = install("evil")
    assert.is_false(ok)
    assert.truthy(tostring(err):find("unsafe", 1, true), err)
    assert.equals(0, #vim.fn.globpath(root, "**/escape.html", false, true))
    assert.is_false(exists(devdocs.dir("evil")))
    assert.is_false(exists(devdocs.dir("evil") .. ".tmp"))
  end)

  it("leaves the previous bundle intact when a reinstall fails", function()
    local dir = devdocs.dir("evil")
    vim.fn.mkdir(dir .. "/pages", "p")
    vim.fn.writefile({ '{"entries":[]}' }, dir .. "/index.json")
    assert.is_false((install("evil")))
    assert.is_true(exists(dir .. "/index.json"))
  end)

  it("reports a download failure", function()
    local ok, err = install("absent")
    assert.is_false(ok)
    assert.truthy(err)
    assert.is_false(exists(devdocs.dir("absent")))
  end)

  it("only accepts slugs that are a single safe path segment", function()
    assert.is_true(devdocs.valid_slug("python~3.10"))
    assert.is_true(devdocs.valid_slug("cpp"))
    assert.is_false(devdocs.valid_slug("../x"))
    assert.is_false(devdocs.valid_slug(".."))
    assert.is_false(devdocs.valid_slug("a/b"))
    assert.is_false(devdocs.valid_slug(""))
    local ok = install("../x")
    assert.is_false(ok)
  end)

  it("lists installed bundles with their install date", function()
    assert.is_true((install("mini")))
    local lines = devdocs.list_installed()
    assert.equals(1, #lines)
    assert.truthy(lines[1]:match("^mini%s+installed %d%d%d%d%-%d%d%-%d%d"))
  end)
end)
