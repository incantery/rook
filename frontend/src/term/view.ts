// The window projector — layout tree → DOM scaffolding. Part of the
// imperative island: the manager calls project() on structural change,
// and the scaffolding (.split/.pane/.divider) is rebuilt around the
// LIVE .term-wrap elements, which appendChild MOVES — pane content is
// never cloned or destroyed here (DOM removal stays the manager's
// session-death path). Weight-only changes (divider drag) mutate
// flex-grow in place, no rebuild.

import type {LayoutNode, SplitNode} from "./layout";

/** thickness of the divider hit area (CSS keeps the visible line 1px) */
const DIVIDER_PX = 6;
/** a pane can't be dragged below this along the split axis */
const MIN_PANE_PX = 80;

export interface ViewHooks {
    /** capture-phase mousedown on a pane, NO preventDefault — xterm's
     *  own focus flow must proceed; this only routes pane focus */
    onFocusPane(paneId: string): void;
    /** divider drag: dxFrac is the TOTAL fraction moved since drag
     *  start (the manager resets to drag-start weights, then applies —
     *  clamping stays cursor-true). Mutates split.weights. */
    onDrag(split: SplitNode, i: number, dxFrac: number, minFrac: number): void;
    /** pointer released: final fit + persist */
    onDragEnd(): void;
}

/** What project() needs of a window — structurally satisfied by the
 *  manager's Win (a type here would import the manager circularly). */
export interface ViewWin {
    root: LayoutNode;
    panes: Map<string, {readonly el: HTMLElement}>;
    focused: string;
    zoomed: string | null;
    el: HTMLElement;
    /** paneId → .pane cell, rebuilt by project() */
    cells: Map<string, HTMLElement>;
}

/** Rebuild the window's scaffolding from its layout tree. Live pane
 *  content is moved into the fresh cells before the old scaffolding is
 *  dropped — the build happens while the old tree is still attached, so
 *  appendChild reparents without a detached moment. */
export function project(win: ViewWin, hooks: ViewHooks): void {
    win.cells.clear();
    const tree = build(win, win.root, hooks);
    win.el.replaceChildren(tree);
    // the focused accent only means something with siblings to lose to
    win.el.classList.toggle("multi", win.cells.size > 1);
    applyFocus(win);
    applyZoom(win);
}

/** Toggle the .focused cell — cheap, no rebuild (click, ` o, ` arrows). */
export function applyFocus(win: ViewWin): void {
    for (const [id, cell] of win.cells) cell.classList.toggle("focused", id === win.focused);
}

/** Toggle zoom classes — visibility-based (hidden siblings keep their
 *  dimensions, so fit stays truthful), no rebuild. */
export function applyZoom(win: ViewWin): void {
    win.el.classList.toggle("zoomed", win.zoomed !== null);
    for (const [id, cell] of win.cells) cell.classList.toggle("zoom", id === win.zoomed);
}

function build(win: ViewWin, node: LayoutNode, hooks: ViewHooks): HTMLElement {
    if (node.kind === "leaf") {
        const cell = document.createElement("div");
        cell.className = "pane";
        const content = win.panes.get(node.id);
        if (content) cell.appendChild(content.el);
        cell.addEventListener("mousedown", () => hooks.onFocusPane(node.id), {capture: true});
        win.cells.set(node.id, cell);
        return cell;
    }
    const el = document.createElement("div");
    el.className = node.dir === "row" ? "split split-row" : "split split-col";
    node.children.forEach((child, i) => {
        if (i > 0) el.appendChild(divider(node, i - 1, hooks));
        const cell = build(win, child, hooks);
        cell.style.flexGrow = String(node.weights[i]);
        el.appendChild(cell);
    });
    return el;
}

function divider(split: SplitNode, i: number, hooks: ViewHooks): HTMLElement {
    const d = document.createElement("div");
    d.className = "divider";
    d.addEventListener("pointerdown", (e: PointerEvent) => {
        e.preventDefault();
        d.setPointerCapture(e.pointerId);
        d.classList.add("dragging");
        const horizontal = split.dir === "row";
        const parent = d.parentElement as HTMLElement;
        const rect = parent.getBoundingClientRect();
        // weights map onto the axis MINUS the fixed dividers — flex
        // distributes only the leftover, so fractions must too
        const axisPx =
            (horizontal ? rect.width : rect.height) - (split.children.length - 1) * DIVIDER_PX;
        const minFrac = axisPx > 0 ? MIN_PANE_PX / axisPx : 0;
        const start = horizontal ? e.clientX : e.clientY;
        const prev = d.previousElementSibling as HTMLElement;
        const next = d.nextElementSibling as HTMLElement;
        const move = (ev: PointerEvent) => {
            if (axisPx <= 0) return;
            const dxFrac = ((horizontal ? ev.clientX : ev.clientY) - start) / axisPx;
            hooks.onDrag(split, i, dxFrac, minFrac);
            prev.style.flexGrow = String(split.weights[i]);
            next.style.flexGrow = String(split.weights[i + 1]);
        };
        const up = () => {
            d.classList.remove("dragging");
            d.removeEventListener("pointermove", move);
            d.removeEventListener("pointerup", up);
            d.removeEventListener("pointercancel", up);
            hooks.onDragEnd();
        };
        d.addEventListener("pointermove", move);
        d.addEventListener("pointerup", up);
        d.addEventListener("pointercancel", up);
    });
    return d;
}
