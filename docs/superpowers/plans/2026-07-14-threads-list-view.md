# Threads Panel List-View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the threads side-panel from a single-thread view into a filterable, collapsible list of every thread on the active file, matching the `Rook Threads.dc.html` mockup — styled with inline Tailwind utilities.

**Architecture:** Two changes. (1) Add pure, DOM-free view-model helpers to `term/threadview.ts`, pinned by the existing vitest spec. (2) Rewrite `ThreadPanel.svelte` to consume them and render filter tabs + card list + inline composer + footer, keeping the existing `EditorSeam` wiring untouched. Styling is inline Tailwind v4 utilities (README decision 7); the only `app.css` change is deleting the now-dead single-thread rules. No host/Go changes.

**Tech Stack:** Svelte 5 (runes: `$state`/`$derived`/`$effect`/`$props`), TypeScript, Tailwind v4 (utilities via `@tailwindcss/vite`, tokens in `app.css` `@theme`), vitest, oxlint/oxfmt. Framework-free ethos — no new deps, no web fonts, no oklch.

Spec: [docs/superpowers/specs/2026-07-14-threads-list-view-design.md](../specs/2026-07-14-threads-list-view-design.md)

## Global Constraints

- **No new dependencies, no web fonts, no oklch, no `@apply`, no `@theme` edits.**
- **Inline Tailwind utilities for all new styling** (README decision 7 — convert a touched surface to utilities). No new `.tp-*`/CSS class block. The only `app.css` change is a deletion (Task 2 Step 2).
- **Palette = the `@theme` colour utilities only:** `acc grn fg dim lo amber red hot` (e.g. `text-acc`, `bg-amber`, `text-grn`, `text-lo`) and `font-mono`. `--line`/`--raise` are NOT theme colours — use white-alpha (`border-white/10`, `bg-white/[0.02]`) for hairlines/surfaces. Opacity via `/N` (e.g. `bg-acc/15`, `border-acc/40`).
- **Tone → class must be a static lookup.** Tailwind scans source for literal class strings; `bg-${tone}` produces nothing. Use the `TONE_TEXT`/`TONE_BG` maps whose values are literal class names.
- **SidePane owns the title.** The panel renders NO "Threads" title of its own (SidePane's header already shows it + a close button). The panel is a flex column filling `.side-pane-body`: sticky filter row, scrolling list, sticky footer.
- **Keep** these shared `app.css` classes (still referenced): `.thread-input`, `.thread-input:focus`, `.thread-err`, `.thread-anchor`, `.thread-active-line`, `.thread-panel-empty`, `.thread-glyph*`, `.editor-btn`, `.side-pane*`.
- **Layer 1 only.** No proposed-revision block, no apply-to-working-tree. Render only real states `pending`/`open`/`resolved`.
- **Seam is frozen.** `EditorSeam` in `term/editor.ts` does not change.
- **State → tone:** `pending → amber`, `open → acc`, `resolved → grn`.
- **Working dir:** all commands run from `frontend/`. Run `pnpm test`, `pnpm run check`, `pnpm run lint`, `pnpm run format` before each commit touching frontend code. Use the `packageManager`-pinned pnpm — never npm.
- **Scoped commits:** `git add` only the task's own files (`M Makefile` is pre-existing unrelated drift; never stage it).
- **Commit messages** end with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

### Task 1: View-model helpers in `term/threadview.ts`

Pure functions the panel renders from. TDD against the existing vitest spec.

**Files:**
- Modify: `frontend/src/term/threadview.ts` (add exports; add `ThreadComment` to the existing type import)
- Test: `frontend/src/term/threadview.spec.ts` (append cases + extend the import list)

**Interfaces:**
- Consumes: `ThreadInfo`, `ThreadComment` from `../hostapi`; the existing `th()` factory in the spec.
- Produces (later tasks rely on these exact signatures):
  - `type ThreadFilter = "open" | "resolved" | "all"`
  - `type StateTone = "amber" | "acc" | "grn"`
  - `fileThreads(all: ThreadInfo[], path: string): ThreadInfo[]`
  - `filterThreads(threads: ThreadInfo[], filter: ThreadFilter): ThreadInfo[]`
  - `stateMeta(state: ThreadInfo["state"]): {label: string; tone: StateTone}`
  - `openCount(all: ThreadInfo[]): number`
  - `resolvedCount(all: ThreadInfo[]): number`
  - `relTime(iso: string, nowMs: number): string`
  - `avatar(author: ThreadComment["author"]): {initials: string; isAgent: boolean}`
  - `snippetOf(t: ThreadInfo): string`

- [ ] **Step 1: Write the failing tests**

Append to `frontend/src/term/threadview.spec.ts`. Also extend the top-of-file import from `./threadview` to add the new names alongside the existing ones:

```ts
import {
    avatar,
    bandThreads,
    contextKey,
    cycleStack,
    fileThreads,
    filterThreads,
    glyphClass,
    markerLines,
    openCount,
    pickFromStack,
    relTime,
    resolvedCount,
    snippetOf,
    stateMeta,
    threadStack,
} from "./threadview";
```

Then append these `describe` blocks at the end of the file:

```ts
describe("fileThreads", () => {
    it("keeps this file across both sides, sorted by line then id", () => {
        const all = [
            th({id: 3, path: "a.ts", currentStart: 10}),
            th({id: 1, path: "a.ts", currentStart: 5}),
            th({id: 2, path: "b.ts", currentStart: 1}),
            th({id: 4, path: "a.ts", side: "original", currentStart: 5}),
        ];
        expect(fileThreads(all, "a.ts").map((t) => t.id)).toEqual([1, 4, 3]);
    });
});

describe("filterThreads", () => {
    const all = [
        th({id: 1, state: "pending"}),
        th({id: 2, state: "open"}),
        th({id: 3, state: "resolved"}),
    ];
    it("open = pending + open (not resolved)", () => {
        expect(filterThreads(all, "open").map((t) => t.id)).toEqual([1, 2]);
    });
    it("resolved = resolved only", () => {
        expect(filterThreads(all, "resolved").map((t) => t.id)).toEqual([3]);
    });
    it("all = everything", () => {
        expect(filterThreads(all, "all").map((t) => t.id)).toEqual([1, 2, 3]);
    });
});

describe("stateMeta", () => {
    it("maps each state to label + tone", () => {
        expect(stateMeta("pending")).toEqual({label: "Pending", tone: "amber"});
        expect(stateMeta("open")).toEqual({label: "Open", tone: "acc"});
        expect(stateMeta("resolved")).toEqual({label: "Resolved", tone: "grn"});
    });
});

describe("openCount / resolvedCount", () => {
    it("counts by resolved-ness", () => {
        const all = [
            th({id: 1, state: "pending"}),
            th({id: 2, state: "open"}),
            th({id: 3, state: "resolved"}),
        ];
        expect(openCount(all)).toBe(2);
        expect(resolvedCount(all)).toBe(1);
    });
});

describe("relTime", () => {
    const now = Date.parse("2026-07-14T12:00:00Z");
    it("floors to just now under 45s", () => {
        expect(relTime("2026-07-14T11:59:30Z", now)).toBe("just now");
    });
    it("minutes", () => {
        expect(relTime("2026-07-14T11:57:00Z", now)).toBe("3m");
    });
    it("hours", () => {
        expect(relTime("2026-07-14T10:00:00Z", now)).toBe("2h");
    });
    it("days", () => {
        expect(relTime("2026-07-09T12:00:00Z", now)).toBe("5d");
    });
    it("empty on unparseable input", () => {
        expect(relTime("", now)).toBe("");
    });
});

describe("avatar", () => {
    it("agent → R, user → me", () => {
        expect(avatar("agent")).toEqual({initials: "R", isAgent: true});
        expect(avatar("user")).toEqual({initials: "me", isAgent: false});
    });
});

describe("snippetOf", () => {
    it("first trimmed line of the anchor", () => {
        expect(snippetOf(th({id: 1, anchorText: "  cp -R bin/rook.app\nnext"}))).toBe(
            "cp -R bin/rook.app",
        );
    });
    it("blank fallback when anchor is empty/whitespace", () => {
        expect(snippetOf(th({id: 1, anchorText: "   "}))).toBe("(blank line)");
    });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd frontend && pnpm test -- threadview`
Expected: FAIL — the new imports are undefined (e.g. `fileThreads is not a function` / TS errors on missing exports).

- [ ] **Step 3: Implement the helpers**

In `frontend/src/term/threadview.ts`, change the top import to include `ThreadComment`:

```ts
import type {ThreadComment, ThreadInfo} from "../hostapi";
```

Then append at the end of the file:

```ts
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
    return author === "agent"
        ? {initials: "R", isAgent: true}
        : {initials: "me", isAgent: false};
}

/** Collapsed-card snippet: first non-blank line of the anchor. */
export function snippetOf(t: ThreadInfo): string {
    const first = (t.anchorText || "").split("\n")[0].trim();
    return first || "(blank line)";
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd frontend && pnpm test -- threadview`
Expected: PASS — all new blocks green, existing blocks still green.

- [ ] **Step 5: Lint + format**

Run: `cd frontend && pnpm run lint && pnpm run format`
Expected: no errors; oxfmt leaves the file clean (or reformats it — stage the result).

- [ ] **Step 6: Commit**

```bash
git add frontend/src/term/threadview.ts frontend/src/term/threadview.spec.ts
git commit -m "$(cat <<'EOF'
threads: view-model helpers for the panel list view

fileThreads / filterThreads / stateMeta / openCount / resolvedCount /
relTime / avatar / snippetOf — pure, pinned by threadview.spec.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Rewrite `ThreadPanel.svelte` (inline Tailwind) + delete dead CSS

Replace the single-thread panel with the list view, styled with inline Tailwind utilities. One deliverable — the working styled panel — because there is no component test harness; the gate is `svelte-check`, a clean build, and the manual checklist.

**Files:**
- Modify (replace whole file): `frontend/src/ThreadPanel.svelte`
- Modify: `frontend/src/app.css` (delete only — the dead single-thread rules)

**Interfaces:**
- Consumes from Task 1: `ThreadFilter`, `StateTone`, `fileThreads`, `filterThreads`, `stateMeta`, `openCount`, `resolvedCount`, `relTime`, `avatar`, `snippetOf`; plus existing `threadStack`, `pickFromStack`, `contextKey`, `type Side`.
- Consumes host API (unchanged): `api.createThread`, `api.threadComment`, `api.threadResolve`, `api.threadReopen`, `api.submitThreads`.
- Consumes seam (unchanged): `editor.context()`, `editor.threads()`, `editor.refetch()`, `editor.reveal()`, `editor.clearHighlight()`, `editor.onMarkerClick()`, `editor.onCompose()`, `editor.onChange()`.
- Produces: no exports beyond the default Svelte component; `App.svelte:676` mounts it inside `SidePane title="Threads"` as today with `{api}` and `editor={activeEditor}` — signature unchanged.

- [ ] **Step 1: Replace `ThreadPanel.svelte`**

Write `frontend/src/ThreadPanel.svelte` in full:

```svelte
<!-- The threads side-pane tenant (mounted inside SidePane, which owns the
     "Threads" title + close button + scroll body). Placement-agnostic: it
     takes the active editor pane's seam + hostapi and lists every thread on
     that file — filterable, one card expanded at a time. Marker clicks and
     ⌘⇧M come UP through the seam; reveal/highlight go DOWN. Drafts live here
     in chrome, so a background refetch never eats them. Styled with inline
     Tailwind utilities (README decision 7). Layer 1: no agent proposed-
     revisions (see spec). -->
<script lang="ts">
    import type {HostAPI, ThreadInfo} from "./hostapi";
    import type {EditorSeam} from "./term/editor";
    import {
        avatar,
        contextKey,
        fileThreads,
        filterThreads,
        openCount,
        pickFromStack,
        relTime,
        resolvedCount,
        snippetOf,
        stateMeta,
        threadStack,
        type Side,
        type StateTone,
        type ThreadFilter,
    } from "./term/threadview";

    let {api, editor}: {api: HostAPI; editor: EditorSeam | null} = $props();

    // Tone → literal class names. Tailwind scans source for literal strings,
    // so this must never be `bg-${tone}` (that emits nothing).
    const TONE_TEXT: Record<StateTone, string> = {
        amber: "text-amber",
        acc: "text-acc",
        grn: "text-grn",
    };
    const TONE_BG: Record<StateTone, string> = {
        amber: "bg-amber",
        acc: "bg-acc",
        grn: "bg-grn",
    };
    const FILTERS: [ThreadFilter, string][] = [
        ["open", "Open"],
        ["resolved", "Resolved"],
        ["all", "All"],
    ];

    let threads = $state<ThreadInfo[]>([]);
    let filter = $state<ThreadFilter>("open");
    let selectedId = $state<number | null>(null); // the one expanded card
    let composer = $state<{startLine: number; endLine: number; side: Side} | null>(null);
    let draft = $state(""); // composer body OR the expanded card's reply
    let err = $state("");
    let busy = $state(false);
    let nowMs = $state(Date.now()); // refreshed on sync; feeds relTime
    let ctxKey = ""; // last-seen file identity; selection/composer reset on change

    // (Re)bind to the active editor whenever the prop changes.
    $effect(() => {
        const seam = editor;
        if (!seam) {
            threads = [];
            selectedId = null;
            composer = null;
            ctxKey = "";
            return;
        }
        sync();
        const offChange = seam.onChange(sync);
        const offMarker = seam.onMarkerClick((line, side, _ids) => selectAt(line, side));
        const offCompose = seam.onCompose((s, e, side) => {
            draft = "";
            err = "";
            selectedId = null;
            composer = {startLine: s, endLine: e, side};
        });
        return () => {
            offChange();
            offMarker();
            offCompose();
        };
    });

    function sync(): void {
        if (!editor) return;
        threads = editor.threads();
        nowMs = Date.now();
        const key = contextKey(editor.context());
        if (key !== ctxKey) {
            // file-nav / workspace switch → drop selection + composer (filter persists)
            ctxKey = key;
            selectedId = null;
            composer = null;
            draft = "";
            err = "";
        }
    }

    // A gutter-marker click expands the matching card and reveals it.
    function selectAt(line: number, side: Side): void {
        const ctx = editor?.context();
        if (!ctx) return;
        const stack = threadStack(threads, ctx.path, side, line);
        const pick = pickFromStack(stack, selectedId ?? undefined);
        if (!pick) return;
        draft = "";
        err = "";
        composer = null;
        selectedId = pick.thread.id;
        editor?.reveal(pick.thread);
    }

    const path = $derived(editor?.context()?.path ?? "");
    const visible = $derived(filterThreads(fileThreads(threads, path), filter));
    const selected = $derived(
        selectedId == null ? null : (threads.find((t) => t.id === selectedId) ?? null),
    );

    function toggle(t: ThreadInfo): void {
        if (selectedId === t.id) {
            collapse();
            return;
        }
        composer = null;
        draft = "";
        err = "";
        selectedId = t.id;
        editor?.reveal(t);
    }

    function headKey(e: KeyboardEvent, t: ThreadInfo): void {
        if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            toggle(t);
        }
    }

    function collapse(): void {
        selectedId = null;
        draft = "";
        err = "";
        editor?.clearHighlight();
    }

    function cancelComposer(): void {
        composer = null;
        draft = "";
        err = "";
        editor?.clearHighlight();
    }

    async function run(fn: () => Promise<void>): Promise<void> {
        busy = true;
        err = "";
        try {
            await fn();
            await editor?.refetch(); // resync gutter + this panel's data
        } catch (e) {
            err = String(e);
        } finally {
            busy = false;
        }
    }

    async function submitComposer(): Promise<void> {
        const body = draft.trim();
        const ctx = editor?.context();
        if (!body || !ctx || !composer) return;
        const {startLine, endLine, side} = composer;
        let created: ThreadInfo | null = null;
        await run(async () => {
            created = await api.createThread(ctx.workspace, {
                path: ctx.path,
                startLine,
                endLine,
                side,
                base: side === "original" ? ctx.base : undefined,
                body,
            });
            draft = "";
            composer = null;
        });
        // select AFTER refetch populated `threads`, so `selected` resolves at once
        if (created) {
            selectedId = (created as ThreadInfo).id;
            editor?.reveal(created as ThreadInfo);
        }
    }

    async function reply(): Promise<void> {
        const body = draft.trim();
        if (!body || !selected) return;
        const id = selected.id;
        await run(async () => {
            await api.threadComment(id, body);
            draft = "";
        });
    }

    async function resolve(): Promise<void> {
        if (!selected) return;
        const id = selected.id;
        await run(() => api.threadResolve(id));
    }

    async function reopen(): Promise<void> {
        if (!selected) return;
        const id = selected.id;
        await run(() => api.threadReopen(id));
    }

    // Ask the agent = the real nudge. Workspace-level batch: flips ALL pending
    // threads → open and nudges once (no per-thread submit endpoint exists).
    async function askAgent(): Promise<void> {
        const ctx = editor?.context();
        if (!ctx) return;
        await run(async () => {
            await api.submitThreads(ctx.workspace);
        });
    }

    function keydown(e: KeyboardEvent, submit: () => void): void {
        if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
            e.preventDefault();
            submit();
        } else if (e.key === "Escape") {
            if (composer) cancelComposer();
            else collapse();
        }
    }

    function fmtRange(a: number, b: number): string {
        return a === b ? `L${a}` : `L${a}–${b}`;
    }
