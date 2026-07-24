// The client half of the framed terminal transport (internal/host/termframe.go).
// WebSocket messages preserve boundaries, so each is a 1-byte tag plus payload —
// no length framing. These helpers are pure so they test without a socket; the
// manager owns the WebSocket and calls them.

export const MSG_FRAME = 0x01; // server -> client: a vt.Frame
export const MSG_STATE = 0x02; // server -> client: session state (alt screen)
export const MSG_SB_CHUNK = 0x03; // server -> client: a page of scrollback history
export const MSG_EDIT = 0x04; // server -> client: edit request JSON (`re` pane takeover)
export const MSG_ASK = 0x05; // server -> client: ask request JSON (a question for the human)
export const MSG_ASK_DONE = 0x06; // server -> client: {"id"} — that ask is settled, stand down
export const MSG_INPUT = 0x10; // client -> server: raw pty bytes
export const MSG_RESIZE = 0x11; // client -> server: cols, rows
export const MSG_PALETTE = 0x12; // client -> server: theme colors for OSC answers
export const MSG_SB_FETCH = 0x13; // client -> server: request a scrollback page
export const MSG_VIS = 0x14; // client -> server: pane visibility (pause frames)

// state flags byte: bit0 alt screen; bits1-3 mouse tracking level (0-4); bit4
// SGR mouse encoding.
export const STATE_ALT = 0x01;
export const STATE_MOUSE_SGR = 0x10;

export type ServerMessage =
    | {kind: "frame"; payload: Uint8Array}
    | {kind: "state"; alt: boolean; mouseLevel: number; mouseSgr: boolean}
    | {kind: "sbchunk"; payload: Uint8Array}
    | {kind: "edit"; payload: Uint8Array}
    | {kind: "ask"; payload: Uint8Array}
    | {kind: "askdone"; payload: Uint8Array}
    | {kind: "unknown"; tag: number};

/** decodeServerMessage classifies one incoming binary message. The frame payload
 *  is a view (no copy) ready for decodeFrame. */
export function decodeServerMessage(buf: ArrayBuffer): ServerMessage {
    const b = new Uint8Array(buf);
    if (b.length === 0) return {kind: "unknown", tag: -1};
    switch (b[0]) {
        case MSG_FRAME:
            return {kind: "frame", payload: b.subarray(1)};
        case MSG_STATE: {
            const flags = b.length > 1 ? b[1] : 0;
            return {
                kind: "state",
                alt: (flags & STATE_ALT) !== 0,
                mouseLevel: (flags >> 1) & 0x7,
                mouseSgr: (flags & STATE_MOUSE_SGR) !== 0,
            };
        }
        case MSG_SB_CHUNK:
            return {kind: "sbchunk", payload: b.subarray(1)};
        case MSG_EDIT:
            return {kind: "edit", payload: b.subarray(1)};
        case MSG_ASK:
            return {kind: "ask", payload: b.subarray(1)};
        case MSG_ASK_DONE:
            return {kind: "askdone", payload: b.subarray(1)};
        default:
            return {kind: "unknown", tag: b[0]};
    }
}

/** encodeVis tells the host whether anyone can see this pane. Hidden panes
 *  keep parsing host-side but ship no frames; the reveal ships the net diff. */
export function encodeVis(visible: boolean): Uint8Array {
    return new Uint8Array([MSG_VIS, visible ? 1 : 0]);
}

/** encodeSbFetch requests count history lines from absolute index start:
 *  BE uint32 start, BE uint16 count. count 0 is a stat (bounds only). */
export function encodeSbFetch(start: number, count: number): Uint8Array {
    return new Uint8Array([
        MSG_SB_FETCH,
        (start >>> 24) & 0xff,
        (start >>> 16) & 0xff,
        (start >>> 8) & 0xff,
        start & 0xff,
        (count >> 8) & 0xff,
        count & 0xff,
    ]);
}

const encoder = new TextEncoder();

/** encodeInput frames terminal input (keystrokes, paste) as pty bytes. */
export function encodeInput(data: string): Uint8Array {
    const body = encoder.encode(data);
    const out = new Uint8Array(1 + body.length);
    out[0] = MSG_INPUT;
    out.set(body, 1);
    return out;
}

/** encodeResize frames a geometry change as two big-endian uint16s. */
export function encodeResize(cols: number, rows: number): Uint8Array {
    return new Uint8Array([
        MSG_RESIZE,
        (cols >> 8) & 0xff,
        cols & 0xff,
        (rows >> 8) & 0xff,
        rows & 0xff,
    ]);
}

export type RGB = [number, number, number];

/** encodePalette frames the theme's colors — default fg/bg/cursor then the 16
 *  ANSI colors — as RGB triples, for the host emulator's OSC palette answers. */
export function encodePalette(fg: RGB, bg: RGB, cursor: RGB, ansi: RGB[]): Uint8Array {
    const out = new Uint8Array(1 + 9 + 48);
    out[0] = MSG_PALETTE;
    let o = 1;
    const put = (c: RGB) => {
        out[o++] = c[0];
        out[o++] = c[1];
        out[o++] = c[2];
    };
    put(fg);
    put(bg);
    put(cursor);
    for (let i = 0; i < 16; i++) put(ansi[i] ?? [0, 0, 0]);
    return out;
}
