-- Placeholder spec to keep PlenaryBustedDirectory a no-op for `make test-lsp`.
-- Real-server e2e-lsp specs (lua_ls/ts_ls) are designed in
-- docs/superpowers/plans/2026-04-26-testing/phase-6-ci-lsp-cleanup.md (Task 4)
-- but intentionally not yet landed: the lane needs mason servers installed and
-- is kept out of the default `make test`. Remove this once those specs land.
describe("placeholder", function()
  it("is a no-op", function()
    assert.is_true(true)
  end)
end)
