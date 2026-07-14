// Build an xterm.js ITheme from a Palette. The background stays transparent —
// the page body paints the tint once, full-bleed, at the config's opacity
// (main.ts), exactly as today. Every ITheme key is optional; we set the ones
// rook has always set plus the full 16-colour ANSI ramp from palette.ansi.

import type {ITheme} from "@xterm/xterm";
import type {Palette} from "./palette";

export function buildXtermTheme(p: Palette): ITheme {
    const a = p.ansi;
    return {
        background: "#00000000", // body paints the tint; terminal stays clear
        foreground: p.editorFg,
        cursor: p.cursor,
        cursorAccent: p.bg,
        selectionBackground: p.selection,
        black: a[0],
        red: a[1],
        green: a[2],
        yellow: a[3],
        blue: a[4],
        magenta: a[5],
        cyan: a[6],
        white: a[7],
        brightBlack: a[8],
        brightRed: a[9],
        brightGreen: a[10],
        brightYellow: a[11],
        brightBlue: a[12],
        brightMagenta: a[13],
        brightCyan: a[14],
        brightWhite: a[15],
    };
}
