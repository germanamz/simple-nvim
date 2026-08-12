-- `:help` is the answer for Lua, not a URL.
--
-- So this adapter is help_tag and nothing else. There is no manifest to walk to
-- and no `deps` to list — and no `url`, because LuaRocks pages are keyed on the
-- uploader (luarocks.org/modules/<user>/<rock>) and the rock name alone does not
-- give us that segment, so any URL built here would be a guess.
--
-- Everything below exists because the help tag namespace is not the Lua
-- namespace, and the mismatch is not uniform. Each row was checked by calling
-- vim.fn.getcompletion(word, "help") for real:
--
--   vim.api.nvim_buf_set_lines  ->  nvim_buf_set_lines()   api.txt
--   vim.fn.expand               ->  expand()               vimfn.txt
--   vim.uv.fs_stat              ->  uv.fs_stat()           luvref.txt
--   vim.o.expandtab             ->  'expandtab'            options.txt
--   vim.v.count                 ->  v:count                vvars.txt
--   vim.g.mapleader             ->  mapleader              map.txt
--   vim.lsp.buf.hover           ->  vim.lsp.buf.hover()    lsp.txt
--   string.format               ->  string.format()        luaref.txt
--
-- The first six words return {} outright: the tag simply does not exist under
-- the name the code spells, so gK on them without the rewrite is an E149. The
-- last two are the shape that needs no prefix stripped at all. Sorting words
-- into those two piles is the whole adapter.
--
-- Nothing is returned until getcompletion has confirmed it. config.docs.init
-- hands the tag straight to vim.cmd.help, so an unconfirmed tag is an E149 in
-- the user's face; and because a non-nil help_tag short-circuits the entire gK
-- cascade, a *wrong* tag also costs the lua_ls hover that would have answered
-- properly. Both failure modes are worse than nil, which the driver handles.

local M = {}

M.ft = { "lua" }

--- Does `tag` exist verbatim?
---
--- A non-empty completion result proves nothing. Help completion is not a prefix
--- match: it matches inside a tag too ("lsp.buf.hover" returns
--- "vim.lsp.buf.hover()"), it ignores case ("VIM.SPLIT" returns "vim.split()"),
--- and it is fuzzy enough that "nvim_buf_set_line" returns the plural. Only an
--- identical entry in the list confirms the tag.
---
--- Not pcall'd: help completion swallows its own pattern errors — `\v(`,
--- `a\{1,`, `[]` and a 3000-character word all return a list rather than raising
--- — so there is no throw to catch on the keypress path.
---@param tag string
---@return boolean
local function exists(tag)
  for _, found in ipairs(vim.fn.getcompletion(tag, "help")) do
    if found == tag then
      return true
    end
  end
  return false
end

--- Word prefixes that name a tag namespace outright. Each row is a pattern with
--- one capture — the member — followed by the string.format templates that turn
--- that member into candidate tags, tried in order.
---
--- Families are handled exclusively: a miss inside one yields no candidates at
--- all rather than falling through to the generic guesses below. The prefix has
--- already told us which chapter owns the word, so an undocumented
--- `vim.api.nvim_whatever` is a real "not in the docs", and answering it with
--- `:help vim.api` would bury the lua_ls hover that knows the signature.
---
--- Row order is only for reading: every pattern demands a literal dot after its
--- prefix, so `vim.opt_local.x` cannot reach the `vim.opt.` row and `vim.bo.x`
--- cannot reach the `vim.b.` one.
local FAMILIES = {
  -- api.txt and vimfn.txt tag every function with its parens and under its bare
  -- name: the `vim.api.` / `vim.fn.` the code spells is part of no tag at all.
  { "^vim%.api%.([%w_]+)$", "%s()" },
  { "^vim%.fn%.([%w_]+)$", "%s()" },
  -- luvref.txt documents libuv under its own `uv.` prefix, so this swaps one
  -- prefix for another rather than dropping it. vim.loop is the deprecated alias
  -- and lands in the same place (`loop.fs_stat` matches nothing).
  { "^vim%.uv%.([%w_]+)$", "uv.%s()", "uv.%s" },
  { "^vim%.loop%.([%w_]+)$", "uv.%s()", "uv.%s" },
  -- Options are tagged in their Vimscript spelling, quotes included, and the
  -- abbreviations are tags too ('ts' as well as 'tabstop'), so whichever form a
  -- config writes resolves without a table of aliases here.
  { "^vim%.opt_local%.([%w_]+)$", "'%s'" },
  { "^vim%.opt_global%.([%w_]+)$", "'%s'" },
  { "^vim%.opt%.([%w_]+)$", "'%s'" },
  { "^vim%.o%.([%w_]+)$", "'%s'" },
  { "^vim%.bo%.([%w_]+)$", "'%s'" },
  { "^vim%.wo%.([%w_]+)$", "'%s'" },
  { "^vim%.go%.([%w_]+)$", "'%s'" },
  -- Same idea for the scope dictionaries: v:count, b:changedtick and
  -- w:quickfix_title are tags, `vim.v.count` and friends are not.
  { "^vim%.v%.([%w_]+)$", "v:%s" },
  { "^vim%.b%.([%w_]+)$", "b:%s" },
  { "^vim%.w%.([%w_]+)$", "w:%s" },
  { "^vim%.t%.([%w_]+)$", "t:%s" },
  -- vim.g earns the extra bare rung: map.txt tags the two globals a config is
  -- most likely to sit on, `mapleader` and `maplocalleader`, under their bare
  -- names with no `g:` tag at all. The `g:` form still goes first, and it is the
  -- one that exists for the globals Neovim documents with a prefix
  -- (g:clipboard, g:python3_host_prog), so the fallback only runs where there
  -- is no prefixed tag to find.
  { "^vim%.g%.([%w_]+)$", "g:%s", "%s" },
}

