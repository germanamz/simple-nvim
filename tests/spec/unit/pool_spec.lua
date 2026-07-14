describe("util.pool", function()
  before_each(function()
    package.loaded["util.pool"] = nil
  end)

  it("bounds GIT_CONCURRENCY to [4, 24]", function()
    local pool = require("util.pool")
    assert.is_true(type(pool.GIT_CONCURRENCY) == "number")
    assert.is_true(pool.GIT_CONCURRENCY >= 4)
    assert.is_true(pool.GIT_CONCURRENCY <= 24)
  end)

  it("floors at 4, scales by cores-2, and caps at 24", function()
    local orig = vim.uv.available_parallelism
    local function concurrency_for(cores)
      vim.uv.available_parallelism = function()
        return cores
      end
      package.loaded["util.pool"] = nil
      return require("util.pool").GIT_CONCURRENCY
    end
    local ok, err = pcall(function()
      assert.are.equal(4, concurrency_for(1)) -- floor: 1-2 clamps up to 4
      assert.are.equal(4, concurrency_for(6)) -- 6-2=4, still the floor
      assert.are.equal(14, concurrency_for(16)) -- 16-2=14, in range
      assert.are.equal(24, concurrency_for(100)) -- cap: 100-2 clamps down to 24
    end)
    -- Always restore the real function and drop the stubbed module, even on failure.
    vim.uv.available_parallelism = orig
    package.loaded["util.pool"] = nil
    assert.is_true(ok, tostring(err))
  end)
end)
