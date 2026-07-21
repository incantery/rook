import {describe, expect, it} from "vitest";
import {claimed, pickScope, SCOPE_ROLES} from "./scope";

describe("claimed", () => {
    it("matches a scope by dotted prefix, longest first", () => {
        expect(claimed("string.quoted.double.go")).toBe(true);
        expect(claimed("entity.name.function.go")).toBe(true);
        expect(claimed("keyword.control.import.go")).toBe(true);
    });
    it("rejects a scope no rule claims", () => {
        expect(claimed("meta.block.go")).toBe(false);
        expect(claimed("nonsense")).toBe(false);
        expect(claimed("")).toBe(false);
    });
    it("does not match on a partial segment", () => {
        // "stringify" must not be claimed by the "string" rule
        expect(claimed("stringify.thing")).toBe(false);
    });
});

describe("pickScope", () => {
    it("takes the innermost claimed scope", () => {
        expect(pickScope(["source.go", "meta.function.go", "entity.name.function.go"])).toBe(
            "entity.name.function.go",
        );
    });

    // the bug the walk exists to prevent: a string's own quotes are
    // punctuation, and must still read as string
    it("falls outward from unclaimed punctuation to its string", () => {
        expect(
            pickScope([
                "source.go",
                "string.quoted.double.go",
                "punctuation.definition.string.begin.go",
            ]),
        ).toBe("string.quoted.double.go");
    });

    it("falls outward from a comment's marker to the comment", () => {
        expect(
            pickScope([
                "source.go",
                "comment.line.double-slash.go",
                "punctuation.definition.comment.go",
            ]),
        ).toBe("comment.line.double-slash.go");
    });

    it("skips meta scopes that claim nothing", () => {
        expect(pickScope(["source.go", "meta.block.go", "keyword.control.go"])).toBe(
            "keyword.control.go",
        );
    });

    it("never returns the grammar's root scope", () => {
        expect(pickScope(["source.go"])).toBe("source.go"); // nothing else to give
        expect(pickScope(["source.go", "meta.block.go"])).toBe("meta.block.go"); // not source.go
        expect(pickScope(["text.html.basic", "meta.tag.html"])).toBe("meta.tag.html");
    });

    it("returns the innermost scope when nothing is claimed", () => {
        expect(pickScope(["source.go", "meta.block.go", "meta.other.go"])).toBe("meta.other.go");
    });

    it("handles an empty stack", () => {
        expect(pickScope([])).toBe("");
    });

    it("honours a caller's own claim set", () => {
        const claims = new Set(["keyword"]);
        expect(pickScope(["source.go", "string.quoted.go", "keyword.other.go"], claims)).toBe(
            "keyword.other.go",
        );
        // string is not claimed by THIS set, so it falls through to innermost
        expect(pickScope(["source.go", "string.quoted.go"], claims)).toBe("string.quoted.go");
    });
});

// Every stack below was CAPTURED from the vendored markdown grammar running
// under vscode-textmate — not invented. Markdown is the one language whose
// constructs span their own content (a quote scope covers the quoted prose, a
// list scope covers the whole item), so what a rule must NOT claim matters as
// much here as what it must.
describe("pickScope on markdown", () => {
    it("paints a heading as one run, marker and text alike", () => {
        const marker = [
            "text.html.markdown",
            "markup.heading.markdown",
            "heading.1.markdown",
            "punctuation.definition.heading.markdown",
        ];
        const text = [
            "text.html.markdown",
            "markup.heading.markdown",
            "heading.1.markdown",
            "entity.name.section.markdown",
        ];
        expect(pickScope(marker)).toBe("markup.heading.markdown");
        expect(pickScope(text)).toBe("markup.heading.markdown");
    });

    it("paints a blockquote's prose, because the quote is the construct", () => {
        expect(
            pickScope(["text.html.markdown", "markup.quote.markdown", "meta.paragraph.markdown"]),
        ).toBe("markup.quote.markdown");
    });

    // The counterpart, and the reason markup.list.* is deliberately unclaimed:
    // its scope spans the entire item, so claiming it would paint every word
    // of every list the bullet's color.
    it("colors a list's bullet but NOT the item's text", () => {
        expect(
            pickScope([
                "text.html.markdown",
                "markup.list.unnumbered.markdown",
                "punctuation.definition.list.begin.markdown",
            ]),
        ).toBe("punctuation.definition.list.begin.markdown");
        expect(
            pickScope([
                "text.html.markdown",
                "markup.list.unnumbered.markdown",
                "meta.paragraph.markdown",
            ]),
        ).toBe("meta.paragraph.markdown");
    });

    // markup.fenced_code.block wraps the embedded grammar's own scopes. If it
    // were claimed it would sit between them and the fall-outward walk and
    // flatten every unstyled token in a fence to one color.
    it("lets an embedded grammar win inside a fence", () => {
        expect(
            pickScope([
                "text.html.markdown",
                "markup.fenced_code.block.markdown",
                "meta.embedded.block.go",
                "constant.language.null.go",
            ]),
        ).toBe("constant.language.null.go");
    });

    it("leaves table cells alone while framing the table", () => {
        expect(pickScope(["text.html.markdown", "markup.table.markdown"])).toBe(
            "markup.table.markdown",
        );
        expect(claimed("markup.table.markdown")).toBe(false);
        expect(claimed("punctuation.definition.table.markdown")).toBe(true);
    });

    it("claims emphasis without claiming a color", () => {
        expect(
            pickScope(["text.html.markdown", "meta.paragraph.markdown", "markup.bold.markdown"]),
        ).toBe("markup.bold.markdown");
        const bold = SCOPE_ROLES.find(([s]) => s === "markup.bold");
        expect(bold?.[1]).toBe(null);
        expect(bold?.[2]).toBe("bold");
    });
});

describe("SCOPE_ROLES", () => {
    it("maps every scope to a real syntax role", () => {
        const roles = new Set([
            "comment",
            "string",
            "number",
            "keyword",
            "type",
            "function",
            "variable",
            "constant",
            "operator",
            "tag",
            "attrName",
            "attrValue",
            "regexp",
        ]);
        for (const [scope, role] of SCOPE_ROLES) {
            // null is legal — a style-only rule (markup.bold) that adds weight
            // and lets the color fall through the theme trie
            if (role === null) continue;
            expect(roles.has(role), `${scope} → ${role}`).toBe(true);
        }
    });

    it("gives every style-only rule an actual style", () => {
        // a rule with neither a color nor a style paints nothing and would
        // silently claim a scope away from the fall-outward walk
        for (const [scope, role, fontStyle] of SCOPE_ROLES) {
            if (role === null) expect(fontStyle, `${scope} has no color`).toBeTruthy();
        }
    });

    it("never claims a string's punctuation (the fall-outward contract)", () => {
        const keys = new Set(SCOPE_ROLES.map(([s]) => s));
        expect(keys.has("punctuation.definition.string")).toBe(false);
    });
});
