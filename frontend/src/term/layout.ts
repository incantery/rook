// The pane-layout tree — pure data, zero DOM, node-testable. A strip
// entry is a WINDOW holding a layout tree whose leaves are PANES; the
// manager owns the runtime objects, view.ts projects this tree into DOM.
// Structural ops are immutable (return a new root) so the projector can
// diff by identity; setWeight mutates in place for drag performance.

/** row = children side-by-side (a vertical divider), col = stacked. */
export type Dir = "row" | "col";

/** What a pane shows — a tagged union on purpose, and every arm now carries
 *  IDENTITY. That asymmetry used to be the bug: `term` named its session (a
 *  host-owned thing a pane merely points at — a buffer in all but name) while
 *  the editor arm named nothing, so a file could only be addressed as "the
 *  window that happens to contain it". Hence a window minted per file.
 *
 *  `file` is a document: a pane can be retargeted from one to another in
 *  place, which is what makes buffers work. `review` is NOT a document and
 *  deliberately has no path — it's a walker over the whole changed set with
 *  its own ‹ › cursor, so it's a surface, not a buffer. The two can't morph
 *  into each other either (different head, diffEditor vs editor).
 *
 *  Neither persists yet: normalize() accepts only `term`, and termOnly()
 *  strips the rest before save. Identity is what a later slice needs to fix
 *  that — a stored `{type:"file", path}` is restorable; `{type:"editor"}` was
 *  not, which is why "an editor-only window has no persistent form". */
export type PaneRef =
    | {type: "term"; session: string}
    | {type: "file"; path: string}
    | {type: "review"}
    /** a claude session as a conversation; `session` is the transcript
     *  session id, not a rook pty session */
    | {type: "agent"; session: string}
    /** an unsent comment. A document like `file` — it carries identity and
     *  holds text being edited — but a TRANSIENT one: it exists only until
     *  :w hands it to the host or :q throws it away, and it is deliberately
     *  its own arm rather than a `file` with a fake path, so the openFile
     *  ladder's `c.type === "file"` retarget predicate can never :e a real
     *  file onto a draft the user is still typing into. */
    | {type: "draft"; id: string};

export interface LeafNode {
    kind: "leaf";
    /** stable pane identity (crypto.randomUUID), persisted — focus and
     *  zoom survive reloads by id, not by tree position */
    id: string;
    content: PaneRef;
}

export interface SplitNode {
    kind: "split";
    dir: Dir;
    /** one weight per child, kept normalized (sum 1); projected to
     *  flex-grow */
    weights: number[];
    children: LayoutNode[];
}

export type LayoutNode = LeafNode | SplitNode;

export interface StoredWindow {
    workspace: string;
    root: LayoutNode;
    /** pane id; reconcile repairs it when the pane didn't survive */
    focused?: string;
}

/** The rook.layout.v1 payload. Window order IS strip order (per
 *  workspace, filtered from the one global list). */
export interface StoredState {
    version: 1;
    windows: StoredWindow[];
}

export interface Rect {
    x: number;
    y: number;
    w: number;
    h: number;
}

export function newLeaf(session: string): LeafNode {
    return {kind: "leaf", id: crypto.randomUUID(), content: {type: "term", session}};
}

export function newFileLeaf(path: string): LeafNode {
    return {kind: "leaf", id: crypto.randomUUID(), content: {type: "file", path}};
}

export function newReviewLeaf(): LeafNode {
    return {kind: "leaf", id: crypto.randomUUID(), content: {type: "review"}};
}

/** Give a leaf a specific share of its parent split, scaling its siblings to
 *  fill the rest. splitAt divides evenly, which is right for two code panes
 *  and wrong for a transient one: a three-line comment does not want half the
 *  window. No-op if the leaf is the root (nothing to take a share of). */
