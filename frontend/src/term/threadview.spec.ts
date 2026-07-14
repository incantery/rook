import {describe, expect, it} from "vitest";
import type {ThreadInfo} from "../hostapi";
import {
    bandThreads,
    contextKey,
    cycleStack,
    glyphClass,
    markerLines,
    pickFromStack,
    threadStack,
} from "./threadview";

// A minimal ThreadInfo factory — only the fields the view-model reads.
function th(p: Partial<ThreadInfo> & {id: number}): ThreadInfo {
    return {
        workspace: "w",
        path: "a.ts",
        startLine: 1,
        endLine: 1,
        side: "modified",
        blobSha: "",
        anchorText: "",
        state: "open",
        created: "",
        updated: "",
        comments: [],
        currentStart: 1,
        currentEnd: 1,
        ...p,
    } as ThreadInfo;
}

describe("bandThreads", () => {
    it("keeps this file + side, sorted by currentStart then id", () => {
        const all = [
            th({id: 3, path: "a.ts", currentStart: 10}),
            th({id: 1, path: "a.ts", currentStart: 5}),
            th({id: 2, path: "b.ts", currentStart: 1}),
            th({id: 4, path: "a.ts", side: "original", currentStart: 1}),
        ];
        expect(bandThreads(all, "a.ts", "modified").map((t) => t.id)).toEqual([1, 3]);
    });
});

describe("markerLines + glyphClass", () => {
    it("groups per anchor line, clamping <1 to 1", () => {
        const t = [th({id: 1, currentStart: 0}), th({id: 2, currentStart: 0})];
        const m = markerLines(t);
        expect(m.get(1)?.map((x) => x.id)).toEqual([1, 2]);
    });
    it("picks the most-demanding state and flags outdated", () => {
        const g = [th({id: 1, state: "resolved"}), th({id: 2, state: "pending", outdated: true})];
        expect(glyphClass(g)).toBe("thread-glyph thread-glyph-pending thread-glyph-outdated");
    });
});

describe("threadStack", () => {
    it("returns the line's threads rank-sorted (pending>open>resolved, then id)", () => {
        const all = [
            th({id: 1, currentStart: 4, state: "open"}),
            th({id: 2, currentStart: 4, state: "pending"}),
            th({id: 3, currentStart: 4, state: "resolved"}),
            th({id: 4, currentStart: 9, state: "open"}),
        ];
        expect(threadStack(all, "a.ts", "modified", 4).map((t) => t.id)).toEqual([2, 1, 3]);
    });
    it("clamps currentStart<1 onto line 1", () => {
        const all = [th({id: 7, currentStart: 0})];
        expect(threadStack(all, "a.ts", "modified", 1).map((t) => t.id)).toEqual([7]);
    });
});

describe("pickFromStack", () => {
    it("returns null for an empty stack", () => {
        expect(pickFromStack([])).toBeNull();
    });
    it("keeps the active thread if still present", () => {
        const stack = [th({id: 2}), th({id: 5}), th({id: 8})];
        expect(pickFromStack(stack, 5)).toEqual({thread: stack[1], index: 1, count: 3});
    });
    it("falls back to the top when the active id is gone", () => {
        const stack = [th({id: 2}), th({id: 8})];
        expect(pickFromStack(stack, 99)?.index).toBe(0);
    });
});

describe("cycleStack", () => {
    it("wraps forward and backward", () => {
        const stack = [th({id: 2}), th({id: 5}), th({id: 8})];
        expect(cycleStack(stack, 5, 1)).toBe(8);
        expect(cycleStack(stack, 8, 1)).toBe(2);
        expect(cycleStack(stack, 2, -1)).toBe(8);
    });
    it("returns null on an empty stack", () => {
        expect(cycleStack([], 1, 1)).toBeNull();
    });
});

describe("contextKey", () => {
    it("changes when workspace or path changes, and is stable otherwise", () => {
        expect(contextKey({workspace: "w", path: "a.ts"})).toBe(
            contextKey({workspace: "w", path: "a.ts"}),
        );
        expect(contextKey({workspace: "w", path: "a.ts"})).not.toBe(
            contextKey({workspace: "w", path: "b.ts"}),
        );
        expect(contextKey(null)).toBe("");
    });
});
