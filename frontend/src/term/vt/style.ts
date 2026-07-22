// Turning a coalesced Span into styled HTML. Kept pure and separate from the DOM
// renderer so the escaping and color math are unit-testable without a browser.
//
// Themeable colors resolve to CSS custom properties (--term-fg, --term-bg, the
// 16 --term-ansi-N) so rook's theme drives them at runtime; the 256-color cube,
// the grayscale ramp, and truecolor are computed directly, as they are not
// themed. This is the seam that will later answer OSC palette queries too.

import type {Color} from "./frame";
import {Attr} from "./frame";
import type {Span} from "./grid";

const COLOR_SET = 0x80000000;
const COLOR_RGB = 0x40000000;

const ESCAPE: Record<string, string> = {"&": "&amp;", "<": "&lt;", ">": "&gt;"};

/** escapeHtml makes terminal content safe as HTML text (it is untrusted output). */
export function escapeHtml(s: string): string {
    return s.replace(/[&<>]/g, (c) => ESCAPE[c]);
}

/** cssColor resolves a Color to a CSS color, or "" for the terminal default
 *  (which the container's base fg/bg supplies). */
export function cssColor(c: Color): string {
    if ((c & COLOR_SET) === 0) return "";
    if ((c & COLOR_RGB) !== 0) {
        const v = c & 0xffffff;
        return "#" + v.toString(16).padStart(6, "0");
    }
    const n = c & 0xff;
    if (n < 16) return `var(--term-ansi-${n})`;
    if (n < 232) {
        // 6x6x6 cube: indices 16..231
        const i = n - 16;
        const r = Math.floor(i / 36),
            g = Math.floor((i % 36) / 6),
            b = i % 6;
        const level = (x: number) => (x === 0 ? 0 : 55 + x * 40);
        return rgbHex(level(r), level(g), level(b));
    }
    const gray = 8 + (n - 232) * 10; // 232..255 grayscale ramp
    return rgbHex(gray, gray, gray);
}

function rgbHex(r: number, g: number, b: number): string {
    return "#" + ((r << 16) | (g << 8) | b).toString(16).padStart(6, "0");
}

/** spanStyle builds the inline CSS for a span from its fg/bg/attr, honoring
 *  reverse video (swap), and the standard bold/dim/italic/underline/strike. A
 *  hidden span renders its width in spaces so layout is preserved. */
export function spanStyle(span: Span): string {
    let fg = cssColor(span.fg);
    let bg = cssColor(span.bg);
    if (span.attr & Attr.Reverse) {
        // swap, defaulting each side to the container's base so a reverse cell
        // with no explicit color still inverts.
        [fg, bg] = [bg || "var(--term-bg)", fg || "var(--term-fg)"];
    }
    const parts: string[] = [];
    if (fg) parts.push(`color:${fg}`);
    if (bg) parts.push(`background:${bg}`);
    if (span.attr & Attr.Bold) parts.push("font-weight:bold");
    if (span.attr & Attr.Dim) parts.push("opacity:.6");
    if (span.attr & Attr.Italic) parts.push("font-style:italic");
    const deco: string[] = [];
    if (span.attr & Attr.Underline) deco.push("underline");
    if (span.attr & Attr.Strike) deco.push("line-through");
    if (deco.length) parts.push(`text-decoration:${deco.join(" ")}`);
    return parts.join(";");
}

/** spanHtml renders one span. Hidden text becomes spaces (kept for width). */
export function spanHtml(span: Span): string {
    const text = span.attr & Attr.Hidden ? " ".repeat([...span.text].length) : span.text;
    const style = spanStyle(span);
    const body = escapeHtml(text);
    return style ? `<span style="${style}">${body}</span>` : `<span>${body}</span>`;
}

/** rowHtml renders a whole row of spans. */
export function rowHtml(spans: Span[]): string {
    let html = "";
    for (const s of spans) html += spanHtml(s);
    return html;
}