export function setLeafFraction(root: LayoutNode, leafId: string, frac: number): void {
    const f = Math.min(0.9, Math.max(0.1, frac));
    const walk = (node: LayoutNode): boolean => {
        if (node.kind === "leaf") return false;
        const i = node.children.findIndex((c) => c.kind === "leaf" && c.id === leafId);
        if (i >= 0) {
            const rest = 1 - f;
            const others = node.weights.reduce((s, w, j) => (j === i ? s : s + w), 0);
            node.weights = node.weights.map((w, j) =>
                j === i ? f : others > 0 ? (w / others) * rest : rest / (node.weights.length - 1),
            );
            return true;
        }
        return node.children.some(walk);
    };
    walk(root);
}

export function newDraftLeaf(id: string): LeafNode {
    return {kind: "leaf", id: crypto.randomUUID(), content: {type: "draft", id}};
}

/** Point an existing leaf at different content, in place — the pane keeps its
 *  id, so focus, zoom and its position in the tree all survive. This is `:e`:
 *  the viewport stays put and the buffer under it changes. */
export function retarget(root: LayoutNode, paneId: string, content: PaneRef): LayoutNode {
    if (root.kind === "leaf") return root.id === paneId ? {...root, content} : root;
    return {...root, children: root.children.map((c) => retarget(c, paneId, content))};
}

/** The first leaf whose content matches, in ` o cycle order. */
export function findLeafBy(root: LayoutNode, pred: (c: PaneRef) => boolean): LeafNode | null {
    return leaves(root).find((l) => pred(l.content)) ?? null;
}

/** All leaves, in-order — this defines the ` o cycle order. */
export function leaves(root: LayoutNode): LeafNode[] {
    if (root.kind === "leaf") return [root];
    return root.children.flatMap(leaves);
}

export function leafOf(root: LayoutNode, session: string): LeafNode | null {
    return (
        leaves(root).find((l) => l.content.type === "term" && l.content.session === session) ?? null
    );
}

/** The tree with every editor leaf stripped (collapse included) — what
 *  save() persists. Null when nothing survives: an editor-only window
 *  has no persistent form. */
export function termOnly(root: LayoutNode): LayoutNode | null {
    let out: LayoutNode | null = root;
    for (const l of leaves(root)) {
        if (l.content.type === "term") continue;
        if (out === null) return null;
        out = removeAt(out, l.id).root;
    }
    return out;
}

export function findLeaf(root: LayoutNode, paneId: string): LeafNode | null {
    return leaves(root).find((l) => l.id === paneId) ?? null;
}

function normalized(weights: number[]): number[] {
    const sum = weights.reduce((a, b) => a + b, 0);
    return weights.map((w) => w / sum);
}

/** Split the target pane in two — tmux semantics: the target halves and
 *  the new leaf takes the second half. If the target's parent already
 *  splits in `dir`, the new leaf slots in right after it (no wrapper);
 *  otherwise the target wraps in a fresh 50/50 split. Unknown paneId
 *  returns the root unchanged. */
export function splitAt(root: LayoutNode, paneId: string, dir: Dir, leaf: LeafNode): LayoutNode {
    if (root.kind === "leaf") {
        if (root.id !== paneId) return root;
        return {kind: "split", dir, weights: [0.5, 0.5], children: [root, leaf]};
    }
    const i = root.children.findIndex((c) => c.kind === "leaf" && c.id === paneId);
    if (i !== -1 && root.dir === dir) {
        const weights = root.weights.slice();
        const children = root.children.slice();
        const half = weights[i] / 2;
        weights.splice(i, 1, half, half);
        children.splice(i + 1, 0, leaf);
        return {...root, weights, children};
    }
    return {...root, children: root.children.map((c) => splitAt(c, paneId, dir, leaf))};
}

/** Remove a pane. The freed weight redistributes proportionally across
 *  the surviving siblings; a split left with one child splices up.
 *  `neighbor` is the absorbing sibling's first leaf — the focus landing
 *  pad when the focused pane dies. Removing the last pane returns a
 *  null root; unknown paneId returns the root unchanged. */
