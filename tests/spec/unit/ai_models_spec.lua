local am = require("config.ai_models")

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
