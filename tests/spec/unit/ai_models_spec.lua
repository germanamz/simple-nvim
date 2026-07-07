local am = require("config.ai_models")
local nvim_env = require("helpers.nvim_env")

-- _build_rows(active, installed, cache_names, fim_only) is the modal's pure
-- merge/rank core (three-source dedupe, the resolved-fim-beats-curated-hint
-- rule, the active/installed/FIM rank order). _show_cache is the module state
-- it reads; tests seed it and clear their entries after each case.
describe("config.ai_models._build_rows", function()
  after_each(function()
    for k in pairs(am._show_cache) do
      am._show_cache[k] = nil
    end
  end)

  local function installed_set(names, map)
    return { map = map or {}, names = names, reachable = true }
  end

  local function rows_by_name(rows)
    local by = {}
    for _, r in ipairs(rows) do
      by[r.name] = r
    end
    return by
  end

  local function pos(rows, name)
    for i, r in ipairs(rows) do
      if r.name == name then
        return i
      end
    end
  end

  it("dedupes: an installed name:tag wins over the curated tag row", function()
    local rows = am._build_rows(
      "none",
      installed_set(
        { "qwen2.5-coder:7b-base" },
        { ["qwen2.5-coder:7b-base"] = { size = 5e9, family = "qwen2" } }
      ),
      {},
      false
    )
    local count = 0
    for _, r in ipairs(rows) do
      if r.name == "qwen2.5-coder:7b-base" then
        count = count + 1
        assert.is_true(r.installed)
        assert.are.equal(5e9, r.size)
      end
    end
    assert.are.equal(1, count)
  end)

  it("dedupes an installed bare name against the library cache", function()
    local rows = am._build_rows("none", installed_set({ "mistral" }), { "mistral" }, false)
    local count = 0
    for _, r in ipairs(rows) do
      if r.name == "mistral" then
        count = count + 1
        assert.is_true(r.installed)
      end
    end
    assert.are.equal(1, count)
  end)

  it("marks an exact curated tag FIM when installed", function()
    local by =
      rows_by_name(am._build_rows("none", installed_set({ "codellama:7b-code" }), {}, false))
    assert.is_true(by["codellama:7b-code"].fim)
  end)

  it("gives an installed non-catalog tag NO curated hint (gate stays authoritative)", function()
    -- Regression: a family-keyed hint let codellama:7b-instruct inherit the
    -- base tags' fim=true and skip the <CR> /api/show check.
    local by =
      rows_by_name(am._build_rows("none", installed_set({ "codellama:7b-instruct" }), {}, false))
    assert.is_nil(by["codellama:7b-instruct"].fim)
  end)

  it("lets a resolved fim=false beat the curated fim=true hint", function()
    am._show_cache["qwen2.5-coder:7b-base"] = { fim = false }
    local by =
      rows_by_name(am._build_rows("none", installed_set({ "qwen2.5-coder:7b-base" }), {}, false))
    assert.is_false(by["qwen2.5-coder:7b-base"].fim)
  end)

  it("falls back to the curated hint when nothing is resolved", function()
    local by =
      rows_by_name(am._build_rows("none", installed_set({ "qwen2.5-coder:7b-base" }), {}, false))
    assert.is_true(by["qwen2.5-coder:7b-base"].fim)
  end)

  it("ranks active first, then installed, then FIM-eligible, then by name", function()
    -- "acoder" is FIM-eligible by the name heuristic; "not-eligible" is not.
    local rows = am._build_rows(
      "zzz-chat",
      installed_set({ "zzz-chat", "aaa-model" }),
      { "not-eligible", "acoder" },
      false
    )
    assert.are.equal("zzz-chat", rows[1].name)
    assert.is_true(rows[1].active)
    -- Installed beats any non-installed row, even a curated FIM tag.
    assert.is_true(pos(rows, "aaa-model") < pos(rows, "qwen2.5-coder:0.5b-base"))
    -- Among non-installed rows, FIM-eligible beats not-eligible.
    assert.is_true(pos(rows, "acoder") < pos(rows, "not-eligible"))
  end)

  it("fim_only drops non-eligible rows and keeps eligible ones", function()
    local by =
      rows_by_name(am._build_rows("none", installed_set({ "llama3.1" }), { "zz-plain" }, true))
    assert.is_nil(by["llama3.1"]) -- curated chat family: fim = false
    assert.is_nil(by["zz-plain"]) -- unknown, name not coder/base
    assert.is_not_nil(by["qwen2.5-coder:7b-base"]) -- curated FIM tag survives
  end)
end)

