// Scrollback harness for the Playwright test (bench/vt-scroll.spec.ts). It feeds
// the renderer 20 numbered lines through a 4-row screen — the first four fill
// it, the rest arrive as scroll frames — so lines L0..L15 land in scrollback and
// L16..L19 stay live. The test then scrolls the viewport and reads back the
// visible rows.

import type {Run, WCell} from "../src/term/vt/frame";
import {GridRenderer} from "../src/term/vt/renderer";
import "../src/term/vt/renderer.css";

const COLS = 20;
const ROWS = 4;

function run(text: string): Run {
    const cells: WCell[] = [...text].map((ch) => ({content: ch, fg: 0, bg: 0, attr: 0, width: 1}));
    return {x: 0, cells};
}

const container = document.getElementById("screen")!;
const renderer = new GridRenderer(container, COLS, ROWS);

for (let i = 0; i < 20; i++) {
    if (i < ROWS) {
        renderer.applyFrame({
            cursor: {x: 0, y: i, visible: true},
            scroll: 0,
            rows: [{y: i, runs: [run("L" + i)]}],
        });
    } else {
        // each further line scrolls one off the top and writes a new bottom row
        renderer.applyFrame({
            cursor: {x: 0, y: ROWS - 1, visible: true},
            scroll: 1,
            rows: [{y: ROWS - 1, runs: [run("L" + i)]}],
        });
    }
}

declare global {
    interface Window {
        visibleRows: () => string[];
        scrollBack: (n: number) => void;
        toBottom: () => void;
        scrollOffset: () => number;
    }
}

window.visibleRows = () =>
    Array.from(container.querySelectorAll(".vt-row")).map((el) => (el.textContent || "").trimEnd());
window.scrollBack = (n) => renderer.scrollLines(n);
window.toBottom = () => renderer.scrollToBottom();
window.scrollOffset = () => renderer.scrollOffset;
