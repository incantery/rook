import {describe, expect, it} from "vitest";
import type {Frame, WCell} from "./frame";
import {ClientGrid} from "./grid";
import {isSelected, rowExtent, type Selection, selectedText} from "./selection";

// a coarse CJK check, enough for the "世" case the tests use
function isWide(cp: number): boolean {
    return (
        (cp >= 0x2e80 && cp <= 0xa4cf) ||
        (cp >= 0xac00 && cp <= 0xd7a3) ||
        (cp >= 0xf900 && cp <= 0xfaff)
    );
}

function gridOf(lines: string[], cols: number): ClientGrid {
    const g = new ClientGrid(cols, lines.length);
    const rows = lines.map((text, y) => {
        const cells: WCell[] = [];
        for (const ch of text) {
            const width = isWide(ch.codePointAt(0)!) ? 2 : 1;
            cells.push({content: ch, fg: 0, bg: 0, attr: 0, width});
            if (width === 2) cells.push({content: " ", fg: 0, bg: 0, attr: 0, width: 0});
        }
        return {y, runs: [{x: 0, cells}]};
    });
    const f: Frame = {cursor: {x: 0, y: 0, visible: true}, rows};
    g.apply(f);
    return g;
}

const lin = (ax: number, ay: number, fx: number, fy: number): Selection => ({
    anchor: {x: ax, y: ay},
    focus: {x: fx, y: fy},
    mode: "linear",
});

describe("rowExtent (linear)", () => {
    it("single row, either drag direction gives the same span", () => {
        expect(rowExtent(lin(2, 0, 6, 0), 0, 80)).toEqual([2, 6]);
        expect(rowExtent(lin(6, 0, 2, 0), 0, 80)).toEqual([2, 6]);
    });
    it("first row runs to the right edge, last row from the left", () => {
        const s = lin(3, 1, 5, 3);
        expect(rowExtent(s, 1, 80)).toEqual([3, 79]);
        expect(rowExtent(s, 2, 80)).toEqual([0, 79]);
        expect(rowExtent(s, 3, 80)).toEqual([0, 5]);
    });
    it("rows outside the selection are null", () => {
        const s = lin(3, 1, 5, 3);
        expect(rowExtent(s, 0, 80)).toBeNull();
        expect(rowExtent(s, 4, 80)).toBeNull();
    });
});

describe("rowExtent (block)", () => {
    it("selects the same column range on every row in range", () => {
        const s: Selection = {anchor: {x: 2, y: 1}, focus: {x: 6, y: 3}, mode: "block"};
        expect(rowExtent(s, 1, 80)).toEqual([2, 6]);
        expect(rowExtent(s, 2, 80)).toEqual([2, 6]);
        expect(rowExtent(s, 0, 80)).toBeNull();
    });
});

describe("isSelected", () => {
    it("bounds the extent inclusively", () => {
        const s = lin(2, 0, 6, 0);
        expect(isSelected(s, 2, 0, 80)).toBe(true);
        expect(isSelected(s, 6, 0, 80)).toBe(true);
        expect(isSelected(s, 1, 0, 80)).toBe(false);
        expect(isSelected(s, 7, 0, 80)).toBe(false);
    });
});

describe("selectedText", () => {
    it("extracts a single-line span", () => {
        const g = gridOf(["hello world"], 20);
        expect(selectedText(g, lin(0, 0, 4, 0))).toBe("hello");
    });

    it("trims each line's trailing whitespace", () => {
        const g = gridOf(["abc", "de"], 20);
        // full-width selection across both rows: padding to col 20 is trimmed
        expect(selectedText(g, lin(0, 0, 19, 1))).toBe("abc\nde");
    });

    it("joins multiple rows with newlines", () => {
        const g = gridOf(["one", "two", "three"], 20);
        expect(selectedText(g, lin(0, 0, 4, 2))).toBe("one\ntwo\nthree");
    });

    it("keeps a wide glyph once, dropping its trailing half", () => {
        const g = gridOf(["a世b"], 20);
        // columns: a=0, 世=1(width2, trailing at 2), b=3
        expect(selectedText(g, lin(0, 0, 3, 0))).toBe("a世b");
    });

    it("returns empty for a selection over blank cells", () => {
        const g = gridOf(["   "], 20);
        expect(selectedText(g, lin(0, 0, 19, 0))).toBe("");
    });
});
