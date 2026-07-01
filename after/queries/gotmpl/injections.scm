; extends

; Go html/templates: everything outside the `{{ ... }}` actions is HTML. The
; gotmpl grammar exposes that literal markup as `text` nodes (interleaved with,
; and nested inside, the actions). Inject html for all of them as ONE combined
; tree so the surrounding tags/attributes highlight and fragments split by an
; action — `<a href="` … `">` around `{{ .URL }}` — rejoin into valid html.
;
; Scoped to the gotmpl parser (i.e. gohtmltmpl buffers), so plain `.html` files
; are untouched. `; extends` keeps nvim-treesitter's bundled gotmpl injections
; (printf / js / html helper strings) in addition to this rule.
((text) @injection.content
  (#set! injection.language "html")
  (#set! injection.combined))
