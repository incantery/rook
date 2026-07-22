// Selection geometry and text extraction — pure, so the fiddly parts (reading
// order, wide-char trailing cells, trailing-whitespace trim) are unit-tested
// without a browser. The renderer (renderer.ts) drives this from mouse events
// and paints the result; nothing here touches the DOM.

import type {ClientGrid} from "./grid";

export interface Point {
    x: number;
    y: number;
}

/** linear selection flows like text (to end of line, wrap, to the focus);
 *  block selects the rectangle between the two corners (column select). */
export type SelectMode = "linear" | "block";

export interface Selection {
    anchor: Point;
    focus: Point;
    mode: SelectMode;
}

/** rowExtent returns the inclusive [startX, endX] columns selected on row y, or
 *  null if the row is outside the selection. */
export function rowExtent(sel: Selection, y: number, cols: number): [number, number] | null {
    if (sel.mode === "block") {
        const y0 = Math.min(sel.anchor.y, sel.focus.y);
        const y1 = Math.max(sel.anchor.y, sel.focus.y);
        if (y < y0 || y > y1) return null;
        return [Math.min(sel.anchor.x, sel.focus.x), Math.max(sel.anchor.x, sel.focus.x)];
    }

    // linear: order the two endpoints in reading order (top-to-bottom, then left)
    let a = sel.anchor;
    let b = sel.focus;
    if (b.y < a.y || (b.y === a.y && b.x < a.x)) [a, b] = [b, a];

    if (y < a.y || y > b.y) return null;
    if (a.y === b.y) return [Math.min(a.x, b.x), Math.max(a.x, b.x)];
    if (y === a.y) return [a.x, cols - 1];
    if (y === b.y) return [0, b.x];
    return [0, cols - 1];
}

/** isSelected reports whether cell (x,y) is inside the selection. */
export function isSelected(sel: Selection, x: number, y: number, cols: number): boolean {
    const ext = rowExtent(sel, y, cols);
    return ext !== null && x >= ext[0] && x <= ext[1];
}

/** selectedText extracts the selection as text the way a terminal copies it:
 *  the trailing half of a wide glyph (width 0) contributes nothing, and each
 *  line's trailing whitespace is trimmed. Rows join with newlines. */
export function selectedText(grid: ClientGrid, sel: Selection): string {
    const lines: string[] = [];
    for (let y = 0; y < grid.rows; y++) {
        const ext = rowExtent(sel, y, grid.cols);
        if (!ext) continue;
        let line = "";
        for (let x = ext[0]; x <= ext[1]; x++) {
            const cell = grid.cellAt(x, y);
            if (cell.width === 0) continue; // trailing half of a wide glyph
            line += cell.content;
        }
        lines.push(trimEnd(line));
    }
    return lines.join("\n");
}

/** trimEnd removes trailing spaces (but not other content) from a copied line. */
function trimEnd(s: string): string {
    let i = s.length;
    while (i > 0 && s[i - 1] === " ") i--;
    return s.slice(0, i);
}

// Characters that break a word for double-click selection — whitespace and the
// common brackets/quotes, matching what a terminal user expects "select word"
// to stop at.
const WORD_SEP = new Set([" ", "\t", "(", ")", "[", "]", "{", "}", "<", ">", "'", '"', "`", "|"]);

/** wordAt returns the [startX, endX] of the word under (x,y): the run of
 *  non-separator cells around it. The trailing half of a wide glyph (width 0) is
 *  part of its word. A click on a separator selects just that cell. */
export function wordAt(grid: ClientGrid, x: number, y: number): [number, number] {
    const isWord = (cx: number): boolean => {
        const c = grid.cellAt(cx, y);
        return c.width === 0 || !WORD_SEP.has(c.content);
    };
    if (!isWord(x)) return [x, x];
    let start = x;
    let end = x;
    while (start > 0 && isWord(start - 1)) start--;
    while (end < grid.cols - 1 && isWord(end + 1)) end++;
    return [start, end];
}
