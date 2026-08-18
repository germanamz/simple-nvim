-- config.blink_fga: the blink.cmp source for OpenFGA models. The scanner and
-- the context/items logic are pure functions over line tables, so everything
-- but the last describe runs without a buffer.
local Kind = vim.lsp.protocol.CompletionItemKind

local MODEL = {
  "model",
  "  schema 1.1",
  "",
  "type user",
  "",
  "type group",
  "  relations",
  "    define member: [user, group#member] # nested groups",
  "",
  "# folders nest",
  "type folder",
  "  relations",
  "    define parent: [folder]",
  "    define owner: [user]",
  "    define viewer: [user, user:*, group#member with non_expired] or owner or viewer from parent",
  "",
  "condition non_expired(current_time: timestamp, grant_time: timestamp) {",
  "  current_time < grant_time",
  "}",
  "",
  "condition ip_ok(ip: ipaddress, allowed: list<string>) {",
  "  ip.in_cidr(allowed[0])",
  "}",
}

local function labels(items)
  local out = {}
  for _, it in ipairs(items) do
    out[#out + 1] = it.label
  end
  table.sort(out)
  return out
end

local function find(items, label)
  for _, it in ipairs(items) do
    if it.label == label then
      return it
    end
  end
end

describe("config.blink_fga", function()
  local M

  before_each(function()
    package.loaded["config.blink_fga"] = nil
    M = require("config.blink_fga")
  end)

  describe("scan", function()
    it("collects types with their relations, in declaration order", function()
      local syms = M.scan(MODEL)
      assert.are.same(
        { "user", "group", "folder" },
        vim.tbl_map(function(t)
          return t.name
        end, syms.types)
      )
      assert.are.same({}, syms.types[1].relations)
      assert.are.same({ "member" }, syms.types[2].relations)
      assert.are.same({ "parent", "owner", "viewer" }, syms.types[3].relations)
    end)

    it("collects conditions with typed params", function()
      local syms = M.scan(MODEL)
      assert.are.equal(2, #syms.conditions)
      assert.are.equal("non_expired", syms.conditions[1].name)
      assert.are.same({
        { name = "current_time", type = "timestamp" },
        { name = "grant_time", type = "timestamp" },
      }, syms.conditions[1].params)
      assert.are.same(
        { { name = "ip", type = "ipaddress" }, { name = "allowed", type = "list<string>" } },
        syms.conditions[2].params
      )
    end)

    it("ignores declarations inside comments", function()
      local syms = M.scan({
        "model",
        "  schema 1.1",
        "# type ghost",
        "type real",
        "  relations",
        "    # define phantom: [real]",
        "    define member: [real] # define trailing: [real]",
      })
      assert.are.same(
        { "real" },
        vim.tbl_map(function(t)
          return t.name
        end, syms.types)
      )
      assert.are.same({ "member" }, syms.types[1].relations)
    end)

    it("reads a parameter list that spans several lines", function()
      local syms = M.scan({
        "model",
        "  schema 1.1",
        "condition c(",
        "  x: int,",
        "  y: string",
        ") {",
        "  x > 1",
        "}",
      })
      assert.are.equal(1, #syms.conditions)
      assert.are.same(
        { { name = "x", type = "int" }, { name = "y", type = "string" } },
        syms.conditions[1].params
      )
    end)

    it("keeps one signature when the same condition is scanned twice", function()
      -- A second loaded copy of the model (a gitsigns diff buffer, a preview)
      -- must not double every parameter.
      local lines = { "model", "  schema 1.1", "condition c(x: int, y: string) {", "  x > 1", "}" }
      local syms = M.scan(lines)
      M.scan(lines, syms)
      assert.are.equal(1, #syms.conditions)
      assert.are.equal(2, #syms.conditions[1].params)
    end)

    it("accepts `/` in identifiers, as the grammar does", function()
      local syms = M.scan({
        "model",
        "  schema 1.1",
        "type org/team",
        "  relations",
        "    define member: [user]",
      })
      assert.are.equal("org/team", syms.types[1].name)
    end)

    it("merges `extend type` and repeated scans into the same type", function()
      -- Modular models spread one type across files: scan the second file into
      -- the symbols of the first.
      local syms = M.scan({ "module core", "type doc", "  relations", "    define owner: [user]" })
      M.scan({ "module wiki", "extend type doc", "  relations", "    define editor: [user]" }, syms)
      assert.are.equal(1, #syms.types)
      assert.are.same({ "owner", "editor" }, syms.types[1].relations)
    end)
  end)

  describe("context", function()
    -- context(lines, row, col): row is 1-based, col is the 0-based cursor
    -- column, i.e. the number of bytes before the cursor on that line.
    local function ctx_for(lines, row, before)
      -- Convenience: `before` is the text of the row up to the cursor.
      lines = vim.deepcopy(lines)
      lines[row] = before
      return M.context(lines, row, #before)
    end

    it("is a comment after `#` at line start or after whitespace", function()
      assert.are.equal("comment", ctx_for(MODEL, 3, "# a comm").kind)
      assert.are.equal("comment", ctx_for(MODEL, 8, "    define member: [user] # nes").kind)
    end)

    it("is not a comment inside a CEL string literal", function()
      local lines =
        { "model", "  schema 1.1", "condition c(s: string) {", '  s == "a #b" && ', "}" }
      local c = M.context(lines, 4, #lines[4])
      assert.are.equal("body", c.kind)
      assert.are.equal("c", c.condition)
    end)

    it("is a userset ref, not a comment, for `type#`", function()
      local c = ctx_for(MODEL, 8, "    define member: [user, group#mem")
      assert.are.equal("relation_ref", c.kind)
      assert.are.equal("group", c.ref_type)
    end)

    it("offers keywords at the start of a line", function()
      assert.are.equal("keyword", ctx_for(MODEL, 5, "").kind)
      assert.are.equal("keyword", ctx_for(MODEL, 5, "  rel").kind)
    end)

    it("knows the enclosing type", function()
      local c = ctx_for(MODEL, 15, "    define can_view: ")
      assert.are.equal("value", c.kind)
      assert.are.equal("folder", c.current_type)
    end)

    it("is a type restriction inside an unclosed `[`", function()
      assert.are.equal("type_ref", ctx_for(MODEL, 15, "    define viewer: [").kind)
      assert.are.equal("type_ref", ctx_for(MODEL, 15, "    define viewer: [user, gro").kind)
      -- closed bracket → back to the value context
      assert.are.equal("value", ctx_for(MODEL, 15, "    define viewer: [user] or ").kind)
    end)

    it("is a condition reference after `with` inside `[`", function()
      assert.are.equal("condition_ref", ctx_for(MODEL, 15, "    define viewer: [user with ").kind)
      assert.are.equal(
        "condition_ref",
        ctx_for(MODEL, 15, "    define viewer: [user, group#member with non").kind
      )
    end)

    it("offers only `not` after a dangling `but`", function()
      -- `but not` is one item; once `but ` is typed, blink's edit range stops at
      -- the space, so accepting the two-word item would produce `but but not`.
      local c = ctx_for(MODEL, 15, "    define viewer: owner but ")
      assert.are.equal("value", c.kind)
      assert.is_true(c.after_but)
      assert.are.equal("value", ctx_for(MODEL, 15, "    define viewer: owner but n").kind)
      assert.is_true(ctx_for(MODEL, 15, "    define viewer: owner but n").after_but)
      assert.is_nil(ctx_for(MODEL, 15, "    define viewer: owner but").after_but)
      -- a relation that merely starts with "but" is not the operator
      assert.is_nil(ctx_for(MODEL, 15, "    define viewer: butler ").after_but)
    end)

    it("is a userset ref for a slash-named type", function()
      local c = ctx_for(MODEL, 8, "    define member: [org/team#")
      assert.are.equal("relation_ref", c.kind)
      assert.are.equal("org/team", c.ref_type)
    end)

    it("is a tupleset relation after `from`", function()
      local c = ctx_for(MODEL, 15, "    define viewer: viewer from ")
      assert.are.equal("tupleset", c.kind)
      assert.are.equal("folder", c.current_type)
    end)

    it("is a schema version after `schema`", function()
      assert.are.equal("schema", ctx_for(MODEL, 2, "  schema ").kind)
      assert.are.equal("schema", ctx_for(MODEL, 2, "  schema 1.").kind)
    end)

    it("is a type name after `extend type`, and nothing after `type` / `module`", function()
      assert.are.equal("extend_type", ctx_for(MODEL, 4, "extend type ").kind)
      assert.are.equal("none", ctx_for(MODEL, 4, "type us").kind)
      assert.are.equal("none", ctx_for(MODEL, 1, "module co").kind)
    end)

    it("is a param type after `:` inside a condition's parameter list", function()
      assert.are.equal("param_type", ctx_for(MODEL, 17, "condition c(x: ").kind)
      assert.are.equal("param_type", ctx_for(MODEL, 17, "condition c(x: int, y: li").kind)
      assert.are.equal("none", ctx_for(MODEL, 17, "condition c(x").kind)
      assert.are.equal("none", ctx_for(MODEL, 17, "condition na").kind)
    end)

    it("is a param type on the continuation lines of a multi-line header", function()
      local lines = { "model", "  schema 1.1", "condition c(", "  x: int,", "  y: " }
      assert.are.equal("param_type", M.context(lines, 5, #lines[5]).kind)
      assert.are.equal("none", M.context(lines, 4, 3).kind)
    end)

    it("is the body of a condition whose header spans several lines", function()
      local lines = { "model", "  schema 1.1", "condition c(", "  x: int", ") {", "  x" }
      local c = M.context(lines, 6, 3)
      assert.are.equal("body", c.kind)
      assert.are.equal("c", c.condition)
    end)

    it("treats an indented or trailing `}` as the end of the body", function()
      local indented = { "model", "  schema 1.1", "condition c(x: int) {", "  x > 1", "  }", "" }
      assert.are.equal("keyword", M.context(indented, 6, 0).kind)
      local trailing = { "model", "  schema 1.1", "condition c(x: int) {", "  x > 1 }", "" }
      assert.are.equal("keyword", M.context(trailing, 5, 0).kind)
    end)

    it("does not mistake a body line starting with `condition_…` for a header", function()
      local lines =
        { "model", "  schema 1.1", "condition c(condition_id: string) {", "  condition_" }
      local c = M.context(lines, 4, #lines[4])
      assert.are.equal("body", c.kind)
      assert.are.equal("c", c.condition)
    end)

    it("is the condition body between the header and the closing brace", function()
      local c = ctx_for(MODEL, 18, "  current_time < gr")
      assert.are.equal("body", c.kind)
      assert.are.equal("non_expired", c.condition)
      -- an empty line inside the body is still the body, not a keyword line
      assert.are.equal("body", ctx_for(MODEL, 18, "  ").kind)
      -- and the line after `}` is a plain keyword line again
      assert.are.equal("keyword", ctx_for(MODEL, 20, "").kind)
    end)
  end)

  describe("items", function()
    local syms
    before_each(function()
      syms = M.scan(MODEL)
    end)

    it("offers types, wildcards and usersets for a type restriction", function()
      local items = M.items({ kind = "type_ref" }, syms)
      local ls = labels(items)
      for _, want in ipairs({ "user", "group", "folder", "user:*", "group#member", "folder#viewer" }) do
        assert.is_true(vim.list_contains(ls, want), "missing " .. want)
      end
      assert.are.equal(Kind.Class, find(items, "user").kind)
      assert.are.equal(Kind.Reference, find(items, "group#member").kind)
      -- a type without relations gets no userset entries
      assert.is_nil(find(items, "user#"))
    end)

    it("offers only that type's relations after `type#`", function()
      assert.are.same(
        { "member" },
        labels(M.items({ kind = "relation_ref", ref_type = "group" }, syms))
      )
      assert.are.same({}, labels(M.items({ kind = "relation_ref", ref_type = "nosuch" }, syms)))
    end)

    it("offers conditions with their signature after `with`", function()
      local items = M.items({ kind = "condition_ref" }, syms)
      assert.are.same({ "ip_ok", "non_expired" }, labels(items))
      local it = find(items, "non_expired")
      assert.are.equal(Kind.Function, it.kind)
      assert.are.equal("(current_time: timestamp, grant_time: timestamp)", it.detail)
    end)

    it(
      "ranks the current type's relations first in a define value, then the rest, then operators",
      function()
        local items = M.items({ kind = "value", current_type = "folder" }, syms)
        local viewer, member, or_ = find(items, "viewer"), find(items, "member"), find(items, "or")
        assert.is_not_nil(viewer)
        assert.is_not_nil(member)
        assert.is_not_nil(or_)
        assert.is_true(viewer.sortText < member.sortText, "own relations sort before others'")
        assert.is_true(member.sortText < or_.sortText, "operators sort last")
        assert.are.equal(Kind.Property, viewer.kind)
        assert.are.equal("relation of group", member.detail)
        assert.is_true(vim.list_contains(labels(items), "but not"))
        assert.is_true(vim.list_contains(labels(items), "from"))
      end
    )

    it("offers only `not` after a dangling `but`", function()
      local items = M.items({ kind = "value", current_type = "folder", after_but = true }, syms)
      assert.are.same({ "not" }, labels(items))
    end)

    it("keeps every keyword the same kind so sortText decides their order", function()
      -- blink penalises Kind.Snippet items (snippets.score_offset), which would
      -- silently reorder the menu against the declared order.
      local kinds = {}
      for _, it in ipairs(M.items({ kind = "keyword" }, syms)) do
        kinds[it.kind] = true
      end
      assert.are.same({ [Kind.Keyword] = true }, kinds)
    end)

    it("offers only the current type's relations after `from`", function()
      local items = M.items({ kind = "tupleset", current_type = "folder" }, syms)
      assert.are.same({ "owner", "parent", "viewer" }, labels(items))
    end)

    it("offers schema versions", function()
      assert.are.same({ "1.1", "1.2" }, labels(M.items({ kind = "schema" }, syms)))
    end)

    it("offers known type names after `extend type`", function()
      assert.are.same(
        { "folder", "group", "user" },
        labels(M.items({ kind = "extend_type" }, syms))
      )
    end)

    it("offers CEL parameter types", function()
      local ls = labels(M.items({ kind = "param_type" }, syms))
      for _, want in ipairs({
        "string",
        "int",
        "uint",
        "bool",
        "double",
        "duration",
        "timestamp",
        "ipaddress",
      }) do
        assert.is_true(vim.list_contains(ls, want), "missing " .. want)
      end
      local items = M.items({ kind = "param_type" }, syms)
      local map = find(items, "map<…>")
      assert.is_not_nil(map, "missing map<…>")
      assert.are.equal(2, map.insertTextFormat, "map<…> is a snippet")
      assert.are.equal("map<${1:string}>", map.insertText)
    end)

    it("offers the enclosing condition's params in its body", function()
      local items = M.items({ kind = "body", condition = "ip_ok" }, syms)
      assert.are.same({ "allowed", "ip" }, labels(items))
      assert.are.equal("list<string>", find(items, "allowed").detail)
      assert.are.equal(Kind.Variable, find(items, "ip").kind)
    end)

    it("offers keyword snippets at a line start", function()
      local items = M.items({ kind = "keyword" }, syms)
      local ls = labels(items)
      for _, want in ipairs({
        "model",
        "schema",
        "type",
        "extend type",
        "relations",
        "define",
        "condition",
        "module",
      }) do
        assert.is_true(vim.list_contains(ls, want), "missing " .. want)
      end
      local relations = find(items, "relations")
      assert.are.equal(2, relations.insertTextFormat)
      assert.are.equal("relations\n\tdefine ${1:relation}: $0", relations.insertText)
      assert.are.equal("define ${1:relation}: $0", find(items, "define").insertText)
      -- plain keywords insert a trailing space and no tabstop
      assert.are.equal("type ", find(items, "type").insertText)
      assert.is_nil(find(items, "type").insertTextFormat)
    end)

    it("offers nothing in a comment or an unknown spot", function()
      assert.are.same({}, M.items({ kind = "comment" }, syms))
      assert.are.same({}, M.items({ kind = "none" }, syms))
    end)
  end)

  describe("blink source", function()
    local bufs = {}

    local function fga_buf(lines)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = "fga"
      bufs[#bufs + 1] = buf
      return buf
    end

    after_each(function()
      for _, b in ipairs(bufs) do
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
      bufs = {}
    end)

    local function complete(buf, row, col)
      local source = M.new({}, {})
      local got
      -- blink's context: 1-based row, 0-based col, the current line's text
      source:get_completions({
        bufnr = buf,
        cursor = { row, col },
        line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1],
      }, function(resp)
        got = resp
      end)
      return got
    end

    it("triggers on `[` and `#`", function()
      local source = M.new({}, {})
      local trig = source:get_trigger_characters()
      assert.is_true(vim.list_contains(trig, "["))
      assert.is_true(vim.list_contains(trig, "#"))
    end)

    it("completes from the buffer under the cursor", function()
      local buf = fga_buf(MODEL)
      vim.api.nvim_buf_set_lines(buf, 15, 15, false, { "    define can_view: [" })
      local resp = complete(buf, 16, #"    define can_view: [")
      assert.is_false(resp.is_incomplete_forward)
      assert.is_true(vim.list_contains(labels(resp.items), "group#member"))
    end)

    it("sees types declared in other loaded fga buffers (modular models)", function()
      local other =
        fga_buf({ "module wiki", "type page", "  relations", "    define author: [user]" })
      assert.is_not_nil(other)
      local buf =
        fga_buf({ "module core", "type user", "type doc", "  relations", "    define viewer: [" })
      local resp = complete(buf, 5, #"    define viewer: [")
      assert.is_true(vim.list_contains(labels(resp.items), "page#author"))
    end)

    it("does not scan buffers of other filetypes", function()
      local yaml = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(
        yaml,
        0,
        -1,
        false,
        { "type notfga", "  relations", "    define x: [user]" }
      )
      vim.bo[yaml].filetype = "yaml"
      bufs[#bufs + 1] = yaml
      local buf =
        fga_buf({ "model", "  schema 1.1", "type user", "  relations", "    define viewer: [" })
      local resp = complete(buf, 5, #"    define viewer: [")
      assert.is_false(vim.list_contains(labels(resp.items), "notfga"))
    end)
  end)
end)
