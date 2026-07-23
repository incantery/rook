// WheelGauge converts pixel-based wheel deltas into whole terminal lines.
//
// The naive per-event conversion (round the delta, minimum 1) is why wheel
// scrolling in a mouse-tracking TUI felt violent: a trackpad flick fires
// dozens of small-delta events, each forced to at least one wheel press, and
// a program like Claude Code scrolls several lines per press. The gauge
// banks deltas and emits a line only when a full cell-height has
// accumulated — small deltas add up instead of each rounding up.

export class WheelGauge {
    private acc = 0;

    /** lines converts one wheel event's delta into whole lines (signed;
     *  positive = down). cellH is the line height in CSS px. */
    lines(deltaY: number, deltaMode: number, cellH: number): number {
        const cell = cellH || 16;
        // deltaMode 1 = lines, 2 = pages (Firefox); normalize to pixels
        const px = deltaMode === 1 ? deltaY * cell : deltaMode === 2 ? deltaY * cell * 24 : deltaY;
        // direction reversal drops the leftover — momentum from the old
        // direction must not eat the first notch of the new one
        if ((px < 0 && this.acc > 0) || (px > 0 && this.acc < 0)) this.acc = 0;
        this.acc += px;
        const n = Math.trunc(this.acc / cell);
        this.acc -= n * cell;
        return n === 0 ? 0 : n; // normalize Math.trunc's -0
    }
}
