// Renderer construction. There is one renderer — beamterm, the WebGL grid
// (beamterm.ts) — and this module exists to load its WASM before any pane is
// built and to hand out instances after.
//
// It used to be a bake-off seam with a DOM renderer behind a localStorage flag
// and silent fallback between them. The DOM renderer was deleted 2026-07-27:
// two renderers meant every fix, theme change and wire change landed twice,
// and the measurements that were supposed to arbitrate could not — headed,
// both sat on the display's frame clock (docs/PERF.md). One renderer to
// optimize was worth more than a comparison neither probe could resolve.
//
// The cost of that decision, stated where it is felt: there is no fallback
// now. If the WASM module fails to load there is no terminal, so the failure
// has to be LOUD — a silent catch here would present an empty pane and no
// reason for it.

import type {RendererOptions, TermRenderer} from "./api";
import {BeamtermGridRenderer, initBeamterm} from "./beamterm";

/** Why the renderer is unavailable, or null while it is fine. Read by the
 *  chrome to explain an empty pane instead of leaving the user guessing. */
let failure: string | null = null;

export function rendererFailure(): string | null {
    return failure;
}

/** loadCanvasFonts re-registers the terminal font stack's families as FontFaces
 *  from bytes the Go side serves (/rookfont, see internal/fontdir). Pass the
 *  configured family AND its symbol fallbacks (main.ts): the atlas needs every
 *  family the CSS stack can reach, or an unpatched configured font rasterizes
 *  tofu for the icons its fallback was meant to supply.
 *
 *  WebKit's canvas 2D ignores user-installed fonts (a fingerprinting
 *  mitigation): DOM text renders them, fillText silently falls back — so the
 *  glyph atlas would lose the terminal font entirely and draw tofu for every
 *  nerd-font icon. FontFace-loaded bytes ARE visible to canvas, and registering
 *  them under the SAME family name means the existing font stack just starts
 *  resolving — no renderer plumbing.
 *
 *  Everything fails open: a 404 (family not found on disk, or a web-safe font
 *  that needs no help) or a FontFace rejection (e.g. .ttc collections) leaves
 *  the browser's own fallback in charge. Call before terminals are
 *  constructed. */
export async function loadCanvasFonts(families: string[]): Promise<void> {
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
                    // fail open — the browser's own fallback stays in charge
                }
            }),
        ),
    );
}

/** preloadRenderer loads the WASM module ahead of the first terminal. Call
 *  before TermManager.init(). It does not throw: a dead renderer must not take
 *  the whole app down with it, because the workbench around the terminal (the
 *  editor, threads, review) still works. It records the reason instead, and
 *  makeRenderer throws per pane. */
export async function preloadRenderer(): Promise<void> {
    try {
        await initBeamterm();
        failure = null;
    } catch (err) {
        failure = String(err);
        console.error("terminal renderer unavailable — panes will not paint", err);
    }
}

export function makeRenderer(
    container: HTMLElement,
    cols: number,
    rows: number,
    opts: RendererOptions,
): TermRenderer {
    return new BeamtermGridRenderer(container, cols, rows, opts);
}
