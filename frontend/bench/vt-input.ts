// Input + resize harness for the Playwright test (bench/vt-input.spec.ts). Mounts
// the real renderer with an onInput sink, so the test can press real keys and
// read back the exact pty bytes the renderer forwarded, and resize the grid and
// check the DOM reshaped.

import type {Frame, Run, WCell} from "../src/term/vt/frame";
import {GridRenderer} from "../src/term/vt/renderer";
import "../src/term/vt/renderer.css";

const COLS = 20;
const ROWS = 4;

function run(text: string): Run {
    const cells: WCell[] = [...text].map((ch) => ({content: ch, fg: 0, bg: 0, attr: 0, width: 1}));
    return {x: 0, cells};
}

const sent: string[] = [];
const container = document.getElementById("screen")!;
const renderer = new GridRenderer(container, COLS, ROWS, {
    onInput: (data) => sent.push(data),
});
container.focus();

declare global {
    interface Window {
        sentInput: () => string[];
        clearInput: () => void;
        doResize: (cols: number, rows: number) => void;
        gridSize: () => {cols: number; rows: number; rowEls: number};
        applyRow: (y: number, text: string) => void;
        rowText: (y: number) => string;
    }
}

window.sentInput = () => sent.slice();
window.clearInput = () => {
    sent.length = 0;
};
window.doResize = (cols, rows) => renderer.resize(cols, rows);
window.gridSize = () => ({
    cols: renderer.grid.cols,
    rows: renderer.grid.rows,
    rowEls: container.querySelectorAll(".vt-row").length,
});
window.applyRow = (y, text) => {
    const f: Frame = {cursor: {x: 0, y, visible: true}, scroll: 0, rows: [{y, runs: [run(text)]}]};
    renderer.applyFrame(f);
};
window.rowText = (y) => (container.querySelectorAll(".vt-row")[y]?.textContent || "").trimEnd();
