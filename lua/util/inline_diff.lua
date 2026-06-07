-- Byte-level common-affix diff, extracted from gitsigns' word-diff painter so
-- the fiddly prefix/suffix arithmetic is testable on its own.
local M = {}

-- Compare two byte strings and return:
--   prefix  - length of the shared leading run
--   old_mid - length of the differing middle span in `old`
--   new_mid - length of the differing middle span in `new`
-- The shared suffix is implied (it is whatever lies past the middle spans).
-- The suffix scan is bounded so the spans never overlap the prefix.
function M.middle_span(old, new)
  local olen, nlen = #old, #new
  local p = 0
  while p < olen and p < nlen and old:byte(p + 1) == new:byte(p + 1) do
    p = p + 1
  end
  local s = 0
  while s < olen - p and s < nlen - p and old:byte(olen - s) == new:byte(nlen - s) do
    s = s + 1
  end
  return { prefix = p, old_mid = olen - p - s, new_mid = nlen - p - s }
end

return M
