// Pure view-model for the thread UI — no DOM, no Monaco, so a node suite
// can pin the logic (scratchpad threadview-test). term/threads.ts renders
// what these compute.

import type {ThreadComment, ThreadInfo} from "../hostapi";

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

/** What a thread is DOING, which is what the gutter and the inline row
 *  actually want to say. Stored `state` is only three values and can't
 *  distinguish the two situations you care about most while reviewing:
 *  whether the ball is with the agent, and whether the agent was ever told.
 *
 *    failed    the nudge never reached a responder (the host recorded why)
 *    pending   written, not yet submitted — the ball is with you
 *    waiting   submitted, last word is yours — the ball is with the agent
 *    answered  the agent has replied and it's your move
 *    resolved  done
 *
 *  Derived, not stored, except `failed` — that one needs the host to
 *  remember a delivery that didn't happen, because nothing about the row
 *  would otherwise differ from a normal wait. */
export type ThreadStatus = "failed" | "pending" | "waiting" | "answered" | "resolved";

export function threadStatus(t: ThreadInfo): ThreadStatus {
    if (t.state === "resolved") return "resolved";
    // A delivery failure outranks pending: a thread can be marked failed
    // only after a submit, so this can't mask an unsubmitted note. Resolved
    // still wins over both — a stale error must not resurrect a done thread.
    if (t.deliverError) return "failed";
    if (t.state === "pending") return "pending";
    const last = t.comments[t.comments.length - 1];
    return last?.author === "user" ? "waiting" : "answered";
}

/** Most-demanding first — the one ranking every thread surface sorts by, so
 *  the quickfix list, the finder, and the gutter glyph agree about what is
 *  urgent. A failure sorts above everything: it's the only status where
 *  nothing at all is happening and only you can restart it. */
export const STATUS_ORDER: Record<ThreadStatus, number> = {
    failed: 0,
    pending: 1,
    answered: 2,
    waiting: 3,
    resolved: 4,
};

/** The glyph reflects the group's most-demanding status, plus an outdated
 *  modifier when any anchor no longer matches the file. */
export function glyphClass(group: ThreadInfo[]): string {
    let best: ThreadStatus = "resolved";
    let outdated = false;
    for (const t of group) {
        const s = threadStatus(t);
        if (STATUS_ORDER[s] < STATUS_ORDER[best]) best = s;
        if (t.outdated) outdated = true;
    }
    return `thread-glyph thread-glyph-${best}${outdated ? " thread-glyph-outdated" : ""}`;
}

/** Label + tone per status — the inline row, the hover, and the list all
 *  name a thread the same way. */
export function statusMeta(s: ThreadStatus): {label: string; tone: StateTone} {
    switch (s) {
        case "failed":
            return {label: "not delivered", tone: "red"};
        case "pending":
            return {label: "not sent yet", tone: "amber"};
        case "waiting":
            return {label: "waiting on agent", tone: "acc"};
        case "answered":
            return {label: "agent replied", tone: "magenta"};
        case "resolved":
            return {label: "resolved", tone: "grn"};
    }
}

/** STATUS rank for one thread — the sort key every stack shares. */
function statusRank(t: ThreadInfo): number {
    return STATUS_ORDER[threadStatus(t)];
}

/** The rank-sorted stack of threads whose marker sits on `line` (this
 *  file + side). Most-demanding status first, then id — matches glyphClass
 *  so the top of the stack is the glyph's state. */
export function threadStack(
    all: ThreadInfo[],
    path: string,
    side: Side,
    line: number,
): ThreadInfo[] {
    return bandThreads(all, path, side)
        .filter((t) => Math.max(1, t.currentStart) === line)
        .sort((a, b) => statusRank(a) - statusRank(b) || a.id - b.id);
}

/** The thread to show for a stack: the active one if still present, else
 *  the top. index is 0-based (render as `index+1 of count`). */
export function pickFromStack(
    stack: ThreadInfo[],
    activeId?: number,
): {thread: ThreadInfo; index: number; count: number} | null {
    if (stack.length === 0) return null;
    let i = activeId != null ? stack.findIndex((t) => t.id === activeId) : -1;
    if (i < 0) i = 0;
    return {thread: stack[i], index: i, count: stack.length};
}

/** Threads whose current range COVERS `line` — what ,t looks up.
 *
 *  Deliberately wider than threadStack, which is marker-line-exact because a
 *  gutter glyph sits on exactly one row. The cursor may legitimately be
 *  anywhere inside an anchored range, and "go to thread" should work from all
 *  of it. Ranked the same way the glyph is, so ,t opens what the margin rule
 *  is pointing at. */