export function removeAt(
    root: LayoutNode,
    paneId: string,
): {root: LayoutNode | null; neighbor: LeafNode | null} {
    if (root.kind === "leaf") {
        if (root.id === paneId) return {root: null, neighbor: null};
        return {root, neighbor: null};
    }
    let neighbor: LeafNode | null = null;
    let found = false;
    const walk = (node: SplitNode): LayoutNode => {
        const i = node.children.findIndex((c) => c.kind === "leaf" && c.id === paneId);
        if (i !== -1) {
            found = true;
            const children = node.children.filter((_, j) => j !== i);
            if (children.length === 1) {
                neighbor = leaves(children[0])[0];
                return children[0];
            }
            const weights = normalized(node.weights.filter((_, j) => j !== i));
            neighbor = leaves(children[Math.min(i, children.length - 1)])[0];
            return {...node, weights, children};
        }
        const children = node.children.map((c) => (c.kind === "split" && !found ? walk(c) : c));
        return found ? {...node, children} : node;
    };
    const out = walk(root);
    return found ? {root: out, neighbor} : {root, neighbor: null};
}

/** Unit-square geometry of every pane — the basis for directional focus.
 *  Divider thickness is ignored; it's a rounding error at this level. */
export function rects(root: LayoutNode): Map<string, Rect> {
    const out = new Map<string, Rect>();
    const walk = (node: LayoutNode, r: Rect): void => {
        if (node.kind === "leaf") {
            out.set(node.id, r);
            return;
        }
        let off = 0;
        node.children.forEach((c, i) => {
            const w = node.weights[i];
            walk(
                c,
                node.dir === "row"
                    ? {x: r.x + off * r.w, y: r.y, w: w * r.w, h: r.h}
                    : {x: r.x, y: r.y + off * r.h, w: r.w, h: w * r.h},
            );
            off += w;
        });
    };
    walk(root, {x: 0, y: 0, w: 1, h: 1});
    return out;
}

export type Edge = "left" | "right" | "up" | "down";

/** The pane across the shared edge in that direction: prefer the
 *  candidate whose cross-axis span contains our center, else the one
 *  with the most overlap. Null at the layout's edge — no wrap (tmux
 *  default). */
export function neighborOf(root: LayoutNode, paneId: string, dir: Edge): string | null {
    const all = rects(root);
    const r = all.get(paneId);
    if (!r) return null;
    const eps = 1e-6;
    const horizontal = dir === "left" || dir === "right";
    const edge =
        dir === "left" ? r.x : dir === "right" ? r.x + r.w : dir === "up" ? r.y : r.y + r.h;
    const center = horizontal ? r.y + r.h / 2 : r.x + r.w / 2;
    let best: string | null = null;
    let bestOverlap = -1;
    for (const [id, c] of all) {
        if (id === paneId) continue;
        const cEdge = horizontal
            ? dir === "left"
                ? c.x + c.w
                : c.x
            : dir === "up"
              ? c.y + c.h
              : c.y;
        if (Math.abs(cEdge - edge) > eps) continue;
        const [lo, hi] = horizontal ? [c.y, c.y + c.h] : [c.x, c.x + c.w];
        if (center > lo - eps && center < hi + eps) return id; // contains our center
        const overlap = horizontal
            ? Math.min(hi, r.y + r.h) - Math.max(lo, r.y)
            : Math.min(hi, r.x + r.w) - Math.max(lo, r.x);
        if (overlap > bestOverlap) {
            bestOverlap = overlap;
            best = id;
        }
    }
    return bestOverlap > eps ? best : null;
}

/** Shift weight between children i and i+1 (positive grows i), clamping
 *  both above minFrac. MUTATES — the drag path runs at pointer rate. */
export function setWeight(split: SplitNode, i: number, deltaFrac: number, minFrac: number): void {
    const a = split.weights[i];
    const b = split.weights[i + 1];
    if (a === undefined || b === undefined || a + b < 2 * minFrac) return;
    const d = Math.min(Math.max(deltaFrac, minFrac - a), b - minFrac);
    split.weights[i] = a + d;
    split.weights[i + 1] = b - d;
}

