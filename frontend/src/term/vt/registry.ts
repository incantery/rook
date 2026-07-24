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

/** loadCanvasFonts re-registers the terminal font stack's families as FontFaces
 *  from bytes the Go side serves (/rookfont, see internal/fontdir). Pass the
 *  configured family AND its symbol fallbacks (main.ts): the atlas needs every
 *  family the CSS stack can reach, or an unpatched configured font rasterizes
 *  tofu for the icons its fallback was meant to supply.
 *
 *  WebKit's canvas 2D ignores user-installed fonts (a fingerprinting
 *  mitigation): DOM text renders them, fillText silently falls back — so the
 *  WebGL renderer's glyph atlas would lose the terminal font entirely and
 *  draw tofu for every nerd-font icon. FontFace-loaded bytes ARE visible to
 *  canvas, and registering them under the SAME family name means the
 *  existing font stack just starts resolving — no renderer plumbing.
 *
 *  Everything fails open: a 404 (family not found on disk, or a web-safe
 *  font that needs no help) or a FontFace rejection (e.g. .ttc collections)
 *  leaves the browser's own fallback in charge. Call before terminals are
 *  constructed, when the webgl renderer is configured. */
export async function loadCanvasFonts(families: string[]): Promise<void> {
    if (rendererKind() !== "webgl") return;
    const styles: [string, FontFaceDescriptors][] = [
        ["regular", {}],
        ["bold", {weight: "700"}],
        ["italic", {style: "italic"}],
        ["bolditalic", {weight: "700", style: "italic"}],
    ];
    await Promise.all(
        families.flatMap((family) =>
            styles.map(async ([style, desc]) => {
                try {
                    const r = await fetch(
                        `/rookfont?family=${encodeURIComponent(family)}&style=${style}`,
                    );
                    if (!r.ok) return;
                    const face = new FontFace(family, await r.arrayBuffer(), desc);
                    await face.load();
                    document.fonts.add(face);
                } catch {
                    // fail open — the DOM path never needed this
                }
            }),
        ),
    );
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
