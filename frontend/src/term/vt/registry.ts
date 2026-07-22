// Renderer selection behind the TermRenderer seam. The DOM renderer is the
// default and the accessibility fallback; the WebGL renderer (beamterm spike)
// is opt-in via localStorage until the bake-off settles:
//
//   localStorage.setItem("rook.renderer", "webgl")   // then reload
//
// Selection fails open: if the WASM module doesn't load or a construction
// throws (no WebGL2, headless quirks), the DOM renderer takes over silently —
// a renderer experiment must never brick the terminal.

import type {TermRenderer} from "./api";
import {GridRenderer, type RendererOptions} from "./renderer";

type BeamtermModule = typeof import("./beamterm");
let beamterm: BeamtermModule | null = null;
let active: RendererKind = "dom";

/** activeRendererKind is what this session actually runs (after fallback) —
 *  compare against rendererKind() to know whether a reload would change it. */
export function activeRendererKind(): RendererKind {
    return active;
}

export type RendererKind = "dom" | "webgl";

export function rendererKind(): RendererKind {
    try {
        return localStorage.getItem("rook.renderer") === "webgl" ? "webgl" : "dom";
    } catch {
        return "dom";
    }
}

/** setRendererKind stores the choice; it applies on the next app load (the
 *  WASM preload and every pane's renderer are constructed at boot). */
export function setRendererKind(kind: RendererKind): void {
    try {
        if (kind === "dom") localStorage.removeItem("rook.renderer");
        else localStorage.setItem("rook.renderer", kind);
    } catch {
        // private-mode storage — the toggle just won't stick
    }
}

/** preloadRenderer loads the WASM module ahead of the first terminal, when the
 *  webgl renderer is configured. Call before TermManager.init(). */
export async function preloadRenderer(): Promise<void> {
    if (rendererKind() !== "webgl") return;
    try {
        const mod = await import("./beamterm");
        await mod.initBeamterm();
        beamterm = mod;
        active = "webgl";
    } catch (err) {
        console.warn("webgl renderer unavailable — DOM fallback", err);
        beamterm = null;
    }
}

export function makeRenderer(
    container: HTMLElement,
    cols: number,
    rows: number,
    opts: RendererOptions,
): TermRenderer {
    if (beamterm) {
        try {
            return new beamterm.BeamtermGridRenderer(container, cols, rows, opts);
        } catch (err) {
            console.warn("webgl renderer failed — DOM fallback", err);
        }
    }
    return new GridRenderer(container, cols, rows, opts);
}
