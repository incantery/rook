import {describe, expect, it} from "vitest";
import {BTN_LEFT, BTN_WHEEL_DOWN, BTN_WHEEL_UP, encodeMouse} from "./mouse";

describe("encodeMouse", () => {
    it("encodes SGR press and release", () => {
        expect(encodeMouse({button: BTN_LEFT, col: 3, row: 5, press: true, sgr: true})).toBe(
            "\x1b[<0;3;5M",
        );
        expect(encodeMouse({button: BTN_LEFT, col: 3, row: 5, press: false, sgr: true})).toBe(
            "\x1b[<0;3;5m",
        );
    });

    it("adds 32 to the button for a drag (motion)", () => {
        expect(
            encodeMouse({button: BTN_LEFT, col: 10, row: 2, press: true, motion: true, sgr: true}),
        ).toBe("\x1b[<32;10;2M");
    });

    it("encodes the wheel as buttons 64/65", () => {
        expect(encodeMouse({button: BTN_WHEEL_UP, col: 1, row: 1, press: true, sgr: true})).toBe(
            "\x1b[<64;1;1M",
        );
        expect(encodeMouse({button: BTN_WHEEL_DOWN, col: 1, row: 1, press: true, sgr: true})).toBe(
            "\x1b[<65;1;1M",
        );
    });

    it("encodes legacy reports with the 32 offset, release as button 3", () => {
        // ESC [ M, then 32+btn, 32+col, 32+row
        expect(encodeMouse({button: BTN_LEFT, col: 1, row: 1, press: true, sgr: false})).toBe(
            "\x1b[M\x20\x21\x21", // 32, 33, 33
        );
        expect(encodeMouse({button: BTN_LEFT, col: 1, row: 1, press: false, sgr: false})).toBe(
            "\x1b[M\x23\x21\x21", // 32+3, 33, 33
        );
    });
});