-- The default completion model is single-sourced: config.ai exports it and
-- ai_models reads the export (its "nothing installed" hint), so the two
-- modules cannot silently diverge on what the fallback model is.
describe("config.ai_models default model", function()
  local env_root

  before_each(function()
    env_root = nvim_env.setup_isolated_env()
  end)

  after_each(function()
    nvim_env.teardown(env_root)
  end)

  it("exposes config.ai.DEFAULT_MODEL as the persisted-model fallback", function()
    local ai = require("config.ai")
    assert.are.equal("string", type(ai.DEFAULT_MODEL))
    assert.is_true(#ai.DEFAULT_MODEL > 0)
    assert.are.equal(ai.DEFAULT_MODEL, ai.load_persisted_model())
  end)
end)

-- pull_model / scrape_library shell out to raw curl via vim.system; these specs
-- pin the watchdog argv (stall / timeout guards) and the active_pull lifecycle.
-- vim.system is stubbed to capture argv and hand the on_exit callback to the
-- test — real curl to ollama.com / localhost must never run here.
describe("config.ai_models curl watchdogs", function()
  local real_system, spawns

  local function argv_has_pair(argv, flag, value)
    for i, a in ipairs(argv) do
      if a == flag and argv[i + 1] == value then
        return true
      end
    end
    return false
  end

  before_each(function()
    spawns = {}
    real_system = vim.system
    vim.system = function(argv, opts, on_exit)
      local s = { argv = argv, opts = opts }
      function s.exit(res)
        s.exited = true
        if on_exit then
          on_exit(res)
        end
      end
      spawns[#spawns + 1] = s
      return { pid = 0 }
    end
  end)

  after_each(function()
    -- Complete every "process" the test left running so active_pull never
    -- wedges into the next case (on_exit is the only place the module clears
    -- it), then drain the callbacks it scheduled.
    for _, s in ipairs(spawns) do
      if not s.exited then
        s.exit({ code = 0 })
      end
    end
    vim.wait(10)
    vim.system = real_system
  end)

  it("pull_model curl argv carries stall detection (--speed-limit/--speed-time)", function()
    am._pull_model("stub-model", function() end, function() end, function() end)
    assert.are.equal(1, #spawns)
    local argv = spawns[1].argv
    assert.are.equal("curl", argv[1])
    assert.is_true(argv_has_pair(argv, "--speed-limit", "1"))
    assert.is_true(argv_has_pair(argv, "--speed-time", "300"))
  end)

  it("a nonzero pull exit (curl 28 stall abort) fails the pull and frees the guard", function()
    local err_msg
    am._pull_model("stub-model", function() end, function()
      error("on_done must not run for a nonzero exit")
    end, function(e)
      err_msg = e
    end)
    assert.are.equal(1, #spawns)
    spawns[1].exit({ code = 28 })
    vim.wait(200, function()
      return err_msg ~= nil
    end)
    assert.are.equal("string", type(err_msg))
    assert.is_truthy(err_msg:find("28", 1, true))
    -- Guard cleared: a second pull must spawn, not be rejected as concurrent.
    am._pull_model("stub-model", function() end, function() end, function() end)
    assert.are.equal(2, #spawns)
  end)

  it("the vim.system scrape fallback bounds curl with --max-time 10", function()
    local real_curl = package.loaded["plenary.curl"]
    package.loaded["plenary.curl"] = {
      get = function()
        error("forced failure: route scrape_library onto the vim.system fallback")
      end,
    }
    local ok, err = pcall(am._scrape_library, function() end, function() end)
    package.loaded["plenary.curl"] = real_curl
    assert.is_true(ok, err)
    assert.are.equal(1, #spawns)
    local argv = spawns[1].argv
    assert.are.equal("curl", argv[1])
    assert.is_true(argv_has_pair(argv, "--max-time", "10"))
  end)
end)
