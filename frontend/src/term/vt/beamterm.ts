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
// SPIKE SCOPE — not yet wired: local scrollback view (shift+wheel),
// scrollback paging (applySbChunk is a no-op), mouse forwarding to tracking
// programs, a11y (canvas has no readable text — the DOM renderer remains the
// accessible fallback). Selection is beamterm's built-in (drag + auto-copy).

import type {TermRenderer} from "./api";
import init, {
    BeamtermRenderer as Beamterm,
    type Batch,
    type CellStyle,
    ModifierKeys,
    SelectionMode,
    style,
} from "@beamterm/renderer/web";
import {Attr, COLOR_RGB, COLOR_SET, type Color, decodeFrame} from "./frame";
import {ClientGrid} from "./grid";
import {keyToBytes} from "./keymap";
import type {RendererOptions} from "./renderer";

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

function cssHex(name: string, fallback: number): number {
    const raw = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
    const m = /^#?([0-9a-f]{6})/i.exec(raw);
    return m ? parseInt(m[1], 16) : fallback;
}

let nextCanvasId = 0;

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

    constructor(container: HTMLElement, cols: number, rows: number, opts: RendererOptions = {}) {
        if (!ready) throw new Error("beamterm: initBeamterm() has not completed");
        this.container = container;
        this.onInput = opts.onInput;
        this.grid = new ClientGrid(cols, rows);

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
        const w = Math.round(cols * this.cellW * this.dpr);
        const h = Math.round(rows * this.cellH * this.dpr);
        this.canvas.width = w;
        this.canvas.height = h;
        this.canvas.style.width = `${w / this.dpr}px`;
        this.canvas.style.height = `${h / this.dpr}px`;
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
        s = style().fg(fg).bg(bg);
        if (attr & Attr.Bold) s = s.bold();
        if (attr & Attr.Italic) s = s.italic();
        if (attr & Attr.Underline) s = s.underline();
        if (attr & Attr.Strike) s = s.strikethrough();
        this.styles.set(key, s);
        return s;
    }

    /** paintRow writes one grid row into the batch as style-spans — the unit
     *  of boundary crossing. Wide glyphs advance two columns (beamterm places
     *  the trailing half itself). */
    private paintRow(batch: Batch, y: number): void {
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
            const cell = this.grid.cellAt(cx, y);
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
        const dirty = this.grid.apply(frame);
        const batch = this.wasm.batch();
        for (const y of dirty) this.paintRow(batch, y);
        this.paintCursor(batch);
        this.wasm.render();
        batch.free();
        // the latency harness's t1 for canvas renderers (no DOM mutations)
        this.container.dispatchEvent(new CustomEvent("rook:frame"));
    }

    applySbChunk(): void {
        // spike: host-paged scrollback view not yet wired for webgl
    }

    setMouseMode(): void {
        // accepted, not yet forwarded — mouse-tracking programs are post-spike
    }

    reset(): void {
        this.grid = new ClientGrid(this.grid.cols, this.grid.rows);
        const batch = this.wasm.batch();
        batch.clear(this.defBg);
        this.wasm.render();
        batch.free();
    }

    resize(cols: number, rows: number): void {
        if (cols === this.grid.cols && rows === this.grid.rows) return;
        this.grid = new ClientGrid(cols, rows);
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
        const lines: string[] = [];
        for (let y = 0; y < this.grid.rows; y++) {
            let line = "";
            for (let x = 0; x < this.grid.cols; x++) {
                const c = this.grid.cellAt(x, y);
                if (c.width !== 0) line += c.content;
            }
            lines.push(line.trimEnd());
        }
        return lines.join("\n");
    }

    private onKeyDown = (e: KeyboardEvent): void => {
        const bytes = keyToBytes(e);
        if (bytes !== null && this.onInput) {
            this.onInput(bytes);
            e.preventDefault();
        }
    };

    private onPaste = (e: ClipboardEvent): void => {
        const text = e.clipboardData?.getData("text");
        if (text && this.onInput) {
            this.onInput(text);
            e.preventDefault();
        }
    };

    destroy(): void {
        this.container.removeEventListener("keydown", this.onKeyDown);
        this.container.removeEventListener("paste", this.onPaste);
        this.wasm.free();
        this.canvas.remove();
    }
}