</script>

{#if !editor}
    <div class="thread-panel-empty">focus a review or file pane to see its threads</div>
{:else}
    <div class="flex h-full min-h-0 flex-col text-fg">
        <!-- filters + counts (SidePane's header already says "Threads") -->
        <div class="flex shrink-0 items-center gap-2 border-b border-white/10 px-3 py-2">
            <div class="flex gap-1.5">
                {#each FILTERS as [id, label] (id)}
                    <button
                        class={"cursor-pointer rounded-lg border px-2.5 py-1 text-[11px] font-semibold " +
                            (filter === id
                                ? "border-acc/40 bg-acc/15 text-acc"
                                : "border-white/10 bg-transparent text-lo hover:text-fg")}
                        onclick={() => (filter = id)}>{label}</button
                    >
                {/each}
            </div>
            <span class="flex-1"></span>
            <span class="flex items-center gap-1.5 font-mono text-[10px] text-lo">
                <span class="size-1.5 rounded-full bg-amber"></span>{openCount(threads)} open
            </span>
        </div>

        <!-- the list is the only scroll region -->
        <div class="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto px-3 py-2.5">
            {#if composer}
                <div class="rounded-xl border border-acc/40 bg-acc/[0.06] px-3 py-2.5">
                    <div class="mb-2 flex items-center gap-2">
                        <span class="text-[10px] font-bold uppercase tracking-wider text-acc"
                            >New thread</span
                        >
                        <span class="font-mono text-[10px] text-lo"
                            >{fmtRange(composer.startLine, composer.endLine)}{composer.side ===
                            "original"
                                ? " (original)"
                                : ""}</span
                        >
                        <span class="flex-1"></span>
                        <button
                            class="cursor-pointer text-xs text-lo hover:text-dim"
                            aria-label="cancel"
                            onclick={cancelComposer}>✕</button
                        >
                    </div>
                    <textarea
                        class="thread-input"
                        rows="3"
                        placeholder="Ask the agent, or leave a note for this region…"
                        bind:value={draft}
                        onkeydown={(e) => keydown(e, submitComposer)}></textarea>
                    {#if err}<div class="thread-err">{err}</div>{/if}
                    <div class="mt-2 flex items-center gap-2">
                        <button
                            class="cursor-pointer rounded-lg bg-acc px-3 py-1.5 text-xs font-semibold text-[#0b0d14] hover:brightness-110 disabled:opacity-50"
                            disabled={busy}
                            onclick={submitComposer}>Start thread</button
                        >
                        <span class="font-mono text-[10px] text-lo">⌘↵ sends · esc closes</span>
                    </div>
                </div>
            {/if}

            {#each visible as t (t.id)}
                {@const meta = stateMeta(t.state)}
                <div
                    class={"overflow-hidden rounded-xl border transition-colors " +
                        (selectedId === t.id
                            ? "border-acc/45 bg-white/[0.04]"
                            : "border-white/10 bg-white/[0.02]")}
                >
                    <div
                        class="flex cursor-pointer items-center gap-2.5 px-3 py-2.5"
                        role="button"
                        tabindex="0"
                        onclick={() => toggle(t)}
                        onkeydown={(e) => headKey(e, t)}
                    >
                        <span class={"size-2 shrink-0 rounded-full " + TONE_BG[meta.tone]}></span>
                        <div class="min-w-0 flex-1">
                            <div class="flex items-center gap-2">
                                <span
                                    class={"text-[10px] font-bold uppercase tracking-wider " +
                                        TONE_TEXT[meta.tone]}>{meta.label}</span
                                >
                                <span class="font-mono text-[10px] text-lo"
                                    >#{t.id} · {fmtRange(t.currentStart, t.currentEnd)}{t.outdated
                                        ? " · outdated"
                                        : ""}</span
                                >
                            </div>
                            <div class="mt-0.5 truncate font-mono text-[11px] text-dim">
                                {snippetOf(t)}
                            </div>
                        </div>
                        <span class="shrink-0 text-[10px] text-lo">{t.comments.length}</span>
                    </div>

                    {#if selectedId === t.id}
                        <div class="px-3 pb-3 pt-0.5">
                            {#if t.outdated && t.anchorText}
                                <pre class="thread-anchor">{t.anchorText}</pre>
                            {/if}
                            <div class="flex flex-col gap-3 py-2.5">
                                {#each t.comments as c (c.id)}
                                    {@const av = avatar(c.author)}
                                    <div class="flex gap-2.5">
                                        <span
                                            class={"inline-flex size-5 shrink-0 items-center justify-center rounded-md text-[10px] font-bold " +
                                                (av.isAgent
                                                    ? "bg-acc/20 text-acc"
                                                    : "bg-white/10 text-fg")}>{av.initials}</span
                                        >
                                        <div class="min-w-0 flex-1 pt-px">
                                            <div class="mb-0.5 flex items-center gap-2">
                                                <span
                                                    class={"text-xs font-semibold " +
                                                        (av.isAgent ? "text-acc" : "text-fg")}
                                                    >{c.author === "agent" ? "agent" : "you"}</span
                                                >
                                                <span class="font-mono text-[10px] text-lo"
                                                    >{relTime(c.created, nowMs)}</span
                                                >
                                            </div>
                                            <div
                                                class="whitespace-pre-wrap break-words text-[13px] leading-normal text-fg"
                                            >
                                                {c.body}
                                            </div>
                                        </div>
                                    </div>
                                {/each}
                            </div>

                            {#if err}<div class="thread-err">{err}</div>{/if}

                            <div class="mt-2.5 flex gap-2">
                                {#if t.state === "pending"}
                                    <button
                                        class="shrink-0 cursor-pointer rounded-lg border border-acc/35 bg-acc/15 px-3 py-1.5 text-[11px] font-semibold text-acc hover:bg-acc/25 disabled:opacity-50"
                                        disabled={busy}
                                        title="submits pending threads and nudges the agent"
                                        onclick={askAgent}>Ask the agent</button
                                    >
                                {/if}
                                <input
                                    class="thread-input min-w-0 flex-1 resize-none"
                                    placeholder="reply…"
                                    bind:value={draft}
                                    onkeydown={(e) => keydown(e, reply)} />
                                <button
                                    class="shrink-0 cursor-pointer rounded-lg border border-white/10 bg-white/5 px-3 text-[11px] font-semibold text-fg hover:border-acc disabled:opacity-50"
                                    disabled={busy}
                                    onclick={reply}>Send</button
                                >
                            </div>

                            <div
                                class="mt-2.5 flex items-center gap-3.5 border-t border-white/10 pt-2.5"
                            >
                                {#if t.state === "resolved"}
                                    <button
                                        class="cursor-pointer text-[11px] font-semibold text-dim hover:text-fg disabled:opacity-50"
                                        disabled={busy}
                                        onclick={reopen}>↺ Reopen</button
                                    >
                                {:else}
                                    <button
                                        class="cursor-pointer text-[11px] font-semibold text-grn hover:brightness-110 disabled:opacity-50"
                                        disabled={busy}
                                        onclick={resolve}>✓ Resolve thread</button
                                    >
                                {/if}
                                <span class="font-mono text-[10px] text-lo"
                                    >attached to {fmtRange(t.currentStart, t.currentEnd)}</span
                                >
                            </div>
                        </div>
                    {/if}
                </div>
            {/each}

            {#if visible.length === 0 && !composer}
                <div class="px-2.5 py-6 text-center text-xs leading-relaxed text-lo">
                    No threads in this filter.{#if resolvedCount(threads) > 0 && filter === "open"}<br
                        />{resolvedCount(threads)} resolved — see the Resolved tab.{/if}
                </div>
            {/if}
        </div>

        <!-- footer hint -->
        <div
            class="flex shrink-0 items-center gap-2.5 border-t border-white/10 px-3.5 py-2 font-mono text-[10px] text-lo"
        >
            <span>click any line to start a thread</span>
            <span class="flex-1"></span>
            <span>agents reply here</span>
        </div>
    </div>
{/if}
```

- [ ] **Step 2: Delete the dead single-thread CSS in `app.css`**

First confirm the classes are dead (used nowhere but the old file you just replaced):

Run: `cd frontend && grep -rnE "thread-card|thread-row|thread-state|thread-meta|thread-comment|thread-author|thread-body|thread-reply|thread-nav" src/ | grep -v app.css`
Expected: no output (the rewritten `ThreadPanel.svelte` uses none of them).

Then in `frontend/src/app.css` delete exactly these rules (the block from `.thread-card {` through `.thread-nav { … }`, roughly the current lines 442–546): `.thread-card`, `.thread-row`, `.thread-state`, `.thread-state-pending`, `.thread-state-open`, `.thread-state-resolved`, `.thread-meta`, `.thread-comment`, `.thread-author`, `.thread-author-user`, `.thread-body`, `.thread-reply`, `.thread-nav`.

**Keep** (do NOT delete): `.thread-anchor`, `.thread-input`, `.thread-input:focus`, `.thread-err`, `.thread-active-line`, `.thread-panel-empty`, `.thread-glyph*`, `.editor-btn`. If `.thread-anchor` sits inside the deleted range, leave it in place (move it out of the deleted span if needed).

- [ ] **Step 3: Type-check**

Run: `cd frontend && pnpm run check`
Expected: 0 errors and 0 warnings referencing `ThreadPanel.svelte` or `threadview.ts`. (Watch specifically for `state_referenced_locally` — none expected here.)

- [ ] **Step 4: Build + lint + format**

Run: `cd frontend && pnpm run build && pnpm run lint && pnpm run format`
Expected: build succeeds (Tailwind emits the utility classes, including the `TONE_*` literals); oxlint clean with `--deny-warnings`; oxfmt formats cleanly (stage any reformat).

- [ ] **Step 5: Manual smoke test**

Run: `cd .. && make dev` (or the running `make dev` loop). In a workspace with a diff, open the Threads pane (`` ` t ``):
- Pane shows the SidePane "THREADS" header (no duplicate title inside), then a **filter row** (`Open/Resolved/All` + `N open`), a **scrolling card list**, and a **footer hint**. Filters and footer stay put while the list scrolls.
- Clicking a card **expands** it (one at a time); the editor reveals+highlights the anchor. Clicking the header again collapses and clears the highlight.
- Clicking a **gutter marker** expands the matching card + reveals.
- **Filter** tabs switch the visible set; the active tab is accented. Empty filter shows "No threads in this filter." (with the resolved hint on the Open tab).
- Select code + **⌘⇧M** opens the composer at the list top; `Start thread` (or ⌘↵) creates + auto-selects the new card; ✕ / esc cancels.
- In an expanded card: **reply** + Send adds a comment; **Resolve** / **Reopen** flips state; on a `pending` thread, **Ask the agent** nudges (thread moves toward open after refetch); avatars show `R`/`me`, timestamps are relative.
- Switch files/workspaces → selection + composer reset; filter persists.
- Colours match the app (acc blue / amber / green tones), mono where the old panel used mono.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/ThreadPanel.svelte frontend/src/app.css
git commit -m "$(cat <<'EOF'
threads: panel becomes a filterable list of collapsible cards

Rewrites ThreadPanel from single-thread view to the Rook Threads.dc.html
list design — Open/Resolved/All filters, per-file cards with avatars +
relative timestamps, inline new-thread composer. Wired to the existing
seam + host API; "Ask the agent" maps to the real submitThreads nudge.
Styled with inline Tailwind utilities (README decision 7); deletes the
dead single-thread app.css rules. SidePane owns the title. Layer 1 only.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Notes for the implementer

- **Tailwind literal-scan rule:** every utility class must appear as a literal string in source. The tone colours go through `TONE_TEXT`/`TONE_BG` (literal values) and the avatar/author/card-open branches use literal ternaries — never interpolate a class fragment. If you add a colour, write the whole class name out.
- **`--line`/`--raise` are not `@theme` colours** — there is no `border-line`/`bg-raise` utility. Hairlines use `border-white/10`; raised surfaces use `bg-white/[0.02]` (collapsed card) / `bg-white/[0.04]` (expanded) / `bg-white/5` (Send). Do not add tokens to `@theme`.
- **SidePane provides title + scroll.** The panel renders no title and fills `.side-pane-body` as `flex h-full min-h-0 flex-col`; only the middle list is `overflow-y-auto`. Don't set a panel width — `.side-pane` owns it (22rem).
- **`nowMs`** is a snapshot taken on `sync()` — relative times are correct at render/refetch time and don't tick live. That's intentional (no timers); a refetch after any action refreshes them.
- **Single shared `draft`** is safe because only one thing is ever active: either the composer is open (no card expanded) or one card is expanded (no composer). `toggle`/`collapse`/`cancelComposer`/`selectAt` all clear it on transition.
- **Kept classes** the markup still references: `.thread-input` (composer textarea + reply input), `.thread-err`, `.thread-anchor`, `.thread-panel-empty`. Leave them in `app.css`.
- **Scoped `git add`** only — `M Makefile` is pre-existing unrelated drift; `build:dev` may regenerate stale Wails bindings (`bindings/…`) which are NOT ours — never stage them (see [[rook-frontend-toolchain]]).
```
