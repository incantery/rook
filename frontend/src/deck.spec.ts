import {describe, expect, it} from "vitest";

import {
    counts,
    cycle,
    group,
    inTab,
    isAgentTab,
    match,
    move,
    rows,
    short,
    TABS,
    type DeckRow,
    type Tab,
} from "./deck";
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

    it("renders a row the host gave no ids for, minus the verbs", () => {
        // The old-daemon case, which is the only way an id goes missing: a
        // current host only emits agents it correlated to a live window, so it
        // always sends both. rows() must not gate on their presence — the row
        // renders and Home drops the verb it can't reach.
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

    it("reads a zero date as no activity, not as 739812d ago", () => {
        // Go's zero time.Time marshals to this, and it is a truthy STRING —
        // so every `lastEvent ? ago(lastEvent) : ""` guard sails past it and
        // renders two millennia into a 56px column. Date.parse gives a big
        // negative number here, not NaN, so that check doesn't catch it either.
        const [r] = rows([ws("a", [{state: "working", lastEvent: "0001-01-01T00:00:00Z"}])]);
        expect(r.lastEvent).toBeUndefined();
    });

    it("keeps a real timestamp verbatim", () => {
        const [r] = rows([ws("a", [{state: "working", lastEvent: "2026-07-15T12:00:00Z"}])]);
        expect(r.lastEvent).toBe("2026-07-15T12:00:00Z");
    });

    it("files a state this build has never heard of under working, never quiet", () => {
        // The host types state as a bare string; a newer daemon could add one.
        // quiet is the bucket you ignore — the one label we must never apply
        // by accident — and an unranked state also NaNs the sort comparator.
        const [r] = rows([ws("a", [{state: "planning" as never}])]);
        expect(r.state).toBe("working");
    });

    it("does not let an unknown state poison the tally", () => {
        const r = rows([
            ws("a", [{state: "planning" as never}, {state: "needs_input"}, {state: "quiet"}]),
        ]);
        expect(counts(r)).toEqual({all: 3, needs_input: 1, working: 1, quiet: 1});
    });

    it("does not let an unknown state scramble the order", () => {
        const r = rows([
            ws("a", [
                {state: "planning" as never, title: "u"},
                {state: "needs_input", title: "n"},
            ]),
        ]);
        // NaN out of the comparator makes sort order arbitrary — needs_input
        // must still lead.
        expect(r[0].title).toBe("n");
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

    it("does not hide anything while you are still typing a field term", () => {
        // A bare `state:` matching everything looks like the typo case above,
        // but it isn't: it's the keystroke on the way to `state:needs`.
        // Failing it closed would make the list flash empty mid-word. The
        // invariant that matters — typing more only narrows — still holds.
        expect(match(r, "state:")).toBe(true);
        expect(match(r, "ws:")).toBe(true);
    });
});

describe("group", () => {
    // Feed group() RAW rows, never rows() output. The earlier version of these
    // tests piped rows() in, which sorts before group() ever sees anything —
    // so group()'s own sorting was dead code and deleting it left the tests
    // green. Unsorted input is the only input that can fail.
    it("floats the most urgent group up, from unsorted input", () => {
        const g = group([
            row({workspace: "quiet-ws", state: "quiet"}),
            row({workspace: "blocked-ws", state: "needs_input"}),
            row({workspace: "busy-ws", state: "working"}),
        ]);
        expect(g.map((x) => x.workspace)).toEqual(["blocked-ws", "busy-ws", "quiet-ws"]);
    });

    it("sorts inside a group too, from unsorted input", () => {
        const [g] = group([
            row({workspace: "rook", state: "quiet", title: "q"}),
            row({workspace: "rook", state: "needs_input", title: "n"}),
            row({workspace: "rook", state: "working", title: "w"}),
        ]);
        expect(g.rows.map((x) => x.title)).toEqual(["n", "w", "q"]);
    });

    it("ranks a group by its best row, not its worst or its first", () => {
        // one blocked agent should outrank a workspace that is merely busy,
        // however many quiet rows sit behind it
        const g = group([
            row({workspace: "busy", state: "working"}),
            row({workspace: "mixed", state: "quiet"}),
            row({workspace: "mixed", state: "needs_input"}),
        ]);
        expect(g.map((x) => x.workspace)).toEqual(["mixed", "busy"]);
    });

    it("survives an empty list", () => {
        expect(group([])).toEqual([]);
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

describe("cycle", () => {
    it("steps forward and back", () => {
        expect(cycle("all", 1)).toBe("needs_input");
        expect(cycle("needs_input", -1)).toBe("all");
    });

    it("wraps both ways — a tab strip is a ring, unlike the cursor", () => {
        expect(cycle("workspaces", 1)).toBe("all");
        expect(cycle("all", -1)).toBe("workspaces");
    });

    it("wraps for any delta, the way move takes big jumps", () => {
        // `(i + delta + n) % n` corrects exactly one step of underflow and
        // then returns undefined — through a signature that says Tab. Only ±1
        // is reachable today, which is precisely how it would have survived.
        expect(TABS.map((_, i) => cycle("all", -(i + 1)))).not.toContain(undefined);
        expect(cycle("all", -7)).toBe("workspaces");
        expect(cycle("all", -999)).toBe(TABS[((-999 % 6) + 6) % 6]);
        expect(cycle("all", 999)).toBe(TABS[999 % 6]);
    });

    it("visits every tab exactly once per lap", () => {
        const seen: Tab[] = [];
        let t: Tab = "all";
        for (let i = 0; i < TABS.length; i++) {
            seen.push(t);
            t = cycle(t, 1);
        }
        expect(new Set(seen).size).toBe(TABS.length);
        expect(t).toBe("all");
    });
});

describe("inTab", () => {
    it("shows every state under all", () => {
        expect(inTab(row({state: "quiet"}), "all")).toBe(true);
        expect(inTab(row({state: "needs_input"}), "all")).toBe(true);
    });

    it("narrows to the tab's own state", () => {
        expect(inTab(row({state: "working"}), "working")).toBe(true);
        expect(inTab(row({state: "quiet"}), "working")).toBe(false);
    });

    it("shows NO agent rows on the non-agent tabs", () => {
        // Not "shows them all unfiltered" — that left the cursor walking the
        // full agent list behind the workspace grid, so ↵ on the workspaces
        // tab opened a row you never selected and could not see. Empty makes
        // every row verb a no-op for free.
        expect(inTab(row({state: "quiet"}), "queue")).toBe(false);
        expect(inTab(row({state: "needs_input"}), "workspaces")).toBe(false);
    });

    it("knows which tabs carry agent rows", () => {
        expect(TABS.filter(isAgentTab)).toEqual(["all", "needs_input", "working", "quiet"]);
    });
});

describe("short", () => {
    it("labels every state in the same width", () => {
        const labels = (["needs_input", "working", "quiet"] as const).map(short);
        expect(labels).toEqual(["needs", "works", "quiet"]);
        expect(new Set(labels.map((l) => l.length)).size).toBe(1);
    });

    it("gives the short forms distinct first letters", () => {
        // match() leans on this: `state:w` means working and `state:q` means
        // quiet only because no two short forms share a prefix. Rename one to
        // "queued" and `state:q` silently becomes ambiguous.
        const firsts = (["needs_input", "working", "quiet"] as const).map((s) => short(s)[0]);
        expect(new Set(firsts).size).toBe(3);
    });
});
