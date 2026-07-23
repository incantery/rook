// The WebGL renderer spike: beamterm (github.com/junkdog/beamterm) behind the
// TermRenderer seam. Beamterm is renderer-only — a Rust/WASM WebGL2 grid with
// a single instanced draw call and a dynamic glyph atlas — which is exactly
// the complement of rook's model: the host emulator owns terminal logic, the
// client renders frames.
//
// The boundary strategy: frames decode in TS (the existing frame.ts), the
// grid lives in TS (ClientGrid), and paint crosses into WASM as ONE
// batch.text() call per style-span, not per cell — spans are what the wire
// already coalesces, so a full 405x113 repaint is a few hundred boundary
// crossings, not 45k.
//
// SPIKE SCOPE — not yet wired: click/drag forwarding to mouse-tracking
// programs (the wheel IS forwarded), a11y (canvas has no readable text — the
// DOM renderer remains the accessible fallback). Selection is beamterm's
// built-in (drag + auto-copy). Scrollback is the shared SbStore (sbstore.ts):
// host-paged history, wheel + Shift+PageUp/Home to view it.

import type {TermRenderer} from "./api";
import init, {
    BeamtermRenderer as Beamterm,
    type Batch,
    type CellStyle,
    ModifierKeys,
    SelectionMode,
    style,
} from "@beamterm/renderer/web";
import {
    Attr,
    COLOR_RGB,
    COLOR_SET,
    type Color,
    decodeFrame,
    decodeSbChunk,
    type WCell,
} from "./frame";
import {ClientGrid} from "./grid";
import {keyToBytes} from "./keymap";
import {BTN_WHEEL_DOWN, BTN_WHEEL_UP, encodeMouse} from "./mouse";
import type {RendererOptions} from "./renderer";
import {SbStore} from "./sbstore";
import {WheelGauge} from "./wheel";

let ready = false;

/** initBeamterm loads and instantiates the WASM module. Call once, before any
 *  BeamtermGridRenderer is constructed; the app preloads it when the webgl
 *  renderer is configured. */
export async function initBeamterm(): Promise<void> {
    if (ready) return;
    await init();
    ready = true;
}

/** xterm256 computes the standard 256-color cube/grayscale for indices 16-255. */
function xterm256(n: number): number {
    if (n < 232) {
        const v = (i: number) => (i === 0 ? 0 : 55 + i * 40);
        const i = n - 16;
        return (v(Math.floor(i / 36)) << 16) | (v(Math.floor((i % 36) / 6)) << 8) | v(i % 6);
    }
    const g = 8 + (n - 232) * 10;
    return (g << 16) | (g << 8) | g;
}

/** mix blends a toward b per channel: t=1 is pure a, t=0 pure b. */
function mix(a: number, b: number, t: number): number {
    const ch = (sh: number) => Math.round(((a >> sh) & 0xff) * t + ((b >> sh) & 0xff) * (1 - t));
    return (ch(16) << 16) | (ch(8) << 8) | ch(0);
}

function cssHex(name: string, fallback: number): number {
    const raw = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
    const m = /^#?([0-9a-f]{6})/i.exec(raw);
    return m ? parseInt(m[1], 16) : fallback;
}

let nextCanvasId = 0;

const BLANK: WCell = {content: " ", fg: 0, bg: 0, attr: 0, width: 1};

export class BeamtermGridRenderer implements TermRenderer {
    private grid: ClientGrid;
    private wasm: Beamterm;
    private container: HTMLElement;
    private canvas: HTMLCanvasElement;
    private onInput?: (data: string) => void;
    private cellW: number; // CSS px
    private cellH: number;
    private dpr: number;
    private theme: number[] = [];
    private defFg = 0xd6deeb;
    private defBg = 0x0f111a;
    private lastCursor = {x: 0, y: 0};
    /** style cache: resolved (attr,fg,bg) -> wasm CellStyle, bounds churn */
    private styles = new Map<number, CellStyle>();
    /** host-paged scrollback viewport (shared state machine, sbstore.ts) */
    private sb: SbStore;
    // mouse tracking a program enabled (msgState): the wheel is forwarded to
    // it instead of scrolling history; Shift forces local scrollback.
    private mouseLevel = 0;
    private mouseSgr = false;

