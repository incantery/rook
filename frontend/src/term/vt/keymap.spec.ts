import {describe, expect, it} from "vitest";
import {keyToBytes, type KeyLike} from "./keymap";

// key builds a KeyLike with no modifiers unless overridden.
function key(k: string, mods: Partial<KeyLike> = {}): KeyLike {
    return {key: k, ctrlKey: false, altKey: false, shiftKey: false, metaKey: false, ...mods};
}

describe("keyToBytes", () => {
    it("sends printable characters as themselves", () => {
        expect(keyToBytes(key("a"))).toBe("a");
        expect(keyToBytes(key("A", {shiftKey: true}))).toBe("A"); // shift baked into key
        expect(keyToBytes(key("!"))).toBe("!");
    });

    it("maps the named editing keys", () => {
        expect(keyToBytes(key("Enter"))).toBe("\r");
        expect(keyToBytes(key("Tab"))).toBe("\t");
        expect(keyToBytes(key("Tab", {shiftKey: true}))).toBe("\x1b[Z");
        expect(keyToBytes(key("Backspace"))).toBe("\x7f");
        expect(keyToBytes(key("Backspace", {ctrlKey: true}))).toBe("\x08");
        expect(keyToBytes(key("Escape"))).toBe("\x1b");
    });

    it("maps arrows and Home/End in normal mode", () => {
        expect(keyToBytes(key("ArrowUp"))).toBe("\x1b[A");
        expect(keyToBytes(key("ArrowDown"))).toBe("\x1b[B");
        expect(keyToBytes(key("ArrowRight"))).toBe("\x1b[C");
        expect(keyToBytes(key("ArrowLeft"))).toBe("\x1b[D");
        expect(keyToBytes(key("Home"))).toBe("\x1b[H");
        expect(keyToBytes(key("End"))).toBe("\x1b[F");
    });

    it("encodes modifiers on cursor keys with the xterm parameter", () => {
        // mod = 1 + shift + 2*alt + 4*ctrl
        expect(keyToBytes(key("ArrowUp", {ctrlKey: true}))).toBe("\x1b[1;5A"); // 1+4
        expect(keyToBytes(key("ArrowLeft", {shiftKey: true}))).toBe("\x1b[1;2D"); // 1+1
        expect(keyToBytes(key("End", {ctrlKey: true, shiftKey: true}))).toBe("\x1b[1;6F"); // 1+1+4
    });

    it("maps the tilde family with and without modifiers", () => {
        expect(keyToBytes(key("PageUp"))).toBe("\x1b[5~");
        expect(keyToBytes(key("Delete"))).toBe("\x1b[3~");
        expect(keyToBytes(key("Insert"))).toBe("\x1b[2~");
        expect(keyToBytes(key("PageDown", {ctrlKey: true}))).toBe("\x1b[6;5~");
    });

    it("maps function keys (SS3 for F1-F4, tilde for F5+)", () => {
        expect(keyToBytes(key("F1"))).toBe("\x1bOP");
        expect(keyToBytes(key("F4"))).toBe("\x1bOS");
        expect(keyToBytes(key("F5"))).toBe("\x1b[15~");
        expect(keyToBytes(key("F12"))).toBe("\x1b[24~");
    });

    it("maps Ctrl+letter to C0 control codes", () => {
        expect(keyToBytes(key("a", {ctrlKey: true}))).toBe("\x01");
        expect(keyToBytes(key("c", {ctrlKey: true}))).toBe("\x03"); // SIGINT
        expect(keyToBytes(key("z", {ctrlKey: true}))).toBe("\x1a");
        expect(keyToBytes(key(" ", {ctrlKey: true}))).toBe("\x00"); // Ctrl+Space -> NUL
        expect(keyToBytes(key("[", {ctrlKey: true}))).toBe("\x1b");
    });

    it("prefixes Alt/Meta chords with ESC", () => {
        expect(keyToBytes(key("b", {altKey: true}))).toBe("\x1bb"); // Alt+b (word-back)
    });

    it("sends nothing for bare modifiers and Cmd chords", () => {
        expect(keyToBytes(key("Shift", {shiftKey: true}))).toBeNull();
        expect(keyToBytes(key("Control", {ctrlKey: true}))).toBeNull();
        expect(keyToBytes(key("c", {metaKey: true}))).toBeNull(); // Cmd+C is a shortcut
        expect(keyToBytes(key("Unidentified"))).toBeNull();
    });
});
