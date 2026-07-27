// The renderer seam (perf-strategy direction, 2026-07-22): everything the
// manager demands of a terminal renderer, and nothing more. It is cut AT THE
// BYTES — applyBytes/applySbChunk take wire payloads, not decoded cells — so a
// WASM renderer (beamterm, a TinyGo port sharing internal/vt's wire package)
// can own the whole decode→drawcall path with no per-cell JS↔WASM marshaling.
//
// BeamtermGridRenderer (beamterm.ts) is the sole implementation as of
// 2026-07-27 — the DOM renderer that shared this interface was deleted so
// there is exactly one path to optimize (see registry.ts for the trade). The
// interface stays: it is what keeps the renderer a FRAMEBUFFER rather than a
// text engine, which is the invariant the host's cell layout depends on.
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

export interface TermRenderer {
    /** apply one frame's wire bytes (msgFrame payload) — decode is the
     *  renderer's business. */
    applyBytes(bytes: Uint8Array): void;
    /** apply a fetched scrollback page (msgSbChunk payload). */
    applySbChunk(bytes: Uint8Array): void;
    /** mouse-tracking state from msgState — decides wheel/click routing. */
    setMouseMode(level: number, sgr: boolean): void;
    /** blank the live grid ahead of a (re)connect snapshot; history kept. */
    reset(): void;
    /** change grid geometry; the host resends the screen after. */
    resize(cols: number, rows: number): void;
    /** the theme changed: re-read the --term-* vars and repaint. A renderer
     *  that paints THROUGH the vars (the DOM one) has nothing to do; one that
     *  samples them into GPU state (beamterm) would otherwise keep painting
     *  the old palette until a reload. Called on every swap, so it must be
     *  cheap and safe when nothing changed. */
    retheme(): void;
    /** take keyboard focus, so key presses reach the input sink. */
    focus(): void;
    /** measured pixel size of one cell, for fit and hit-testing. */
    cellSize(): {w: number; h: number};
    /** tear down DOM/GPU resources; the renderer is dead after this. */
    destroy(): void;
}

/** One frame's cost through the client pipeline, in milliseconds. Emitted per
 *  applied frame when a harness installs `globalThis.__rookFrameProbe`; never
 *  in production, where the sink is undefined and the renderer pays one check.
 *
 *  It exists because the browser cannot see past its own frame clock: headed,
 *  keystroke latency is quantized by the display (docs/PERF.md), so the only
 *  falsifiable statement about client-side work is how long the work itself
 *  takes. decode/apply/paint are the three stages a Worker + OffscreenCanvas
 *  would move off the main thread, which is what makes this the instrument
 *  that judges that change. */
export interface FrameTiming {
    /** wire payload size */
    bytes: number;
    /** rows the frame dirtied */
    rows: number;
    /** varint wire -> Frame object graph */
    decode: number;
    /** Frame -> ClientGrid, plus scrollback bookkeeping */
    apply: number;
    /** dirty rows -> spans -> WASM batch -> draw call */
    paint: number;
    /** decode + apply + paint */
    total: number;
}

export type FrameProbe = (t: FrameTiming) => void;

export interface GlobalWithProbe {
    __rookFrameProbe?: FrameProbe;
}