    constructor(container: HTMLElement, cols: number, rows: number, opts: RendererOptions = {}) {
        if (!ready) throw new Error("beamterm: initBeamterm() has not completed");
        this.container = container;
        this.onInput = opts.onInput;
        this.grid = new ClientGrid(cols, rows);
        this.sb = new SbStore(opts.scrollbackCap ?? 5000, opts.onSbFetch);

        container.classList.add("vt-screen", "vt-webgl");
        container.setAttribute("role", "log");
        container.setAttribute("aria-label", "terminal (webgl)");
        if (!container.hasAttribute("tabindex")) container.tabIndex = 0;

        this.canvas = document.createElement("canvas");
        this.canvas.id = `beamterm-${nextCanvasId++}`;
        this.canvas.style.display = "block";
        container.appendChild(this.canvas);

        const cs = getComputedStyle(container);
        const fonts = cs.fontFamily.split(",").map((f) => f.trim().replace(/^"|"$/g, ""));
        const fontSize = parseFloat(cs.fontSize) || 13;
        this.wasm = Beamterm.withDynamicAtlas(`#${this.canvas.id}`, fonts, fontSize, false);

        this.dpr = window.devicePixelRatio || 1;
        const cell = this.wasm.cellSize(); // device px (atlas raster scale)
        this.cellW = cell.width / this.dpr;
        this.cellH = cell.height / this.dpr;
        this.readTheme();
        this.sizeCanvas(cols, rows);

        // built-in linear selection with auto-copy; plain drag (no forwarding yet)
        this.wasm.enableSelectionWithOptions(SelectionMode.Linear, true, ModifierKeys.NONE);

        container.addEventListener("keydown", this.onKeyDown);
        container.addEventListener("paste", this.onPaste);
        container.addEventListener("wheel", this.onWheel, {passive: false});

        // spike probe: expose readable text for e2e (canvas has no innerText)
        (container as HTMLElement & {__screenText?: () => string}).__screenText = () =>
            this.screenText();
    }

    private readTheme(): void {
        this.defFg = cssHex("--term-fg", this.defFg);
        this.defBg = cssHex("--term-bg", this.defBg);
        this.theme = [];
        for (let i = 0; i < 16; i++) this.theme.push(cssHex(`--term-ansi-${i}`, 0x808080));
    }

    private sizeCanvas(cols: number, rows: number): void {
        // resize() takes CSS pixels and owns the backing store, scaling by dpr
        // itself — hand it device pixels and it doubles them again, leaving
        // the grid at 2x the cols/rows we feed (content in the top-left
        // quadrant on retina; invisible at dpr 1, where the units coincide).
        const w = Math.round(cols * this.cellW);
        const h = Math.round(rows * this.cellH);
        this.canvas.style.width = `${w}px`;
        this.canvas.style.height = `${h}px`;
        this.wasm.resize(w, h);
    }

    private resolve(c: Color, def: number): number {
        if (!(c & COLOR_SET)) return def;
        if (c & COLOR_RGB) return c & 0xffffff;
        const n = c & 0xff;
        return n < 16 ? this.theme[n] : xterm256(n);
    }

    private styleFor(attr: number, fg: number, bg: number): CellStyle {
        // pack a cache key from resolved colors + attr bits
        const key = attr * 0x1000000000000 + fg * 0x1000000 + bg;
        let s = this.styles.get(key);
        if (s) return s;
        if (this.styles.size > 512) this.styles.clear(); // bound wasm object churn
        // beamterm has no faint/hidden styles, so fold them into the fg color:
        // dim blends toward bg (the DOM renderer's opacity:.6 over bg), hidden
        // becomes bg. Cache-miss only — the hot path never pays for the mix.
        if (attr & Attr.Hidden) fg = bg;
        else if (attr & Attr.Dim) fg = mix(fg, bg, 0.6);
        s = style().fg(fg).bg(bg);
        if (attr & Attr.Bold) s = s.bold();
        if (attr & Attr.Italic) s = s.italic();
        if (attr & Attr.Underline) s = s.underline();
        if (attr & Attr.Strike) s = s.strikethrough();
        this.styles.set(key, s);
        return s;
    }

