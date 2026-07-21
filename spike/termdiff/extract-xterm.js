// The reference oracle: feed a corpus capture into headless xterm.js — the
// SAME emulator version the app ships (6.0.0) — at the capture's geometry, and
// emit its grid as normalized JSON. termdiff diffs a candidate Go emulator's
// grid against this. Whatever xterm renders is, by definition, what rook shows
// today, so this is ground truth for "did the Go emulator agree".
//
//   node extract-xterm.js ../corpus/nvim-edit.raw > /tmp/nvim.xterm.json
//
// Emits {name, cols, rows, cells}: cells[y][x] = {c,w,fg,bg,attrs} for the
// VISIBLE screen (the active buffer — alt-screen when a full-screen app owns
// it), which is what the two emulators must agree on.

import {readFileSync} from "node:fs";
import pkg from "@xterm/headless"; // CommonJS: no named exports
const {Terminal} = pkg;

const rawPath = process.argv[2];
if (!rawPath) {
    console.error("usage: node extract-xterm.js <capture.raw>");
    process.exit(2);
}
const metaPath = rawPath.replace(/\.raw$/, ".meta.json");
const meta = JSON.parse(readFileSync(metaPath, "utf8"));
const bytes = readFileSync(rawPath);

const term = new Terminal({
    cols: meta.cols,
    rows: meta.rows,
    allowProposedApi: true, // getFgColor & friends live behind this
    scrollback: 2000,
});

/** a cell's colour as a stable token: "d" default, "p<n>" palette, "#rrggbb" */
function color(isDefault, isPalette, isRGB, raw) {
    if (isDefault) return "d";
    if (isPalette) return `p${raw}`;
    if (isRGB) return `#${(raw & 0xffffff).toString(16).padStart(6, "0")}`;
    return "d";
}

function extract() {
    const buf = term.buffer.active;
    const cells = [];
    const cell = buf.getNullCell?.() ?? undefined;
    for (let y = 0; y < meta.rows; y++) {
        const line = buf.getLine(buf.baseY + y);
        const row = [];
        for (let x = 0; x < meta.cols; x++) {
            const cc = line ? line.getCell(x, cell) : undefined;
            if (!cc) {
                row.push({c: " ", w: 1, fg: "d", bg: "d", a: ""});
                continue;
            }
            const attrs =
                (cc.isBold() ? "B" : "") +
                (cc.isItalic() ? "I" : "") +
                (cc.isUnderline() ? "U" : "") +
                (cc.isInverse() ? "R" : "") +
                (cc.isDim() ? "D" : "") +
                (cc.isStrikethrough() ? "S" : "");
            row.push({
                c: cc.getChars() || " ",
                w: cc.getWidth(),
                fg: color(cc.isFgDefault(), cc.isFgPalette(), cc.isFgRGB(), cc.getFgColor()),
                bg: color(cc.isBgDefault(), cc.isBgPalette(), cc.isBgRGB(), cc.getBgColor()),
                a: attrs,
            });
        }
        cells.push(row);
    }
    return cells;
}

await new Promise((resolve) => term.write(bytes, resolve));
const cells = extract();
process.stdout.write(JSON.stringify({name: meta.name, cols: meta.cols, rows: meta.rows, cells}));
term.dispose();
