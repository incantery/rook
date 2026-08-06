; Python highlights — hand-cut, not upstream's.
;
; tree-sitter-python's own highlights.scm leans on #match? predicates
; ("an identifier starting with a capital is a constructor"), and this
; engine does not evaluate predicates: it takes captures and maps their
; names to style buckets. Importing upstream wholesale would paint every
; identifier with whatever the last predicate-guarded pattern claimed.
;
; So: only captures that mean something without a predicate. A name that
; maps to no bucket contributes nothing, which is how the deliberately
; unstyled ones below stay plain.

; Comments

(comment) @comment

; Strings — captured whole, so f-string interpolation stays string
; coloured rather than flickering between two buckets mid-token.

(string) @string
(concatenated_string) @string
(escape_sequence) @escape

; Numbers and the literals that behave like them

[
  (integer)
  (float)
] @number

[
  (true)
  (false)
  (none)
] @constant.builtin

; Keywords

[
  "and"
  "as"
  "assert"
  "async"
  "await"
  "break"
  "class"
  "continue"
  "def"
  "del"
  "elif"
  "else"
  "except"
  "finally"
  "for"
  "from"
  "global"
  "if"
  "import"
  "in"
  "is"
  "lambda"
  "nonlocal"
  "not"
  "or"
  "pass"
  "raise"
  "return"
  "try"
  "while"
  "with"
  "yield"
] @keyword

; Definitions

(function_definition
  name: (identifier) @function)

(class_definition
  name: (identifier) @type)

; Calls

(call
  function: (identifier) @function)

(call
  function: (attribute
    attribute: (identifier) @function.method))

; Decorators read as structure, which is closer to a keyword than to a
; call — @decorator lands on the whole `@name` including the sigil.

(decorator) @keyword

; Annotations are the one place a bare identifier IS a type without a
; predicate to prove it.

(type
  (identifier) @type)
