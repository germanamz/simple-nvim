; The DSL nests by indentation only:
;
;   type folder            <- 0
;     relations            <- +1 inside type_declaration
;       define viewer: …   <- +1 inside relations
;
;   condition c(x: int) {  <- 0
;     x > 1                <- +1 inside condition_body
;   }                      <- back out (branch)
;
; No `indent.immediate` on type_declaration on purpose: `type user` with no
; relations is the most common line in a model, and immediate would indent the
; line after it — the wrong default for the next `type`. So `type X<CR>` lands
; at column 0 and you type the two spaces before `relations`; from then on
; the type_declaration spans two lines and every following line indents by
; itself. `relations<CR>` needs no such help — relations requires a define, so
; the half-typed block is in error and counts as open.
[
  (type_declaration)
  (relations)
  (condition_body)
] @indent.begin

; fga.mod: the `- file` entries sit under `contents:`; immediate so
; `contents:<CR>` already lands at +1. (`schema` under `model` has no such
; rule: they are siblings, and nvim-treesitter has no sibling-relative
; indent — see docs/openfga.md.)
((contents) @indent.begin
  (#set! indent.immediate 1))

(condition_body
  "}" @indent.branch @indent.end)

; A bare `relations` with no define yet is an ERROR *beside* the type
; declaration, not inside it, so neither begin rule above sees the next line.
; Align that line one level right of the `relations` keyword instead.
; indent.increment is in columns, i.e. this assumes the config's shiftwidth
; of 2 (options.lua) — the same 2-space nesting every OpenFGA model uses.
(ERROR
  "relations" @indent.align
  (#set! indent.increment 2))

; No `(comment) @indent.auto`: comments are single-line tokens here, and
; nvim-treesitter only honours indent.auto for a node that starts above the
; target line and still covers it — it would never fire. Comment lines are
; handled by config.fga_indent instead.
(ERROR) @indent.auto
