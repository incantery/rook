import {describe, expect, it} from "vitest";

import {counts, group, match, move, rows, short, type DeckRow} from "./deck";
import type {OverviewItem} from "./hostapi";

/** Minimal overview item — only the fields the deck reads. */
function ws(name: string, agents: OverviewItem["agents"], extra: Partial<OverviewItem> = {}) {
    return {
        name,
        created: "2026-07-01T00:00:00Z",
        lastUsed: "2026-07-15T00:00:00Z",
        sessions: agents?.length ?? 0,
        agents,
        ...extra,
    } as OverviewItem;
}

function row(p: Partial<DeckRow> = {}): DeckRow {
    return {key: "k", workspace: "rook", state: "quiet", title: "t", ...p};
}

describe("rows", () => {
    it("flattens agents out of their workspaces", () => {
        const r = rows([
            ws("rook", [{state: "working", title: "a"}]),
            ws("web", [
                {state: "quiet", title: "b"},
                {state: "working", title: "c"},
            ]),
        ]);
        expect(r.map((x) => x.title)).toEqual(["a", "c", "b"]);
        expect(r.map((x) => x.workspace)).toEqual(["rook", "web", "web"]);
    });

    it("orders needs_input first, then working, then quiet", () => {
        const r = rows([
            ws("a", [{state: "quiet", title: "q"}]),
            ws("b", [{state: "needs_input", title: "n"}]),
            ws("c", [{state: "working", title: "w"}]),
        ]);
        expect(r.map((x) => x.title)).toEqual(["n", "w", "q"]);
    });

    it("breaks ties by most recent activity", () => {
        const r = rows([
            ws("a", [
                {state: "working", title: "older", lastEvent: "2026-07-15T10:00:00Z"},
                {state: "working", title: "newer", lastEvent: "2026-07-15T12:00:00Z"},
            ]),
        ]);
        expect(r.map((x) => x.title)).toEqual(["newer", "older"]);
    });

    it("carries both ids so a row can be opened either way", () => {
        const [r] = rows([
            ws("rook", [{state: "working", title: "t", sessionId: "tx", rookSession: "pty1"}]),
        ]);
        expect(r.session).toBe("tx");
        expect(r.rookSession).toBe("pty1");
    });

    it("keeps an uncorrelated agent, minus the verb it can't reach", () => {
        // An agent with no pty is still real. Dropping it would hide a
        // working claude for the sole reason that rook couldn't guess its
        // window — the row renders, raw attach is what goes away.
        const [r] = rows([ws("rook", [{state: "working", title: "t", sessionId: "tx"}])]);
        expect(r.session).toBe("tx");
        expect(r.rookSession).toBeUndefined();
    });

    it("keys by transcript id, which survives re-correlation to a new pty", () => {
        const [before] = rows([
            ws("rook", [{state: "working", sessionId: "tx", rookSession: "p1"}]),
        ]);
        const [after] = rows([
            ws("rook", [{state: "working", sessionId: "tx", rookSession: "p2"}]),
        ]);
        expect(before.key).toBe(after.key);
    });

    it("gives idless rows distinct keys instead of colliding", () => {
        // What an old daemon sends for every row: no ids at all. Colliding
        // keys would make the list render one row and drop the rest.
        const r = rows([ws("rook", [{state: "working"}, {state: "working"}])]);
        expect(r[0].key).not.toBe(r[1].key);
    });

    it("falls back through ask then tool before calling a row untitled", () => {
        const r = rows([
            ws("a", [{state: "needs_input", ask: "Keep the legacy export?"}]),
            ws("b", [{state: "working", tool: "Edit"}]),
            ws("c", [{state: "quiet"}]),
        ]);
        expect(r.map((x) => x.title)).toEqual([
            "Keep the legacy export?",
            "Edit",
            "untitled session",
        ]);
    });

    it("carries the workspace's lineage onto the row", () => {
        const [r] = rows([
            ws("rook-fix", [{state: "working"}], {worktreeOf: "rook", branch: "rook/fix"}),
        ]);
        expect(r.worktreeOf).toBe("rook");
        expect(r.branch).toBe("rook/fix");
    });

    it("survives a workspace with no agents", () => {
        expect(rows([ws("idle", undefined)])).toEqual([]);
    });
});

