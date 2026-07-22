// The browser side of the wire protocol (internal/vt/wire.go). The host owns the
// grid; this decodes the structured Frames it sends and hands them to the grid
// model (grid.ts) to apply. No re-parsing of a byte stream, no emulator in the
// browser — the emulator now lives in Go.
//
// The binary layout mirrors wire.go's Encode exactly:
//
//   byte    version (1)
//   uvarint cursor.x
//   uvarint cursor.y
//   byte    cursor.visible
//   uvarint rowCount
//   per row:   uvarint y, uvarint runCount
//   per run:   uvarint x, uvarint cellCount
//   per cell:  byte attr, byte width, uvarint fg, uvarint bg, uvarint len, len UTF-8 bytes

/** A packed terminal color, identical to Go's vt.Color. */
export type Color = number;

const COLOR_SET = 0x80000000;
const COLOR_RGB = 0x40000000;

/** Attribute bits, matching vt.Attr's iota order. */
export const Attr = {
    Bold: 1 << 0,
    Italic: 1 << 1,
    Underline: 1 << 2,
    Reverse: 1 << 3,
    Dim: 1 << 4,
    Strike: 1 << 5,
    Blink: 1 << 6,
    Hidden: 1 << 7,
} as const;

/** A cell as it arrives on the wire: content resolved to a string, plus style. */
export interface WCell {
    content: string;
    fg: Color;
    bg: Color;
    attr: number;
    width: number;
}

export interface Run {
    x: number;
    cells: WCell[];
}

export interface RowRuns {
    y: number;
    runs: Run[];
}

export interface Cursor {
    x: number;
    y: number;
    visible: boolean;
}

export interface Frame {
    cursor: Cursor;
    /** rows the primary screen scrolled off the top since the client's last
     *  frame; the client captures those rows into scrollback, then shifts up.
     *  Capped at the screen height — hist carries the real depth. */
    scroll: number;
    /** absolute index of the live screen's top row (lines ever pushed to the
     *  host's history ring). The client's captured rows live at [prevHist,
     *  prevHist+scroll); anything between that and hist is fetchable. */
    hist: number;
    /** history numbering epoch — a change (resize, reset) voids cached pages. */
    epoch: number;
    rows: RowRuns[];
}

const WIRE_VERSION = 3;

/** colorToken renders a Color the way Go's Color.Token does, so a decoded grid
 *  can be compared against the emulator: "d" default, "p<n>" palette, "#rrggbb". */
export function colorToken(c: Color): string {
    if ((c & COLOR_SET) === 0) return "d";
    if ((c & COLOR_RGB) !== 0) return "#" + (c & 0xffffff).toString(16).padStart(6, "0");
    return "p" + (c & 0xff);
}

/** attrToken renders attributes the way Go's Attr.Token does. */
export function attrToken(a: number): string {
    let s = "";
    if (a & Attr.Bold) s += "B";
    if (a & Attr.Italic) s += "I";
    if (a & Attr.Underline) s += "U";
    if (a & Attr.Reverse) s += "R";
    if (a & Attr.Dim) s += "D";
    if (a & Attr.Strike) s += "S";
    return s;
}

class Reader {
    private dec = new TextDecoder();
    private i = 0;

    constructor(private buf: Uint8Array) {}

    byte(): number {
        if (this.i >= this.buf.length) throw new Error("vt: truncated frame");
        return this.buf[this.i++];
    }

    /** LEB128 unsigned varint, matching Go's binary.Uvarint. */
    uvarint(): number {
        let result = 0;
        let shift = 0;
        for (;;) {
            const b = this.byte();
            result += (b & 0x7f) * 2 ** shift; // 2**shift avoids 32-bit << overflow past bit 31
            if ((b & 0x80) === 0) break;
            shift += 7;
            if (shift > 63) throw new Error("vt: varint overflow");
        }
        return result;
    }

    str(n: number): string {
        if (this.i + n > this.buf.length) throw new Error("vt: truncated frame");
        const s = this.dec.decode(this.buf.subarray(this.i, this.i + n));
        this.i += n;
        return s;
    }
}

/** decodeFrame parses one Frame from wire bytes produced by vt.Frame.Encode.
 *  Version 2 (a host older than this frontend — the daemon outlives installs)
 *  is accepted with zeroed history fields: scrollback degrades to nothing,
 *  typing and rendering survive. Fail open on host skew, always. */
export function decodeFrame(buf: Uint8Array): Frame {
    const r = new Reader(buf);
    const version = r.byte();
    if (version !== 2 && version !== WIRE_VERSION) throw new Error("vt: unknown wire version");
    const cursor: Cursor = {x: r.uvarint(), y: r.uvarint(), visible: r.byte() !== 0};
    const scroll = r.uvarint();
    const hist = version >= 3 ? r.uvarint() : 0;
    const epoch = version >= 3 ? r.byte() : 0;
    const rowCount = r.uvarint();
    const rows: RowRuns[] = [];
    for (let ri = 0; ri < rowCount; ri++) {
        const y = r.uvarint();
        const runCount = r.uvarint();
        const runs: Run[] = [];
        for (let ki = 0; ki < runCount; ki++) {
            const x = r.uvarint();
            const cellCount = r.uvarint();
            const cells: WCell[] = [];
            for (let ci = 0; ci < cellCount; ci++) {
                const attr = r.byte();
                const width = r.byte();
                const fg = r.uvarint();
                const bg = r.uvarint();
                const content = r.str(r.uvarint());
                cells.push({content, fg, bg, attr, width});
            }
            runs.push({x, cells});
        }
        rows.push({y, runs});
    }
    return {cursor, scroll, hist, epoch, rows};
}

/** A decoded page of scrollback lines starting at absolute index start
 *  (vt.EncodeScrollback). Lines are trimmed of trailing blanks. */
export interface SbChunk {
    epoch: number;
    /** the retained window: absolute lines [base, total) are fetchable */
    base: number;
    total: number;
    start: number;
    lines: WCell[][];
}

/** decodeSbChunk parses one scrollback page from wire bytes. */
export function decodeSbChunk(buf: Uint8Array): SbChunk {
    const r = new Reader(buf);
    if (r.byte() !== WIRE_VERSION) throw new Error("vt: unknown wire version");
    const epoch = r.byte();
    const base = r.uvarint();
    const total = r.uvarint();
    const start = r.uvarint();
    const n = r.uvarint();
    const lines: WCell[][] = [];
    for (let i = 0; i < n; i++) {
        const m = r.uvarint();
        const line: WCell[] = [];
        for (let j = 0; j < m; j++) {
            const attr = r.byte();
            const width = r.byte();
            const fg = r.uvarint();
            const bg = r.uvarint();
            const content = r.str(r.uvarint());
            line.push({content, fg, bg, attr, width});
        }
        lines.push(line);
    }
    return {epoch, base, total, start, lines};
}
