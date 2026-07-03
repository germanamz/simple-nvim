local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")

-- The dot-folder / symlink / git-ignored decorators (config.nvim_tree_dotfolder,
-- config.nvim_tree_symlink, config.nvim_tree_ignore) need a loaded nvim-tree, so
-- their construction and rendered colours are pinned here rather than in a unit
-- spec. Covers: the three groups resolve to distinct colours against the real
-- theme; each node class dispatches to its own group; an ignored dot-folder
-- resolves to grey (ignore wins the overlap); and — the regression — reloading a
-- tree that contains a dot-folder and a symlink does not crash.
describe("e2e: nvim-tree decorator colours", function()
  local root, work, prev_cwd

  local function open_tree(path)
    local api = require("nvim-tree.api")
    api.tree.open({ path = path })
    wait.wait_for(function()
      return api.tree.is_visible()
    end, 3000, "tree did not open")
    return api
  end

  local function fg(group)
    return vim.api.nvim_get_hl(0, { name = group, link = false }).fg
  end

  before_each(function()
    root = nvim_env.setup_isolated_env()
    prev_cwd = vim.fn.getcwd()
    -- A plain working tree with a dot-folder, a file, and a symlink to it, so a
    -- render exercises the dot-folder and symlink (type "link") code paths.
    work = root .. "/work"
    vim.fn.mkdir(work .. "/.hidden", "p")
    local f = assert(io.open(work .. "/real.lua", "w"))
    f:write("return 1\n")
    f:close()
    vim.uv.fs_symlink(work .. "/real.lua", work .. "/link.lua")
    require("lazy").load({ plugins = { "nvim-tree.lua" } })
    -- Building the decorators (also done by nvim-tree's config) defines their
    -- highlight groups against the loaded theme.
    require("config.nvim_tree_dotfolder").decorator()
    require("config.nvim_tree_symlink").decorator()
    require("config.nvim_tree_ignore").decorator()
  end)

  after_each(function()
    pcall(function()
      require("nvim-tree.api").tree.close()
    end)
    vim.cmd("silent! %bwipeout!")
    pcall(vim.fn.chdir, prev_cwd)
    nvim_env.teardown(root)
  end)

  it("defines three pairwise-distinct colours for the sibling decorators", function()
    local grey, blue, teal =
      fg("NvimTreeGitIgnored"), fg("NvimTreeHiddenFolderHL"), fg("NvimTreeSymlinkMark")
    assert.is_not_nil(grey)
    assert.is_not_nil(blue)
    assert.is_not_nil(teal)
    assert.is_true(grey ~= blue, "ignored grey collided with dot-folder blue")
    assert.is_true(grey ~= teal, "ignored grey collided with symlink teal")
    assert.is_true(blue ~= teal, "dot-folder blue collided with symlink teal")
  end)

  it("dispatches each node class to its own group", function()
    local df = require("config.nvim_tree_dotfolder").decorator()()
    local sl = require("config.nvim_tree_symlink").decorator()()
    assert.are.equal(
      "NvimTreeHiddenFolderHL",
      df:highlight_group({ type = "directory", absolute_path = "/p/.git" })
    )
    assert.is_nil(df:highlight_group({ type = "link", absolute_path = "/p/link" }))
    assert.are.equal(
      "NvimTreeSymlinkMark",
      sl:highlight_group({ type = "link", absolute_path = "/p/link" })
    )
    assert.is_nil(sl:highlight_group({ type = "directory", absolute_path = "/p/.git" }))
  end)

  it("resolves an ignored dot-folder to grey — the ignore decorator wins the overlap", function()
    -- .next is both a static-ignored dir and a dot-folder, so the dot-folder
    -- decorator yields blue and the ignore decorator yields grey. nvim-tree's
    -- create_combined_group force-merges name groups in decorators-list order
    -- (dot-folder before ignore), so grey wins. Replicate that merge to pin it.
    local function combine(groups)
      local c = {}
      for _, g in ipairs(groups) do
        c = vim.tbl_extend("force", c, vim.api.nvim_get_hl(0, { name = g, link = false }))
      end
      return c.fg
    end
    assert.are.equal(
      fg("NvimTreeGitIgnored"),
      combine({ "NvimTreeHiddenFolderHL", "NvimTreeGitIgnored" })
    )
  end)

  it("reloads a tree containing a dot-folder and a symlink without error", function()
    -- Regression: custom decorators receive metatable-less api-node clones, so a
    -- node:is_dotfile() call crashed reload (SmartCodesRefreshed -> reload). The
    -- predicates are now field-only; a full build + reload must stay clean.
    vim.fn.chdir(work)
    local api = open_tree(work)
    api.tree.expand_all()
    local ok, err = pcall(api.tree.reload)
    assert.is_true(ok, "tree.reload errored: " .. tostring(err))
  end)
end)
