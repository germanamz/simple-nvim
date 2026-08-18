; OpenFGA authorization-model DSL (matoous/tree-sitter-fga).
;
; Adapted from the grammar's own queries/highlights.scm: that file leans on
; `(#is-not? local)`, an nvim-treesitter/master predicate that core Neovim has
; no handler for (the highlighter throws "No handler for is-not?" and the
; buffer drops to no highlighting at all), so the locals-based clauses are
; replaced with plain captures. Capture names follow :h treesitter-highlight-groups.

; Keywords -----------------------------------------------------------------

(model) @keyword

(module
  "module" @keyword.import)

(schema
  "schema" @keyword)

(contents
  "contents" @keyword)

(type_declaration
  "extend" @keyword)

(type_declaration
  "type" @keyword.type)

(relations
  "relations" @keyword)

(definition
  "define" @keyword)

(condition_declaration
  "condition" @keyword.function)

; `or` / `and` / `but not` between relation terms, `X from Y`, `T with cond`
(operator) @keyword.operator

(indirect_relation
  "from" @keyword.operator)

(conditional
  "with" @keyword.operator)

; Names ------------------------------------------------------------------------

(module
  name: (identifier) @module)

(type_declaration
  name: (extended_identifier) @type)

; `[user, user:*, group#member]` — the types a relation may be assigned to
(direct_relationship_item
  (extended_identifier) @type)

(relation_ref) @type

(all) @type

; `define viewer: …` and the relations referenced on the right-hand side
(definition
  relation: (extended_identifier) @property)

(relation_def
  (extended_identifier) @property)

(indirect_relation
  relation: (extended_identifier) @property
  tupleset: (extended_identifier) @property)

; Conditions ------------------------------------------------------------------

(condition_declaration
  name: (identifier) @function)

(conditional
  condition: (identifier) @function.call)

(param
  name: (identifier) @variable.parameter)

(simple_type_identifier) @type.builtin

(container_type_identifier
  [
    "map"
    "list"
  ] @type.builtin)

; CEL inside the condition body. Every identifier is a plain variable (params,
; map keys, builtins alike — the grammar does not distinguish them)…
(condition_body
  (identifier) @variable)

(parenthesized_condition
  (identifier) @variable)

(bracket_condition
  (identifier) @variable)

(braced_condition
  (identifier) @variable)

; …except one directly followed by a parenthesized group, which is a call:
; `x.startsWith("a")`. This pattern must stay BELOW the @variable ones — the
; highlighter paints captures in query order, so the later capture wins.
((identifier) @function.call
  .
  (parenthesized_condition))

; Literals --------------------------------------------------------------------

(version) @number

(int) @number

(uint) @number

(float) @number.float

(string) @string

(bytes) @string.special

(boolean) @boolean

(null) @constant.builtin

; `contents:` entries in fga.mod
(file) @string.special.path

; Operators & punctuation -----------------------------------------------------

(condition_operator) @operator

((condition_operator) @keyword.operator
  (#eq? @keyword.operator "in"))

[
  ":"
  ","
  "."
  "?"
  "-"
] @punctuation.delimiter

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
  "<"
  ">"
] @punctuation.bracket

(quoted_version
  [
    "\""
    "'"
  ] @string)

; Comments --------------------------------------------------------------------

(comment) @comment @spell
