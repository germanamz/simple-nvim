-- blink.cmp completion source for OpenFGA authorization models (ft=fga).
--
-- OpenFGA's own language server (openfga/vscode-ext) does diagnostics, hover
-- and code actions but no completion, and it is not in mason's registry — so
-- suggestions come from here. The DSL is line-oriented (`type X`, `define
-- r: …`, `condition c(p: t) {`), so a line scanner over every loaded fga
-- buffer is both simpler and more robust while typing than a treesitter walk
-- of a half-written tree: it needs no parser, ignores comments correctly and
-- is unit-testable as pure functions over line tables.
--
-- Three pure pieces, one blink glue:
--   M.scan(lines, symbols?)   -> the model's types (+ relations) and conditions
--   M.context(lines, row, col) -> what the cursor is completing (see CONTEXTS)
--   M.items(ctx, symbols)     -> LSP-shaped completion items for that context
--   M.new / get_completions   -> the blink.cmp source wrapping the three
--
-- Contexts, from the text before the cursor on its line (and, for the current
-- type / enclosing condition, the lines above):
--   comment        after `#` at line start or after whitespace  -> nothing
--   keyword        only whitespace + a word so far              -> keyword snippets
--   schema         `schema `                                    -> versions
--   extend_type    `extend type `                               -> known types
--   type_ref       inside an unclosed `[`                       -> types, `t:*`, `t#r`
--   relation_ref   `[… t#`                                      -> relations of t
--   condition_ref  `[… with `                                   -> conditions
--   value          `define r: …` outside brackets               -> relations + operators
--   tupleset       `define r: … from `                          -> current type's relations
--   param_type     `condition c(p: `                            -> CEL param types
--   body           between `condition … {` and `}`             -> that condition's params
--   none           anywhere else (a fresh type/module name…)    -> nothing
local Kind = vim.lsp.protocol.CompletionItemKind
local Snippet = vim.lsp.protocol.InsertTextFormat.Snippet

local M = {}

-- Identifier characters as the grammar accepts them: extended identifiers
-- (types, relations) may carry `.`, `/` and `-` besides word characters.
local ID_CHARS = "[%w_./-]"
local ID = ID_CHARS .. "+"

-- Strip a trailing comment. `#` opens a comment at line start or after
-- whitespace; `group#member` (no space) is a userset reference, and a `#`
-- inside a CEL string literal (`s == "a #b"`) is just text — so this walks the
-- line rather than pattern-matching, tracking quotes as it goes.
local function strip_comment(line)
  local quote
  local i, n = 1, #line
  while i <= n do
    local ch = line:sub(i, i)
    if quote then
      if ch == "\\" then
        i = i + 1
      elseif ch == quote then
        quote = nil
      end
    elseif ch == '"' or ch == "'" then
      quote = ch
    elseif ch == "#" and (i == 1 or line:sub(i - 1, i - 1):match("%s")) then
      return line:sub(1, i - 1)
    end
    i = i + 1
  end
  return line
end

-- `condition name(` with its parameter list still open on this line.
local function open_condition_header(line)
  return line:match("^%s*condition%s+[%w_-]+%s*%([^)]*$") ~= nil
end

local function type_name(line)
  return line:match("^%s*type%s+(" .. ID .. ")") or line:match("^%s*extend%s+type%s+(" .. ID .. ")")
end

-- Symbols ---------------------------------------------------------------------

---@class fga.Type
---@field name string
---@field relations string[]

---@class fga.Condition
---@field name string
---@field params { name: string, type: string }[]

---@class fga.Symbols
---@field types fga.Type[]
---@field conditions fga.Condition[]

