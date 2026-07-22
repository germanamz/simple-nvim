-- The minuet spec (lua/plugins/minuet.lua) must wire a `stop` list into the
-- openai_fim_compatible provider so the local *base* model can't leak editor /
-- repo sentinel tokens (the reported `<|Cursor|>` bug) into the ghost text. This
-- pins the contract: run the spec's `config` with minuet stubbed, capture the
-- table it hands to minuet.setup, and assert the stops are present.
--
-- Unit init loads no plugins, so `require("minuet")` is stubbed here to capture
-- setup opts; config.ai's bootstrap (also invoked by config()) is guarded with
-- pcall in the spec, so it can't fail the test on a machine without Ollama.
describe("plugins.minuet FIM stop list", function()
  local captured
  local real_minuet

  before_each(function()
    captured = nil
    real_minuet = package.loaded["minuet"]
    -- Capturing stub: config() calls require("minuet").setup(opts); grab opts.
    package.loaded["minuet"] = {
      setup = function(opts)
        captured = opts
      end,
      config = {},
    }
    -- Re-require the spec fresh so its config() closure is rebuilt each run.
    package.loaded["plugins.minuet"] = nil
  end)

  after_each(function()
    package.loaded["minuet"] = real_minuet
    package.loaded["plugins.minuet"] = nil
    pcall(vim.api.nvim_del_user_command, "AIModel")
  end)

  local function run_config()
    local spec = require("plugins.minuet")
    assert.are.equal("function", type(spec.config))
    spec.config()
    assert.is_truthy(captured, "config() did not call minuet.setup")
    return captured
  end

  local function fim_stops(opts)
    local po = opts.provider_options or {}
    local fim = po.openai_fim_compatible or {}
    local optional = fim.optional or {}
    return optional.stop
  end

  it("passes a non-empty stop list to openai_fim_compatible", function()
    local stops = fim_stops(run_config())
    assert.are.equal("table", type(stops))
    assert.is_true(#stops > 0)
  end)

  it("stops on the reported `<|Cursor|>` sentinel (and its lowercase variant)", function()
    local stops = fim_stops(run_config())
    local set = {}
    for _, s in ipairs(stops) do
      set[s] = true
    end
    assert.is_true(set["<|Cursor|>"], "stop list must contain <|Cursor|>")
    assert.is_true(set["<|cursor|>"], "stop list must contain <|cursor|>")
  end)

  it("stops on the qwen2.5-coder repo/FIM structural tokens the base model spills", function()
    local stops = fim_stops(run_config())
    local set = {}
    for _, s in ipairs(stops) do
      set[s] = true
    end
    for _, tok in ipairs({ "<|file_sep|>", "<|repo_name|>", "<|fim_prefix|>", "<|endoftext|>" }) do
      assert.is_true(set[tok], "stop list must contain " .. tok)
    end
  end)
end)
