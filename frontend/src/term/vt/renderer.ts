// The DOM renderer (D4). It owns a container, one <div> per row, and repaints a
// row only when a Frame changed it — the diff-driven, run-coalesced path that
// makes DOM viable: a firehose that rewrites one line touches one row's
// innerHTML, not the whole screen, and that row is ~10 styled spans, not 200
// nodes.
//
// It deliberately holds no emulator and no byte parsing. It consumes Frames
// (frame.ts) through a ClientGrid (grid.ts) and paints. On top of the glyph core
// it owns the interaction xterm gave for free (D4): mouse selection (linear,
// block, word, line), copy, and the a11y roles that make the screen readable.
// Scrollback needs server-side history (a later slice) and is not here.
//
// Not a Svelte component: like Monaco and xterm before it, the hot path is
// imperative DOM. A thin Svelte wrapper mounts it (later); the raw CSS lives
// alongside, per rook's convention for imperative islands.

import {decodeFrame, type Frame} from "./frame";
import {ClientGrid} from "./grid";
import {rowExtent, type Selection, selectedText, wordAt} from "./selection";
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
    private selectionEl: HTMLElement;
    private raf = 0;
    private pending: Frame[] = [];

    private selection: Selection | null = null;
    private dragging = false;
    private moved = false;
    private cellW = 0;
    private cellH = 0;

    constructor(container: HTMLElement, cols: number, rows: number, opts: RendererOptions = {}) {
        this.container = container;
        this.grid = new ClientGrid(cols, rows);

        container.classList.add("vt-screen");
        if (opts.className) container.classList.add(opts.className);
        container.style.setProperty("--vt-cols", String(cols));
        container.style.setProperty("--vt-rows", String(rows));

        // a11y: a readable text region. Rows carry real text, so a screen reader
        // and the accessibility tree can read the screen; focusable so copy works.
        container.setAttribute("role", "log");
        container.setAttribute("aria-label", "terminal");
        container.setAttribute("aria-roledescription", "terminal");
        if (!container.hasAttribute("tabindex")) container.tabIndex = 0;

        const frag = document.createDocumentFragment();
        for (let y = 0; y < rows; y++) {
            const el = document.createElement("div");
            el.className = "vt-row";
            el.textContent = ""; // starts blank
            this.rowEls.push(el);
            frag.appendChild(el);
        }
        this.selectionEl = document.createElement("div");
        this.selectionEl.className = "vt-selection";
        this.selectionEl.setAttribute("aria-hidden", "true");
        frag.appendChild(this.selectionEl);
        this.cursorEl = document.createElement("div");
        this.cursorEl.className = "vt-cursor";
        this.cursorEl.setAttribute("aria-hidden", "true");
        frag.appendChild(this.cursorEl);
        container.appendChild(frag);
        this.paintCursor();
        this.installInput();
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

    /** getSelectedText returns the current selection as copy-ready text, or "". */
    getSelectedText(): string {
        return this.selection ? selectedText(this.grid, this.selection) : "";
    }

    /** copySelection writes the selection to the clipboard; resolves false if
     *  there is nothing selected or no clipboard. */
    async copySelection(): Promise<boolean> {
        const text = this.getSelectedText();
        if (!text || !navigator.clipboard) return false;
        await navigator.clipboard.writeText(text);
        return true;
    }

    /** clearSelection removes any highlight. */
    clearSelection(): void {
        this.selection = null;
        this.paintSelection();
    }

    /** cellSize returns the measured pixel size of one cell (for hit-testing and
     *  tests). Triggers a measurement against the laid-out DOM if needed. */
    cellSize(): {w: number; h: number} {
        if (!this.cellW) this.measureCell();
        return {w: this.cellW, h: this.cellH};
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

    // --- interaction ---

    private installInput(): void {
        this.container.addEventListener("mousedown", this.onMouseDown);
        this.container.addEventListener("keydown", this.onKeyDown);
        window.addEventListener("mousemove", this.onMouseMove);
        window.addEventListener("mouseup", this.onMouseUp);
    }

    /** measureCell reads the pixel size of one cell from the laid-out DOM, so
     *  pixel<->cell mapping and the selection overlay line up with the glyphs. */
    private measureCell(): void {
        const probe = document.createElement("span");
        probe.style.cssText = "visibility:hidden;position:absolute;white-space:pre";
        probe.textContent = "0".repeat(10);
        this.container.appendChild(probe);
        this.cellW = probe.getBoundingClientRect().width / 10 || 8;
        probe.remove();
        this.cellH = this.rowEls[0]?.getBoundingClientRect().height || 16;
    }

    private pointToCell(clientX: number, clientY: number): {x: number; y: number} {
        if (!this.cellW) this.measureCell();
        const rect = this.container.getBoundingClientRect();
        const x = Math.max(
            0,
            Math.min(this.grid.cols - 1, Math.floor((clientX - rect.left) / this.cellW)),
        );
        const y = Math.max(
            0,
            Math.min(this.grid.rows - 1, Math.floor((clientY - rect.top) / this.cellH)),
        );
        return {x, y};
    }

    private onMouseDown = (e: MouseEvent): void => {
        if (e.button !== 0) return; // left button only
        const cell = this.pointToCell(e.clientX, e.clientY);

        if (e.detail === 2) {
            // double-click: select the word under the cursor
            const [s, end] = wordAt(this.grid, cell.x, cell.y);
            this.setSelection({
                anchor: {x: s, y: cell.y},
                focus: {x: end, y: cell.y},
                mode: "linear",
            });
            return;
        }
        if (e.detail >= 3) {
            // triple-click: select the whole line
            this.setSelection({
                anchor: {x: 0, y: cell.y},
                focus: {x: this.grid.cols - 1, y: cell.y},
                mode: "linear",
            });
            return;
        }
        this.dragging = true;
        this.moved = false;
        this.selection = {anchor: cell, focus: cell, mode: e.altKey ? "block" : "linear"};
        e.preventDefault();
    };

    private onMouseMove = (e: MouseEvent): void => {
        if (!this.dragging || !this.selection) return;
        this.moved = true;
        this.selection.focus = this.pointToCell(e.clientX, e.clientY);
        this.paintSelection();
    };

    private onMouseUp = (): void => {
        if (!this.dragging) return;
        this.dragging = false;
        if (!this.moved) this.clearSelection(); // a plain click clears the selection
    };

    private onKeyDown = (e: KeyboardEvent): void => {
        if (
            (e.metaKey || e.ctrlKey) &&
            (e.key === "c" || e.key === "C") &&
            this.getSelectedText()
        ) {
            void this.copySelection();
            e.preventDefault();
        }
    };

    private setSelection(sel: Selection): void {
        this.selection = sel;
        this.paintSelection();
    }

    private paintSelection(): void {
        if (!this.selection) {
            this.selectionEl.replaceChildren();
            return;
        }
        if (!this.cellW) this.measureCell();
        const rects: HTMLElement[] = [];
        for (let y = 0; y < this.grid.rows; y++) {
            const ext = rowExtent(this.selection, y, this.grid.cols);
            if (!ext) continue;
            const r = document.createElement("div");
            r.className = "vt-sel-rect";
            r.style.left = ext[0] * this.cellW + "px";
            r.style.top = y * this.cellH + "px";
            r.style.width = (ext[1] - ext[0] + 1) * this.cellW + "px";
            r.style.height = this.cellH + "px";
            rects.push(r);
        }
        this.selectionEl.replaceChildren(...rects);
    }

    destroy(): void {
        if (this.raf) cancelAnimationFrame(this.raf);
        this.container.removeEventListener("mousedown", this.onMouseDown);
        this.container.removeEventListener("keydown", this.onKeyDown);
        window.removeEventListener("mousemove", this.onMouseMove);
        window.removeEventListener("mouseup", this.onMouseUp);
        this.container.replaceChildren();
    }
}
