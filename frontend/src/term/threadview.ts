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

/** The glyph reflects the group's most-demanding state — pending (not
 *  yet submitted) > open (live conversation) > resolved — plus an
 *  outdated modifier when any anchor no longer matches the file. */
export function glyphClass(group: ThreadInfo[]): string {
    let best: ThreadInfo["state"] = "resolved";
    let outdated = false;
    for (const t of group) {
        if (STATE_RANK[t.state] < STATE_RANK[best]) best = t.state;
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

const STATE_RANK = {pending: 0, open: 1, resolved: 2} as const;

/** The rank-sorted stack of threads whose marker sits on `line` (this
 *  file + side). Pending > open > resolved, then id — matches glyphClass
 *  so the top of the stack is the glyph's state. */
export function threadStack(
    all: ThreadInfo[],
    path: string,
    side: Side,
    line: number,
): ThreadInfo[] {
    return bandThreads(all, path, side)
        .filter((t) => Math.max(1, t.currentStart) === line)
        .sort((a, b) => STATE_RANK[a.state] - STATE_RANK[b.state] || a.id - b.id);
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
        .sort((a, b) => STATE_RANK[a.state] - STATE_RANK[b.state] || a.id - b.id);
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
export type StateTone = "amber" | "acc" | "grn";

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

/** Label + accent tone for a thread state. */
export function stateMeta(state: ThreadInfo["state"]): {label: string; tone: StateTone} {
    if (state === "pending") return {label: "Pending", tone: "amber"};
    if (state === "resolved") return {label: "Resolved", tone: "grn"};
    return {label: "Open", tone: "acc"};
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

/** Extension → the fence language, so the anchored source in a thread buffer
 *  highlights as the code it came from. Unknown suffixes fence bare rather
 *  than guessing: a wrong grammar looks broken, no grammar just looks plain. */
const FENCE_LANG: Record<string, string> = {
    go: "go",
    ts: "typescript",
    tsx: "typescript",
    js: "javascript",
    jsx: "javascript",
    svelte: "svelte",
    py: "python",
    rs: "rust",
    css: "css",
    html: "html",
    json: "json",
    md: "markdown",
    sh: "shell",
    yml: "yaml",
    yaml: "yaml",
};

export function fenceLang(path: string): string {
    const dot = path.lastIndexOf(".");
    return dot < 0 ? "" : (FENCE_LANG[path.slice(dot + 1).toLowerCase()] ?? "");
}

function rangeLabel(t: ThreadInfo): string {
    const a = t.currentStart;
    const b = t.currentEnd;
    return a === b ? `${a}` : `${a}-${b}`;
}

/** The hover PREVIEW of a thread: enough to decide whether to open it.
 *
 *  Deliberately not renderThread — a hover is a glance, so it skips the
 *  anchored source (you are looking straight at it) and truncates a long
 *  conversation to its ends, which is what you actually want to know: what was
 *  asked, and what the last word was. `,t` is one keystroke away for the rest. */
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
    return [head, "", line(first), "", ...middle, "", line(last), "", "`,t` opens the thread"].join(
        "\n",
    );
}

const HOVER_CLIP = 280;

function clip(body: string): string {
    const s = body.trim();
    if (s.length <= HOVER_CLIP) return s;
    return s.slice(0, HOVER_CLIP).trimEnd() + "…";
}

/** A thread as MARKDOWN — the content of its read-only buffer.
 *
 *  Markdown rather than a bespoke render because the buffer is a real Monaco
 *  document: the vendored markdown grammar highlights it, including the
 *  anchored source in its own language via fence injection, and every vim
 *  motion, search and yank works on the conversation the way it works on code.
 *
 *  Pure, so the shape is pinned by unit tests with no Monaco in sight. */
export function renderThread(t: ThreadInfo, nowMs: number): string {
    const out: string[] = [];
    const state = t.outdated ? `${t.state} · outdated` : t.state;
    out.push(`# Thread #${t.id} — ${state}`, "");
    out.push(`\`${t.path}:${rangeLabel(t)}\`${t.side === "original" ? " (original)" : ""}`, "");

    // The snapshot appears ONLY when the anchor drifted — which is the whole
    // reason anchor_text is stored: the lines moved or changed, so the file no
    // longer says what was meant. While the thread is still anchored the code
    // is in the pane you just came from, and fencing it here would push the
    // conversation below the fold of a short split. You opened a thread to
    // read the thread.
    if (t.outdated && t.anchorText) {
        out.push("*anchored to, when written:*", "");
        out.push("```" + fenceLang(t.path), t.anchorText.replace(/\n+$/, ""), "```", "");
    }

    for (const c of t.comments) {
        const who = c.author === "agent" ? "claude" : "you";
        out.push(`## ${who} · ${relTime(c.created, nowMs)}`, "");
        out.push(c.body.trimEnd(), "");
    }
    return out.join("\n");
}
