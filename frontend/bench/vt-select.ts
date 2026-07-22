// Interaction harness for the selection/copy Playwright test (bench/
// vt-select.spec.ts). Mounts the real renderer with known content and exposes
// helpers so the test can drive real mouse drags at exact cell coordinates and
// read back what got selected.

import type {Frame, WCell} from "../src/term/vt/frame";
import {GridRenderer} from "../src/term/vt/renderer";
import "../src/term/vt/renderer.css";

const COLS = 40;
const LINES = ["hello world", "second line here", "foo(bar) baz"];

function textFrame(lines: string[]): Frame {
    const rows = lines.map((text, y) => {
        const cells: WCell[] = [...text].map((ch) => ({
            content: ch,
            fg: 0,
            bg: 0,
            attr: 0,
            width: 1,
        }));
        return {y, runs: [{x: 0, cells}]};
    });
    return {cursor: {x: 0, y: 0, visible: true}, rows};
}

const container = document.getElementById("screen")!;
const renderer = new GridRenderer(container, COLS, LINES.length);
renderer.applyFrame(textFrame(LINES));

declare global {
    interface Window {
        cellCenter: (x: number, y: number) => {x: number; y: number};
        getSel: () => string;
    }
}

// pixel center of cell (x,y), for page.mouse to aim at
window.cellCenter = (x, y) => {
    const rect = container.getBoundingClientRect();
    const {w, h} = renderer.cellSize();
    return {x: rect.left + (x + 0.5) * w, y: rect.top + (y + 0.5) * h};
};

window.getSel = () => renderer.getSelectedText();
