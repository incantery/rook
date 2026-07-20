import {describe, expect, it} from "vitest";
import {fuzzyMatch, fuzzyRank, fuzzySegments} from "./fuzzy";

const items = (q: string, cands: string[]) => fuzzyRank(q, cands, 200).map((r) => r.item);

describe("fuzzyMatch", () => {
    it("requires the query as a subsequence", () => {
        expect(fuzzyMatch("abc", "a-b-c")).not.toBeNull();
        expect(fuzzyMatch("abc", "acb")).toBeNull();
        expect(fuzzyMatch("abc", "ab")).toBeNull();
    });

    it("is case-insensitive", () => {
        expect(fuzzyMatch("fp", "FilePicker.svelte")).not.toBeNull();
    });

    it("empty query matches everything with no marks", () => {
        expect(fuzzyMatch("", "anything")).toEqual({score: 0, positions: []});
    });

    it("positions are ascending candidate indices", () => {
        const h = fuzzyMatch("fpk", "FilePicker.svelte")!;
        expect(h.positions).toHaveLength(3);
        const [a, b, c] = h.positions;
        expect(a).toBeLessThan(b);
        expect(b).toBeLessThan(c);
        expect("FilePicker.svelte"[a].toLowerCase()).toBe("f");
    });

    it("prefers boundary starts over mid-word hits", () => {
        const boundary = fuzzyMatch("pick", "file-picker.ts")!;
        const mid = fuzzyMatch("pick", "sharpickle.ts")!;
        expect(boundary.score).toBeGreaterThan(mid.score);
    });

    it("prefers consecutive runs over scattered chars", () => {
        const run = fuzzyMatch("host", "hostapi.ts")!;
        const scattered = fuzzyMatch("host", "h-o-s-t-x.ts")!;
        expect(run.score).toBeGreaterThan(scattered.score);
    });
});

describe("fuzzyRank", () => {
    it("basename hits beat directory hits", () => {
        const got = items("config", [
            "internal/configure-me/other.go",
            "internal/config/config.go",
            "docs/misc.md",
        ]);
        expect(got[0]).toBe("internal/config/config.go");
        expect(got).not.toContain("docs/misc.md");
    });

    it("short exact-ish names float over deep paths", () => {
        const got = items("editor", [
            "frontend/src/some/deep/editor-helpers-extra.ts",
            "frontend/src/term/editor.ts",
        ]);
        expect(got[0]).toBe("frontend/src/term/editor.ts");
    });

    it("empty query keeps input order under the cap", () => {
        const got = fuzzyRank("", ["b", "a", "c"], 2);
        expect(got.map((r) => r.item)).toEqual(["b", "a"]);
    });

    it("caps results after ranking, not before", () => {
        const cands = Array.from({length: 50}, (_, i) => `dir/file${i}.txt`);
        cands.push("exact.txt");
        const got = fuzzyRank("exact", cands, 5);
        expect(got[0].item).toBe("exact.txt");
    });
});

describe("fuzzySegments", () => {
    it("splits into alternating runs", () => {
        expect(fuzzySegments("abcd", [1, 2])).toEqual([
            {text: "a", hit: false},
            {text: "bc", hit: true},
            {text: "d", hit: false},
        ]);
    });

    it("no positions is one cold run", () => {
        expect(fuzzySegments("abc", [])).toEqual([{text: "abc", hit: false}]);
    });

    it("full-hit text is one hot run", () => {
        expect(fuzzySegments("ab", [0, 1])).toEqual([{text: "ab", hit: true}]);
    });
});