export function threadsCovering(
    all: ThreadInfo[],
    path: string,
    side: Side,
    line: number,
): ThreadInfo[] {
    return bandThreads(all, path, side)
        .filter((t) => line >= Math.max(1, t.currentStart) && line <= Math.max(1, t.currentEnd))
        .sort((a, b) => statusRank(a) - statusRank(b) || a.id - b.id);
}

/** Next thread id when cycling `‹ ›` within a line's stack; wraps. */
export function cycleStack(stack: ThreadInfo[], activeId: number, dir: 1 | -1): number | null {
    if (stack.length === 0) return null;
    let i = stack.findIndex((t) => t.id === activeId);
    if (i < 0) i = 0;
    return stack[(i + dir + stack.length) % stack.length].id;
}

/** Identity of the panel's file context — selection resets when it
 *  changes (file-nav / workspace switch). */
export function contextKey(ctx: {workspace: string; path: string} | null): string {
    return ctx ? `${ctx.workspace}:${ctx.path}` : "";
}

export type ThreadFilter = "open" | "resolved" | "all";
export type StateTone = "amber" | "acc" | "grn" | "red" | "magenta";

/** The threads the panel lists: this file, both sides, top-down. */
export function fileThreads(all: ThreadInfo[], path: string): ThreadInfo[] {
    return all
        .filter((t) => t.path === path)
        .sort((a, b) => a.currentStart - b.currentStart || a.id - b.id);
}

/** Client-side filter tab. "open" means not-resolved (pending + open). */
export function filterThreads(threads: ThreadInfo[], filter: ThreadFilter): ThreadInfo[] {
    if (filter === "all") return threads;
    if (filter === "resolved") return threads.filter((t) => t.state === "resolved");
    return threads.filter((t) => t.state !== "resolved");
}

export function openCount(all: ThreadInfo[]): number {
    return all.filter((t) => t.state !== "resolved").length;
}

export function resolvedCount(all: ThreadInfo[]): number {
    return all.filter((t) => t.state === "resolved").length;
}

/** Compact relative time from an ISO string; nowMs injected for testability. */
export function relTime(iso: string, nowMs: number): string {
    const t = Date.parse(iso);
    if (Number.isNaN(t)) return "";
    const secs = Math.max(0, Math.floor((nowMs - t) / 1000));
    if (secs < 45) return "just now";
    const mins = Math.floor(secs / 60);
    if (mins < 60) return `${mins}m`;
    const hrs = Math.floor(mins / 60);
    if (hrs < 24) return `${hrs}h`;
    return `${Math.floor(hrs / 24)}d`;
}

/** Avatar chip for a comment author — no authenticated identity exists. */
export function avatar(author: ThreadComment["author"]): {initials: string; isAgent: boolean} {
    return author === "agent" ? {initials: "R", isAgent: true} : {initials: "me", isAgent: false};
}

/** Collapsed-card snippet: first non-blank line of the anchor. */
export function snippetOf(t: ThreadInfo): string {
    const first = (t.anchorText || "").split("\n")[0].trim();
    return first || "(blank line)";
}

/** The hover PREVIEW of a thread: enough to decide whether to open it.
 *
 *  Deliberately not the full document (that's the host's threaddoc render,
 *  behind gt) — a hover is a glance, so it skips the anchored source (you
 *  are looking straight at it) and truncates a long conversation to its
 *  ends, which is what you actually want to know: what was asked, and what
 *  the last word was. gt is one gesture away for the rest. */
export function hoverPreview(t: ThreadInfo, nowMs: number): string {
    const head = `**#${t.id}** · ${t.state}${t.outdated ? " · outdated" : ""}`;
    if (t.comments.length === 0) return head;
    const line = (c: ThreadComment) =>
        `**${c.author === "agent" ? "claude" : "you"}** · ${relTime(c.created, nowMs)}\n\n${clip(c.body)}`;
    const first = t.comments[0];
    const last = t.comments[t.comments.length - 1];
    if (t.comments.length === 1) return [head, "", line(first)].join("\n");
    const skipped = t.comments.length - 2;
    const middle = skipped > 0 ? [`*…${skipped} more*`] : [];
    return [head, "", line(first), "", ...middle, "", line(last), "", "`gt` opens the thread"].join(
        "\n",
    );
}

const HOVER_CLIP = 280;

function clip(body: string): string {
    const s = body.trim();
    if (s.length <= HOVER_CLIP) return s;
    return s.slice(0, HOVER_CLIP).trimEnd() + "…";
}