--- Tag candidates for a bare (undotted) identifier.
---
--- The dangerous case. In a Lua buffer most bare words are locals, and the tag
--- namespace is full of Vimscript builtins wearing the same names: `count`,
--- `line`, `col`, `bufnr`, `state`, `insert`, `sort`, `map`, `match`, `filter`
--- and `mode` all confirm as `<name>()`, and every one of them is a local this
--- config declares somewhere. Confirmation alone is therefore not enough here —
--- the word also has to prove it belongs to a namespace we can name.
---
--- Two ways it can: Neovim's own Lua state says it is a global function (the set
--- the Lua manual documents — assert, ipairs, pcall, require, select,
--- setmetatable...), or it is CamelCase, which in practice means an autocmd
--- event, all of which are tags.
---
--- `type` is excluded by name because it is the single global where the two
--- namespaces collide: help tags are globally unique and `type()` is owned by
--- vimfn.txt, so Lua's type() has no reachable tag and claiming it would answer
--- a Lua question with Vimscript's docs. It is the only one — the other 26
--- tagged globals all resolve into luaref.txt.
---
--- The CamelCase gate is `%u%l`, not merely "has an uppercase letter", because
--- of `M`: `local M = {}` is this config's module convention and `M` is also a
--- help tag (the middle-of-window motion). Beyond that one, the CamelCase names
--- a Lua file carries — Opts, Config, Client, State, Range, Node — have no exact
--- tag, so the confirmation step covers them.
---@param word string
---@return string[]
local function bare_candidates(word)
  if word ~= "type" and type(_G[word]) == "function" then
    return { word .. "()" }
  end
  if word:match("^%u%l") then
    return { word }
  end
  return {}
end

--- The ordered tag candidates for `word`, most specific first.
---
--- Exposed for unit tests: it asks nothing of the help tags (that is `exists`'s
--- job), so the ladder can be asserted against fixture words on its own.
---@param word string
---@return string[]
function M._candidates(word)
  -- Every other adapter type-checks rather than comparing to "": the driver
  -- always passes a string today, but a nil here would index a nil local and
  -- take the keymap down rather than falling through to the next mechanism.
  if type(word) ~= "string" or word == "" then
    return {}
  end

  for _, family in ipairs(FAMILIES) do
    local member = word:match(family[1])
    if member then
      local tags = {}
      for i = 2, #family do
        tags[#tags + 1] = family[i]:format(member)
      end
      return tags
    end
  end

  local out = {}
  if word:find(".", 1, true) then
    -- Anything else dotted is already spelled the way lua.txt, lsp.txt and the
    -- plugin docs spell their tags (vim.lsp.buf.hover(), vim.keymap.set(),
    -- string.format(), uv.fs_stat() via a `local uv = vim.uv`). Parens first:
    -- where both forms exist (vim.iter, vim.regex, vim.version) the cursor is on
    -- a call far more often than on the module.
    out[#out + 1] = word .. "()"
    out[#out + 1] = word
    -- One trailing segment, and only one, for constants living inside a
    -- documented table: vim.log.levels.WARN and vim.diagnostic.severity.ERROR
    -- have no tags of their own but their tables do. Trimming further would just
    -- walk up to a chapter page (`:help vim.lsp`) and short-circuit the cascade
    -- ahead of the hover that could still answer precisely.
    local table_name = word:match("^(vim%..+)%.[%w_]+$")
    if table_name then
      out[#out + 1] = table_name
    end
  else
    vim.list_extend(out, bare_candidates(word))
  end

  -- `local api = vim.api` is common enough to be worth a rung, and the last
  -- segment can be tried safely here where it could not be in general: `nvim_`
  -- names nothing outside api.txt. Covers a bare `nvim_buf_set_lines` too.
  local last = word:match("[^.]+$")
  if last and last:match("^nvim_[%w_]+$") then
    out[#out + 1] = last .. "()"
  end

  return out
end

--- A confirmed `:help` tag for the identifier under the cursor, or nil.
---@param ctx DocCtx
---@return string|nil
function M.help_tag(ctx)
  for _, tag in ipairs(M._candidates(ctx.word)) do
    if exists(tag) then
      return tag
    end
  end
  return nil
end

return M