    /** paintRow writes one live grid row into the batch as style-spans — the
     *  unit of boundary crossing. */
    private paintRow(batch: Batch, y: number): void {
        this.paintCells(batch, y, (x) => this.grid.cellAt(x, y));
    }

    /** paintCells writes one display row from an arbitrary cell source
     *  (live grid or a scrollback line), covering every column — short
     *  history rows pad with blanks so stale canvas cells can't linger. Wide
     *  glyphs advance two columns (beamterm places the trailing half itself). */
    private paintCells(batch: Batch, y: number, at: (x: number) => WCell): void {
        let x = 0;
        let spanX = 0;
        let text = "";
        let attr = -1;
        let fg = 0;
        let bg = 0;
        const flush = () => {
            if (text.length > 0) batch.text(spanX, y, text, this.styleFor(attr, fg, bg));
        };
        for (let cx = 0; cx < this.grid.cols; cx++) {
            const cell = at(cx);
            if (cell.width === 0) continue; // trailer of a wide glyph
            const rf = this.resolve(cell.attr & Attr.Reverse ? cell.bg : cell.fg, this.defFg);
            const rb = this.resolve(cell.attr & Attr.Reverse ? cell.fg : cell.bg, this.defBg);
            const a = cell.attr & ~Attr.Reverse;
            if (a !== attr || rf !== fg || rb !== bg) {
                flush();
                spanX = x;
                text = "";
                attr = a;
                fg = rf;
                bg = rb;
            }
            text += cell.content;
            x += cell.width;
        }
        flush();
    }

    private paintCursor(batch: Batch): void {
        const {x, y, visible} = this.grid.cursor;
        const prev = this.lastCursor;
        if (prev.y < this.grid.rows && (prev.x !== x || prev.y !== y)) {
            this.paintRow(batch, prev.y); // un-invert the old cursor cell
        }
        this.lastCursor = {x, y};
        if (!visible) return;
        const cell = this.grid.cellAt(x, y);
        const rf = this.resolve(cell.fg, this.defFg);
        const rb = this.resolve(cell.bg, this.defBg);
        // the cursor is the cell, inverted
        batch.text(x, y, cell.content || " ", this.styleFor(cell.attr & ~Attr.Reverse, rb, rf));
    }

    applyBytes(bytes: Uint8Array): void {
        const frame = decodeFrame(bytes);
        this.sb.noteFrame(frame, this.grid.rows, (y) => this.grid.rowCells(y));
        const dirty = this.grid.apply(frame);
        // while scrolled up the live grid changes below the viewport; nothing
        // to repaint until the user returns to the bottom.
        if (this.sb.offset > 0) return;
        const batch = this.wasm.batch();
        for (const y of dirty) this.paintRow(batch, y);
        this.paintCursor(batch);
        this.wasm.render();
        batch.free();
        // the latency harness's t1 for canvas renderers (no DOM mutations)
        this.container.dispatchEvent(new CustomEvent("rook:frame"));
    }

    applySbChunk(bytes: Uint8Array): void {
        if (!this.sb.applyChunk(decodeSbChunk(bytes))) return;
        if (this.sb.offset > 0) this.repaintViewport();
    }

    /** repaintViewport redraws the whole canvas from the virtual buffer
     *  (history above, live screen below). One batch, one draw call — the
     *  full repaint per scroll step is what the renderer is built for. */
    private repaintViewport(): void {
        const rows = this.sb.viewport(this.grid.rows, (y) => this.grid.rowCells(y));
        const batch = this.wasm.batch();
        for (let y = 0; y < this.grid.rows; y++) {
            const cells = rows[y];
            this.paintCells(batch, y, cells ? (x) => cells[x] ?? BLANK : () => BLANK);
        }
        // the cursor lives on the live screen; it returns with the bottom
        if (this.sb.offset === 0) this.paintCursor(batch);
        this.wasm.render();
        batch.free();
        this.container.dispatchEvent(new CustomEvent("rook:frame"));
    }

