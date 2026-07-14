// Map a Palette to the CSS custom properties rook already uses. Tailwind v4
// utilities compile to var(--color-*), and the imperative islands read the
// bare --acc/--fg/--dim/--line mirrors — so writing these onto :root at
// runtime re-themes chrome + every utility live, with no DOM walk. Keep the
// var NAMES exactly as the existing markup/CSS reference them; a missing name
// silently keeps a hardcoded color. (--mono is a font, not a color — untouched.)

import {withAlpha} from "./color";
import type {Palette} from "./palette";

/** The line hairline is stored solid; chrome uses border-line/15 for the
 *  0.14 body hairline. main.ts's body --line carried the 0.14 alpha baked in. */
const LINE_ALPHA = 0.14;

export function cssVars(p: Palette): Record<string, string> {
    return {
        // @theme utility tokens (text-acc, bg-raise, border-line/15, …)
        "--color-acc": p.accent,
        "--color-grn": p.green,
        "--color-fg": p.fg,
        "--color-dim": p.dim,
        "--color-lo": p.lo,
        "--color-amber": p.yellow,
        "--color-red": p.red,
        "--color-hot": p.hot,
        "--color-line": p.line,
        "--color-raise": p.raise,
        // bare mirrors read by the imperative islands (term/*, editor pane)
        "--acc": p.accent,
        "--fg": p.fg,
        "--dim": p.dim,
        "--line": withAlpha(p.line, LINE_ALPHA),
    };
}
