// The client half of the framed terminal transport (internal/host/termframe.go).
// WebSocket messages preserve boundaries, so each is a 1-byte tag plus payload —
// no length framing. These helpers are pure so they test without a socket; the
// manager owns the WebSocket and calls them.

export const MSG_FRAME = 0x01; // server -> client: a vt.Frame
export const MSG_STATE = 0x02; // server -> client: session state (alt screen)
export const MSG_INPUT = 0x10; // client -> server: raw pty bytes
export const MSG_RESIZE = 0x11; // client -> server: cols, rows

export const STATE_ALT = 0x01; // bit0 of a state payload: alt screen active

export type ServerMessage =
    | {kind: "frame"; payload: Uint8Array}
    | {kind: "state"; alt: boolean}
    | {kind: "unknown"; tag: number};

/** decodeServerMessage classifies one incoming binary message. The frame payload
 *  is a view (no copy) ready for decodeFrame. */
export function decodeServerMessage(buf: ArrayBuffer): ServerMessage {
    const b = new Uint8Array(buf);
    if (b.length === 0) return {kind: "unknown", tag: -1};
    switch (b[0]) {
        case MSG_FRAME:
            return {kind: "frame", payload: b.subarray(1)};
        case MSG_STATE:
            return {kind: "state", alt: b.length > 1 && (b[1] & STATE_ALT) !== 0};
        default:
            return {kind: "unknown", tag: b[0]};
    }
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