    private scrollLines(delta: number): void {
        if (this.sb.scroll(delta)) this.repaintViewport();
    }

    private scrollToBottom(): void {
        if (this.sb.toBottom()) this.repaintViewport();
    }

    setMouseMode(level: number, sgr: boolean): void {
        this.mouseLevel = level;
        this.mouseSgr = sgr;
    }

    reset(): void {
        this.grid = new ClientGrid(this.grid.cols, this.grid.rows);
        this.sb.toBottom();
        const batch = this.wasm.batch();
        batch.clear(this.defBg);
        this.wasm.render();
        batch.free();
    }

    resize(cols: number, rows: number): void {
        if (cols === this.grid.cols && rows === this.grid.rows) return;
        this.grid = new ClientGrid(cols, rows);
        this.sb.toBottom();
        this.sizeCanvas(cols, rows);
        // beamterm preserves cell content across resize, but our grid is
        // fresh — clear, or pre-resize cells (a stale cursor block) survive
        const batch = this.wasm.batch();
        batch.clear(this.defBg);
        this.wasm.render();
        batch.free();
        this.lastCursor = {x: 0, y: 0};
    }

    focus(): void {
        this.container.focus();
    }

    cellSize(): {w: number; h: number} {
        return {w: this.cellW, h: this.cellH};
    }

    private screenText(): string {
        // viewport-aware: while scrolled, report what the canvas shows
        const rows =
            this.sb.offset > 0
                ? this.sb.viewport(this.grid.rows, (y) => this.grid.rowCells(y))
                : null;
        const lines: string[] = [];
        for (let y = 0; y < this.grid.rows; y++) {
            let line = "";
            for (let x = 0; x < this.grid.cols; x++) {
                const c = rows ? (rows[y]?.[x] ?? BLANK) : this.grid.cellAt(x, y);
                if (c.width !== 0) line += c.content;
            }
            lines.push(line.trimEnd());
        }
        return lines.join("\n");
    }

    private onKeyDown = (e: KeyboardEvent): void => {
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
        const bytes = keyToBytes(e);
        if (bytes !== null && this.onInput) {
            this.scrollToBottom(); // typing returns to live
            this.onInput(bytes);
            e.preventDefault();
        }
    };

    private onPaste = (e: ClipboardEvent): void => {
        const text = e.clipboardData?.getData("text");
        if (text && this.onInput) {
            this.scrollToBottom();
            this.onInput(text);
            e.preventDefault();
        }
    };

    private wheel = new WheelGauge();

    private onWheel = (e: WheelEvent): void => {
        const lines = this.wheel.lines(e.deltaY, e.deltaMode, this.cellH);
        // A program tracking the mouse owns the wheel — it scrolls its own view
        // (Claude Code's conversation, a pager). Shift forces local scrollback.
        if (this.mouseLevel >= 2 && !e.shiftKey) {
            if (this.onInput && lines !== 0) {
                const rect = this.canvas.getBoundingClientRect();
                const col = Math.max(
                    1,
                    Math.min(this.grid.cols, Math.floor((e.clientX - rect.left) / this.cellW) + 1),
                );
                const row = Math.max(
                    1,
                    Math.min(this.grid.rows, Math.floor((e.clientY - rect.top) / this.cellH) + 1),
                );
                const button = lines < 0 ? BTN_WHEEL_UP : BTN_WHEEL_DOWN;
                for (let i = 0; i < Math.abs(lines); i++) {
                    this.onInput(
                        encodeMouse({
                            button,
                            col,
                            row,
                            press: true,
                            motion: false,
                            sgr: this.mouseSgr,
                        }),
                    );
                }
            }
            e.preventDefault();
            return;
        }
        if (lines !== 0) this.scrollLines(-lines);
        if (this.sb.max > 0) e.preventDefault();
    };

    destroy(): void {
        this.container.removeEventListener("keydown", this.onKeyDown);
        this.container.removeEventListener("paste", this.onPaste);
        this.container.removeEventListener("wheel", this.onWheel);
        this.wasm.free();
        this.canvas.remove();
    }
}
