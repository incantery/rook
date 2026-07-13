// Pure view-model for the thread UI — no DOM, no Monaco, so a node suite
// can pin the logic (scratchpad threadview-test). term/threads.ts renders
// what these compute.

import type {ThreadInfo} from "../hostapi";

export type Side = "modified" | "original";

/** The threads one band renders: this file, this side, top-down. */
export function bandThreads(all: ThreadInfo[], path: string, side: Side): ThreadInfo[] {
    return all
        .filter((t) => t.path === path && t.side === side)
        .sort((a, b) => a.currentStart - b.currentStart || a.id - b.id);
}

/** Markers group per anchor line — one glyph per line, however many
 *  threads landed there. Fail-open anchors can report 0; clamp to 1. */
export function markerLines(threads: ThreadInfo[]): Map<number, ThreadInfo[]> {
    const m = new Map<number, ThreadInfo[]>();
    for (const t of threads) {
        const line = Math.max(1, t.currentStart);
        const g = m.get(line);
        if (g) g.push(t);
        else m.set(line, [t]);
    }
    return m;
}

/** The glyph reflects the group's most-demanding state — pending (not
 *  yet submitted) > open (live conversation) > resolved — plus an
 *  outdated modifier when any anchor no longer matches the file. */
export function glyphClass(group: ThreadInfo[]): string {
    const rank = {pending: 0, open: 1, resolved: 2} as const;
    let best: ThreadInfo["state"] = "resolved";
    let outdated = false;
    for (const t of group) {
        if (rank[t.state] < rank[best]) best = t.state;
        if (t.outdated) outdated = true;
    }
    return `thread-glyph thread-glyph-${best}${outdated ? " thread-glyph-outdated" : ""}`;
}

export function pendingCount(all: ThreadInfo[]): number {
    return all.filter((t) => t.state === "pending").length;
}

/** Open threads whose last word was the user's — the host's re-nudge
 *  condition, mirrored so the button can offer "nudge again". */
export function awaitingAgent(all: ThreadInfo[]): number {
    return all.filter(
        (t) =>
            t.state === "open" &&
            t.comments.length > 0 &&
            t.comments[t.comments.length - 1].author === "user",
    ).length;
}

/** The head button's label; "" hides it. */
export function submitLabel(all: ThreadInfo[]): string {
    const p = pendingCount(all);
    if (p > 0) return `submit ${p}`;
    if (awaitingAgent(all) > 0) return "nudge again";
    return "";
}
