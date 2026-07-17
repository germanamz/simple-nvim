-- Pins config.submodule_status: the per-submodule worktree-status cache keyed by
-- the cheap index state, shared by the pickers' bulk scan() and the tree's
-- on-demand request(). The real spawn path shells out to git, so those cases run
-- with the sandbox OFF; the single-flight / notify / revalidate logic is driven
-- through the swappable _resolve seam with no spawns.
local submodule_status = require("config.submodule_status")
local nvim_env = require("helpers.nvim_env")
local git_fixture = require("helpers.git_fixture")

local function write_file(dir, rel, content)
  local full = dir .. "/" .. rel
  vim.fn.mkdir(vim.fn.fnamemodify(full, ":h"), "p")
  local f = assert(io.open(full, "w"))
  f:write(content)
  f:close()
end

describe("config.submodule_status", function()
  local env_root, fired, group

  before_each(function()
    env_root = nvim_env.setup_isolated_env()
    submodule_status._reset()
    fired = {}
    group = vim.api.nvim_create_augroup("submodule_status_spec", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "SubmoduleStatusChanged",
      callback = function(args)
        table.insert(fired, args.data)
      end,
    })
  end)

  after_each(function()
    submodule_status._reset()
    vim.api.nvim_del_augroup_by_id(group)
    nvim_env.teardown(env_root)
  end)

  local function wait_fired(n)
    return vim.wait(3000, function()
      return #fired >= (n or 1)
    end, 10)
  end

  describe("get / dirty (cold)", function()
    it("return nil for a submodule that was never requested", function()
      assert.is_nil(submodule_status.get("/nope"))
      assert.is_nil(submodule_status.dirty("/nope"))
    end)
  end)

  describe("request (real spawn)", function()
    it("caches a dirty submodule's lines, marks it dirty, and fires once", function()
      local sp = git_fixture.superproject({ children = { "childA" } })
      write_file(sp.children.childA, "childA.txt", "changed\n")
      write_file(sp.children.childA, "new.lua", "x\n")
      submodule_status.request(sp.children.childA)
      assert.is_true(wait_fired(1))
      assert.are.equal(sp.children.childA, fired[1].dir)
      assert.is_true(submodule_status.dirty(sp.children.childA))
      local lines = submodule_status.get(sp.children.childA)
      assert.is_truthy(lines)
      assert.is_true(#lines >= 2) -- one modified + one untracked

      -- Already cached: a second request is a no-op (no spawn, no event).
      submodule_status.request(sp.children.childA)
      vim.wait(200, function()
        return #fired > 1
      end, 10)
      assert.are.equal(1, #fired)
    end)

    it("caches a clean submodule as resolved-and-not-dirty", function()
      local sp = git_fixture.superproject({ children = { "childA" } })
      submodule_status.request(sp.children.childA)
      assert.is_true(wait_fired(1))
      assert.is_false(submodule_status.dirty(sp.children.childA))
      assert.are.same({}, submodule_status.get(sp.children.childA))
    end)
  end)

  describe("scan (bulk, silent)", function()
    it("returns a key->lines map and fires NO SubmoduleStatusChanged", function()
      local sp = git_fixture.superproject({ children = { "childA", "childB" } })
      write_file(sp.children.childA, "new.lua", "x\n")
      local results
      submodule_status.scan({
        { key = "childA", dir = sp.children.childA },
        { key = "childB", dir = sp.children.childB },
      }, function(r)
        results = r
      end)
      assert.is_true(vim.wait(3000, function()
        return results ~= nil
      end, 10))
      assert.is_true(#results.childA >= 1) -- childA dirty
      assert.are.same({}, results.childB) -- childB clean
      assert.are.equal(0, #fired) -- bulk scan is silent
    end)

    it("completes immediately on an empty item list", function()
      local done = false
      submodule_status.scan({}, function()
        done = true
      end)
      assert.is_true(done)
    end)
  end)

  describe("single-flight + notify (seam-driven)", function()
    it("collapses a concurrent request + scan onto one resolve, notifying once", function()
      local cbs = {}
      submodule_status._resolve = function(_, cb)
        cbs[#cbs + 1] = cb
      end
      submodule_status.request("/x") -- notify path starts the resolve
      local scanned
      submodule_status.scan({ { key = "x", dir = "/x" } }, function(r)
        scanned = r
      end) -- attaches to the same in-flight resolve
      assert.are.equal(1, #cbs) -- single-flight: exactly one spawn
      cbs[1]({ " M a.lua" }) -- land
      assert.are.equal(1, #fired) -- notified exactly once
      assert.are.same({ " M a.lua" }, scanned.x)
      assert.are.same({ " M a.lua" }, submodule_status.get("/x"))
    end)

    it("does not fire or cache when a resolve fails", function()
      submodule_status._resolve = function(_, cb)
        cb(nil)
      end
      local scanned
      submodule_status.scan({ { key = "x", dir = "/x" } }, function(r)
        scanned = r
      end)
      assert.are.same({}, scanned.x) -- failure contributes empty
      assert.is_nil(submodule_status.get("/x")) -- not cached
      assert.are.equal(0, #fired)
    end)
  end)

  describe("revalidate / invalidate (seam-driven)", function()
    local function seed(dir, lines, state)
      submodule_status._resolve = function(_, cb)
        cb(lines)
      end
      submodule_status.scan({ { key = "k", dir = dir } }, function() end)
      -- overwrite the captured (nil) state for a fake dir with a controllable one
      if state ~= nil then
        submodule_status._set_state(dir, state)
      end
    end

    it("keeps entries whose index key is unchanged, drops changed ones", function()
      -- Two fake dirs seeded with known states; stub index_key via the util.git
      -- seam so revalidate's comparison is deterministic without real repos.
      local git = require("util.git")
      local real = git.index_key
      seed("/a", { " M x" })
      seed("/b", { " M y" })
      submodule_status._set_state("/a", "s1")
      submodule_status._set_state("/b", "s2")
      git.index_key = function(dir)
        if dir == "/a" then
          return "s1"
        end -- unchanged
        if dir == "/b" then
          return "s2-moved"
        end -- moved
        return nil
      end
      submodule_status.revalidate()
      git.index_key = real
      assert.is_not_nil(submodule_status.get("/a"))
      assert.is_nil(submodule_status.get("/b"))
    end)

    it("invalidate drops one entry; invalidate_all drops everything", function()
      seed("/a", { " M x" })
      seed("/b", { " M y" })
      submodule_status.invalidate("/a")
      assert.is_nil(submodule_status.get("/a"))
      assert.is_not_nil(submodule_status.get("/b"))
      submodule_status.invalidate_all()
      assert.is_nil(submodule_status.get("/b"))
    end)
  end)
end)
