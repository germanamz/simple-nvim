local nvim_env = require("tests.helpers.nvim_env")
local wait = require("tests.helpers.wait")

describe("smoke: checkhealth", function()
  local root

  before_each(function()
    root = nvim_env.setup_isolated_env()
  end)

  after_each(function()
    nvim_env.teardown(root)
  end)

  local targets = {
    { health = "nvim-treesitter", plugin = "nvim-treesitter" },
    { health = "telescope", plugin = "telescope.nvim" },
    { health = "vim.lsp" },
  }

  for _, target in ipairs(targets) do
    it("checkhealth " .. target.health .. " reports no errors", function()
      if target.plugin then
        require("lazy").load({ plugins = { target.plugin } })
      end
      vim.cmd("checkhealth " .. target.health)
      wait.wait_for(function()
        return vim.bo.filetype == "checkhealth"
      end, 5000, "checkhealth buffer never appeared for " .. target.health)

      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      local errors = {}
      for _, line in ipairs(lines) do
        if line:match("^ERROR:") or line:match("ERROR ") then
          errors[#errors + 1] = line
        end
      end
      assert.are.same({}, errors, "checkhealth " .. target.health .. " reported errors")
    end)
  end
end)
