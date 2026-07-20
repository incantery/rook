import {beforeEach, describe, expect, it} from "vitest";
import {
    legendIndex,
    legendModifiers,
    legendTypes,
    remapTokens,
    STANDARD_MODIFIERS,
    STANDARD_TYPES,
    unifyTokens,
} from "./semantic";

// the unified legend is module state that grows; reset between tests
beforeEach(() => {
    legendTypes.splice(0, legendTypes.length, ...STANDARD_TYPES);
    legendModifiers.splice(0, legendModifiers.length, ...STANDARD_MODIFIERS);
});

describe("legendIndex", () => {
    it("finds an existing name without growing the list", () => {
        const n = legendTypes.length;
        expect(legendIndex(legendTypes, "function")).toBe(STANDARD_TYPES.indexOf("function"));
        expect(legendTypes.length).toBe(n);
    });
    it("appends an unknown name and returns its new index", () => {
        const n = legendTypes.length;
        expect(legendIndex(legendTypes, "goTypeParam")).toBe(n);
        expect(legendTypes.length).toBe(n + 1);
        // stable on a second ask — indices already handed out never move
        expect(legendIndex(legendTypes, "goTypeParam")).toBe(n);
    });
});

describe("remapTokens", () => {
    it("rewrites type indices and leaves the position deltas alone", () => {
        // one token: line+0, char+4, len 5, type 1, no modifiers
        const data = Uint32Array.from([0, 4, 5, 1, 0]);
        remapTokens(data, [10, 20, 30], []);
        expect([...data]).toEqual([0, 4, 5, 20, 0]);
    });

    it("moves each modifier BIT independently", () => {
        // modifiers bitset 0b101 = server modifiers 0 and 2, which map to
        // unified 3 and 1 → 0b1010
        const data = Uint32Array.from([0, 0, 3, 0, 0b101]);
        remapTokens(data, [0], [3, 9, 1]);
        expect(data[4]).toBe(0b1010);
    });

    it("leaves a zero modifier set at zero", () => {
        const data = Uint32Array.from([0, 0, 3, 0, 0]);
        remapTokens(data, [7], [1, 2]);
        expect(data[4]).toBe(0);
    });

    it("walks every group in a multi-token stream", () => {
        const data = Uint32Array.from([0, 0, 3, 0, 0, 2, 4, 5, 1, 0]);
        remapTokens(data, [5, 6], []);
        expect([...data]).toEqual([0, 0, 3, 5, 0, 2, 4, 5, 6, 0]);
    });

    it("ignores a trailing partial group rather than reading past the end", () => {
        const data = Uint32Array.from([0, 0, 3, 0, 0, 9, 9]); // 5 + 2 stragglers
        expect(() => remapTokens(data, [4], [])).not.toThrow();
        expect([...data.slice(5)]).toEqual([9, 9]);
    });

    it("passes an out-of-range type index through untouched", () => {
        // a server that sends an index its own legend doesn't cover is
        // broken, but it must not become undefined/NaN in the stream
        const data = Uint32Array.from([0, 0, 3, 99, 0]);
        remapTokens(data, [0, 1], []);
        expect(data[3]).toBe(99);
    });
});

describe("unifyTokens", () => {
    it("is the identity when the server speaks the standard legend", () => {
        const data = [0, 0, 4, STANDARD_TYPES.indexOf("function"), 0];
        const out = unifyTokens(data, STANDARD_TYPES, STANDARD_MODIFIERS);
        expect([...out]).toEqual(data);
    });

    it("relocates a server whose legend is in a different order", () => {
        // this server calls index 0 "function"; unified has it at 12
        const out = unifyTokens([0, 0, 4, 0, 0], ["function", "type"], []);
        expect(out[3]).toBe(STANDARD_TYPES.indexOf("function"));
    });

    it("grows the legend for a nonstandard type and maps into it", () => {
        const before = legendTypes.length;
        const out = unifyTokens([0, 0, 4, 0, 0], ["goBuiltin"], []);
        expect(out[3]).toBe(before);
        expect(legendTypes[before]).toBe("goBuiltin");
    });

    it("returns a Uint32Array Monaco can consume directly", () => {
        expect(unifyTokens([0, 0, 1, 0, 0], ["type"], [])).toBeInstanceOf(Uint32Array);
    });
});
