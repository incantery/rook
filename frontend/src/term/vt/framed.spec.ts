import {describe, expect, it} from "vitest";
import {
    decodeServerMessage,
    encodeInput,
    encodeResize,
    MSG_FRAME,
    MSG_INPUT,
    MSG_RESIZE,
    MSG_STATE,
} from "./framed";

// buf builds an ArrayBuffer from bytes (an incoming ws binary message).
function buf(...bytes: number[]): ArrayBuffer {
    return new Uint8Array(bytes).buffer;
}

describe("framed transport", () => {
    it("decodes a frame message into a payload view", () => {
        const msg = decodeServerMessage(buf(MSG_FRAME, 2, 0, 5));
        expect(msg.kind).toBe("frame");
        if (msg.kind === "frame") {
            expect([...msg.payload]).toEqual([2, 0, 5]); // the tag is stripped
        }
    });

    it("decodes a state message's alt bit", () => {
        const on = decodeServerMessage(buf(MSG_STATE, 0x01));
        const off = decodeServerMessage(buf(MSG_STATE, 0x00));
        expect(on).toEqual({kind: "state", alt: true});
        expect(off).toEqual({kind: "state", alt: false});
    });

    it("reports unknown tags and empty messages", () => {
        expect(decodeServerMessage(buf(0x99))).toEqual({kind: "unknown", tag: 0x99});
        expect(decodeServerMessage(buf())).toEqual({kind: "unknown", tag: -1});
    });

    it("encodes input as tag + utf8 bytes", () => {
        expect([...encodeInput("hi")]).toEqual([MSG_INPUT, 0x68, 0x69]);
        // a control byte (Ctrl+C) round-trips faithfully
        expect([...encodeInput("\x03")]).toEqual([MSG_INPUT, 0x03]);
        // multi-byte utf8 (世 = e4 b8 96) is preserved
        expect([...encodeInput("世")]).toEqual([MSG_INPUT, 0xe4, 0xb8, 0x96]);
    });

    it("encodes resize as tag + two big-endian uint16", () => {
        expect([...encodeResize(80, 24)]).toEqual([MSG_RESIZE, 0, 80, 0, 24]);
        expect([...encodeResize(300, 100)]).toEqual([MSG_RESIZE, 1, 44, 0, 100]); // 300 = 0x012c
    });
});
