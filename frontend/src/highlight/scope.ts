// TextMate scopes → rook's 13 syntax roles.
//
// A TextMate grammar hands back a scope STACK per token, outermost first:
//   ["source.go", "meta.function.go", "entity.name.function.go"]
// Monaco's TokensProvider takes ONE string per token and matches it against
// its theme rules, which are a dotted trie with longest-prefix wins — so
// "entity.name.function.go" resolves against a rule keyed "entity.name.function".
//
// The naive bridge passes the innermost scope and takes what it gets. That
// miscolors a whole class of tokens: a string's own quote characters carry
//   ["source.go", "string.quoted.double.go", "punctuation.definition.string.begin.go"]
// and the innermost scope is punctuation — so the quotes come out operator-
// colored while the text between them is string-colored. Same for comment
// markers, and for the delimiters of every regex and template literal.
//
// So pickScope walks the stack INNERMOST → OUTERMOST and takes the first scope
// that some rule actually claims. Punctuation inside a string finds no rule of
// its own (we deliberately don't key one), falls outward, and lands on
// "string.quoted.double" → the quotes match their string. It's the same answer
// TextMate's own specificity rules give for the cases that matter, without
// implementing the full selector language.

import type {Syntax} from "../theme/palette";

/** A scope prefix, the syntax role it paints, and optionally a font style.
 *
 *  The role may be null: a rule with weight but no color. Monaco merges the
 *  two independently (`acceptOverwrite` skips a foreground of ColorId.None),
 *  so such a rule leaves the color to fall through the trie. That is what
 *  emphasis wants — **bold** in a paragraph should be body text that is
 *  heavier, not a new hue.
 *
 *  Fall-through goes to the trie's PARENT, not to whatever the token was
 *  nested inside: pickScope hands Monaco one scope string per token, so by
 *  theme-resolution time there is no memory of the enclosing construct.
 *  "markup.bold.markdown" resolves against "markup" (no rule) and lands on
 *  the root default. The honest cost: bold inside a heading is body-colored
 *  and bold, not heading-colored and bold. Rare enough to accept; the common
 *  case — emphasis in prose — is exactly right. */
export type ScopeRule = [scope: string, role: keyof Syntax | null, fontStyle?: string];

/** A scope prefix and the syntax role it paints. Order is irrelevant —
 *  matching is by dotted-prefix specificity, longest wins — but the table
 *  reads outermost-concept-first on purpose. */
export const SCOPE_ROLES: ScopeRule[] = [
    // comments — the leading // or /* is punctuation.definition.comment,
    // which nothing claims, so it falls outward onto this rule
    ["comment", "comment"],

    // strings. Their quotes deliberately have NO rule of their own: the
    // walk falls outward to the enclosing string scope, which is what makes
    // "hello" read as one colored run instead of three.
    ["string", "string"],
    ["string.regexp", "regexp"],
    ["constant.character.escape", "regexp"],

    // literals
    ["constant.numeric", "number"],
    ["constant", "constant"],
    ["constant.language", "constant"],

    // keywords. `storage` is TextMate's home for func/var/type/class and the
    // modifiers (static, async, pub) — all keyword-colored in every theme
    // rook ships against.
    ["keyword", "keyword"],
    ["storage", "keyword"],
    ["storage.type", "keyword"],
    ["storage.modifier", "keyword"],
    ["keyword.operator", "operator"],

    // types
    ["entity.name.type", "type"],
    ["entity.name.class", "type"],
    ["entity.name.namespace", "type"],
    ["support.type", "type"],
    ["support.class", "type"],

    // functions
    ["entity.name.function", "function"],
    ["support.function", "function"],
    ["meta.function-call", "function"],
    ["variable.function", "function"],

    // variables
    ["variable", "variable"],
    ["variable.parameter", "variable"],
    ["variable.other.property", "variable"],
    ["support.variable", "variable"],

    // markup: html/svelte
    ["entity.name.tag", "tag"],
    ["entity.other.attribute-name", "attrName"],
    ["meta.attribute.value", "attrValue"],

    // PROSE — markdown's markup.* family. This table was code-shaped until
    // these landed, so a .md file tokenized correctly and then rendered as
    // flat editorFg: the grammar emits 82 markup.* scopes and not one of them
    // was claimed. Only fenced code had color, because those tokens carry the
    // embedded grammar's source.* scopes.
    //
    // The `##`, the `**`, the `>` are punctuation.definition.* and stay
    // deliberately unclaimed, exactly like a string's quotes — they fall
    // outward onto the construct they open, so a heading is one colored run.
    ["markup.heading", "keyword", "bold"],
    ["markup.bold", null, "bold"],
    ["markup.italic", null, "italic"],
    ["markup.strikethrough", null, "strikethrough"],
    ["markup.inline.raw", "string"], // `code span`
    ["markup.raw.block", "string"], // indented block, no language to embed
    ["markup.underline.link", "function", "underline"],
    ["markup.quote", "comment", "italic"],
    ["meta.separator", "comment"], // ---
    // The bullet ONLY. markup.list.* spans the whole item (begin/while), so
    // claiming it would paint every word of every list.
    ["punctuation.definition.list.begin", "keyword"],
    // A table's frame. Its |---|---| row already resolved to operator through
    // the generic punctuation.separator rule, so without this the pipes and
    // the dashes of one table read as two different things.
    ["punctuation.definition.table", "operator"],
    // the `go` in ```go — a quiet label, like the --- rule above
    ["fenced_code.block.language", "comment"],
    //
    // NOT claimed, on purpose:
    //   markup.fenced_code.block — spans the embedded code, whose own scopes
    //     must win; claiming it would flatten every unstyled identifier in a
    //     fence to one color.
    //   markup.table — spans the cells, not just the pipes.

    // Structural punctuation ONLY, named family by family. A blanket
    // "punctuation" rule would claim punctuation.definition.string.begin and
    // punctuation.definition.comment — the very scopes that must stay
    // unclaimed so a quote inherits its string and a // inherits its comment.
    // (The tests hold this line; a blanket rule fails them.)
    ["punctuation.separator", "operator"], // , :
    ["punctuation.terminator", "operator"], // ;
    ["punctuation.section", "operator"], // braces, brackets, parens
    ["punctuation.accessor", "operator"], // the . in a.b
    ["punctuation.definition.tag", "tag"], // the < > of a tag
    ["meta.brace", "operator"],
    ["keyword.control", "keyword"],
];

