import {describe, expect, it} from "vitest";
import {darken, lighten, mix, noHash, normalizeHex, stripAlpha, withAlpha} from "./color";

describe("normalizeHex", () => {
    it("expands shorthand and lowercases", () => {
        expect(normalizeHex("#abc")).toBe("#aabbcc");
        expect(normalizeHex("#AbCd")).toBe("#aabbccdd");
        expect(normalizeHex("#AABBCC")).toBe("#aabbcc");
    });
    it("passes 6/8-digit through, tolerates missing #", () => {
        expect(normalizeHex("#12345678")).toBe("#12345678");
        expect(normalizeHex("112233")).toBe("#112233");
    });
    it("throws on garbage", () => {
        expect(() => normalizeHex("nope")).toThrow();
        expect(() => normalizeHex("#12345")).toThrow();
    });
});

describe("alpha helpers", () => {
    it("stripAlpha and noHash", () => {
        expect(stripAlpha("#11223344")).toBe("#112233");
        expect(noHash("#112233")).toBe("112233");
        expect(noHash("#11223344")).toBe("112233");
    });
    it("withAlpha sets the alpha byte", () => {
        expect(withAlpha("#112233", 1)).toBe("#112233ff");
        expect(withAlpha("#112233", 0)).toBe("#11223300");
        expect(withAlpha("#11223344", 0.5)).toBe("#11223380");
    });
});

describe("derivation", () => {
    it("mixes linearly", () => {
        expect(mix("#000000", "#ffffff", 0.5)).toBe("#808080");
        expect(mix("#000000", "#ffffff", 0)).toBe("#000000");
    });
    it("lighten/darken move toward white/black", () => {
        expect(lighten("#808080", 1)).toBe("#ffffff");
        expect(darken("#808080", 1)).toBe("#000000");
    });
});
