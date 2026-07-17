-- Backs the mini.ai `o` ("object") textobject: select a whole dotted identifier
-- chain as one unit, so `app.property` (or `std::vec::Vec`, `obj:method`,
-- `app?.property`) can be operated on or surrounded in a single motion.
-- Wired in lua/plugins/mini-ai.lua; design in
-- docs/dotted-chain-textobject-design.md.
--
-- `a` and `i` deliberately select the same span: an identifier has no
-- meaningful "inside". `iw` already gives one segment and `af`/`if` cover the
-- call form.
local M = {}

-- Pre-escaped character-class FRAGMENTS (already `[]`-safe), appended to the
-- `%w_%.` base per filetype:
--   • `:` for lua (obj:method) and rust/cpp (std::vec::Vec).
--   • `?` (escaped to `%?`) for ts/js optional chaining (app?.property).
--
-- Deliberately NO `-`/`>` for C's `ptr->field`: a Lua character class cannot
-- express "a `-` followed by `>`", so admitting the arrow would also swallow
-- subtraction — `arr[i-1]` would select `i-1`, `n-1` would select `n-1`. C/C++
-- is the smallest slice of this stack and Go doesn't have `->` at all (pointer
-- access is plain `.`, and `<-` is a channel op, never part of a chain), so the
-- arrow is dropped. If it later proves worth it, mini.ai lets a composed-pattern
-- element be a callable `f(line, init) -> from, to` that could match `->` as a
-- real two-char token (must return from >= init). See the design doc.
local EXTRA_CLASS = {
  lua = ":",
  rust = ":",
  cpp = ":",
  typescript = "%?",
  typescriptreact = "%?",
  javascript = "%?",
  javascriptreact = "%?",
}

-- The character class of chain characters for a filetype, e.g. "%w_%.:".
function M.class(ft)
  return "%w_%." .. (EXTRA_CLASS[ft] or "")
end

-- A mini.ai composed pattern (outer match + extraction template) for a
-- filetype's dotted chain.
function M.spec(ft)
  local c = M.class(ft)
  -- Outer match: a run of chain chars ending on a word char. The frontier
  -- `%f[c]` (previous char is NOT a chain char) is load-bearing — mini.ai keeps
  -- the NARROWEST covering match, so without it `app.property` would offer both
  -- `app.property` and `property` as candidates and the cursor-on-`property`
  -- case would wrongly select just `property`. Requiring the previous char to
  -- be outside the class means only one span (the full chain) ever matches.
  -- The trailing `[%w_]` stops the match on a word char, so a chain never keeps
  -- a dangling separator (e.g. `app.` -> `app`).
  local outer = "%f[" .. c .. "][" .. c .. "]*[%w_]"
  -- Extraction: strip any leading separator run. Filetype-agnostic because the
  -- outer match can only contain class chars, so any leading non-word char is a
  -- separator. Four identical capture pairs make `a` and `i` the same span.
  local extract = "^[^%w_]*()().*()()$"
  return { outer, extract }
end

return M