/** Parse untrusted localStorage into a StoredState. A malformed window
 *  drops; unusable data returns null — corrupt state fails open to
 *  all-single-pane, never to a broken boot. */
export function normalize(data: unknown): StoredState | null {
    if (typeof data !== "object" || data === null) return null;
    const d = data as {version?: unknown; windows?: unknown};
    if (d.version !== 1 || !Array.isArray(d.windows)) return null;
    const seen = new Set<string>(); // pane ids are unique ACROSS windows
    const validNode = (n: unknown): n is LayoutNode => {
        if (typeof n !== "object" || n === null) return false;
        const node = n as Record<string, unknown>;
        if (node.kind === "leaf") {
            const c = node.content as Record<string, unknown> | undefined;
            if (typeof node.id !== "string" || node.id === "" || seen.has(node.id)) return false;
            if (typeof c !== "object" || c === null) return false;
            if (c.type !== "term" || typeof c.session !== "string" || c.session === "")
                return false;
            seen.add(node.id);
            return true;
        }
        if (node.kind !== "split") return false;
        if (node.dir !== "row" && node.dir !== "col") return false;
        if (!Array.isArray(node.children) || node.children.length < 2) return false;
        if (!Array.isArray(node.weights) || node.weights.length !== node.children.length)
            return false;
        if (!node.weights.every((w) => typeof w === "number" && Number.isFinite(w) && w > 0))
            return false;
        return node.children.every(validNode);
    };
    const windows: StoredWindow[] = [];
    for (const w of d.windows) {
        if (typeof w !== "object" || w === null) continue;
        const win = w as Record<string, unknown>;
        if (typeof win.workspace !== "string" || win.workspace === "") continue;
        const before = new Set(seen); // a rejected window's ids must not block later ones
        if (!validNode(win.root)) {
            for (const id of seen) if (!before.has(id)) seen.delete(id);
            continue;
        }
        windows.push({
            workspace: win.workspace,
            root: renormalize(win.root),
            focused: typeof win.focused === "string" ? win.focused : undefined,
        });
    }
    return {version: 1, windows};
}

/** Re-balance every split's weights to sum 1 (stored floats drift). */
function renormalize(node: LayoutNode): LayoutNode {
    if (node.kind === "leaf") return node;
    return {...node, weights: normalized(node.weights), children: node.children.map(renormalize)};
}

/** Marry stored layout to the host's live session list — the host is
 *  truth. Leaves pointing at dead sessions, at sessions already claimed
 *  by an earlier window, or at sessions the host moved to another
 *  workspace are pruned (with collapse); emptied windows drop; focus
 *  falls back to the first leaf. Live sessions no window claimed append
 *  as single-pane windows in host list order. */
export function reconcile(
    stored: StoredState | null,
    sessions: {id: string; workspace: string}[],
): StoredWindow[] {
    const ws = new Map(sessions.map((s) => [s.id, s.workspace || "main"]));
    const claimed = new Set<string>();
    const out: StoredWindow[] = [];
    for (const win of stored?.windows ?? []) {
        let root: LayoutNode | null = win.root;
        for (const l of leaves(win.root)) {
            // editor leaves can't come out of storage (normalize rejects
            // them) — prune defensively anyway, the fail-open path
            if (l.content.type === "term") {
                const sid = l.content.session;
                if (ws.get(sid) === win.workspace && !claimed.has(sid)) {
                    claimed.add(sid);
                    continue;
                }
            }
            root = root === null ? null : removeAt(root, l.id).root;
        }
        if (root === null) continue;
        const ids = new Set(leaves(root).map((l) => l.id));
        const focused = win.focused && ids.has(win.focused) ? win.focused : leaves(root)[0].id;
        out.push({workspace: win.workspace, root, focused});
    }
    for (const s of sessions) {
        if (claimed.has(s.id)) continue;
        const leaf = newLeaf(s.id);
        out.push({workspace: s.workspace || "main", root: leaf, focused: leaf.id});
    }
    return out;
}