// LSP semantic token types → the same 13 roles. This is the layer ABOVE the
// grammar: where a TextMate rule infers from shape (a name before "(" is
// probably a call), these come from a compiler that actually resolved the
// symbol. Standalone Monaco matches them through the same dotted trie as
// scopes — [type, ...modifiers].join(".") — so "variable.readonly" refines
// "variable" with no extra machinery, and a modifier rule can be added later
// without touching this table.
//
// The list is LSP's standard token types (3.17). A server may publish types
// outside it; those simply find no rule and keep the grammar's color, which
// is the correct fallback.
export const SEMANTIC_ROLES: [string, keyof Syntax][] = [
    ["namespace", "type"],
    ["type", "type"],
    ["class", "type"],
    ["enum", "type"],
    ["interface", "type"],
    ["struct", "type"],
    ["typeParameter", "type"],
    ["parameter", "variable"],
    ["variable", "variable"],
    ["property", "variable"],
    ["enumMember", "constant"],
    ["event", "function"],
    ["function", "function"],
    ["method", "function"],
    ["macro", "keyword"],
    ["keyword", "keyword"],
    ["modifier", "keyword"],
    ["comment", "comment"],
    ["string", "string"],
    ["number", "number"],
    ["regexp", "regexp"],
    ["operator", "operator"],
    ["decorator", "function"],
];

/** Every scope prefix some rule claims — the set pickScope walks against. */
const CLAIMED: ReadonlySet<string> = new Set(SCOPE_ROLES.map(([scope]) => scope));

/** Does any rule claim this scope, by dotted-prefix? "string.quoted.double.go"
 *  is claimed by a rule keyed "string" or "string.quoted"; it walks the dots
 *  down, longest first, exactly as Monaco's theme trie will. */
export function claimed(scope: string, claims: ReadonlySet<string> = CLAIMED): boolean {
    for (let s: string = scope; s !== "";) {
        if (claims.has(s)) return true;
        const dot = s.lastIndexOf(".");
        if (dot === -1) return false;
        s = s.slice(0, dot);
    }
    return false;
}

/** The scope to hand Monaco for a token: innermost that some rule claims,
 *  else the innermost scope (Monaco's trie falls through to the default
 *  foreground, which is the right answer for an unstyled token). */
export function pickScope(
    scopes: readonly string[],
    claims: ReadonlySet<string> = CLAIMED,
): string {
    for (let i = scopes.length - 1; i >= 0; i--) {
        const s = scopes[i];
        // "source.go" / "text.html.basic" are the grammar's own root scope —
        // never a color, and claiming one would paint an entire file.
        if (s.startsWith("source.") || s.startsWith("text.")) continue;
        if (claimed(s, claims)) return s;
    }
    return scopes.length > 0 ? scopes[scopes.length - 1] : "";
}
