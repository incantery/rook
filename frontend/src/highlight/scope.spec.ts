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
            expect(roles.has(role), `${scope} → ${role}`).toBe(true);
        }
    });

    it("never claims a string's punctuation (the fall-outward contract)", () => {
        const keys = new Set(SCOPE_ROLES.map(([s]) => s));
        expect(keys.has("punctuation.definition.string")).toBe(false);
    });
});
