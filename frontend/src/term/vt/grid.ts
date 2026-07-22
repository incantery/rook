// The client grid: the state a renderer paints from. It applies decoded Frames
// (frame.ts) into a flat cell array, tracks which rows changed, and coalesces a
// row into style-runs — a line becomes ~10 spans, not one node per column, which
// is what keeps the DOM renderer fast.
//
// This holds no emulator: it never parses bytes, only applies structured diffs.

import {attrToken, colorToken, type Color, type Frame, type WCell} from "./frame";

const BLANK: WCell = {content: " ", fg: 0, bg: 0, attr: 0, width: 1};

/** A run of consecutive cells sharing one style — the unit a renderer emits as a
 *  single styled span. */
export interface Span {
    text: string;
    fg: Color;
    bg: Color;
    attr: number;
}

export class ClientGrid {
    readonly cols: number;
    readonly rows: number;
    private cells: WCell[];
    cursor = {x: 0, y: 0, visible: true};

    constructor(cols: number, rows: number) {
        this.cols = cols;
        this.rows = rows;
        this.cells = Array.from({length: cols * rows}, () => BLANK);
    }

    /** apply a Frame: first the scroll (shift up, blanking the exposed bottom),
     *  then the changed runs. Returns the indices of the rows that changed — all
     *  of them when the frame scrolled — so a renderer repaints only those. */
    apply(f: Frame): number[] {
        this.cursor = f.cursor;
        const scrolled = f.scroll > 0;
        if (scrolled) this.scrollUp(f.scroll);
        const dirty: number[] = [];
        for (const row of f.rows) {
            if (row.y < 0 || row.y >= this.rows) continue;
            const base = row.y * this.cols;
            for (const run of row.runs) {
                for (let k = 0; k < run.cells.length; k++) {
                    const x = run.x + k;
                    if (x >= 0 && x < this.cols) this.cells[base + x] = run.cells[k];
                }
            }
            if (!scrolled) dirty.push(row.y);
        }
        // A scroll moves every row's content, so all of them need repainting.
        if (scrolled) for (let y = 0; y < this.rows; y++) dirty.push(y);
        return dirty;
    }

    /** scrollUp shifts the visible grid up by n rows, blanking the exposed
     *  bottom — mirroring the emulator so a scroll frame reconstructs exactly. */
    private scrollUp(n: number): void {
        const blank: WCell = {content: " ", fg: 0, bg: 0, attr: 0, width: 1};
        if (n >= this.rows) {
            this.cells.fill(blank);
            return;
        }
        this.cells.copyWithin(0, n * this.cols);
        this.cells.fill(blank, (this.rows - n) * this.cols);
    }

    cellAt(x: number, y: number): WCell {
        return this.cells[y * this.cols + x];
    }

    /** the {c,w,fg,bg,a} token tuple for one cell — the fidelity oracle's schema,
     *  used to compare a reconstructed grid against the emulator. */
    token(x: number, y: number): {c: string; w: number; fg: string; bg: string; a: string} {
        const cell = this.cellAt(x, y);
        return {
            c: cell.content,
            w: cell.width,
            fg: colorToken(cell.fg),
            bg: colorToken(cell.bg),
            a: attrToken(cell.attr),
        };
    }

    /** coalesceRow merges a row's cells into style-runs. The trailing half of a
     *  wide glyph (width 0) is skipped: its pixels belong to the lead cell's
     *  double-width character. */
    coalesceRow(y: number): Span[] {
        const spans: Span[] = [];
        const base = y * this.cols;
        let cur: Span | null = null;
        for (let x = 0; x < this.cols; x++) {
            const cell = this.cells[base + x];
            if (cell.width === 0) continue;
            if (cur && cur.fg === cell.fg && cur.bg === cell.bg && cur.attr === cell.attr) {
                cur.text += cell.content;
            } else {
                cur = {text: cell.content, fg: cell.fg, bg: cell.bg, attr: cell.attr};
                spans.push(cur);
            }
        }
        return spans;
    }
}
