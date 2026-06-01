local nvim_env = require("tests.helpers.nvim_env")

-- Launching nvim on a directory (`nvim .`) should open nvim-tree instead of
-- netrw, while staying lazy for ordinary launches and leaving netrw's :Explore
-- (the <leader>E fallback) intact. The directory-launch path hinges on a
-- startup race — nvim-tree's setup() must run before the directory buffer is
-- read — so that case is exercised by spawning a real child nvim. Laziness and
-- the option wiring are asserted in-process.
describe("e2e: nvim-tree directory launch", function()
  -- Repo root, derived from the harness that resolves it onto the runtimepath.
  local full_init = vim.api.nvim_get_runtime_file("tests/full_init.lua", false)[1]
    or (vim.fn.getcwd() .. "/tests/full_init.lua")
  local repo = vim.fn.fnamemodify(full_init, ":h:h")

  it("does not eager-load nvim-tree when launched without a directory", function()
    -- This harness booted with no file argument, so the spec's `init` hook must
    -- not have pulled nvim-tree in — it stays lazy until a directory or keymap.
    assert.is_nil(
      package.loaded["nvim-tree"],
      "nvim-tree was loaded at boot despite no directory argument"
    )
  end)

  it("wires hijack_netrw on, netrw enabled, and a directory-launch hook", function()
    -- Read the source spec directly: these are the declarations that make a
    -- directory launch show the tree while keeping netrw's :Explore fallback.
    local spec = dofile(repo .. "/lua/plugins/nvim-tree.lua")

    assert.is_true(spec.opts.hijack_netrw, "hijack_netrw must be on for `nvim .` to show the tree")
    assert.is_false(spec.opts.disable_netrw, "netrw must stay enabled for the :Explore fallback")
    assert.are.equal(
      "function",
      type(spec.init),
      "the directory-launch eager-load hook (init) is missing"
    )
  end)

  describe("on a real directory launch", function()
    local root

    before_each(function()
      root = nvim_env.setup_isolated_env()
    end)

    after_each(function()
      nvim_env.teardown(root)
    end)

    it("opens nvim-tree (not netrw), with :Explore still on netrw", function()
      -- Boots the real config (via tests/full_init.lua) on a directory and
      -- records the outcome. The probe writes its JSON result atomically (.part
      -- then rename) so the parent never reads a half-written file while polling.
      local probe = root .. "/probe.lua"
      local pf = assert(io.open(probe, "w"))
      pf:write([[
local function fts()
  local t = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    t[#t + 1] = vim.api.nvim_get_option_value("filetype", { buf = b })
  end
  return t
end
local result = { startup_fts = fts(), tree_loaded = package.loaded["nvim-tree"] ~= nil }
pcall(vim.cmd, "silent! Explore")
result.explore_fts = fts()
local out = assert(os.getenv("PROBE_OUT"))
local fd = assert(io.open(out .. ".part", "w"))
fd:write(vim.json.encode(result))
fd:close()
os.rename(out .. ".part", out)
]])
      pf:close()

      local dir = root .. "/proj"
      vim.fn.mkdir(dir, "p")
      local out = root .. "/result.json"
      vim.env.PROBE_OUT = out

      -- Spawn async (jobstart, not vim.fn.system): a synchronous spawn blocks
      -- the main loop, and under plenary's coroutine runner the child deadlocks
      -- mid-boot. Polling for the result keeps the loop pumping.
      local jid = vim.fn.jobstart({
        vim.v.progpath,
        "--headless",
        "-n", -- no swapfile
        "-i",
        "NONE", -- no shada
        "-u",
        full_init,
        dir,
        "-c",
        "luafile " .. probe,
        "-c",
        "qa!",
      })
      assert.is_true(jid > 0, "jobstart failed to launch the child nvim")

      local produced = vim.wait(60000, function()
        return vim.fn.filereadable(out) == 1
      end, 50)
      vim.env.PROBE_OUT = nil
      pcall(vim.fn.jobstop, jid)
      assert.is_true(produced, "child nvim never produced a result on a directory launch")

      local fd = assert(io.open(out, "r"))
      local r = vim.json.decode(fd:read("*a"))
      fd:close()

      assert.is_true(r.tree_loaded, "nvim-tree did not load for a directory launch")
      assert.is_true(
        vim.tbl_contains(r.startup_fts, "NvimTree"),
        "expected an NvimTree window at startup, saw: " .. vim.inspect(r.startup_fts)
      )
      -- hijack_netrw suppresses netrw's auto-open but leaves :Explore intact, so
      -- the <leader>E fallback still reaches netrw.
      assert.is_true(
        vim.tbl_contains(r.explore_fts, "netrw"),
        ":Explore fallback no longer reaches netrw, saw: " .. vim.inspect(r.explore_fts)
      )
    end)
  end)
end)
