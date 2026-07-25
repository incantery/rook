import {describe, expect, it} from "vitest";
import {splitAt, type LayoutNode, type LeafNode} from "./layout";

// splitAt's `before` flag — the primitive behind putting the file tree on
// the LEFT of what it opens. The two paths through the function place the
// leaf differently (wrap a lone leaf vs splice into an existing row), so
// both need holding down: an off-by-one here puts the tree on the wrong
// side, which is a pane the user has to move every single time.

const leaf = (id: string, session: string): LeafNode => ({
    kind: "leaf",
    id,
    content: {type: "term", session},
});

const tree: LeafNode = {kind: "leaf", id: "T", content: {type: "tree"}};

const ids = (n: LayoutNode): string[] =>
    n.kind === "leaf" ? [n.id] : n.children.flatMap(ids);

describe("splitAt", () => {
    it("wraps a lone leaf with the new pane after by default", () => {
        expect(ids(splitAt(leaf("a", "s1"), "a", "row", tree))).toEqual(["a", "T"]);
    });

    it("wraps a lone leaf with the new pane BEFORE when asked", () => {
        expect(ids(splitAt(leaf("a", "s1"), "a", "row", tree, true))).toEqual(["T", "a"]);
    });

    it("splices into an existing row after the target", () => {
        const root: LayoutNode = {
            kind: "split",
            dir: "row",
            weights: [0.5, 0.5],
            children: [leaf("a", "s1"), leaf("b", "s2")],
        };
        expect(ids(splitAt(root, "b", "row", tree))).toEqual(["a", "b", "T"]);
    });

    it("splices into an existing row BEFORE the target", () => {
        const root: LayoutNode = {
            kind: "split",
            dir: "row",
            weights: [0.5, 0.5],
            children: [leaf("a", "s1"), leaf("b", "s2")],
        };
        // ahead of b, not ahead of the whole row — the tree belongs to the
        // pane it was opened from, not to the window
        expect(ids(splitAt(root, "b", "row", tree, true))).toEqual(["a", "T", "b"]);
    });

    it("halves the target's weight either way, leaving the row normalized", () => {
        const root: LayoutNode = {
            kind: "split",
            dir: "row",
            weights: [0.5, 0.5],
            children: [leaf("a", "s1"), leaf("b", "s2")],
        };
        const out = splitAt(root, "b", "row", tree, true);
        if (out.kind !== "split") throw new Error("expected a split");
        expect(out.weights).toEqual([0.5, 0.25, 0.25]);
        expect(out.weights.reduce((x, y) => x + y, 0)).toBeCloseTo(1);
    });

    it("recurses into nested splits and leaves an unknown id alone", () => {
        const root: LayoutNode = {
            kind: "split",
            dir: "col",
            weights: [0.5, 0.5],
            children: [
                leaf("a", "s1"),
                {kind: "split", dir: "row", weights: [1], children: [leaf("b", "s2")]},
            ],
        };
        expect(ids(splitAt(root, "b", "row", tree, true))).toEqual(["a", "T", "b"]);
        expect(ids(splitAt(root, "nope", "row", tree, true))).toEqual(["a", "b"]);
    });
});