---Scan one buffer's lines into `symbols` (a fresh table when omitted). Calling
---it again with a second buffer merges: a type declared in one file and
---extended in another is one entry with the union of its relations, in the
---order seen — which is how modular models are laid out.
---@param lines string[]
---@param symbols? fga.Symbols
---@return fga.Symbols
function M.scan(lines, symbols)
  symbols = symbols or { types = {}, conditions = {} }
  local by_name = {}
  for _, t in ipairs(symbols.types) do
    by_name[t.name] = t
  end
  local cond_by_name = {}
  for _, c in ipairs(symbols.conditions) do
    cond_by_name[c.name] = c
  end

  local current
  -- A `condition c(` header whose parameter list continues on the next
  -- line(s): accumulate until the `)` shows up, then scan the joined line.
  local pending
  for _, raw in ipairs(lines) do
    local line = strip_comment(raw)
    if pending then
      line = pending .. " " .. line
      pending = nil
    end
    local tname = type_name(line)
    if tname then
      current = by_name[tname]
      if not current then
        current = { name = tname, relations = {} }
        by_name[tname] = current
        symbols.types[#symbols.types + 1] = current
      end
    else
      local rel = line:match("^%s*define%s+(" .. ID .. ")%s*:")
      if rel and current then
        if not vim.list_contains(current.relations, rel) then
          current.relations[#current.relations + 1] = rel
        end
      else
        local cname, args = line:match("^%s*condition%s+([%w_-]+)%s*%((.-)%)")
        if cname then
          -- The first declaration wins: a second loaded copy of the same
          -- model (a diff or preview buffer) must not double the params.
          if not cond_by_name[cname] then
            local cond = { name = cname, params = {} }
            cond_by_name[cname] = cond
            symbols.conditions[#symbols.conditions + 1] = cond
            for seg in args:gmatch("[^,]+") do
              local pname, ptype = seg:match("^%s*([%w_-]+)%s*:%s*(.-)%s*$")
              if pname then
                cond.params[#cond.params + 1] = { name = pname, type = ptype }
              end
            end
          end
        elseif open_condition_header(line) then
          pending = line
        end
      end
    end
  end
  return symbols
end

-- Context ---------------------------------------------------------------------

---@class fga.Context
---@field kind string one of the CONTEXTS in the header
---@field current_type? string nearest `type X` above the cursor
---@field ref_type? string the `t` of a `t#` userset being typed
---@field condition? string enclosing condition when kind == "body"
---@field after_but? boolean value context right after `but ` (offer `not`)

-- Nearest `type X` / `extend type X` strictly above `row`.
local function enclosing_type(lines, row)
  for i = row - 1, 1, -1 do
    local name = type_name(strip_comment(lines[i]))
    if name then
      return name
    end
  end
end

-- Name of the condition whose `{ … }` body contains `row`, if any: walk up to
-- the header, giving up at a closing `}` (at any indent, or trailing a body
-- line) or at anything that can only appear outside a body. A header whose
-- parameter list spans lines is recognised by its `condition c(` first line;
-- the rows between it and the `) {` line are the parameter list, not the
-- body (see M.context).
local function enclosing_condition(lines, row)
  for i = row - 1, 1, -1 do
    local line = strip_comment(lines[i])
    local name = line:match("^%s*condition%s+([%w_-]+)")
    if name then
      -- A one-line body `condition c(x: int) { x > 1 }` is already closed.
      if line:match("{.*}%s*$") then
        return nil
      end
      return name
    end
    if
      line:match("}%s*$")
      or type_name(line)
      or line:match("^%s*define%s")
      or line:match("^%s*relations%s*$")
      or line:match("^%s*model%s*$")
      or line:match("^%s*module%s")
      or line:match("^%s*schema%s")
    then
      return nil
    end
  end
end

-- What is being completed inside `define r: <rhs>`.
local function value_context(rhs)
  local open = rhs:match(".*()%[")
  local close = rhs:match(".*()%]")
  if open and (not close or close < open) then
    -- Inside the type-restriction list; look at the entry being typed.
    local entry = rhs:sub(open + 1):match("[^,]*$")
    if entry:match("%f[%w]with%s+[%w_-]*$") then
      return { kind = "condition_ref" }
    end
    local ref_type = entry:match("(" .. ID .. ")#" .. ID_CHARS .. "*$")
    if ref_type then
      return { kind = "relation_ref", ref_type = ref_type }
    end
    return { kind = "type_ref" }
  end
  if rhs:match("%f[%w]from%s+" .. ID_CHARS .. "*$") then
    return { kind = "tupleset" }
  end
  -- `but not` is one item, but once `but ` has been typed blink's edit range
  -- stops at the space, so accepting the two-word item would leave
  -- `but but not`; offer just `not` there.
  if rhs:match("%f[%w]but%s+[%w_]*$") then
    return { kind = "value", after_but = true }
  end
  return { kind = "value" }
end

---@param lines string[] the buffer
---@param row integer 1-based cursor row
---@param col integer 0-based cursor column (bytes before the cursor)
---@return fga.Context
function M.context(lines, row, col)
  local before = (lines[row] or ""):sub(1, col)

  if strip_comment(before) ~= before then
    return { kind = "comment" }
  end

  -- Condition header: `condition name(p: type, …) {`. When the parameter
  -- list is still open on an earlier line, this row is one of its
  -- continuation lines and is judged as if joined onto the header.
  local header = before:match("^%s*condition%s") and before
  if not header then
    for i = row - 1, 1, -1 do
      local prev = strip_comment(lines[i])
      if open_condition_header(prev) then
        header = prev .. " " .. before
        break
      end
      if prev:match("%)") or prev:match("^%s*condition%s") or prev == "" then
        break
      end
    end
  end
  if header then
    local args = header:match("^%s*condition%s+[%w_-]*%s*%((.*)$")
    if not args then
      return { kind = "none" }
    end
    if args:find("%)") then
      -- Past the parameter list. On the header line itself the body starts
      -- after `{`; nothing else to offer here.
      return {
        kind = args:match("%)%s*{") and "body" or "none",
        condition = header:match("^%s*condition%s+([%w_-]+)"),
      }
    end
    local seg = args:match("[^,]*$")
    if seg:find(":") then
      return { kind = "param_type" }
    end
    return { kind = "none" }
  end

  local cond = enclosing_condition(lines, row)
  if cond then
    return { kind = "body", condition = cond }
  end

  local rhs = before:match("^%s*define%s+" .. ID .. "%s*:(.*)$")
  if rhs then
    local ctx = value_context(rhs)
    ctx.current_type = enclosing_type(lines, row)
    return ctx
  end

  if before:match("^%s*schema%s+[%d.]*$") then
    return { kind = "schema" }
  end
  if before:match("^%s*extend%s+type%s+" .. ID_CHARS .. "*$") then
    return { kind = "extend_type" }
  end
  if before:match("^%s*[%w_]*$") then
    return { kind = "keyword", current_type = enclosing_type(lines, row) }
  end
  return { kind = "none" }
end

-- Items -----------------------------------------------------------------------

-- Bodies use `\t` for nesting so vim.snippet re-indents them with the
-- buffer's shiftwidth/expandtab under the current line's indent.
local KEYWORDS = {
  { label = "model", body = "model\n\tschema ${1:1.1}", snippet = true },
  { label = "schema", body = "schema ${1:1.1}", snippet = true },
  { label = "type", body = "type " },
  { label = "extend type", body = "extend type " },
  { label = "relations", body = "relations\n\tdefine ${1:relation}: $0", snippet = true },
  { label = "define", body = "define ${1:relation}: $0", snippet = true },
  {
    label = "condition",
    body = "condition ${1:name}(${2:param}: ${3:string}) {\n\t$0\n}",
    snippet = true,
  },
  { label = "module", body = "module " },
}

local SCHEMA_VERSIONS = { "1.1", "1.2" }

local OPERATORS = { "or", "and", "but not", "from" }

local PARAM_TYPES = {
  "string",
  "int",
  "uint",
  "bool",
  "double",
  "duration",
  "timestamp",
  "ipaddress",
}

local function signature(cond)
  local parts = {}
  for _, p in ipairs(cond.params) do
    parts[#parts + 1] = p.name .. ": " .. p.type
  end
  return "(" .. table.concat(parts, ", ") .. ")"
end

local function find_type(symbols, name)
  for _, t in ipairs(symbols.types) do
    if t.name == name then
      return t
    end
  end
end

local function relation_items(t, sort_prefix, detail)
  local items = {}
  for _, r in ipairs(t.relations) do
    items[#items + 1] = {
      label = r,
      kind = Kind.Property,
      detail = detail,
      sortText = sort_prefix .. r,
    }
  end
  return items
end

local builders = {}

-- All Kind.Keyword, snippet bodies included: blink docks Kind.Snippet items
-- (snippets.score_offset), which would reorder the menu against sortText.
function builders.keyword()
  local items = {}
  for i, kw in ipairs(KEYWORDS) do
    items[#items + 1] = {
      label = kw.label,
      kind = Kind.Keyword,
      insertText = kw.body,
      insertTextFormat = kw.snippet and Snippet or nil,
      sortText = ("%02d"):format(i),
    }
  end
  return items
end

function builders.schema()
  local items = {}
  for _, v in ipairs(SCHEMA_VERSIONS) do
    items[#items + 1] = { label = v, kind = Kind.Value, detail = "schema version" }
  end
  return items
end

function builders.extend_type(_, symbols)
  local items = {}
  for _, t in ipairs(symbols.types) do
    items[#items + 1] = { label = t.name, kind = Kind.Class }
  end
  return items
end

function builders.type_ref(_, symbols)
  local items = {}
  for _, t in ipairs(symbols.types) do
    items[#items + 1] = { label = t.name, kind = Kind.Class, sortText = "0" .. t.name }
    items[#items + 1] = {
      label = t.name .. ":*",
      kind = Kind.Class,
      detail = "every " .. t.name,
      sortText = "1" .. t.name,
    }
    for _, r in ipairs(t.relations) do
      items[#items + 1] = {
        label = t.name .. "#" .. r,
        kind = Kind.Reference,
        detail = "userset",
        sortText = "2" .. t.name .. "#" .. r,
      }
    end
  end
  return items
end

function builders.relation_ref(ctx, symbols)
  local t = find_type(symbols, ctx.ref_type)
  return t and relation_items(t, "0", "relation of " .. t.name) or {}
end

function builders.condition_ref(_, symbols)
  local items = {}
  for _, c in ipairs(symbols.conditions) do
    items[#items + 1] = { label = c.name, kind = Kind.Function, detail = signature(c) }
  end
  return items
end

function builders.value(ctx, symbols)
  if ctx.after_but then
    return { { label = "not", kind = Kind.Operator } }
  end
  local items = {}
  local seen = {}
  local own = ctx.current_type and find_type(symbols, ctx.current_type)
  if own then
    for _, it in ipairs(relation_items(own, "0", "relation of " .. own.name)) do
      items[#items + 1] = it
      seen[it.label] = true
    end
  end
  -- Relations of the other types, so `viewer from parent` can pick a relation
  -- the parent's type declares. Deduped by name, declaring types as detail.
  local others, order = {}, {}
  for _, t in ipairs(symbols.types) do
    if t ~= own then
      for _, r in ipairs(t.relations) do
        if not seen[r] then
          if not others[r] then
            others[r] = {}
            order[#order + 1] = r
          end
          others[r][#others[r] + 1] = t.name
        end
      end
    end
  end
  for _, r in ipairs(order) do
    items[#items + 1] = {
      label = r,
      kind = Kind.Property,
      detail = "relation of " .. table.concat(others[r], ", "),
      sortText = "1" .. r,
    }
  end
  for i, op in ipairs(OPERATORS) do
    items[#items + 1] = { label = op, kind = Kind.Operator, sortText = "2" .. i }
  end
  return items
end

function builders.tupleset(ctx, symbols)
  local own = ctx.current_type and find_type(symbols, ctx.current_type)
  return own and relation_items(own, "0", "relation of " .. own.name) or {}
end

function builders.param_type()
  local items = {}
  for _, t in ipairs(PARAM_TYPES) do
    items[#items + 1] = { label = t, kind = Kind.TypeParameter }
  end
  for _, container in ipairs({ "map", "list" }) do
    items[#items + 1] = {
      label = container .. "<…>",
      kind = Kind.TypeParameter,
      insertText = container .. "<${1:string}>",
      insertTextFormat = Snippet,
    }
  end
  return items
end

function builders.body(ctx, symbols)
  local items = {}
  for _, c in ipairs(symbols.conditions) do
    if c.name == ctx.condition then
      for _, p in ipairs(c.params) do
        items[#items + 1] = { label = p.name, kind = Kind.Variable, detail = p.type }
      end
    end
  end
  return items
end

---@param ctx fga.Context
---@param symbols fga.Symbols
---@return lsp.CompletionItem[]
function M.items(ctx, symbols)
  local build = builders[ctx.kind]
  return build and build(ctx, symbols) or {}
end

-- blink.cmp source ------------------------------------------------------------

local Source = {}
Source.__index = Source

---@return blink.cmp.Source
function M.new(_, _)
  return setmetatable({}, Source)
end

function Source:enabled()
  return vim.bo.filetype == "fga"
end

-- `#` continues a userset ref: `group#` reopens the menu with group's
-- relations. `[` would open the type-restriction list the same way, but
-- mini.pairs expands it to `[]<Left>`, blink then sees `]` as the typed char
-- and hides — so with pairs on it only fires after a letter or <C-space>
-- (docs/openfga.md); it is kept for the pairs-off case.
function Source:get_trigger_characters()
  return { "[", "#" }
end

-- Every loaded fga buffer, current one first: modular models declare a type in
-- one file and extend it in another, and only the union completes correctly.
local function fga_line_sets(bufnr)
  local sets = { vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) }
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= bufnr and vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "fga" then
      sets[#sets + 1] = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    end
  end
  return sets
end

function Source:get_completions(ctx, callback)
  local sets = fga_line_sets(ctx.bufnr)
  local symbols
  for _, lines in ipairs(sets) do
    symbols = M.scan(lines, symbols)
  end
  local row, col = ctx.cursor[1], ctx.cursor[2]
  -- ctx.line is the live line (the buffer may lag it by a keystroke).
  sets[1][row] = ctx.line
  local items = M.items(M.context(sets[1], row, col), symbols)
  callback({ is_incomplete_forward = false, is_incomplete_backward = false, items = items })
end

return M
