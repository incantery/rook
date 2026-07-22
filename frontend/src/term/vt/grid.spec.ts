import {describe, expect, it} from "vitest";
import {Attr, type Frame, type WCell} from "./frame";
import {ClientGrid} from "./grid";

// Build a Frame that writes `cells` starting at (x,y) as one run — the shape the
// tests use to drive the grid without hand-encoding wire bytes.
function frame(y: number, x: number, cells: WCell[], cursor = {x: 0, y: 0, visible: true}): Frame {
    return {cursor, scroll: 0, rows: [{y, runs: [{x, cells}]}]};
}

function cell(content: string, over: Partial<WCell> = {}): WCell {
    return {content, fg: 0, bg: 0, attr: 0, width: 1, ...over};
}

describe("ClientGrid.apply", () => {
    it("starts blank", () => {
        const g = new ClientGrid(4, 2);
        expect(g.token(0, 0)).toEqual({c: " ", w: 1, fg: "d", bg: "d", a: ""});
    });

    it("returns only the rows a frame touched", () => {
        const g = new ClientGrid(10, 5);
        const dirty = g.apply({
            cursor: {x: 0, y: 0, visible: true},
            scroll: 0,
            rows: [
                {y: 1, runs: [{x: 0, cells: [cell("a")]}]},
                {y: 3, runs: [{x: 2, cells: [cell("b")]}]},
            ],
        });
        expect(dirty).toEqual([1, 3]);
        expect(g.cellAt(0, 1).content).toBe("a");
        expect(g.cellAt(2, 3).content).toBe("b");
        expect(g.cellAt(0, 0).content).toBe(" ");
    });

    it("carries the cursor", () => {
        const g = new ClientGrid(4, 2);
        g.apply(frame(0, 0, [cell("x")], {x: 3, y: 1, visible: false}));
        expect(g.cursor).toEqual({x: 3, y: 1, visible: false});
    });

    it("scroll shifts rows up, blanks the bottom, and applies new rows", () => {
        const g = new ClientGrid(2, 3);
        g.apply({
            cursor: {x: 0, y: 0, visible: true},
            scroll: 0,
            rows: [
                {y: 0, runs: [{x: 0, cells: [cell("A")]}]},
                {y: 1, runs: [{x: 0, cells: [cell("B")]}]},
                {y: 2, runs: [{x: 0, cells: [cell("C")]}]},
            ],
        });
        const dirty = g.apply({
            cursor: {x: 0, y: 2, visible: true},
            scroll: 1,
            rows: [{y: 2, runs: [{x: 0, cells: [cell("D")]}]}],
        });
        expect([g.cellAt(0, 0).content, g.cellAt(0, 1).content, g.cellAt(0, 2).content]).toEqual([
            "B",
            "C",
            "D",
        ]);
        expect(dirty).toEqual([0, 1, 2]); // a scroll repaints every row
    });
});

describe("ClientGrid.coalesceRow", () => {
    it("merges consecutive cells of the same style into one span", () => {
        const g = new ClientGrid(5, 1);
        g.apply(frame(0, 0, [cell("h"), cell("e"), cell("l"), cell("l"), cell("o")]));
        const spans = g.coalesceRow(0);
        // all default style, exact width -> a single span
        expect(spans.length).toBe(1);
        expect(spans[0].text).toBe("hello");
    });

    it("breaks a span when style changes", () => {
        const g = new ClientGrid(3, 1);
        g.apply(
            frame(0, 0, [
                cell("R", {fg: 0x80000001, attr: Attr.Bold}),
                cell("g"),
                cell("B", {attr: Attr.Underline}),
            ]),
        );
        const spans = g.coalesceRow(0);
        expect(spans.map((s) => s.text)).toEqual(["R", "g", "B"]);
        expect(spans[0].attr).toBe(Attr.Bold);
        expect(spans[2].attr).toBe(Attr.Underline);
    });

    it("skips the trailing half of a wide glyph", () => {
        const g = new ClientGrid(3, 1);
        g.apply(
            frame(0, 0, [cell("世", {width: 2}), cell(" ", {width: 0}), cell("!", {width: 1})]),
        );
        const spans = g.coalesceRow(0);
        // the width-0 trailing cell contributes no glyph: "世" then "!"
        expect(spans[0].text).toBe("世!");
    });
});
