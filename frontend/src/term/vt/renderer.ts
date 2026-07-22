// The DOM renderer (D4). It owns a container, one <div> per row, and repaints a
// row only when a Frame changed it — the diff-driven, run-coalesced path that
// makes DOM viable: a firehose that rewrites one line touches one row's
// innerHTML, not the whole screen, and that row is ~10 styled spans, not 200
// nodes.
//
// It deliberately holds no emulator and no byte parsing. It consumes Frames
// (frame.ts) through a ClientGrid (grid.ts) and paints. Selection/copy and
// scrollback are a later slice; this is the glyph-and-cursor core the frame-time
// gate measures.
//
// Not a Svelte component: like Monaco and xterm before it, the hot path is
// imperative DOM. A thin Svelte wrapper mounts it (later); the raw CSS lives
// alongside, per rook's convention for imperative islands.

import {decodeFrame, type Frame} from "./frame";
import {ClientGrid} from "./grid";
import {rowHtml} from "./style";

export interface RendererOptions {
    /** class applied to the container; styling (font, --term-* vars) hangs off it. */
    className?: string;
}

export class GridRenderer {
    readonly grid: ClientGrid;
    private container: HTMLElement;
    private rowEls: HTMLElement[] = [];
    private cursorEl: HTMLElement;
    private raf = 0;
    private pending: Frame[] = [];

    constructor(container: HTMLElement, cols: number, rows: number, opts: RendererOptions = {}) {
        this.container = container;
        this.grid = new ClientGrid(cols, rows);

        container.classList.add("vt-screen");
        if (opts.className) container.classList.add(opts.className);
        container.style.setProperty("--vt-cols", String(cols));
        container.style.setProperty("--vt-rows", String(rows));

        const frag = document.createDocumentFragment();
        for (let y = 0; y < rows; y++) {
            const el = document.createElement("div");
            el.className = "vt-row";
            el.textContent = ""; // starts blank
            this.rowEls.push(el);
            frag.appendChild(el);
        }
        this.cursorEl = document.createElement("div");
        this.cursorEl.className = "vt-cursor";
        frag.appendChild(this.cursorEl);
        container.appendChild(frag);
        this.paintCursor();
    }

    /** applyFrame applies a decoded Frame immediately: repaint changed rows, move
     *  the cursor. Synchronous — the coalescing already happened server-side. */
    applyFrame(frame: Frame): void {
        const dirty = this.grid.apply(frame);
        for (const y of dirty) this.paintRow(y);
        this.paintCursor();
    }

    /** applyBytes decodes wire bytes and applies the frame. */
    applyBytes(bytes: Uint8Array): void {
        this.applyFrame(decodeFrame(bytes));
    }

    /** queue coalesces multiple frames that arrive within one animation frame,
     *  applying them on the next rAF — a second line of defense if the host ever
     *  sends faster than the display refreshes. */
    queue(frame: Frame): void {
        this.pending.push(frame);
        if (this.raf) return;
        this.raf = requestAnimationFrame(() => {
            this.raf = 0;
            const frames = this.pending;
            this.pending = [];
            for (const f of frames) this.applyFrame(f);
        });
    }

    private paintRow(y: number): void {
        this.rowEls[y].innerHTML = rowHtml(this.grid.coalesceRow(y));
    }

    private paintCursor(): void {
        const {x, y, visible} = this.grid.cursor;
        this.cursorEl.style.display = visible ? "block" : "none";
        this.cursorEl.style.setProperty("--vt-cx", String(x));
        this.cursorEl.style.setProperty("--vt-cy", String(y));
    }

    destroy(): void {
        if (this.raf) cancelAnimationFrame(this.raf);
        this.container.replaceChildren();
    }
}
