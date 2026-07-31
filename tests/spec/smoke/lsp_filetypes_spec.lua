-- Pins the one property biome's narrowed filetype list exists to hold: no
-- filetype gets two language servers claiming it.
--
-- biome's own default list covers json/jsonc/css/graphql on top of js/jsx/ts/tsx,
-- and lua/plugins/lsp.lua narrows it off those four because jsonls, cssls and
-- the graphql server already own them. Restoring biome's defaults — the obvious
-- "why are we fighting the plugin's own config" edit — silently reinstates two
-- servers and duplicate diagnostics on every .json and .css file in a biome
-- repo, with nothing else in the suite to notice.
local nvim_env = require("tests.helpers.nvim_env")

describe("smoke: language server filetype ownership", function()
  local root

  before_each(function()
    root = nvim_env.setup_isolated_env()
    -- The LSP stack is deferred to BufReadPre/BufNewFile; loading
    -- mason-lspconfig stands in for opening the first real file.
    require("lazy").load({ plugins = { "mason-lspconfig.nvim" } })
  end)

  after_each(function()
    nvim_env.teardown(root)
  end)

  local function filetypes(server)
    local cfg = vim.lsp.config[server]
    return (cfg and cfg.filetypes) or {}
  end

  local function set_of(server)
    local out = {}
    for _, ft in ipairs(filetypes(server)) do
      out[ft] = true
    end
    return out
  end

  it("registers biome for the four JS/TS filetypes", function()
    assert.are.same(
      { "javascript", "javascriptreact", "typescript", "typescriptreact" },
      filetypes("biome")
    )
  end)

  -- The list above is the decision; this is the reason for it. Asserted as a
  -- property rather than a second copy of the list, so it keeps holding if the
  -- JS/TS set is ever revised for some unrelated reason.
  for _, other in ipairs({ "jsonls", "cssls", "graphql" }) do
    it("gives biome no filetype that " .. other .. " already claims", function()
      local theirs = set_of(other)
      assert.is_true(next(theirs) ~= nil, other .. " has no filetypes; the check would be vacuous")
      for _, ft in ipairs(filetypes("biome")) do
        assert.is_nil(theirs[ft], ("biome and %s both claim %q"):format(other, ft))
      end
    end)
  end
end)
