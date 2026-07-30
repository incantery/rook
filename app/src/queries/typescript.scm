; TypeScript highlights — shared by the ts and tsx grammars.
;
; tsx.scm is this file PLUS the JSX patterns (syntax.zig concatenates
; them at comptime). It has to be that way round rather than one file
; with everything: a query naming a node the grammar does not have fails
; to COMPILE, and jsx_element exists only in the tsx grammar — so a
; shared file carrying JSX patterns would silently leave every .ts file
; with no highlighting at all.
;
; Hand-cut, like python.scm: no #match? predicates, because this engine
; does not evaluate them.

; Comments

(comment) @comment

; Strings and the things that behave like them

(string) @string
(template_string) @string
(escape_sequence) @escape
(regex) @string

; Numbers and literals

(number) @number

[
  (true)
  (false)
  (null)
  (undefined)
] @constant.builtin

; Types. The one thing TypeScript adds that JavaScript never had, so
; it earns its own bucket loudly.

(type_identifier) @type
(predefined_type) @type

; Definitions and calls

(function_declaration
  name: (identifier) @function)

(function_signature
  name: (identifier) @function)

(method_definition
  name: (property_identifier) @function.method)

(method_signature
  name: (property_identifier) @function.method)

(call_expression
  function: (identifier) @function)

(call_expression
  function: (member_expression
    property: (property_identifier) @function.method))

(new_expression
  constructor: (identifier) @type)

; Keywords

[
  "abstract"
  "as"
  "async"
  "await"
  "break"
  "case"
  "catch"
  "class"
  "const"
  "continue"
  "declare"
  "default"
  "delete"
  "do"
  "else"
  "enum"
  "export"
  "extends"
  "finally"
  "for"
  "from"
  "function"
  "get"
  "if"
  "implements"
  "import"
  "in"
  "instanceof"
  "interface"
  "keyof"
  "let"
  "namespace"
  "new"
  "of"
  "private"
  "protected"
  "public"
  "readonly"
  "return"
  "satisfies"
  "set"
  "static"
  "switch"
  "target"
  "throw"
  "try"
  "type"
  "typeof"
  "var"
  "void"
  "while"
  "yield"
] @keyword

; A decorator reads as structure rather than as the call it desugars to.

(decorator) @keyword
