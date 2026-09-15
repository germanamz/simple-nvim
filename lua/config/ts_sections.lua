-- `]]` / `[[` as a treesitter section motion, for every filetype with a parser.
--
-- Stock `]]` is documented (`:h ]]`) as "next `{` in the FIRST COLUMN". Neovim's
-- runtime ships purpose-built replacements for go/python/rust/vim/markdown/sql
-- and a handful of others, but ftplugin/c.vim and cpp.vim map nothing — so C and
-- C++ fall through to that literal column-1 search. Written brace-on-the-
-- signature-line (`int alpha(int x) {`) a file has no column-1 braces at all and
-- `]]` silently runs to EOF, skipping every function. This replaces the motion
-- with one derived from the syntax tree, uniformly, in every parser-backed
-- buffer.
--
-- Targets come from two tiers, chosen per language rather than from a
-- hand-maintained node-type table:
--
--   1. The language's own `locals` query: `@local.definition.function` and
--      `@local.definition.method`. Those captures land on the definition's NAME
--      identifier, which is what makes anonymous inline closures
--      (`xs.map(x => x + 1)`) fall out for free — they have no name to capture.
--      Covers c, cpp, lua, javascript, typescript/tsx (via `; inherits: ecma`),
--      python, go, rust, zig, bash, vim, starlark.
--
--   2. Languages whose locals query has no function captures at all (hcl,
--      terraform, sql, css, json, yaml, graphql, fga, toml, html, git_config,
--      markdown) fall back to structural nodes: see structural_nodes below.
--
-- The jump lands on the first non-blank column of the row a target starts on,
-- so `]]` on `int alpha(int x) {` stops at `int` rather than at `alpha` — a
-- section motion, and no ancestor-walking guesswork to get there.
--
-- See docs/section-motion.md.
local M = {}

local cache = {} -- [buf] = { tick = <changedtick>, targets = {...} }

-- How far to walk down through wrapper levels before giving up. Real grammars
-- need one or two (json document>object, terraform config_file>body); the bound
-- just stops a pathological tree from turning this into a descent loop.
local MAX_DESCENT = 4

local FUNCTION_CAPTURES = {
  ["local.definition.function"] = true,
  ["local.definition.method"] = true,
}

-- True when `node` contains a named child of its own type. Such a node is a
-- recursive container — a markdown `section` holding its sub-sections — which
-- means the node itself is the section unit and its children are its contents,
-- not a list of siblings to enumerate. Descending past one turns `]]` in a
-- single-`# Heading` markdown file into a paragraph motion.
local function nests_own_type(node)
  for child in node:iter_children() do
    if child:named() and child:type() == node:type() then
      return true
    end
  end
  return false
end

