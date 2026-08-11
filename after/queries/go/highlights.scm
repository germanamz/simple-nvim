; extends

; Upstream's doc-comment patterns cover the comment run above a source_file-level
; const / function / type / var declaration, plus the package doc — but NOT the
; one above a `method_declaration`. So every method's doc block stayed plain
; @comment and read a tier louder than the doc block above a plain function,
; which is backwards: methods are exactly where Go's doc comments cluster.
;
; Matched against the same `source_file` anchor as upstream's siblings, so the
; comment run has to sit directly above the method with nothing between.
; See lua/config/syntax_emphasis.lua for what the two comment tiers render as.
(source_file
  (comment)+ @comment.documentation
  .
  (method_declaration))
