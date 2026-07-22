// Encoding mouse events as the reports a program expects when it has enabled
// mouse tracking (DECSET ?1000/?1002/?1003, encoding ?1006). Pure, so it tests
// without a DOM. The renderer forwards these instead of scrolling locally when a
// TUI is driving the mouse itself — Claude Code's conversation scroll, a pager,
// an editor's mouse support.

// Button codes: 0 left, 1 middle, 2 right; 64 wheel-up, 65 wheel-down. A drag
// (motion) adds 32. SGR reports a real release; legacy can't say which button.
export const BTN_LEFT = 0;
export const BTN_MIDDLE = 1;
export const BTN_RIGHT = 2;
export const BTN_WHEEL_UP = 64;
export const BTN_WHEEL_DOWN = 65;

export interface MouseReport {
    button: number;
    col: number; // 1-based cell column
    row: number; // 1-based cell row
    press: boolean; // press / wheel / motion (M); false = release (m)
    motion?: boolean; // the pointer moved with a button held (a drag)
    sgr: boolean; // program enabled SGR encoding (?1006)
}

/** encodeMouse builds the byte string for one mouse report. */
export function encodeMouse(r: MouseReport): string {
    let b = r.button;
    if (r.motion) b += 32;
    if (r.sgr) {
        // ESC [ < b ; col ; row (M press | m release)
        return `\x1b[<${b};${r.col};${r.row}${r.press ? "M" : "m"}`;
    }
    // Legacy X10/normal: ESC [ M, then three bytes each offset by 32. A release
    // is button 3 (the protocol can't encode which button let go).
    const btn = r.press ? b : 3;
    const cap = (n: number) => String.fromCharCode(Math.min(255, 32 + n));
    return `\x1b[M${cap(btn)}${cap(r.col)}${cap(r.row)}`;
}
