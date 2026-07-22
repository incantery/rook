// keyToBytes translates a key press into the bytes a pty expects — the input
// half of the terminal that xterm.js gave us for free. It is a pure function of
// a KeyLike (the fields we read off a KeyboardEvent), so it tests without a DOM.
//
// Scope for now: the "normal" keypad/cursor mode, which is the default and what
// a shell, vim, and most TUIs use. Application-cursor mode (DECCKM ?1, which
// swaps ESC[ for ESC O on the arrows) and bracketed paste (?2004) are host-known
// modes that the client can't see yet; they arrive with the session-state signal
// in a later slice. Meta/Cmd chords are treated as app/OS shortcuts, not input.

export interface KeyLike {
    key: string;
    ctrlKey: boolean;
    altKey: boolean;
    shiftKey: boolean;
    metaKey: boolean;
}

// Cursor + Home/End: the CSI-letter family, which shares the modified form
// ESC[1;{mod}{letter}.
const CSI_LETTER: Record<string, string> = {
    ArrowUp: "A",
    ArrowDown: "B",
    ArrowRight: "C",
    ArrowLeft: "D",
    Home: "H",
    End: "F",
};

// Editing + PageUp/Down + F5.. : the tilde family, ESC[{n}~ / ESC[{n};{mod}~.
const CSI_TILDE: Record<string, string> = {
    Insert: "2",
    Delete: "3",
    PageUp: "5",
    PageDown: "6",
    F5: "15",
    F6: "17",
    F7: "18",
    F8: "19",
    F9: "20",
    F10: "21",
    F11: "23",
    F12: "24",
};

// F1-F4: the SS3 family, ESC O {letter}.
const SS3: Record<string, string> = {F1: "P", F2: "Q", F3: "R", F4: "S"};

// modCode is xterm's modifier parameter: 1 + shift(1) + alt(2) + ctrl(4). Meta is
// excluded — we never reach here with it (see keyToBytes). A value of 1 means no
// modifier, and the caller omits the ";mod" section entirely.
function modCode(e: KeyLike): number {
    return 1 + (e.shiftKey ? 1 : 0) + (e.altKey ? 2 : 0) + (e.ctrlKey ? 4 : 0);
}

// controlByte maps a printable char under Ctrl to its C0 control code, or null if
// the combination has no control byte (so the caller can decide not to send it).
function controlByte(ch: string): number | null {
    const up = ch.toUpperCase();
    const c = up.charCodeAt(0);
    if (c >= 65 && c <= 90) return c - 64; // Ctrl+A..Z -> 0x01..0x1a
    switch (ch) {
        case " ":
        case "@":
            return 0; // NUL
        case "[":
            return 27;
        case "\\":
            return 28;
        case "]":
            return 29;
        case "^":
            return 30;
        case "_":
            return 31;
        case "?":
            return 127;
    }
    return null;
}

/** keyToBytes returns the pty input for a key press, or null when nothing should
 *  be sent (a bare modifier, a Cmd/Meta chord, or an unmapped combination). */
export function keyToBytes(e: KeyLike): string | null {
    if (e.metaKey) return null; // Cmd chords are shortcuts, not terminal input

    const k = e.key;
    switch (k) {
        case "Shift":
        case "Control":
        case "Alt":
        case "Meta":
        case "CapsLock":
        case "Dead":
            return null;
        case "Enter":
            return "\r";
        case "Tab":
            return e.shiftKey ? "\x1b[Z" : "\t";
        case "Backspace":
            return e.ctrlKey ? "\x08" : "\x7f";
        case "Escape":
            return "\x1b";
    }

    const letter = CSI_LETTER[k];
    if (letter) {
        const m = modCode(e);
        return m === 1 ? `\x1b[${letter}` : `\x1b[1;${m}${letter}`;
    }

    const tilde = CSI_TILDE[k];
    if (tilde) {
        const m = modCode(e);
        return m === 1 ? `\x1b[${tilde}~` : `\x1b[${tilde};${m}~`;
    }

    const ss3 = SS3[k];
    if (ss3) return `\x1bO${ss3}`;

    // A single printable character (one code point).
    if ([...k].length === 1) {
        if (e.ctrlKey) {
            const b = controlByte(k);
            return b === null ? null : String.fromCharCode(b);
        }
        if (e.altKey) return "\x1b" + k; // Alt/Meta prefixes ESC
        return k;
    }

    return null;
}
