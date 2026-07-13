# Threads 2b: threads in the Monaco panes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The review pane (` g) and file viewer (` e) become commenting surfaces: gutter markers, thread widgets (read/reply/resolve/reopen), a selection composer, and a submit button — the frontend of the slice-2a threads API (PR #29).

**Architecture:** All UI is framework-free DOM in the imperative island, mirroring `editor.ts`. A new `ThreadBand` class (`term/threads.ts`) owns one Monaco editor's thread layer — glyph-margin decorations for markers, view zones for widgets and the composer (verified: zone DOM receives pointer events when `suppressMouseDown` is unset). Pure view-model logic lives in `term/threadview.ts` so a node suite can pin it. `EditorPane` orchestrates: fetches the workspace's threads, slices them per (path, side) into bands, routes mutations through `hostapi.ts`, and refetches after every mutation — the pane's data is always the host's answer, never locally patched.

**Tech Stack:** TypeScript, Monaco 0.55.1 (pinned, ESM deep imports), Svelte 5 (one guard in App.svelte only), pnpm.

## Global Constraints

- **Branch:** `threads-pane`, created from `threads-host` (PR #29 is NOT merged — this PR stacks on it: `git checkout threads-host && git checkout -b threads-pane`; the eventual PR's base is `threads-host`).
- **Working dir for all frontend commands:** `frontend/` (pnpm, pinned via packageManager).
- **Hygiene per commit** (every task's final pre-commit step): `pnpm lint && pnpm format && pnpm check && pnpm build` — all must pass (oxlint --deny-warnings, oxfmt, svelte-check, vite build).
- **No new npm dependencies.** Monaco stays pinned exact `0.55.1`.
- **The webview always declares `author`/`by` = `"user"`** — author is declared, not authenticated (spec: one localhost token, trust-based by design).
- **Editor panes still never persist**; `layout.ts` and `manager.ts` are NOT touched by this slice.
- **The backtick prefix is untouched.** The comment keybinding ⌘⇧M lives inside Monaco's keybinding layer. The only App.svelte change is a narrow keydown guard for `.thread-zone` textareas (comments about code contain backticks; the capture-phase prefix must not eat them). xterm and Monaco's own hidden textareas are NOT guarded — the prefix keeps working there.
- **Fail open on protocol skew** (rook-host outlives app installs): GET threads 404 → empty list + `console.warn`, review keeps working; mutations → visible error (inline `.thread-err` in the widget, or titlebar flash for submit) with the existing " 404 " → "needs a newer rook-host" message.
- **No polling.** Threads refetch with the existing cycles: on load, on manual ⟳, on focus when >2 s stale, and after every mutation. A refetch must never destroy a textarea holding unsent text (draft preservation).
- **Monaco discipline:** `term/threads.ts` imports monaco **types only**; the live `monaco` namespace arrives as a constructor parameter from `EditorPane` (which lazy-imports it) — nothing new lands in the boot bundle.
- **Node test suites** live in the session scratchpad: `/private/tmp/claude-501/-Users-sethlowie-go-src-github-com-incantery-rook/a17c11fe-fd45-44d5-9891-8f501efdbee3/scratchpad/` (referred to as `$SCRATCH` below). They are dev tools, not repo assets — never commit them.

## Verified ground truth (do not re-derive)

- **Host API (slice 2a, `internal/host/threads.go`):** `GET /workspaces/{ws}/threads?state=&path=` → `[]ThreadInfo` (comments inline, `currentStart`/`currentEnd`/`outdated` computed on read). `POST /workspaces/{ws}/threads` body `{path, startLine, endLine, side?, base?, body}` → ThreadInfo (side defaults `modified`; `base` only matters for `side=original`). `POST /threads/{id}/comments` `{body, author, agentSession?}` → 204. `POST /threads/{id}/resolve` and `/reopen` `{by}` → 204, 409 on wrong state. `POST /workspaces/{ws}/threads/submit` → `{mode: "typed"|"spawned", rookSession, count}`, 400 "nothing to submit". Re-nudge: zero pending but open threads awaiting the agent (last comment by user) → submit nudges again.
- **Monaco 0.55.1 facts (verified in node_modules):** view-zone `domNode`s are absolutely-positioned children of the `.view-zones` layer with NO `pointer-events: none` — interactive textareas/buttons inside zones work directly; `suppressMouseDown` defaults to false and must stay unset. `IViewZone.heightInPx` is re-read by `changeViewZones(a => a.layoutZone(id))` — mutate the held zone object, then layout. `editor.createDecorationsCollection()` exists on `ICodeEditor`. Glyph margin needs `glyphMargin: true` in construction options (applies to both diff children). Glyph clicks: `editor.onMouseDown`, `e.target.type === monaco.editor.MouseTargetType.GUTTER_GLYPH_MARGIN`, line via `e.target.position.lineNumber`.
- **Focus routing is safe:** `setFocusedPane` (manager.ts) early-returns when the pane is already focused, and mousedown's default action (textarea focus) runs after the capture handler — clicking a zone textarea keeps focus in it. The real hazard is `EditorPane.focus()`'s stale-refresh tearing down zones: guarded via `hasDraft()`.
- **Diff-editor alignment quirk (accepted):** a custom zone on one side is not mirrored on the other, so line alignment below an open widget skews until it closes. Accepted for this slice.
- **CSS vars in app.css:** `--mono`, `--line`, `--dim`, `--fg`, `--acc`. Editor pane block is at the `/* ==== editor pane` comment; append thread styles after `.editor-status`.
- **`editor.ts` today:** `EditorPane` builds head DOM in ctor (`baseBtn ‹ › counter path note ⟳ ×`), `load()` → `refresh()` (review) / `loadFile()` (file), `open(i)` swaps models on `ensureDiffEditor()`, `focus()` refetches review when >2 s stale, `fail()` maps " 404 " to the relaunch flash. `this.monaco` is the lazy-loaded namespace.

## File structure

- Modify `frontend/src/hostapi.ts` — thread methods + result interfaces (Task 1)
- Create `frontend/src/term/threadview.ts` — pure view-model helpers, node-testable (Task 2)
- Create `frontend/src/term/threads.ts` — `ThreadBand`: decorations, widgets, composer (Tasks 3–5)
- Modify `frontend/src/term/editor.ts` — orchestration: fetch, bands, hooks, action, submit (Tasks 3–6)
- Modify `frontend/src/App.svelte` — one keydown guard (Task 4)
- Modify `frontend/src/app.css` — thread styles (Tasks 3, 4, 6)

---

### Task 1: hostapi thread methods

**Files:**
- Modify: `frontend/src/hostapi.ts`
- Test: `$SCRATCH/hostapi-test/{run.sh,test.mjs}`

**Interfaces:**
- Consumes: the slice-2a HTTP endpoints (ground truth above).
- Produces (later tasks import these exact names from `../hostapi`):
  - `interface ThreadComment {id: number; author: "user"|"agent"; agentSession?: string; body: string; created: string}`
  - `interface ThreadInfo {id: number; workspace: string; path: string; startLine: number; endLine: number; side: "modified"|"original"; blobSha: string; commitSha?: string; anchorText: string; state: "pending"|"open"|"resolved"; resolvedBy?: "user"|"agent"; agentReopens?: number; created: string; updated: string; submitted?: string; comments: ThreadComment[]; currentStart: number; currentEnd: number; outdated?: boolean}`
  - `interface ThreadsSubmitResult {mode: "typed"|"spawned"; rookSession: string; count: number}`
  - Methods on `HostAPI`: `threads(ws, opts?) → Promise<ThreadInfo[]>`, `createThread(ws, req) → Promise<ThreadInfo>`, `threadComment(id, body) → Promise<void>`, `threadResolve(id) → Promise<void>`, `threadReopen(id) → Promise<void>`, `submitThreads(ws) → Promise<ThreadsSubmitResult>`.

- [ ] **Step 1: Write the failing test**

Create `$SCRATCH/hostapi-test/run.sh` (`chmod +x`):

```sh
#!/bin/sh -e
cd "$(dirname "$0")"
FE=/Users/sethlowie/go/src/github.com/incantery/rook/frontend
rm -rf build && mkdir build
cp "$FE/src/hostapi.ts" build/
"$FE/node_modules/.bin/tsc" --module esnext --target es2022 --lib es2022,dom --skipLibCheck build/hostapi.ts
node test.mjs
```

Create `$SCRATCH/hostapi-test/test.mjs`:

```js
// Pins the wire shapes of HostAPI's thread methods against a stub server:
// exact URLs, methods, JSON bodies, auth header, and author/by = "user".
import assert from "node:assert/strict";
import http from "node:http";
import {HostAPI} from "./build/hostapi.js";

const reqs = [];
const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
        reqs.push({method: req.method, url: req.url, auth: req.headers.authorization, body});
        res.setHeader("content-type", "application/json");
        if (req.url.endsWith("/threads/submit")) {
            res.end(JSON.stringify({mode: "typed", rookSession: "s1", count: 2}));
        } else if (req.method === "POST" && req.url.endsWith("/threads")) {
            res.end(JSON.stringify({id: 7}));
        } else if (req.method === "GET") {
            res.end("[]");
        } else {
            res.statusCode = 204;
            res.end();
        }
    });
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const api = new HostAPI(`http://127.0.0.1:${server.address().port}`, "tok");

await api.threads("my ws");
await api.threads("w", {state: "pending", path: "a b.go"});
await api.createThread("w", {
    path: "main.go", startLine: 3, endLine: 5, side: "original", base: "branch", body: "why?",
});
await api.threadComment(7, "hi");
await api.threadResolve(7);
await api.threadReopen(7);
const sub = await api.submitThreads("w");

assert.equal(reqs[0].method, "GET");
assert.equal(reqs[0].url, "/workspaces/my%20ws/threads");
assert.equal(reqs[0].auth, "Bearer tok");
assert.equal(reqs[1].url, "/workspaces/w/threads?state=pending&path=a+b.go");
assert.equal(reqs[2].method, "POST");
assert.equal(reqs[2].url, "/workspaces/w/threads");
assert.deepEqual(JSON.parse(reqs[2].body), {
    path: "main.go", startLine: 3, endLine: 5, side: "original", base: "branch", body: "why?",
});
assert.equal(reqs[3].url, "/threads/7/comments");
assert.deepEqual(JSON.parse(reqs[3].body), {body: "hi", author: "user"});
assert.equal(reqs[4].url, "/threads/7/resolve");
assert.deepEqual(JSON.parse(reqs[4].body), {by: "user"});
assert.equal(reqs[5].url, "/threads/7/reopen");
assert.deepEqual(JSON.parse(reqs[5].body), {by: "user"});
assert.equal(reqs[6].method, "POST");
assert.equal(reqs[6].url, "/workspaces/w/threads/submit");
assert.deepEqual(sub, {mode: "typed", rookSession: "s1", count: 2});
server.close();
console.log("hostapi threads: all assertions passed");
```

- [ ] **Step 2: Run it to verify it fails**

Run: `$SCRATCH/hostapi-test/run.sh`
Expected: FAIL — tsc error or `api.threads is not a function` (the methods don't exist yet).

- [ ] **Step 3: Implement**

In `frontend/src/hostapi.ts`, add methods inside `class HostAPI`, directly after the `listFiles` method:

```ts
    /** All of a workspace's threads — comments inline, ranges re-anchored
     *  on read (currentStart/currentEnd, outdated). The pane fetches
     *  everything and slices locally; filters exist for cheaper pulls. */
    async threads(ws: string, opts?: {state?: string; path?: string}): Promise<ThreadInfo[]> {
        const q = new URLSearchParams();
        if (opts?.state) q.set("state", opts.state);
        if (opts?.path) q.set("path", opts.path);
        const qs = q.size > 0 ? `?${q}` : "";
        return (await this.req(`/workspaces/${encodeURIComponent(ws)}/threads${qs}`)).json();
    }

    /** Comment on a file range → a pending thread. The host snapshots the
     *  anchored content NOW; base only matters for side=original (which
     *  ref the original text came from). */
    async createThread(
        ws: string,
        req: {
            path: string;
            startLine: number;
            endLine: number;
            side?: "modified" | "original";
            base?: "head" | "branch";
            body: string;
        },
    ): Promise<ThreadInfo> {
        return (
            await this.req(`/workspaces/${encodeURIComponent(ws)}/threads`, {
                method: "POST",
                body: JSON.stringify(req),
            })
        ).json();
    }

    /** The webview IS the user — author is declared, and here always "user". */
    async threadComment(id: number, body: string): Promise<void> {
        await this.req(`/threads/${id}/comments`, {
            method: "POST",
            body: JSON.stringify({body, author: "user"}),
        });
    }

    async threadResolve(id: number): Promise<void> {
        await this.req(`/threads/${id}/resolve`, {
            method: "POST",
            body: JSON.stringify({by: "user"}),
        });
    }

    async threadReopen(id: number): Promise<void> {
        await this.req(`/threads/${id}/reopen`, {
            method: "POST",
            body: JSON.stringify({by: "user"}),
        });
    }

    /** Flip pending→open and nudge the responder — or re-nudge when open
     *  threads still await the agent. 400 = nothing to submit. */
    async submitThreads(ws: string): Promise<ThreadsSubmitResult> {
        return (
            await this.req(`/workspaces/${encodeURIComponent(ws)}/threads/submit`, {
                method: "POST",
                body: "{}",
            })
        ).json();
    }
```

Add interfaces after the `FilesResult` interface:

```ts
/** One utterance in a thread. Author is declared, not authenticated —
 *  every client shares the one localhost token (spec, by design). */
export interface ThreadComment {
    id: number;
    author: "user" | "agent";
    agentSession?: string;
    body: string;
    created: string;
}

/** A file-anchored AI conversation (GET /workspaces/{ws}/threads). The
 *  current* fields are computed on read — the stored anchor mapped onto
 *  today's file; outdated means the anchored lines themselves changed
 *  (render anchorText instead of pointing at live lines). */
export interface ThreadInfo {
    id: number;
    workspace: string;
    path: string;
    startLine: number;
    endLine: number;
    side: "modified" | "original";
    blobSha: string;
    commitSha?: string;
    anchorText: string;
    state: "pending" | "open" | "resolved";
    resolvedBy?: "user" | "agent";
    agentReopens?: number;
    created: string;
    updated: string;
    submitted?: string;
    comments: ThreadComment[];
    currentStart: number;
    currentEnd: number;
    outdated?: boolean;
}

/** POST /workspaces/{ws}/threads/submit — how the nudge landed. */
export interface ThreadsSubmitResult {
    mode: "typed" | "spawned";
    rookSession: string;
    count: number;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `$SCRATCH/hostapi-test/run.sh`
Expected: `hostapi threads: all assertions passed`

- [ ] **Step 5: Hygiene + commit**

```bash
cd frontend && pnpm lint && pnpm format && pnpm check && pnpm build
cd .. && git add frontend/src/hostapi.ts
git commit -m "frontend: hostapi thread methods — the pane's wire to slice 2a"
```

---

### Task 2: threadview — pure view-model helpers

**Files:**
- Create: `frontend/src/term/threadview.ts`
- Test: `$SCRATCH/threadview-test/{run.sh,test.mjs}`

**Interfaces:**
- Consumes: `ThreadInfo` from `../hostapi` (Task 1) — type-only.
- Produces (Tasks 3–6 import these exact names from `./threadview`):
  - `type Side = "modified" | "original"`
  - `bandThreads(all: ThreadInfo[], path: string, side: Side): ThreadInfo[]`
  - `markerLines(threads: ThreadInfo[]): Map<number, ThreadInfo[]>`
  - `glyphClass(group: ThreadInfo[]): string`
  - `pendingCount(all: ThreadInfo[]): number`
  - `awaitingAgent(all: ThreadInfo[]): number`
  - `submitLabel(all: ThreadInfo[]): string`

- [ ] **Step 1: Write the failing test**

Create `$SCRATCH/threadview-test/run.sh` (`chmod +x`):

```sh
#!/bin/sh -e
cd "$(dirname "$0")"
FE=/Users/sethlowie/go/src/github.com/incantery/rook/frontend
rm -rf build && mkdir -p build/term
cp "$FE/src/hostapi.ts" build/
cp "$FE/src/term/threadview.ts" build/term/
"$FE/node_modules/.bin/tsc" --module esnext --target es2022 --lib es2022,dom --skipLibCheck \
    build/hostapi.ts build/term/threadview.ts
node test.mjs
```

Create `$SCRATCH/threadview-test/test.mjs`:

```js
// Pins the thread view-model: band slicing, marker grouping, glyph state
// precedence, and the submit button's label state machine.
import assert from "node:assert/strict";
import {
    awaitingAgent, bandThreads, glyphClass, markerLines, pendingCount, submitLabel,
} from "./build/term/threadview.js";

// minimal ThreadInfo factory — only the fields the helpers read
const T = (o) => ({
    id: 1, workspace: "w", path: "a.go", startLine: 1, endLine: 1,
    side: "modified", blobSha: "", anchorText: "", state: "open",
    created: "", updated: "", comments: [],
    currentStart: 1, currentEnd: 1, ...o,
});

// bandThreads: filters (path, side), sorts by currentStart then id
{
    const all = [
        T({id: 3, path: "a.go", currentStart: 9}),
        T({id: 1, path: "b.go", currentStart: 2}),
        T({id: 2, path: "a.go", currentStart: 4}),
        T({id: 5, path: "a.go", currentStart: 4}),
        T({id: 4, path: "a.go", side: "original", currentStart: 1}),
    ];
    assert.deepEqual(bandThreads(all, "a.go", "modified").map((t) => t.id), [2, 5, 3]);
    assert.deepEqual(bandThreads(all, "a.go", "original").map((t) => t.id), [4]);
    assert.deepEqual(bandThreads(all, "c.go", "modified"), []);
}

// markerLines: groups by currentStart, clamps below 1 up to line 1
{
    const m = markerLines([
        T({id: 1, currentStart: 4}), T({id: 2, currentStart: 4}),
        T({id: 3, currentStart: 0}),
    ]);
    assert.deepEqual([...m.keys()], [4, 1]);
    assert.equal(m.get(4).length, 2);
    assert.equal(m.get(1)[0].id, 3);
}

// glyphClass: pending > open > resolved; outdated is a modifier
{
    assert.equal(glyphClass([T({state: "resolved"})]), "thread-glyph thread-glyph-resolved");
    assert.equal(
        glyphClass([T({state: "resolved"}), T({state: "open"})]),
        "thread-glyph thread-glyph-open",
    );
    assert.equal(
        glyphClass([T({state: "open"}), T({state: "pending", outdated: true})]),
        "thread-glyph thread-glyph-pending thread-glyph-outdated",
    );
}

// pendingCount / awaitingAgent / submitLabel
{
    const c = (author) => ({id: 1, author, body: "x", created: ""});
    assert.equal(pendingCount([T({state: "pending"}), T({state: "open"})]), 1);
    // awaiting agent = open AND last comment authored by the user
    assert.equal(awaitingAgent([T({state: "open", comments: [c("user")]})]), 1);
    assert.equal(awaitingAgent([T({state: "open", comments: [c("user"), c("agent")]})]), 0);
    assert.equal(awaitingAgent([T({state: "pending", comments: [c("user")]})]), 0);
    assert.equal(awaitingAgent([T({state: "open", comments: []})]), 0);
    assert.equal(submitLabel([T({state: "pending"}), T({state: "pending"})]), "submit 2");
    assert.equal(submitLabel([T({state: "open", comments: [c("user")]})]), "nudge again");
    assert.equal(submitLabel([T({state: "open", comments: [c("user"), c("agent")]})]), "");
    assert.equal(submitLabel([]), "");
}

console.log("threadview: all assertions passed");
```

- [ ] **Step 2: Run it to verify it fails**

Run: `$SCRATCH/threadview-test/run.sh`
Expected: FAIL — `cp` errors (threadview.ts doesn't exist).

- [ ] **Step 3: Implement**

Create `frontend/src/term/threadview.ts`:

```ts
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `$SCRATCH/threadview-test/run.sh`
Expected: `threadview: all assertions passed`

- [ ] **Step 5: Hygiene + commit**

```bash
cd frontend && pnpm lint && pnpm format && pnpm check && pnpm build
cd .. && git add frontend/src/term/threadview.ts
git commit -m "frontend: threadview — pure view-model for the thread UI"
```

---

### Task 3: gutter markers in the panes

**Files:**
- Create: `frontend/src/term/threads.ts` (v1 — markers only)
- Modify: `frontend/src/term/editor.ts`
- Modify: `frontend/src/app.css`

**Interfaces:**
- Consumes: `ThreadInfo`, `HostAPI.threads` (Task 1); `bandThreads`, `glyphClass`, `markerLines`, `Side` (Task 2).
- Produces: `class ThreadBand` with `constructor(monaco, editor, side)`, `render(all: ThreadInfo[], path: string): void`, `dispose(): void` — Task 4 REPLACES this file wholesale, so keep it exactly as written here. `EditorPane` gains `threadsAll`, `bands`, `fetchThreads()`, `currentPath()`, `rebuildBands()` — Task 4 modifies `rebuildBands`.

No node test — this is Monaco/DOM territory; the type-checker, build, and the live GUI checklist are the verification (svelte-check catches interface drift against Tasks 1–2).

- [ ] **Step 1: Create `frontend/src/term/threads.ts`**

```ts
// The thread layer on ONE Monaco editor: gutter markers for the file's
// threads on one diff side, later widgets and the composer. Framework-
// free DOM like the rest of the island. Monaco arrives as a constructor
// param (types only here) — this module must never grow an import edge
// that drags Monaco into an eager chunk.

import type * as monacoTypes from "monaco-editor";
import type {ThreadInfo} from "../hostapi";
import {bandThreads, glyphClass, markerLines, type Side} from "./threadview";

type Monaco = typeof monacoTypes;
type ICodeEditor = monacoTypes.editor.ICodeEditor;

export class ThreadBand {
    private decorations: monacoTypes.editor.IEditorDecorationsCollection;
    private threads: ThreadInfo[] = [];

    constructor(
        private monaco: Monaco,
        readonly editor: ICodeEditor,
        readonly side: Side,
    ) {
        this.decorations = editor.createDecorationsCollection();
    }

    /** all = the workspace's threads; the band slices its own. */
    render(all: ThreadInfo[], path: string): void {
        this.threads = bandThreads(all, path, this.side);
        const decs: monacoTypes.editor.IModelDeltaDecoration[] = [];
        for (const [line, group] of markerLines(this.threads)) {
            decs.push({
                range: new this.monaco.Range(line, 1, line, 1),
                options: {
                    glyphMarginClassName: glyphClass(group),
                    glyphMarginHoverMessage: {
                        value: `${group.length} thread${group.length === 1 ? "" : "s"}`,
                    },
                },
            });
        }
        this.decorations.set(decs);
    }

    dispose(): void {
        this.decorations.clear();
    }
}
```

- [ ] **Step 2: Wire the pane** (`frontend/src/term/editor.ts`)

2a. Extend the imports at the top:

```ts
import type {ChangedFile, HostAPI, ThreadInfo} from "../hostapi";
import type {PaneContent} from "./manager";
import type * as monacoTypes from "monaco-editor";
import {ThreadBand} from "./threads";
```

2b. Add fields after `private seq = 0;`:

```ts
    /** every thread in the workspace — bands slice per (path, side) */
    private threadsAll: ThreadInfo[] = [];
    private bands: ThreadBand[] = [];
```

2c. In `editorOpts()`, add `glyphMargin: true,` directly after `readOnly: true,`.

2d. In `refresh()`, directly BEFORE the line
`const res = await this.api.changes(this.opts.workspace, this.base);`
insert (threads ride the same fetch cycle but never gate it — a hanging
`/threads` must not stall a diff the pane already has; fail open):

```ts
            void this.fetchThreads().then(() => {
                const p = this.currentPath();
                if (this.disposed || !p) return;
                for (const b of this.bands) b.render(this.threadsAll, p);
            });
```

2e. In `open(i)`, add `this.rebuildBands();` immediately after the `this.fit();` line (the success path's tail).

2f. In `loadFile()`, directly BEFORE the line
`const res = await this.api.readFile(this.opts.workspace, path);`
insert the same non-gating fetch:

```ts
            void this.fetchThreads().then(() => {
                const p = this.currentPath();
                if (this.disposed || !p) return;
                for (const b of this.bands) b.render(this.threadsAll, p);
            });
```

and add `this.rebuildBands();` immediately after its `this.fit();` line.

2g. In `dispose()`, add before `this.disposeModels();`:

```ts
        for (const b of this.bands) b.dispose();
```

2h. Add a new section before `// ---- monaco plumbing ----`:

```ts
    // ---- threads: the conversation layer (term/threads.ts) ----

    /** Thread-less daemons must not take the review pane down — the list
     *  just stays empty (fail open, the protocol-skew rule). */
    private async fetchThreads(): Promise<void> {
        try {
            this.threadsAll = await this.api.threads(this.opts.workspace);
        } catch (err) {
            console.warn("editor pane: threads unavailable:", err);
        }
    }

    private currentPath(): string | undefined {
        return this.opts.kind === "file" ? this.opts.path : this.files[this.idx]?.path;
    }

    /** Editors persist across file navs but models don't — decorations
     *  and zones live on the model/view, so bands rebuild per nav. */
    private rebuildBands(): void {
        for (const b of this.bands) b.dispose();
        this.bands = [];
        const m = this.monaco;
        const path = this.currentPath();
        if (!m || !path) return;
        if (this.diffEditor) {
            this.bands = [
                new ThreadBand(m, this.diffEditor.getOriginalEditor(), "original"),
                new ThreadBand(m, this.diffEditor.getModifiedEditor(), "modified"),
            ];
        } else if (this.editor) {
            this.bands = [new ThreadBand(m, this.editor, "modified")];
        }
        for (const b of this.bands) b.render(this.threadsAll, path);
    }
```

- [ ] **Step 3: Glyph CSS** — in `frontend/src/app.css`, append after the `.editor-status` rule block:

```css
/* ==== threads (term/threads.ts): gutter glyphs + zone widgets ==== */
.thread-glyph {
    display: flex;
    align-items: center;
    justify-content: center;
    cursor: pointer;
    font-size: 9px;
}
.thread-glyph::before {
    content: "●";
}
.thread-glyph-pending {
    color: #ffcb6b;
}
.thread-glyph-pending::before {
    content: "◐"; /* half-full: written but not yet submitted */
}
.thread-glyph-open {
    color: #82aaff;
}
.thread-glyph-resolved {
    color: #464b66;
}
.thread-glyph-outdated::before {
    content: "◌"; /* the anchor no longer matches the file */
}
```

- [ ] **Step 4: Verify by hygiene gates**

```bash
cd frontend && pnpm lint && pnpm format && pnpm check && pnpm build
```
Expected: all green — svelte-check pins the ThreadBand/HostAPI/threadview interfaces against each other. Marker rendering itself is confirmed live in the end-of-plan GUI checklist (creating threads needs `rookctl comment` from the 2a branch, which is already underneath this stacked branch).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/term/threads.ts frontend/src/term/editor.ts frontend/src/app.css
git commit -m "frontend: thread markers in the Monaco gutters"
```

---

### Task 4: thread widgets — read, reply, resolve, reopen

**Files:**
- Modify: `frontend/src/term/threads.ts` (REPLACE with v2 below — markers + widgets)
- Modify: `frontend/src/term/editor.ts` (hooks + refetch, rebuildBands update)
- Modify: `frontend/src/App.svelte` (keydown guard)
- Modify: `frontend/src/app.css` (widget styles)

**Interfaces:**
- Consumes: Task 1 methods `threadComment`/`threadResolve`/`threadReopen`; Task 3's pane fields.
- Produces:
  - `interface BandHooks {reply(id, body): Promise<void>; resolve(id): Promise<void>; reopen(id): Promise<void>; create(startLine, endLine, body): Promise<void>}` (create is used by Task 5's composer; defined now so the interface is stable)
  - `ThreadBand` constructor becomes `(monaco, editor, side, hooks: BandHooks)`; `render(all, path, reopen?: Set<number>)`; new `openThreadIds(): number[]`.
  - `EditorPane` gains `refetchThreads()` and `bandHooks(side)`.
- Behavior contract: **a refetch/render must never rebuild a widget whose textarea holds unsent text** (`zoneBusy`); a successful reply clears the textarea BEFORE the hook so the refetch renders it; a failed reply restores the draft; reopen focuses the reply box afterward (2a rider: a reopened thread only awaits the agent again once the user says why).

- [ ] **Step 1: Replace `frontend/src/term/threads.ts` with v2**

```ts
// The thread layer on ONE Monaco editor: gutter markers, and view-zone
// widgets for reading and driving conversations on one diff side.
// Framework-free DOM like the rest of the island. Monaco arrives as a
// constructor param (types only here) — this module must never grow an
// import edge that drags Monaco into an eager chunk.
//
// Zone mechanics (verified against pinned 0.55.1): zone domNodes receive
// pointer events as long as suppressMouseDown stays unset; heights are
// fixed, so every content change re-measures the card and layoutZone()s.

import type * as monacoTypes from "monaco-editor";
import type {ThreadInfo} from "../hostapi";
import {bandThreads, glyphClass, markerLines, type Side} from "./threadview";

type Monaco = typeof monacoTypes;
type ICodeEditor = monacoTypes.editor.ICodeEditor;

/** Mutations, owned by the pane: it calls the API, refetches, and
 *  re-renders every band — the band never patches its own data. Hooks
 *  reject on failure; the band shows the error inline. */
export interface BandHooks {
    reply(id: number, body: string): Promise<void>;
    resolve(id: number): Promise<void>;
    reopen(id: number): Promise<void>;
    create(startLine: number, endLine: number, body: string): Promise<void>;
}

interface Zone {
    id: string;
    zone: monacoTypes.editor.IViewZone;
    dom: HTMLElement; // .thread-zone (the zone's domNode)
    card: HTMLElement; // .thread-card inside it
}

export class ThreadBand {
    private decorations: monacoTypes.editor.IEditorDecorationsCollection;
    private threads: ThreadInfo[] = [];
    private zones = new Map<number, Zone>(); // thread id → open widget
    private mouseSub: monacoTypes.IDisposable;
    /** focus this thread's reply box on its next refresh (post-reopen) */
    private focusReply: number | null = null;

    constructor(
        private monaco: Monaco,
        readonly editor: ICodeEditor,
        readonly side: Side,
        private hooks: BandHooks,
    ) {
        this.decorations = editor.createDecorationsCollection();
        this.mouseSub = editor.onMouseDown((e) => {
            if (e.target.type !== this.monaco.editor.MouseTargetType.GUTTER_GLYPH_MARGIN) return;
            const line = e.target.position?.lineNumber;
            if (line && markerLines(this.threads).has(line)) this.toggleLine(line);
        });
    }

    /** all = the workspace's threads; the band slices its own. Open
     *  widgets refresh against the new data — except any holding a draft
     *  (the user is mid-thought; never yank the DOM out from under them).
     *  reopen = widget ids to restore after a band rebuild. */
    render(all: ThreadInfo[], path: string, reopen?: Set<number>): void {
        this.threads = bandThreads(all, path, this.side);
        const decs: monacoTypes.editor.IModelDeltaDecoration[] = [];
        for (const [line, group] of markerLines(this.threads)) {
            decs.push({
                range: new this.monaco.Range(line, 1, line, 1),
                options: {
                    glyphMarginClassName: glyphClass(group),
                    glyphMarginHoverMessage: {
                        value: `${group.length} thread${group.length === 1 ? "" : "s"}`,
                    },
                },
            });
        }
        this.decorations.set(decs);
        for (const [tid, z] of [...this.zones]) {
            if (this.zoneBusy(z)) continue;
            const t = this.threads.find((x) => x.id === tid);
            if (t) this.refreshZone(t, z);
            else this.closeZone(tid);
        }
        if (reopen) {
            for (const t of this.threads) if (reopen.has(t.id)) this.openZone(t);
        }
    }

    openThreadIds(): number[] {
        return [...this.zones.keys()];
    }

    /** True while any textarea in this band holds unsent text — the
     *  signal that auto-refetch must keep its hands off. */
    hasDraft(): boolean {
        for (const z of this.zones.values()) if (this.zoneBusy(z)) return true;
        return false;
    }

    dispose(): void {
        this.mouseSub.dispose();
        this.decorations.clear();
        for (const tid of [...this.zones.keys()]) this.closeZone(tid);
    }

    // ---- widgets ----

    private zoneBusy(z: Zone): boolean {
        for (const i of z.dom.querySelectorAll("textarea")) {
            if (i.value.trim() !== "") return true;
        }
        return false;
    }

    private toggleLine(line: number): void {
        const group = markerLines(this.threads).get(line) ?? [];
        const allOpen = group.every((t) => this.zones.has(t.id));
        for (const t of group) {
            if (allOpen) this.closeZone(t.id);
            else this.openZone(t);
        }
    }

    private openZone(t: ThreadInfo): void {
        if (this.zones.has(t.id)) return;
        const dom = document.createElement("div");
        dom.className = "thread-zone";
        const card = this.buildCard(t);
        dom.appendChild(card);
        const zone: monacoTypes.editor.IViewZone = {
            afterLineNumber: Math.max(1, t.currentEnd),
            heightInPx: 60,
            domNode: dom,
        };
        let id = "";
        this.editor.changeViewZones((a) => {
            id = a.addZone(zone);
        });
        const z: Zone = {id, zone, dom, card};
        this.zones.set(t.id, z);
        this.sizeZone(z);
    }

    private closeZone(tid: number): void {
        const z = this.zones.get(tid);
        if (!z) return;
        this.zones.delete(tid);
        this.editor.changeViewZones((a) => a.removeZone(z.id));
    }

    private refreshZone(t: ThreadInfo, z: Zone): void {
        const card = this.buildCard(t);
        z.card.replaceWith(card);
        z.card = card;
        this.sizeZone(z);
        if (this.focusReply === t.id) {
            this.focusReply = null;
            requestAnimationFrame(() => card.querySelector("textarea")?.focus());
        }
    }

    /** Zones are fixed-height; measure the card once it's laid out and
     *  tell Monaco. layoutZone re-reads the SAME zone object's height. */
    private sizeZone(z: Zone): void {
        requestAnimationFrame(() => {
            const h = z.card.offsetHeight + 8;
            if (h === z.zone.heightInPx) return;
            z.zone.heightInPx = h;
            this.editor.changeViewZones((a) => a.layoutZone(z.id));
        });
    }

    private buildCard(t: ThreadInfo): HTMLElement {
        const card = document.createElement("div");
        card.className = "thread-card";
        const head = document.createElement("div");
        head.className = "thread-row";
        const state = document.createElement("span");
        state.className = `thread-state thread-state-${t.state}`;
        state.textContent = t.state;
        const meta = document.createElement("span");
        meta.className = "thread-meta";
        const range =
            t.currentStart === t.currentEnd
                ? `L${t.currentStart}`
                : `L${t.currentStart}–${t.currentEnd}`;
        meta.textContent =
            `#${t.id} · ${range}` +
            (t.outdated ? " · outdated" : "") +
            (t.resolvedBy ? ` · by ${t.resolvedBy}` : "");
        head.append(state, meta);
        card.appendChild(head);
        if (t.outdated && t.anchorText) {
            // the lines commented on, as they were — the live file moved on
            const anchor = document.createElement("pre");
            anchor.className = "thread-anchor";
            anchor.textContent = t.anchorText;
            card.appendChild(anchor);
        }
        for (const c of t.comments) {
            const row = document.createElement("div");
            row.className = "thread-comment";
            const who = document.createElement("span");
            who.className = `thread-author thread-author-${c.author}`;
            who.textContent = c.author;
            const body = document.createElement("div");
            body.className = "thread-body";
            body.textContent = c.body;
            row.append(who, body);
            card.appendChild(row);
        }
        card.appendChild(this.buildActions(t));
        return card;
    }

    private buildActions(t: ThreadInfo): HTMLElement {
        const wrap = document.createElement("div");
        wrap.className = "thread-reply";
        const input = document.createElement("textarea");
        input.className = "thread-input";
        input.rows = 1;
        input.placeholder = "reply… (⌘⏎ sends · esc collapses)";
        const err = document.createElement("div");
        err.className = "thread-err";
        err.hidden = true;
        const row = document.createElement("div");
        row.className = "thread-row";
        const run = (fn: () => Promise<void>) => async () => {
            err.hidden = true;
            for (const b of row.querySelectorAll("button")) b.disabled = true;
            try {
                await fn();
            } catch (e) {
                err.textContent = String(e);
                err.hidden = false;
            } finally {
                for (const b of row.querySelectorAll("button")) b.disabled = false;
                const z = this.zones.get(t.id);
                if (z) this.sizeZone(z);
            }
        };
        const reply = this.actBtn(
            "reply",
            run(async () => {
                const body = input.value.trim();
                if (!body) return;
                // clear BEFORE the hook: its refetch skips draft-holding
                // widgets, and this reply must render as a comment
                input.value = "";
                try {
                    await this.hooks.reply(t.id, body);
                } catch (e) {
                    input.value = body; // a failed reply is not an eaten draft
                    throw e;
                }
            }),
        );
        row.appendChild(reply);
        row.appendChild(
            t.state === "resolved"
                ? this.actBtn(
                      "reopen",
                      run(async () => {
                          // a reopen without a why isn't actionable — cursor
                          // goes to the reply box once the refresh lands
                          this.focusReply = t.id;
                          try {
                              await this.hooks.reopen(t.id);
                          } catch (e) {
                              this.focusReply = null;
                              throw e;
                          }
                      }),
                  )
                : this.actBtn("resolve", run(() => this.hooks.resolve(t.id))),
        );
        input.addEventListener("keydown", (e) => {
            if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                e.preventDefault();
                reply.click();
            } else if (e.key === "Escape") {
                this.closeZone(t.id);
            }
        });
        input.addEventListener("input", () => {
            input.rows = Math.min(6, input.value.split("\n").length);
            const z = this.zones.get(t.id);
            if (z) this.sizeZone(z);
        });
        wrap.append(input, row, err);
        return wrap;
    }

    private actBtn(label: string, onClick: () => void | Promise<void>): HTMLButtonElement {
        const b = document.createElement("button");
        b.className = "editor-btn thread-act";
        b.textContent = label;
        b.addEventListener("click", () => void onClick());
        return b;
    }
}
```

- [ ] **Step 2: Pane hooks** (`frontend/src/term/editor.ts`)

2a. Extend the threads import:

```ts
import {ThreadBand, type BandHooks} from "./threads";
```

2b. In the `// ---- threads` section, add after `currentPath()`:

```ts
    /** Mutations refetch and re-render — the pane's data is always the
     *  host's answer, never locally patched. */
    private async refetchThreads(): Promise<void> {
        await this.fetchThreads();
        const path = this.currentPath();
        if (!path) return;
        for (const b of this.bands) b.render(this.threadsAll, path);
    }

    private bandHooks(side: "modified" | "original"): BandHooks {
        return {
            reply: async (id, body) => {
                await this.api.threadComment(id, body);
                await this.refetchThreads();
            },
            resolve: async (id) => {
                await this.api.threadResolve(id);
                await this.refetchThreads();
            },
            reopen: async (id) => {
                await this.api.threadReopen(id);
                await this.refetchThreads();
            },
            create: async (startLine, endLine, body) => {
                const path = this.currentPath();
                if (!path) return;
                await this.api.createThread(this.opts.workspace, {
                    path,
                    startLine,
                    endLine,
                    side,
                    base: side === "original" ? this.base : undefined,
                    body,
                });
                await this.refetchThreads();
            },
        };
    }
```

2c. Replace `rebuildBands()` with (open widgets survive file navs and refreshes; drafts don't survive an explicit rebuild — accepted, noted in Edge cases):

```ts
    /** Editors persist across file navs but models don't — decorations
     *  and zones live on the model/view, so bands rebuild per nav. Open
     *  widgets are restored by id where the new file still has them. */
    private rebuildBands(): void {
        const open = new Set(this.bands.flatMap((b) => b.openThreadIds()));
        for (const b of this.bands) b.dispose();
        this.bands = [];
        const m = this.monaco;
        const path = this.currentPath();
        if (!m || !path) return;
        if (this.diffEditor) {
            this.bands = [
                new ThreadBand(
                    m,
                    this.diffEditor.getOriginalEditor(),
                    "original",
                    this.bandHooks("original"),
                ),
                new ThreadBand(
                    m,
                    this.diffEditor.getModifiedEditor(),
                    "modified",
                    this.bandHooks("modified"),
                ),
            ];
        } else if (this.editor) {
            this.bands = [new ThreadBand(m, this.editor, "modified", this.bandHooks("modified"))];
        }
        for (const b of this.bands) b.render(this.threadsAll, path, open);
    }
```

- [ ] **Step 3: Keydown guard** (`frontend/src/App.svelte`)

In `onKeydown`, directly after the line `if (app.pickerOpen || app.filePickerOpen) return; // pickers' own inputs handle keys`, insert:

```ts
        // thread widgets own their keys: comments about code are full of
        // backticks, and the capture-phase prefix must not eat them. Only
        // .thread-zone is guarded — xterm's and Monaco's hidden textareas
        // are NOT, so the prefix keeps working everywhere else.
        const tgt = e.target as HTMLElement | null;
        if (tgt?.closest?.(".thread-zone")) return;
```

- [ ] **Step 4: Widget CSS** — append to the threads block in `frontend/src/app.css`:

```css
/* zone widgets: cards floating in the space a view zone reserves */
.thread-card {
    box-sizing: border-box;
    max-width: 640px;
    margin: 4px 12px 4px 4px;
    padding: 8px 10px;
    display: flex;
    flex-direction: column;
    gap: 6px;
    background: #151928;
    border: 1px solid #252a3d;
    border-radius: 6px;
    font-family: var(--mono);
    font-size: 12px;
    line-height: 1.45;
    color: var(--fg);
}
.thread-row {
    display: flex;
    align-items: center;
    gap: 6px;
}
.thread-state {
    flex: none;
    padding: 0 6px;
    border: 1px solid currentColor;
    border-radius: 999px;
    font-size: 9px;
    text-transform: uppercase;
    letter-spacing: 0.08em;
}
.thread-state-pending {
    color: #ffcb6b;
}
.thread-state-open {
    color: #82aaff;
}
.thread-state-resolved {
    color: #c3e88d;
}
.thread-meta {
    color: var(--dim);
    font-size: 10px;
    overflow: hidden;
    text-overflow: ellipsis;
}
/* outdated: the anchored lines as they were when commented */
.thread-anchor {
    margin: 0;
    padding: 4px 8px;
    background: #0b0d14;
    border-left: 2px solid #464b66;
    color: var(--dim);
    font-size: 11px;
    white-space: pre;
    overflow-x: auto;
}
.thread-comment {
    display: flex;
    flex-direction: column;
    gap: 2px;
}
.thread-author {
    font-size: 10px;
    color: #82aaff; /* agent */
}
.thread-author-user {
    color: #ffcb6b;
}
.thread-body {
    white-space: pre-wrap;
    overflow-wrap: anywhere;
}
.thread-reply {
    display: flex;
    flex-direction: column;
    gap: 4px;
}
.thread-input {
    box-sizing: border-box;
    width: 100%;
    min-height: 26px;
    padding: 4px 6px;
    background: #0b0d14;
    border: 1px solid #252a3d;
    border-radius: 4px;
    color: var(--fg);
    font-family: var(--mono);
    font-size: 12px;
    resize: vertical;
}
.thread-input:focus {
    outline: none;
    border-color: var(--acc);
}
.thread-err {
    color: #ff5370;
    font-size: 11px;
    overflow-wrap: anywhere;
}
```

- [ ] **Step 5: Hygiene + commit**

```bash
cd frontend && pnpm lint && pnpm format && pnpm check && pnpm build
cd .. && git add frontend/src/term/threads.ts frontend/src/term/editor.ts frontend/src/App.svelte frontend/src/app.css
git commit -m "frontend: thread widgets — read, reply, resolve, reopen in the pane"
```

---

### Task 5: composer — start threads from a selection

**Files:**
- Modify: `frontend/src/term/threads.ts` (add composer)
- Modify: `frontend/src/term/editor.ts` (comment action on every editor)

**Interfaces:**
- Consumes: `BandHooks.create` (Task 4), `ThreadBand` internals (`Zone`, `sizeZone`, `actBtn`).
- Produces: `ThreadBand.openComposer(startLine, endLine)`, `ThreadBand.closeComposer()`; `hasDraft()` now also covers the composer. `EditorPane.addCommentAction(ed, side)` registered once per editor.

- [ ] **Step 1: Composer in `frontend/src/term/threads.ts`**

1a. Add a field after `private focusReply: number | null = null;`:

```ts
    private composer: Zone | null = null;
```

1b. Replace `hasDraft()` with:

```ts
    /** True while any textarea in this band holds unsent text — the
     *  signal that auto-refetch must keep its hands off. */
    hasDraft(): boolean {
        for (const z of this.zones.values()) if (this.zoneBusy(z)) return true;
        return this.composer !== null && this.zoneBusy(this.composer);
    }
```

1c. In `dispose()`, add `this.closeComposer();` after `this.decorations.clear();`.

1d. Add before `// ---- widgets ----`:

```ts
    // ---- composer: selection → new pending thread ----

    /** One composer per band; opening again moves it. The pane maps the
     *  editor selection to lines and routes ⌘⇧M/context-menu here. */
    openComposer(startLine: number, endLine: number): void {
        this.closeComposer();
        const dom = document.createElement("div");
        dom.className = "thread-zone";
        const card = document.createElement("div");
        card.className = "thread-card";
        const meta = document.createElement("div");
        meta.className = "thread-meta";
        const lines = startLine === endLine ? `L${startLine}` : `L${startLine}–${endLine}`;
        meta.textContent = `new thread on ${lines}${this.side === "original" ? " (original side)" : ""}`;
        const input = document.createElement("textarea");
        input.className = "thread-input";
        input.rows = 3;
        input.placeholder = "start a thread… (⌘⏎ comments · esc cancels)";
        const err = document.createElement("div");
        err.className = "thread-err";
        err.hidden = true;
        const row = document.createElement("div");
        row.className = "thread-row";
        const save = this.actBtn("comment", async () => {
            const body = input.value.trim();
            if (!body) return;
            err.hidden = true;
            save.disabled = true;
            try {
                await this.hooks.create(startLine, endLine, body);
                this.closeComposer(); // the refetch renders the pending marker
            } catch (e) {
                err.textContent = String(e);
                err.hidden = false;
                if (this.composer) this.sizeZone(this.composer);
            } finally {
                save.disabled = false;
            }
        });
        row.append(save, this.actBtn("cancel", () => this.closeComposer()));
        input.addEventListener("keydown", (e) => {
            if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                e.preventDefault();
                save.click();
            } else if (e.key === "Escape") {
                this.closeComposer();
            }
        });
        card.append(meta, input, row, err);
        dom.appendChild(card);
        const zone: monacoTypes.editor.IViewZone = {
            afterLineNumber: endLine,
            heightInPx: 120,
            domNode: dom,
        };
        let id = "";
        this.editor.changeViewZones((a) => {
            id = a.addZone(zone);
        });
        this.composer = {id, zone, dom, card};
        this.sizeZone(this.composer);
        this.editor.revealLinesInCenterIfOutsideViewport(startLine, endLine);
        requestAnimationFrame(() => input.focus());
    }

    closeComposer(): void {
        const c = this.composer;
        if (!c) return;
        this.composer = null;
        this.editor.changeViewZones((a) => a.removeZone(c.id));
    }
```

- [ ] **Step 2: Comment action in `frontend/src/term/editor.ts`**

2a. In `ensureDiffEditor()`, after the `createDiffEditor` call (inside the `if`):

```ts
            this.addCommentAction(this.diffEditor.getOriginalEditor());
            this.addCommentAction(this.diffEditor.getModifiedEditor());
```

2b. In `ensureEditor()`, after the `create` call (inside the `if`):

```ts
            this.addCommentAction(this.editor);
```

2c. Add to the threads section, after `bandHooks`:

```ts
    /** ⌘⇧M / right-click → composer on the invoking editor's selection.
     *  Registered once per editor; the keybinding lives inside Monaco's
     *  own layer, so the backtick prefix is untouched. */
    private addCommentAction(ed: monacoTypes.editor.ICodeEditor): void {
        const m = this.monaco;
        if (!m) return;
        ed.addAction({
            id: "rook.comment",
            label: "Comment on selection",
            keybindings: [m.KeyMod.CtrlCmd | m.KeyMod.Shift | m.KeyCode.KeyM],
            contextMenuGroupId: "9_rook",
            contextMenuOrder: 1,
            run: () => {
                const band = this.bands.find((b) => b.editor === ed);
                const sel = ed.getSelection();
                if (!band || !sel) return;
                let end = sel.endLineNumber;
                // a full-line drag ends at column 1 of the NEXT line — not a line
                if (end > sel.startLineNumber && sel.endColumn === 1) end--;
                band.openComposer(sel.startLineNumber, end);
            },
        });
    }
```

(Note: `run` finds the band by editor identity — bands rebuild per file nav and carry their own side, while actions register once per editor's life. `ensureDiffEditor`/`ensureEditor` run before the first `rebuildBands`, so by the time a user can invoke the action the band exists; an empty-selection cursor is a valid 1-line range.)

- [ ] **Step 3: Hygiene + commit**

```bash
cd frontend && pnpm lint && pnpm format && pnpm check && pnpm build
cd .. && git add frontend/src/term/threads.ts frontend/src/term/editor.ts
git commit -m "frontend: composer — start threads from a selection (⌘⇧M)"
```

---

### Task 6: submit button + stale refetch

**Files:**
- Modify: `frontend/src/term/editor.ts`
- Modify: `frontend/src/app.css`

**Interfaces:**
- Consumes: `submitLabel` (Task 2), `HostAPI.submitThreads` (Task 1), `ThreadBand.hasDraft()` (Tasks 4–5).
- Produces: head submit button on BOTH pane kinds (submit is workspace-level and both panes are commenting surfaces); `focus()` refetch extended to threads with draft protection.

- [ ] **Step 1: Implement** (`frontend/src/term/editor.ts`)

1a. Import `submitLabel`:

```ts
import {submitLabel} from "./threadview";
```

1b. Add a field after `private baseBtn: HTMLButtonElement | null = null;`:

```ts
    private submitBtn: HTMLButtonElement;
```

1c. In the constructor, replace the trailing head cluster

```ts
        head.append(
            this.btn(
                "⟳",
                "refresh",
                () => void (opts.kind === "file" ? this.loadFile() : this.refresh()),
            ),
            this.btn("×", "close pane", () => opts.onClose()),
        );
```

with:

```ts
        this.submitBtn = this.btn("", "send review comments to the workspace's claude", () =>
            void this.submit(),
        );
        this.submitBtn.classList.add("editor-submit");
        this.submitBtn.hidden = true;
        head.append(
            this.submitBtn,
            this.btn(
                "⟳",
                "refresh",
                () => void (opts.kind === "file" ? this.loadFile() : this.refresh()),
            ),
            this.btn("×", "close pane", () => opts.onClose()),
        );
```

1d. Replace `focus()` with:

```ts
    focus(): void {
        (this.diffEditor ?? this.editor)?.focus();
        // a re-focused pane is often stale — the agent kept working. But
        // never refetch out from under a half-written comment.
        if (!this.monaco || Date.now() - this.fetchedAt <= STALE_MS) return;
        if (this.bands.some((b) => b.hasDraft())) return;
        if (this.opts.kind === "review") void this.refresh();
        else void this.refetchThreads();
    }
```

1e. In `fetchThreads()`, after the successful assignment inside `try`, add:

```ts
            this.fetchedAt = Date.now();
```

and add `this.updateSubmit();` as the method's last line (after the try/catch — the label must also settle when the fetch fails).

1f. Add after `bandHooks` (before `addCommentAction`):

```ts
    /** "submit N" while pending threads exist; "nudge again" when open
     *  threads still await the agent (the host's re-nudge semantics,
     *  mirrored); hidden otherwise. */
    private updateSubmit(): void {
        const label = submitLabel(this.threadsAll);
        this.submitBtn.textContent = label;
        this.submitBtn.hidden = label === "";
    }

    private async submit(): Promise<void> {
        if (this.submitBtn.disabled) return;
        this.submitBtn.disabled = true;
        try {
            const res = await this.api.submitThreads(this.opts.workspace);
            this.opts.onFlash(
                res.mode === "typed"
                    ? "review sent — nudged the live claude session"
                    : "review sent — spawned a responder",
            );
        } catch (err) {
            const msg = String(err);
            this.opts.onFlash(
                msg.includes(" 404 ")
                    ? "threads need a newer rook-host — relaunch rook"
                    : `submit failed: ${msg}`,
            );
        } finally {
            this.submitBtn.disabled = false;
        }
        await this.refetchThreads();
    }
```

- [ ] **Step 2: CSS** — append to the threads block in `frontend/src/app.css`:

```css
/* the head's submit button carries the review's call to action */
.editor-submit {
    color: #ffcb6b;
    border-color: #ffcb6b55;
}
.editor-submit:hover {
    color: #ffcb6b;
    border-color: #ffcb6b;
}
```

- [ ] **Step 3: Hygiene + commit**

```bash
cd frontend && pnpm lint && pnpm format && pnpm check && pnpm build
cd .. && git add frontend/src/term/editor.ts frontend/src/app.css
git commit -m "frontend: submit review from the pane + stale thread refetch"
```

---

## Edge cases (accepted / handled)

- **Draft loss on explicit actions:** ⟳, base toggle, and ‹ › file navs rebuild bands — an unsent draft there is lost (open widgets are restored by id, their text is not). Focus-refetch is guarded by `hasDraft()`, so the common case (glance at a terminal, come back) never eats a draft. Accepted for this slice.
- **Diff alignment skew below an open widget** — zones aren't mirrored to the other side. Accepted.
- **Original side of added/untracked files:** composer works, host answers 404 "no original content" → inline `.thread-err`. Not suppressed client-side.
- **Old daemon:** GET list fails silently (console.warn, review usable); create/reply/resolve show the inline error; submit flashes "needs a newer rook-host".
- **Marker on a moved anchor:** host re-anchors on read; markers land on `currentStart`, clamped to line 1 (line 0 can only come from fail-open paths).
- **Resolved threads keep dim markers** so reopen stays reachable from the pane (spec: widgets have resolve/reopen).
- **Multiple threads on one line:** one glyph, most-demanding state; click toggles the whole group.
- **The `` ` `` prefix inside thread textareas** is disarmed by the `.thread-zone` guard; everywhere else (xterm, Monaco find/editor) behavior is unchanged.

## Verification

Automated (per task, above): node suites for `hostapi` and `threadview`; `pnpm lint && pnpm format && pnpm check && pnpm build` per commit; final `go build ./internal/... ./cmd/...` + `go test ./internal/host/` sanity (this branch stacks on 2a — its tests must stay green).

Live (make dev, against a worktree with threads created via `rookctl comment` — Seth's GUI checklist):
1. ` g in a workspace with threads → glyphs in the gutter on the right lines; pending ◐ amber, open ● blue, resolved ● dim, outdated ◌.
2. Click a glyph → widget expands with the full conversation; click again → collapses. Reply (⌘⏎) appears immediately; author chips read user/agent correctly.
3. Select lines → ⌘⇧M (or right-click → "Comment on selection") → composer under the selection; comment → pending marker appears; backticks type fine in the textarea; Esc cancels; ` prefix still works when Monaco (not a textarea) has focus.
4. Original-side selection in the diff → composer says "(original side)"; thread lands on the left editor.
5. Head shows "submit N" → click → flash "nudged the live claude session" (live claude in the workspace) or "spawned a responder" (none); pending markers turn open.
6. `rookctl threads pending` in that workspace sees the submitted threads; `rookctl reply <id>` + refocusing the pane (>2 s) shows the agent's reply without ⟳.
7. Resolve from the widget → dim marker; reopen → cursor lands in the reply box; reply → "nudge again" appears in the head.
8. Agent commits a change to anchored lines → after refetch the thread shows "outdated" with the anchored text block.
9. File viewer (` e) on a plan/markdown file → same commenting flow works (side=modified).
10. Half-written reply + click to a terminal + wait >2 s + click back → draft still there (no refetch clobber).

## Riding items → 2c

- Inbox thread rows + jump-to-thread (spec slice 2c) — the pane side is ready: opening at a thread = `openEditorPane("review")` + expand by id (2c wires it).
- rook-threads skill + `rookctl install-skill` (2c) — checklist items 5–6 exercise the loop manually until then.
- Submit result could name the window number; it names the mode for now (the session id → window mapping lives in the manager, not the pane).
