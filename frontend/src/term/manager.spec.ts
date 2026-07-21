import {describe, expect, it} from "vitest";
import {HOST_ANSWERED, REPLAY_ONLY} from "./manager";

// AUTO_REPLY is the replay gate's filter: while the host is replaying its
// ring, xterm re-parses every query the session ever received and answers
// them again — to a program that is not asking. Those answers must not reach
// the pty. Typing must.
//
// Every sequence below was CAPTURED from a websocket tap on the real app
// while nvim started and the pane reattached — not invented.

/** what reaches the pty while a replay is in flight — both rules apply */
const through = (s: string) => s.replace(HOST_ANSWERED, "").replace(REPLAY_ONLY, "");

/** what reaches the pty when nothing is replaying — the steady state */
const live = (s: string) => s.replace(HOST_ANSWERED, "");

describe("the filters strip what xterm answers on its own", () => {
    it.each([
        ["cursor position (CPR)", "\x1b[24;80R"],
        ["device status (DSR)", "\x1b[0n"],
        ["primary device attributes", "\x1b[?1;2c"],
        ["secondary device attributes", "\x1b[>0;276;0c"],
        ["background color (OSC 11)", "\x1b]11;rgb:0000/0000/0000\x1b\\"],
        ["foreground color (OSC 10)", "\x1b]10;rgb:c0c0/caca/f5f5\x1b\\"],
        ["DECRQSS reply (DCS)", "\x1bP1$r0m\x1b\\"],
    ])("%s", (_name, seq) => {
        expect(through(seq)).toBe("");
    });

    // The regression. nvim asks about synchronized output and friends on
    // every start (CSI ?2026$p …); before $y was covered, a reattach replayed
    // all five of these into whatever was running in the pane.
    it.each([
        ["?69 — left/right margin mode", "\x1b[?69;0$y"],
        ["?2026 — synchronized output", "\x1b[?2026;2$y"],
        ["?2027 — grapheme clustering", "\x1b[?2027;0$y"],
        ["?2031 — color scheme updates", "\x1b[?2031;0$y"],
        ["?2048 — in-band resize", "\x1b[?2048;0$y"],
        ["the ANSI form, no ? prefix", "\x1b[4;1$y"],
    ])("mode report %s", (_name, seq) => {
        expect(through(seq)).toBe("");
    });

    it("strips the whole burst nvim's startup provokes, leaving nothing", () => {
        const burst =
            "\x1b[?69;0$y\x1b[?2026;2$y\x1b[?2027;0$y\x1b[?2031;0$y\x1b[?2048;0$y" +
            "\x1bP1$r0m\x1b\\\x1b[?1;2c\x1b]11;rgb:0000/0000/0000\x1b\\\x1b[0n";
        expect(through(burst)).toBe("");
    });
});

describe("the filters leave input alone", () => {
    // A filter that ate keys would be worse than the bug it fixes: these run
    // through the same gate, and a partial match is the dangerous failure —
    // it would forward the REMAINDER as literal text, which in vim's normal
    // mode is a command.
    it.each([
        ["typed text", "nvim\r"],
        ["a lone Escape", "\x1b"],
        ["arrows", "\x1b[A\x1b[B\x1b[C\x1b[D"],
        ["modified arrows", "\x1b[1;5A"],
        ["Home/End/Delete", "\x1b[H\x1b[F\x1b[3~"],
        ["function keys", "\x1bOP\x1bOQ\x1b[15~"],
        ["a control character", "\x03"],
        ["focus events", "\x1b[I\x1b[O"],
        ["an SGR mouse report", "\x1b[<0;10;5M"],
        ["text that merely contains $y", "cost $y later"],
    ])("%s survives", (_name, seq) => {
        expect(through(seq)).toBe(seq);
    });
});

// The point of the split: what the HOST answers is dropped whether or not a
// replay is in flight, because xterm's copy is always a second answer to a
// question that already got one. What only xterm can answer stays live —
// dropping those outside a replay would break vim's background detection and
// hang anything asking where the cursor is.
describe("host-answered replies are dropped even when nothing is replaying", () => {
    it.each([
        ["primary device attributes", "\x1b[?1;2c"],
        ["secondary device attributes", "\x1b[>0;276;0c"],
        ["device status ok", "\x1b[0n"],
        ["a mode report", "\x1b[?2026;2$y"],
    ])("%s", (_name, seq) => {
        expect(live(seq)).toBe("");
    });

    it.each([
        ["cursor position", "\x1b[24;80R"],
        ["background color", "\x1b]11;rgb:0000/0000/0000\x1b\\"],
        ["the DECRQSS status string", "\x1bP1$r0m\x1b\\"],
    ])("%s survives — only xterm can answer it", (_name, seq) => {
        expect(live(seq)).toBe(seq);
    });

    // A reply shape nobody answers must never be swallowed: the host does not
    // handle private DSR, so eating xterm's answer would hang the asker.
    it("does not touch a private status report", () => {
        expect(live("\x1b[?13n")).toBe("\x1b[?13n");
        expect(through("\x1b[?13n")).toBe("\x1b[?13n");
    });
});
