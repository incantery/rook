// Alpha-safe hex color math for the theme system. Every color that flows
// through a Palette is normalized here first — real VS Code themes use
// #RRGGBBAA and #RGBA shorthand throughout (One Dark Pro's selection is
// #67769660), so nothing downstream may assume opaque 6-digit hex. The
// derivation helpers (mix/lighten/darken) mirror how VS Code fills the
// ~600 workbench keys it doesn't ship from a handful of base colors.

const HEX = /^#?([0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/;

/** Expand #RGB/#RGBA → #RRGGBB(AA), lowercase, keep alpha; pass 6/8 through. */
export function normalizeHex(input: string): string {
    const m = HEX.exec(input.trim());
    if (!m) throw new Error(`bad hex color: ${input}`);
    let h = m[1].toLowerCase();
    if (h.length === 3 || h.length === 4) {
        h = h
            .split("")
            .map((c) => c + c)
            .join("");
    }
    return `#${h}`;
}

/** #RRGGBBAA → #RRGGBB (drop alpha) — Monaco rule foregrounds can't carry it. */
export function stripAlpha(hex: string): string {
    return normalizeHex(hex).slice(0, 7);
}

/** Drop the leading # — Monaco `rules[].foreground` wants bare 6-digit hex. */
export function noHash(hex: string): string {
    return stripAlpha(hex).slice(1);
}

/** Force an alpha channel (0–1) → #RRGGBBAA. */
export function withAlpha(hex: string, a: number): string {
    const base = stripAlpha(hex);
    const byte = Math.round(clamp01(a) * 255)
        .toString(16)
        .padStart(2, "0");
    return `${base}${byte}`;
}

/** Linear RGB blend, t in [0,1] toward `b`; alpha dropped (opaque result). */
export function mix(a: string, b: string, t: number): string {
    const [ar, ag, ab] = rgb(a);
    const [br, bg, bb] = rgb(b);
    const k = clamp01(t);
    return toHex(ar + (br - ar) * k, ag + (bg - ag) * k, ab + (bb - ab) * k);
}

/** Lighten toward white by amt in [0,1]. */
export function lighten(hex: string, amt: number): string {
    return mix(hex, "#ffffff", amt);
}

/** Darken toward black by amt in [0,1]. */
export function darken(hex: string, amt: number): string {
    return mix(hex, "#000000", amt);
}

export function rgb(hex: string): [number, number, number] {
    const h = stripAlpha(hex);
    return [parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16)];
}

function toHex(r: number, g: number, b: number): string {
    const byte = (n: number) =>
        Math.round(Math.max(0, Math.min(255, n)))
            .toString(16)
            .padStart(2, "0");
    return `#${byte(r)}${byte(g)}${byte(b)}`;
}

function clamp01(n: number): number {
    return Math.max(0, Math.min(1, n));
}
