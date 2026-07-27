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

import type {TermRenderer} from "./api";
import {decodeFrame, decodeSbChunk, type Frame} from "./frame";
import {ClientGrid, coalesceCells} from "./grid";
import {keyToBytes} from "./keymap";
import {BTN_LEFT, BTN_MIDDLE, BTN_RIGHT, BTN_WHEEL_DOWN, BTN_WHEEL_UP, encodeMouse} from "./mouse";
import {SbStore} from "./sbstore";
import {rowExtent, type Selection, selectedText, wordAt} from "./selection";
import {rowHtml} from "./style";
import {WheelGauge} from "./wheel";

export interface RendererOptions {
    /** class applied to the container; styling (font, --term-* vars) hangs off it. */
    className?: string;
    /** how many history lines to cache client-side (default 5000). The host ring
     *  is the store; this only bounds the local page cache. */
    scrollbackCap?: number;
    /** sink for terminal input — key presses and pastes translated to pty bytes.
     *  Omit for a read-only renderer (e.g. a preview or a bench harness). */
    onInput?: (data: string) => void;
    /** sink for history page requests (encodeSbFetch on the wire). Omit and the
     *  renderer scrolls only what it captured itself. */
    onSbFetch?: (start: number, count: number) => void;
}

export class GridRenderer implements TermRenderer {
    grid: ClientGrid;
    private container: HTMLElement;
    private onInput?: (data: string) => void;
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

    // Mouse tracking a program has enabled (from the host's msgState): level
    // 0 off .. 4 any-event, and whether SGR encoding is on. When tracking, the
    // wheel and clicks are forwarded to the program instead of driving local
    // scrollback/selection — Shift always forces the local behavior.
    private mouseLevel = 0;
    private mouseSgr = false;
    private mouseReporting = false; // a press was forwarded; the gesture is the program's
    private mouseBtn = 0;

    // History is the host ring; the SbStore (sbstore.ts) is a viewport over it
    // — capture, paging, prefetch, eviction. This renderer only paints.
    private sb: SbStore;

