
; ---- JSX, appended to typescript.scm for the tsx grammar only ----
;
; These nodes exist in the tsx grammar and nowhere else, which is why
; they live in their own file. See the note at the top of typescript.scm.

; Element names. A capitalised name is a component and a lowercase one
; is an HTML tag, and telling them apart needs a predicate this engine
; does not evaluate — so both read as a type, which is what a tag IS in
; the shape of the document.

(jsx_opening_element
  name: (identifier) @type)

(jsx_closing_element
  name: (identifier) @type)

(jsx_self_closing_element
  name: (identifier) @type)

; A member component: <Foo.Bar />

(jsx_opening_element
  name: (member_expression
    property: (property_identifier) @type))

(jsx_self_closing_element
  name: (member_expression
    property: (property_identifier) @type))

; Attribute names — the same family as an object key, and the bucket
; that keeps them from reading as values.

(jsx_attribute
  (property_identifier) @attribute)
