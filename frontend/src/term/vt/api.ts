// The renderer seam (perf-strategy direction, 2026-07-22): everything the
// manager demands of a terminal renderer, and nothing more. It is cut AT THE
// BYTES — applyBytes/applySbChunk take wire payloads, not decoded cells — so a
// WASM renderer (beamterm, a TinyGo port sharing internal/vt's wire package)
// can own the whole decode→drawcall path with no per-cell JS↔WASM marshaling.
//
// GridRenderer (renderer.ts, DOM) is the native implementation and stays as
// the accessibility fallback; a WebGL implementation is the planned default.
// The config knob arrives with the second implementation.
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