describe("counts", () => {
    it("counts each state and the total", () => {
        const r = rows([
            ws("a", [{state: "needs_input"}, {state: "working"}]),
            ws("b", [{state: "working"}, {state: "quiet"}]),
        ]);
        expect(counts(r)).toEqual({all: 4, needs_input: 1, working: 2, quiet: 1});
    });
});

describe("match", () => {
    const r = row({
        title: "Migrate charts to design tokens",
        workspace: "web-dashboard",
        branch: "rook/chart-tokens",
        state: "needs_input",
        model: "opus",
    });

    it("matches free text anywhere in the row", () => {
        expect(match(r, "charts")).toBe(true);
        expect(match(r, "dashboard")).toBe(true);
        expect(match(r, "chart-tokens")).toBe(true);
        expect(match(r, "nonsense")).toBe(false);
    });

    it("is case-insensitive", () => {
        expect(match(r, "MIGRATE")).toBe(true);
    });

    it("requires every term, so typing more only narrows", () => {
        expect(match(r, "charts opus")).toBe(true);
        expect(match(r, "charts sonnet")).toBe(false);
    });

    it("narrows by state, long form or short", () => {
        expect(match(r, "state:needs_input")).toBe(true);
        expect(match(r, "state:needs")).toBe(true);
        expect(match(r, "state:working")).toBe(false);
    });

    it("narrows by workspace under either spelling", () => {
        expect(match(r, "ws:web")).toBe(true);
        expect(match(r, "project:web")).toBe(true);
        expect(match(r, "ws:payments")).toBe(false);
    });

    it("treats an unknown prefix as plain text, so a typo finds nothing", () => {
        // The dangerous alternative is silently ignoring the term and
        // matching everything — a filter that lies about what it filtered.
        expect(match(r, "stat:needs")).toBe(false);
    });

    it("matches everything when empty or blank", () => {
        expect(match(r, "")).toBe(true);
        expect(match(r, "   ")).toBe(true);
    });
});

describe("group", () => {
    it("groups by workspace and floats the most urgent group up", () => {
        const r = rows([
            ws("quiet-ws", [{state: "quiet", title: "q"}]),
            ws("busy-ws", [{state: "working", title: "w"}]),
            ws("blocked-ws", [{state: "needs_input", title: "n"}]),
        ]);
        expect(group(r).map((g) => g.workspace)).toEqual(["blocked-ws", "busy-ws", "quiet-ws"]);
    });

    it("keeps triage order inside a group", () => {
        const r = rows([
            ws("rook", [
                {state: "quiet", title: "q"},
                {state: "needs_input", title: "n"},
            ]),
        ]);
        const [g] = group(r);
        expect(g.rows.map((x) => x.title)).toEqual(["n", "q"]);
    });
});

describe("move", () => {
    it("steps within the list", () => {
        expect(move(0, 1, 5)).toBe(1);
        expect(move(3, -1, 5)).toBe(2);
    });

    it("clamps rather than wrapping", () => {
        // Wrapping from the bottom lands you on the first row — most likely
        // the one you just acted on, and on this screen acting is destructive.
        expect(move(4, 1, 5)).toBe(4);
        expect(move(0, -1, 5)).toBe(0);
    });

    it("takes big jumps (gg / G / half-page)", () => {
        expect(move(0, 999, 5)).toBe(4);
        expect(move(4, -999, 5)).toBe(0);
    });

    it("returns 0 for an empty list so callers need no special case", () => {
        expect(move(0, 1, 0)).toBe(0);
    });
});

describe("short", () => {
    it("labels every state in the same width", () => {
        const labels = (["needs_input", "working", "quiet"] as const).map(short);
        expect(labels).toEqual(["needs", "works", "quiet"]);
        expect(new Set(labels.map((l) => l.length)).size).toBe(1);
    });
});