    constructor(container: HTMLElement, cols: number, rows: number, opts: RendererOptions = {}) {
        this.container = container;
        this.grid = new ClientGrid(cols, rows);
        this.sb = new SbStore(opts.scrollbackCap ?? 5000, opts.onSbFetch);
        this.onInput = opts.onInput;

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

    /** applyFrame applies a decoded Frame immediately: capture any scrolled-off
     *  rows into the history cache at their absolute indices, apply the frame,
     *  and repaint. Synchronous — the coalescing already happened server-side.
     *
     *  A SCROLLED frame takes the recycling path. ClientGrid.apply reports every
     *  row dirty when the frame scrolled ("a scroll moves every row's content"),
     *  which is true of the CELLS and false of the DOM: the rows that merely
     *  moved are already painted, just parented at the wrong index. Rotating the
     *  row elements puts them back and leaves only the newly exposed band to
     *  paint — turning the common case (a shell printing a line, a TUI scrolling
     *  its view) from N innerHTML writes into scroll-many. Measured at 405x113:
     *  47ms -> ~1ms per frame. See bench/vt-wheel.ts. */
    applyFrame(frame: Frame): void {
        this.sb.noteFrame(frame, this.grid.rows, (y) => this.grid.rowCells(y));
        const dirty = this.grid.apply(frame);
        // while scrolled up the live grid changes below the viewport; nothing to
        // repaint until the user returns to the bottom.
        if (this.sb.offset !== 0) return;
        const n = frame.scroll;
        if (n > 0 && n < this.grid.rows) {
            this.shiftRows(n);
            // The frame's own runs, plus the band scrollUp just blanked — a
            // blanked row no run covered still has to lose its old glyphs.
            const repaint = new Set<number>();
            for (let y = this.grid.rows - n; y < this.grid.rows; y++) repaint.add(y);
            for (const r of frame.rows) {
                if (r.y >= 0 && r.y < this.grid.rows) repaint.add(r.y);
            }
            for (const y of repaint) this.paintRow(y);
        } else {
            for (const y of dirty) this.paintRow(y);
        }
        this.paintCursor();
    }

    /** shiftRows rotates the row elements by n so the DOM keeps the rows that
     *  only MOVED. Positive n = content travels up the screen (the terminal
     *  scrolled; the top n rows are recycled to the bottom); negative n = down
     *  (the viewport went back into history; the bottom |n| are recycled to the
     *  top). The recycled elements hold stale glyphs and are the caller's to
     *  repaint. rowEls is rotated in step so rowEls[y] is still display row y.
     *
     *  Cheap because .vt-row carries `contain: layout style` — moving a row
     *  cannot reflow its siblings. The elements land before selectionEl, which
     *  keeps the overlay and cursor last in the container. */
    private shiftRows(n: number): void {
        const rows = this.grid.rows;
        if (n === 0 || Math.abs(n) >= rows) return;
        const frag = document.createDocumentFragment();
        if (n > 0) {
            const moved = this.rowEls.splice(0, n);
            for (const el of moved) frag.appendChild(el);
            this.rowEls.push(...moved);
            this.container.insertBefore(frag, this.selectionEl);
        } else {
            const k = -n;
            const moved = this.rowEls.splice(rows - k, k);
            const first = this.rowEls[0];
            for (const el of moved) frag.appendChild(el);
            this.rowEls.unshift(...moved);
            this.container.insertBefore(frag, first);
        }
    }

    /** applySbChunk fills the cache from a fetched history page and repaints any
     *  viewport rows it satisfied. */
    applySbChunk(bytes: Uint8Array): void {
        if (!this.sb.applyChunk(decodeSbChunk(bytes))) return;
        if (this.sb.offset > 0) this.repaintViewport();
    }

    /** scrollLines moves the viewport by delta lines (positive = back into
     *  history), clamped to what the host holds, and repaints.
     *
     *  Recycles rows like a scrolled frame does: a wheel notch moves the
     *  viewport a line or two, so all but that band is already painted. The
     *  full repaint is kept for a jump bigger than the screen, where nothing
     *  is reusable. This is the hot path of a trackpad flick — ~120 events for
     *  one gesture, each of which used to rewrite every row. */
    scrollLines(delta: number): void {
        const before = this.sb.offset;
        if (!this.sb.scroll(delta)) return;
        // going further back in history moves content DOWN the screen
        this.repaintScrolled(before - this.sb.offset);
    }

    /** repaintScrolled shifts by n and paints only the band the shift exposed.
     *  viewport() is still called in full: it is a map lookup per row, and it
     *  carries the prefetch that keeps a smooth scroll ahead of the round trip
     *  — dropping it to save a few lookups would trade paint cost for network
     *  stalls. Only the innerHTML writes are narrowed. */
    private repaintScrolled(n: number): void {
        const rows = this.grid.rows;
        if (Math.abs(n) >= rows) {
            this.repaintViewport();
            return;
        }
        this.shiftRows(n);
        const view = this.sb.viewport(rows, (y) => this.grid.rowCells(y));
        const lo = n > 0 ? rows - n : 0;
        const hi = n > 0 ? rows : -n;
        for (let y = lo; y < hi; y++) {
            this.rowEls[y].innerHTML = rowHtml(coalesceCells(view[y] ?? []));
        }
        this.paintCursor();
    }

    /** focus gives the screen keyboard focus, so key presses reach onInput. */
    focus(): void {
        this.container.focus();
    }

    /** setMouseMode records the mouse tracking a program has enabled (msgState),
     *  which decides whether the wheel and clicks are forwarded to it. */
    setMouseMode(level: number, sgr: boolean): void {
        this.mouseLevel = level;
        this.mouseSgr = sgr;
        if (level === 0) this.mouseReporting = false;
    }

    private forwardMouse(
        button: number,
        clientX: number,
        clientY: number,
        press: boolean,
        motion: boolean,
    ): void {
        if (!this.onInput) return;
        const {x, y} = this.pointToCell(clientX, clientY);
        this.onInput(
            encodeMouse({button, col: x + 1, row: y + 1, press, motion, sgr: this.mouseSgr}),
        );
    }

    /** reset blanks the live grid and pins to the bottom — used on (re)connect,
     *  before the host's fresh snapshot arrives, so stale cells can't linger.
     *  Scrollback history is kept: it belongs to the same session. */
    reset(): void {
        this.grid = new ClientGrid(this.grid.cols, this.grid.rows);
        this.sb.toBottom();
        for (let y = 0; y < this.grid.rows; y++) this.paintRow(y);
        this.paintCursor();
    }

    /** scrollToBottom pins the viewport back to the live screen. */
    scrollToBottom(): void {
        if (this.sb.toBottom()) this.repaintViewport();
    }

    /** how many lines the viewport is scrolled back (0 = live). */
    get scrollOffset(): number {
        return this.sb.offset;
    }

    /** resize changes the grid geometry (a window resize / SIGWINCH). It rebuilds
     *  the client grid and row elements at the new size and pins the viewport to
     *  the live screen; the next Frame — the host resends the whole screen after a
     *  resize — repaints them. Scrollback history is kept (its rows keep their own
     *  width and render fine); the selection is dropped, since its coordinates no
     *  longer map. The caller is responsible for telling the host the new size. */
    resize(cols: number, rows: number): void {
        if (cols === this.grid.cols && rows === this.grid.rows) return;
        this.grid = new ClientGrid(cols, rows);
        this.selection = null;
        this.sb.toBottom();
        this.cellW = 0; // geometry changed — re-measure lazily
        this.cellH = 0;
        this.container.style.setProperty("--vt-cols", String(cols));
        this.container.style.setProperty("--vt-rows", String(rows));

        const frag = document.createDocumentFragment();
        this.rowEls = [];
        for (let y = 0; y < rows; y++) {
            const el = document.createElement("div");
            el.className = "vt-row";
            this.rowEls.push(el);
            frag.appendChild(el);
        }
        this.selectionEl.replaceChildren(); // drop stale selection rects
        frag.appendChild(this.selectionEl);
        frag.appendChild(this.cursorEl);
        this.container.replaceChildren(frag);
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

    /** Nothing to do: every color this renderer emits is a `var(--term-*)`
     *  reference (style.ts), so the swap has already happened by the time
     *  anyone could call this — the vars are on documentElement and CSS
     *  recomputes. The seam has the method because the GPU renderer samples
     *  those vars into buffers instead, and only it can know that. */
    retheme(): void {}

    /** cellSize returns the measured pixel size of one cell (for hit-testing and
     *  tests). Triggers a measurement against the laid-out DOM if needed. */
    cellSize(): {w: number; h: number} {
        if (!this.cellW) this.measureCell();
        return {w: this.cellW, h: this.cellH};
    }

    private paintRow(y: number): void {
        this.rowEls[y].innerHTML = rowHtml(this.grid.coalesceRow(y));
    }

    // repaintViewport redraws every display row from the virtual buffer
    // (history above, live screen below) at the current offset. A history row
    // missing from the cache paints blank and is fetched; the chunk repaints it.
    // Used whenever the offset changes; the live path (offset 0) uses the faster
    // paintRow.
    private repaintViewport(): void {
        const rows = this.sb.viewport(this.grid.rows, (y) => this.grid.rowCells(y));
        for (let y = 0; y < this.grid.rows; y++) {
            this.rowEls[y].innerHTML = rowHtml(coalesceCells(rows[y] ?? []));
        }
        this.paintCursor();
    }

    private paintCursor(): void {
        const {x, y, visible} = this.grid.cursor;
        // the cursor lives on the live screen; hide it while viewing history
        this.cursorEl.style.display = visible && this.sb.offset === 0 ? "block" : "none";
        this.cursorEl.style.setProperty("--vt-cx", String(x));
        this.cursorEl.style.setProperty("--vt-cy", String(y));
    }

    // --- interaction ---

    private installInput(): void {
        this.container.addEventListener("mousedown", this.onMouseDown);
        this.container.addEventListener("keydown", this.onKeyDown);
        this.container.addEventListener("paste", this.onPaste);
        this.container.addEventListener("wheel", this.onWheel, {passive: false});
        this.container.addEventListener("contextmenu", this.onContextMenu);
        window.addEventListener("mousemove", this.onMouseMove);
        window.addEventListener("mouseup", this.onMouseUp);
    }

    private onContextMenu = (e: MouseEvent): void => {
        // a right-click belongs to a mouse-tracking program, not the browser menu
        if (this.mouseLevel >= 1) e.preventDefault();
    };

    private onPaste = (e: ClipboardEvent): void => {
        if (!this.onInput) return;
        const text = e.clipboardData?.getData("text");
        if (!text) return;
        this.scrollToBottom();
        // Raw text for now; bracketed-paste wrapping (?2004) arrives with the
        // host session-state signal in a later slice.
        this.onInput(text);
        e.preventDefault();
    };

    private wheel = new WheelGauge();

    private onWheel = (e: WheelEvent): void => {
        if (!this.cellH) this.measureCell();
        const lines = this.wheel.lines(e.deltaY, e.deltaMode, this.cellH);
        // A program tracking the mouse owns the wheel — it scrolls its own view
        // (Claude Code's conversation, a pager). Shift forces local scrollback.
        //
        // The N presses go out as ONE write. Identical bytes, but one ws.send,
        // one pty.Write, and one stdin read for the program to service instead
        // of N — a TUI that redraws per read redraws once. The cell is resolved
        // once too: pointToCell reads getBoundingClientRect, and doing that per
        // LINE put a forced layout inside the loop (beamterm.ts already hoists
        // it; this is the DOM renderer catching up).
        if (this.mouseLevel >= 2 && !e.shiftKey) {
            if (this.onInput && lines !== 0) {
                const button = lines < 0 ? BTN_WHEEL_UP : BTN_WHEEL_DOWN;
                const {x, y} = this.pointToCell(e.clientX, e.clientY);
                const press = encodeMouse({
                    button,
                    col: x + 1,
                    row: y + 1,
                    press: true,
                    motion: false,
                    sgr: this.mouseSgr,
                });
                this.onInput(press.repeat(Math.abs(lines)));
            }
            e.preventDefault();
            return;
        }
        if (lines !== 0) this.scrollLines(-lines);
        if (this.sb.max > 0) e.preventDefault();
    };

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
        // A program tracking the mouse owns clicks too. Shift forces local
        // selection so text is still selectable over a mouse-driven TUI.
        if (this.mouseLevel >= 1 && !e.shiftKey) {
            this.mouseBtn = e.button === 1 ? BTN_MIDDLE : e.button === 2 ? BTN_RIGHT : BTN_LEFT;
            this.forwardMouse(this.mouseBtn, e.clientX, e.clientY, true, false);
            this.mouseReporting = true;
            // preventDefault blocks the native focus, so take it explicitly — the
            // click must still put the keyboard on this pane.
            this.container.focus();
            e.preventDefault();
            return;
        }
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
        if (this.mouseReporting) {
            // report drags only when the program asked for motion (level >= 3)
            if (this.mouseLevel >= 3) {
                this.forwardMouse(this.mouseBtn, e.clientX, e.clientY, true, true);
            }
            return;
        }
        if (!this.dragging || !this.selection) return;
        this.moved = true;
        this.selection.focus = this.pointToCell(e.clientX, e.clientY);
        this.paintSelection();
    };

    private onMouseUp = (e: MouseEvent): void => {
        if (this.mouseReporting) {
            this.mouseReporting = false;
            // X10 (level 1) has no release event; normal+ (>=2) does
            if (this.mouseLevel >= 2) {
                this.forwardMouse(this.mouseBtn, e.clientX, e.clientY, false, false);
            }
            return;
        }
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
            return;
        }
        // Shift+PageUp/PageDown/Home/End scroll history without disturbing the pty
        if (e.shiftKey) {
            const page = this.grid.rows - 1;
            switch (e.key) {
                case "PageUp":
                    this.scrollLines(page);
                    e.preventDefault();
                    return;
                case "PageDown":
                    this.scrollLines(-page);
                    e.preventDefault();
                    return;
                case "Home":
                    this.scrollLines(this.sb.max);
                    e.preventDefault();
                    return;
                case "End":
                    this.scrollToBottom();
                    e.preventDefault();
                    return;
            }
        }

        // Everything else is terminal input: translate and forward to the pty.
        const bytes = keyToBytes(e);
        if (bytes !== null && this.onInput) {
            this.scrollToBottom(); // typing returns to live
            this.onInput(bytes);
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
        this.container.removeEventListener("paste", this.onPaste);
        this.container.removeEventListener("wheel", this.onWheel);
        this.container.removeEventListener("contextmenu", this.onContextMenu);
        window.removeEventListener("mousemove", this.onMouseMove);
        window.removeEventListener("mouseup", this.onMouseUp);
        this.container.replaceChildren();
    }
}
