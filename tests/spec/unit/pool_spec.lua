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

  it("scales to available parallelism (cores - 2), floored/capped", function()
    -- Recompute the formula independently and confirm the module matches it.
    local cores = vim.uv.available_parallelism and vim.uv.available_parallelism() or 8
    local expected = math.max(4, math.min(cores - 2, 24))
    assert.are.equal(expected, require("util.pool").GIT_CONCURRENCY)
  end)
end)