-- Collect `node` plus any same-type descendants, so markdown's nested sections
-- are targets alongside the top-level ones rather than being swallowed by them.
local function add_with_nested(out, node)
  out[#out + 1] = node
  for child in node:iter_children() do
    if child:named() and child:type() == node:type() then
      add_with_nested(out, child)
    end
  end
end

-- Tier 2. Grammars wrap the real top level in one or more single-child nodes
-- (json `document` > `object`, terraform `config_file` > `body`), so taking the
-- root's children literally would yield one useless target covering the whole
-- file. Descend through those wrappers, stopping at a node that nests its own
-- type, then take that level's named children.
local function structural_nodes(root)
  local node = root
  for _ = 1, MAX_DESCENT do
    if node:named_child_count() ~= 1 then
      break
    end
    local child = node:named_child(0)
    -- A lone child with nothing under it is the content, not a wrapper.
    if child:named_child_count() < 2 or nests_own_type(child) then
      break
    end
    node = child
  end

  local out = {}
  for child in node:iter_children() do
    if child:named() then
      add_with_nested(out, child)
    end
  end
  return out
end

-- The definition a captured name belongs to: the highest ancestor still
-- starting on the name's own row, stopping short of the root. `alpha` in
-- `int alpha(int x) {` walks identifier > function_declarator >
-- function_definition and stops there, because translation_unit starts further
-- up the file. Excluding the root is what keeps a function on line 1 from
-- resolving to the whole tree.
local function enclosing_definition(node, root)
  local best = node
  local parent = node:parent()
  while parent and parent ~= root and parent:start() == node:start() do
    best = parent
    parent = parent:parent()
  end
  return best
end

-- Definition nodes found without any help from the locals query, for files
-- whose captures come up empty. A C++ header holding nothing but a class of
-- inline methods is the motivating case: cpp/locals.scm captures none of them,
-- so there is no capture to learn a type from.
--
-- A definition is a node whose type mentions function or method AND that has
-- both a body and something naming it. Those two field tests are what keep this
-- from needing a per-grammar list: `function_call` (lua) has a name but no body,
-- `arrow_function` (javascript) has a body but no name, and `function_declarator`
-- (c) has neither a body nor a reason to be listed separately from the
-- definition wrapping it. All three drop out on their own.
local function seed_definitions(root)
  local out = {}
  local function scan(node)
    for child in node:iter_children() do
      if child:named() then
        local kind = child:type()
        if
          (kind:find("function", 1, true) or kind:find("method", 1, true))
          and child:field("body")[1]
          and (child:field("name")[1] or child:field("declarator")[1])
        then
          out[#out + 1] = child
        end
        scan(child)
      end
    end
  end
  scan(root)
  return out
end

-- Tier 1. Nodes captured as function/method definitions by the language's
-- locals query, or nil when the language has no such captures (which is the
-- signal to fall back rather than to report "no sections here").
--
-- The captures alone are not enough. cpp/locals.scm has no pattern for a method
-- DEFINED inline in a class — those are function_definition nodes, while its
-- only method pattern matches field_declaration, a declaration without a body —
-- so a class body would contribute nothing. Rather than hand-maintain a list of
-- definition node types per language, learn them: resolve each capture to its
-- enclosing definition, then sweep the tree for every other node of the same
-- type. One out-of-class `void Widget::other()` teaches us `function_definition`
-- and the inline methods come along with it.
--
-- Learning the types beats matching them by name (`type:match("function")`)
-- because it inherits the captures' own exclusion of anonymous functions: in
-- javascript it learns `function_declaration` and leaves `arrow_function` alone.
local function function_nodes(root, buf, lang)
  local ok, query = pcall(vim.treesitter.query.get, lang, "locals")
  if not ok or not query then
    return nil
  end

  local out, types = {}, {}
  for id, node in query:iter_captures(root, buf, 0, -1) do
    if FUNCTION_CAPTURES[query.captures[id]] then
      local def = enclosing_definition(node, root)
      out[#out + 1] = def
      types[def:type()] = true
    end
  end
  if #out == 0 then
    out = seed_definitions(root)
    if #out == 0 then
      return nil
    end
    for _, node in ipairs(out) do
      types[node:type()] = true
    end
  end

  local function sweep(node)
    for child in node:iter_children() do
      if child:named() then
        if types[child:type()] then
          out[#out + 1] = child
        end
        sweep(child)
      end
    end
  end
  sweep(root)
  return out
end

-- First non-blank column of `row` (0-indexed), or 0 for a blank/absent line.
local function first_non_blank(buf, row)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  if not line then
    return 0
  end
  local indent = line:match("^%s*")
  return #indent < #line and #indent or 0
end

-- Sorted, row-deduplicated jump targets for `buf` as { row = 0-indexed,
-- col = 0-indexed }. Empty when the buffer has no parser.
function M.targets(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return {}
  end

  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local hit = cache[buf]
  if hit and hit.tick == tick then
    return hit.targets
  end

  local targets = {}
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if ok and parser then
    local tree = parser:parse()[1]
    if tree then
      local root = tree:root()
      local nodes = function_nodes(root, buf, parser:lang()) or structural_nodes(root)
      local seen = {}
      for _, node in ipairs(nodes) do
        local row = node:start()
        if not seen[row] then
          seen[row] = true
          targets[#targets + 1] = { row = row, col = first_non_blank(buf, row) }
        end
      end
      table.sort(targets, function(a, b)
        return a.row < b.row
      end)
    end
  end

  cache[buf] = { tick = tick, targets = targets }
  return targets
end

-- Move `count` targets forward (dir = 1) or back (dir = -1). Running out of
-- targets lands on the last / first line, matching what stock `]]` and `[[` do
-- at the ends of a buffer.
function M.jump(dir, count)
  local buf = vim.api.nvim_get_current_buf()
  local targets = M.targets(buf)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1

  -- Only normal mode pushes the jumplist: `m'` during operator-pending or
  -- visual would abort the pending operator / collapse the selection.
  if vim.fn.mode(1) == "n" then
    vim.cmd("normal! m'")
  end

  local found
  for _ = 1, count or 1 do
    local from = found and found.row or row
    local next_target
    if dir > 0 then
      for _, t in ipairs(targets) do
        if t.row > from then
          next_target = t
          break
        end
      end
    else
      for i = #targets, 1, -1 do
        if targets[i].row < from then
          next_target = targets[i]
          break
        end
      end
    end
    if not next_target then
      found = nil
      break
    end
    found = next_target
  end

  if found then
    vim.api.nvim_win_set_cursor(0, { found.row + 1, found.col })
  else
    local last = vim.api.nvim_buf_line_count(buf)
    local edge = dir > 0 and last or 1
    vim.api.nvim_win_set_cursor(0, { edge, first_non_blank(buf, edge - 1) })
  end
end

-- Wire the buffer-local motions. Called from the treesitter FileType autocmd
-- once the parser is known to have started, so it inherits that handler's
-- large-file guard. Buffer-local maps set here land after core's filetypeplugin
-- autocmd has run, which is what lets them replace the runtime's own `]]` in
-- go/python/rust/vim/markdown/sql without unmapping anything.
function M.attach(buf)
  local modes = { "n", "x", "o" }
  vim.keymap.set(modes, "]]", function()
    M.jump(1, vim.v.count1)
  end, { buffer = buf, silent = true, desc = "Next section (treesitter)" })
  vim.keymap.set(modes, "[[", function()
    M.jump(-1, vim.v.count1)
  end, { buffer = buf, silent = true, desc = "Previous section (treesitter)" })
end

vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
  callback = function(args)
    cache[args.buf] = nil
  end,
})

return M
