# Threads Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the thread conversation UI out of Monaco view-zones into a global, toggleable Svelte side pane, leaving the editor island a read-only decoration + seam layer.

**Architecture:** The editor pane (`term/editor.ts`, framework-free imperative DOM) keeps only gutter markers, a read-only anchor highlight, and jump — exposing a narrow **seam** upward. A new global **`SidePane`** (Svelte chrome, sibling of the workbench) hosts a placement-agnostic **`ThreadPanel`** tenant that renders the conversation and drives the seam. `App.svelte` tracks the active editor pane and wires it to the panel.

**Tech Stack:** Svelte 5 (runes), TypeScript, Monaco 0.55.1 (pinned), Vite 8, pnpm, oxlint/oxfmt, vitest (added here).

## Global Constraints

- **Package manager: pnpm** (pinned via `packageManager`). Install deps with `pnpm add -D …`; never npm.
- **Monaco stays pinned at `0.55.1`** — do not bump.
- **The `term/` island must never grow an import edge that pulls Monaco into an eager chunk.** `monaco-editor` is `import type` only in `term/threads.ts`; keep it that way.
- **Lint/format gates:** every changed file must pass `pnpm lint` (`oxlint --deny-warnings`) and `pnpm format:check` (`oxfmt`). Run `pnpm format` before committing.
- **Type gate:** `pnpm check` (`svelte-check`) must pass.
- **Fail open on host protocol skew:** any thread call that 404s must degrade gracefully (flash + empty), never crash the pane (rook-host outlives app installs).
- **`ThreadPanel` must never reference "left"/"right"; `SidePane` must never reference threads.** Placement is the slot's concern; the panel is a tenant.
- **Author is always `"user"`** from the webview (declared, not authenticated) — the existing `hostapi` methods already hardcode this.

---

## File structure

**Created:**
- `frontend/vitest.config.ts` — vitest runner config (node env).
- `frontend/src/term/threadview.spec.ts` — view-model unit tests.
- `frontend/src/SidePane.svelte` — the generic side-pane slot (placement-agnostic container).
- `frontend/src/ThreadPanel.svelte` — the thread conversation tenant.

**Modified:**
- `frontend/package.json` — add `vitest` dev dep + `test` script.
- `frontend/src/term/threadview.ts` — add pure selection/stack helpers.
- `frontend/src/term/threads.ts` — slim `ThreadBand` to decoration + marker-click + highlight; delete the view-zone machine.
- `frontend/src/term/editor.ts` — expose the `EditorSeam`; remove `BandHooks`/composer wiring; emit marker-click/compose; drop the `hasDraft` focus guard.
- `frontend/src/state.svelte.ts` — add `threadPaneOpen` state.
- `frontend/src/keymap.ts` — add the `threads.toggle` default binding.
- `frontend/src/App.svelte` — workbench row layout, mount `SidePane`+`ThreadPanel`, track `activeEditor`, register `threads.toggle`.
- `frontend/src/app.css` — workbench/side-pane/thread-panel styles; the gutter-glyph rules stay, the view-zone card rules move into the panel's scope.

---

## Task 1: vitest + view-model helpers

**Files:**
- Modify: `frontend/package.json`
- Create: `frontend/vitest.config.ts`
- Modify: `frontend/src/term/threadview.ts`
- Test: `frontend/src/term/threadview.spec.ts`

**Interfaces:**
- Consumes: `ThreadInfo` (`hostapi.ts`), existing `bandThreads`/`markerLines`/`glyphClass`/`Side`.
- Produces (added to `threadview.ts`, used by `ThreadPanel` in Task 5):
  - `threadStack(all: ThreadInfo[], path: string, side: Side, line: number): ThreadInfo[]` — the rank-sorted stack of threads whose marker sits on `line`.
  - `pickFromStack(stack: ThreadInfo[], activeId?: number): {thread: ThreadInfo; index: number; count: number} | null` — the thread to show (active if still present, else top), 1-based-friendly 0-index + count.
  - `cycleStack(stack: ThreadInfo[], activeId: number, dir: 1 | -1): number | null` — next thread id when cycling `‹ ›`.
  - `contextKey(ctx: {workspace: string; path: string} | null): string` — identity used to detect a file/workspace change (selection resets when it changes).

- [ ] **Step 1: Add vitest**

Run:
```bash
cd frontend && pnpm add -D vitest
```
Expected: `vitest` appears under `devDependencies`; lockfile updates.

- [ ] **Step 2: Add the `test` script**

In `frontend/package.json`, add to `"scripts"` (after `"preview"`):
```json
        "test": "vitest run",
```

- [ ] **Step 3: Create `frontend/vitest.config.ts`**

```ts
import {defineConfig} from "vitest/config";

// Standalone from vite.config so the Wails/Svelte app build stays out of
// the test path — the view-model is pure, node env, no DOM.
export default defineConfig({
    test: {
        environment: "node",
        include: ["src/**/*.spec.ts"],
    },
});
```

- [ ] **Step 4: Write the failing tests**

Create `frontend/src/term/threadview.spec.ts`:
```ts
import {describe, expect, it} from "vitest";
import type {ThreadInfo} from "../hostapi";
import {
    bandThreads,
    contextKey,
    cycleStack,
    glyphClass,
    markerLines,
    pickFromStack,
    threadStack,
} from "./threadview";

// A minimal ThreadInfo factory — only the fields the view-model reads.
function th(p: Partial<ThreadInfo> & {id: number}): ThreadInfo {
    return {
        workspace: "w",
        path: "a.ts",
        startLine: 1,
        endLine: 1,
        side: "modified",
        blobSha: "",
        anchorText: "",
        state: "open",
        created: "",
        updated: "",
        comments: [],
        currentStart: 1,
        currentEnd: 1,
        ...p,
    } as ThreadInfo;
}

describe("bandThreads", () => {
    it("keeps this file + side, sorted by currentStart then id", () => {
        const all = [
            th({id: 3, path: "a.ts", currentStart: 10}),
            th({id: 1, path: "a.ts", currentStart: 5}),
            th({id: 2, path: "b.ts", currentStart: 1}),
            th({id: 4, path: "a.ts", side: "original", currentStart: 1}),
        ];
        expect(bandThreads(all, "a.ts", "modified").map((t) => t.id)).toEqual([1, 3]);
    });
});

describe("markerLines + glyphClass", () => {
    it("groups per anchor line, clamping <1 to 1", () => {
        const t = [th({id: 1, currentStart: 0}), th({id: 2, currentStart: 0})];
        const m = markerLines(t);
        expect(m.get(1)?.map((x) => x.id)).toEqual([1, 2]);
    });
    it("picks the most-demanding state and flags outdated", () => {
        const g = [th({id: 1, state: "resolved"}), th({id: 2, state: "pending", outdated: true})];
        expect(glyphClass(g)).toBe("thread-glyph thread-glyph-pending thread-glyph-outdated");
    });
});

describe("threadStack", () => {
    it("returns the line's threads rank-sorted (pending>open>resolved, then id)", () => {
        const all = [
            th({id: 1, currentStart: 4, state: "open"}),
            th({id: 2, currentStart: 4, state: "pending"}),
            th({id: 3, currentStart: 4, state: "resolved"}),
            th({id: 4, currentStart: 9, state: "open"}),
        ];
        expect(threadStack(all, "a.ts", "modified", 4).map((t) => t.id)).toEqual([2, 1, 3]);
    });
    it("clamps currentStart<1 onto line 1", () => {
        const all = [th({id: 7, currentStart: 0})];
        expect(threadStack(all, "a.ts", "modified", 1).map((t) => t.id)).toEqual([7]);
    });
});

describe("pickFromStack", () => {
    it("returns null for an empty stack", () => {
        expect(pickFromStack([])).toBeNull();
    });
    it("keeps the active thread if still present", () => {
        const stack = [th({id: 2}), th({id: 5}), th({id: 8})];
        expect(pickFromStack(stack, 5)).toEqual({thread: stack[1], index: 1, count: 3});
    });
    it("falls back to the top when the active id is gone", () => {
        const stack = [th({id: 2}), th({id: 8})];
        expect(pickFromStack(stack, 99)?.index).toBe(0);
    });
});

describe("cycleStack", () => {
    it("wraps forward and backward", () => {
        const stack = [th({id: 2}), th({id: 5}), th({id: 8})];
        expect(cycleStack(stack, 5, 1)).toBe(8);
        expect(cycleStack(stack, 8, 1)).toBe(2);
        expect(cycleStack(stack, 2, -1)).toBe(8);
    });
    it("returns null on an empty stack", () => {
        expect(cycleStack([], 1, 1)).toBeNull();
    });
});

describe("contextKey", () => {
    it("changes when workspace or path changes, and is stable otherwise", () => {
        expect(contextKey({workspace: "w", path: "a.ts"})).toBe(
            contextKey({workspace: "w", path: "a.ts"}),
        );
        expect(contextKey({workspace: "w", path: "a.ts"})).not.toBe(
            contextKey({workspace: "w", path: "b.ts"}),
        );
        expect(contextKey(null)).toBe("");
    });
});
```

- [ ] **Step 5: Run the tests to verify they fail**

Run: `cd frontend && pnpm test`
Expected: FAIL — `threadStack`, `pickFromStack`, `cycleStack`, `contextKey` are `not exported` / undefined.

- [ ] **Step 6: Implement the new helpers**

Append to `frontend/src/term/threadview.ts`:
```ts
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
    return ctx ? `${ctx.workspace} ${ctx.path}` : "";
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `cd frontend && pnpm test`
Expected: PASS — all suites green.

- [ ] **Step 8: Lint, format, commit**

```bash
cd frontend && pnpm format && pnpm lint && pnpm test
git add frontend/package.json frontend/pnpm-lock.yaml frontend/vitest.config.ts frontend/src/term/threadview.ts frontend/src/term/threadview.spec.ts
git commit -m "frontend: vitest + thread view-model stack/selection helpers"
```

---

## Task 2: Slim `ThreadBand` to a decoration + seam layer

Strip every interactive/view-zone concern from `ThreadBand`; keep gutter markers, add a marker-click callback and a read-only anchor highlight.

**Files:**
- Modify: `frontend/src/term/threads.ts` (full rewrite of the class)

**Interfaces:**
- Consumes: `bandThreads`, `glyphClass`, `markerLines`, `Side` (`threadview.ts`); `ThreadInfo` (`hostapi.ts`).
- Produces (used by `EditorPane` in Task 3):
  - `new ThreadBand(monaco, editor, side, onMarkerClick)` where `onMarkerClick: (line: number, side: Side, threadIds: number[]) => void`.
  - `render(all: ThreadInfo[], path: string): void` — gutter glyphs only.
  - `highlight(startLine: number, endLine: number): void` — the read-only active-anchor decoration.
  - `clearHighlight(): void`.
  - `dispose(): void`.
- **Removed** (callers in Task 3 must stop using): `BandHooks`, `openComposer`, `openThreadIds`, `hasDraft`, and the `reopen?` arg to `render`.

- [ ] **Step 1: Replace `frontend/src/term/threads.ts` in full**

```ts
// The thread layer on ONE Monaco editor, read-only: gutter markers and a
// single active-anchor highlight. All conversation UI lives in the Svelte
// ThreadPanel (chrome); this band only paints the code surface and reports
// marker clicks up through onMarkerClick.
//
// Framework-free DOM like the rest of the island. Monaco arrives as a
// constructor param (types only here) — this module must never grow an
// import edge that drags Monaco into an eager chunk.

import type * as monacoTypes from "monaco-editor";
import type {ThreadInfo} from "../hostapi";
import {bandThreads, glyphClass, markerLines, type Side} from "./threadview";

type Monaco = typeof monacoTypes;
type ICodeEditor = monacoTypes.editor.ICodeEditor;

export class ThreadBand {
    private glyphs: monacoTypes.editor.IEditorDecorationsCollection;
    private active: monacoTypes.editor.IEditorDecorationsCollection;
    private threads: ThreadInfo[] = [];
    private mouseSub: monacoTypes.IDisposable;

    constructor(
        private monaco: Monaco,
        readonly editor: ICodeEditor,
        readonly side: Side,
        private onMarkerClick: (line: number, side: Side, threadIds: number[]) => void,
    ) {
        this.glyphs = editor.createDecorationsCollection();
        this.active = editor.createDecorationsCollection();
        this.mouseSub = editor.onMouseDown((e) => {
            if (e.target.type !== this.monaco.editor.MouseTargetType.GUTTER_GLYPH_MARGIN) return;
            const line = e.target.position?.lineNumber;
            if (!line) return;
            const group = markerLines(this.threads).get(line);
            if (group) this.onMarkerClick(line, this.side, group.map((t) => t.id));
        });
    }

    /** all = the workspace's threads; the band slices its own (path, side)
     *  and repaints one glyph per anchor line. */
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
        this.glyphs.set(decs);
    }

    /** The read-only highlight for the active thread's anchor lines. */
    highlight(startLine: number, endLine: number): void {
        const a = Math.max(1, startLine);
        const b = Math.max(a, endLine);
        this.active.set([
            {
                range: new this.monaco.Range(a, 1, b, 1),
                options: {isWholeLine: true, className: "thread-active-line"},
            },
        ]);
    }

    clearHighlight(): void {
        this.active.clear();
    }

    dispose(): void {
        this.mouseSub.dispose();
        this.glyphs.clear();
        this.active.clear();
    }
}
```

- [ ] **Step 2: Type-check (expect known errors in editor.ts — fixed in Task 3)**

Run: `cd frontend && pnpm check`
Expected: errors ONLY in `src/term/editor.ts` (it still imports `BandHooks`, calls `openComposer`, `openThreadIds`, `hasDraft`, `render(..., open)`). No errors inside `threads.ts` itself.

If any error points inside `threads.ts`, fix it before continuing. Do **not** commit yet — the tree doesn't type-check until Task 3.

---

## Task 3: Expose the `EditorSeam`; remove conversation logic from the pane

**Files:**
- Modify: `frontend/src/term/editor.ts`

**Interfaces:**
- Consumes: the slimmed `ThreadBand` (Task 2).
- Produces (exported type + `EditorPane.seam`, used by `App.svelte`/`ThreadPanel` in Tasks 4–5):
  ```ts
  export interface EditorContext {
      workspace: string;
      path: string;
      base: "head" | "branch" | undefined;
  }
  export interface EditorSeam {
      context(): EditorContext | null;
      threads(): ThreadInfo[];
      refetch(): Promise<void>;
      reveal(t: ThreadInfo): void;
      clearHighlight(): void;
      onMarkerClick(cb: (line: number, side: Side, ids: number[]) => void): () => void;
      onCompose(cb: (startLine: number, endLine: number, side: Side) => void): () => void;
      onChange(cb: () => void): () => void;
  }
  ```
- New `EditorPaneOpts.onActivate?: (seam: EditorSeam) => void` — the pane calls it when a Monaco editor gains focus, so `App` can track the active editor.

- [ ] **Step 1: Update imports + add the seam types**

In `frontend/src/term/editor.ts`, replace the threads import line:
```ts
import {ThreadBand, type BandHooks} from "./threads";
import {submitLabel} from "./threadview";
```
with:
```ts
import {ThreadBand} from "./threads";
import {submitLabel, type Side} from "./threadview";
```
Then add, just below the imports (before `EditorPaneOpts`):
```ts
export interface EditorContext {
    workspace: string;
    path: string;
    base: "head" | "branch" | undefined;
}

/** The narrow door between the editor island and the thread panel (chrome).
 *  Signals out (marker click, compose, change), calls in (reveal/clear). */
export interface EditorSeam {
    context(): EditorContext | null;
    threads(): ThreadInfo[];
    refetch(): Promise<void>;
    reveal(t: ThreadInfo): void;
    clearHighlight(): void;
    onMarkerClick(cb: (line: number, side: Side, ids: number[]) => void): () => void;
    onCompose(cb: (startLine: number, endLine: number, side: Side) => void): () => void;
    onChange(cb: () => void): () => void;
}
```

- [ ] **Step 2: Add the `onActivate` opt**

In `interface EditorPaneOpts`, add after `onClose`:
```ts
    /** the pane calls this when a Monaco editor gains focus, so chrome can
     *  bind the thread panel to the active editor */
    onActivate?: (seam: EditorSeam) => void;
```

- [ ] **Step 3: Add subscriber fields**

In the `EditorPane` class, replace the two thread fields:
```ts
    /** every thread in the workspace — bands slice per (path, side) */
    private threadsAll: ThreadInfo[] = [];
    private bands: ThreadBand[] = [];
```
with:
```ts
    /** every thread in the workspace — bands slice per (path, side) */
    private threadsAll: ThreadInfo[] = [];
    private bands: ThreadBand[] = [];

    // seam subscribers (chrome side)
    private markerCbs: ((line: number, side: Side, ids: number[]) => void)[] = [];
    private composeCbs: ((s: number, e: number, side: Side) => void)[] = [];
    private changeCbs: (() => void)[] = [];
```

- [ ] **Step 4: Add the seam implementation**

Add these methods to `EditorPane` (place them right after `dispose()`):
```ts
    // ---- the seam (chrome ↔ island) ----

    get seam(): EditorSeam {
        return {
            context: () => {
                const path = this.currentPath();
                return path ? {workspace: this.opts.workspace, path, base: this.base} : null;
            },
            threads: () => this.threadsAll,
            refetch: () => this.refetchThreads(),
            reveal: (t) => this.reveal(t),
            clearHighlight: () => {
                for (const b of this.bands) b.clearHighlight();
            },
            onMarkerClick: (cb) => this.sub(this.markerCbs, cb),
            onCompose: (cb) => this.sub(this.composeCbs, cb),
            onChange: (cb) => this.sub(this.changeCbs, cb),
        };
    }

    private sub<T>(list: T[], cb: T): () => void {
        list.push(cb);
        return () => {
            const i = list.indexOf(cb);
            if (i >= 0) list.splice(i, 1);
        };
    }

    private emitChange(): void {
        for (const cb of this.changeCbs) cb();
    }

    /** Jump the right editor to a thread's anchor and paint the highlight;
     *  outdated threads still reveal their best-effort mapped range. */
    private reveal(t: ThreadInfo): void {
        for (const b of this.bands) {
            if (b.side === t.side) {
                b.highlight(t.currentStart, t.currentEnd);
                b.editor.revealLinesInCenterIfOutsideViewport(
                    Math.max(1, t.currentStart),
                    Math.max(1, t.currentEnd),
                );
                b.editor.focus();
            } else {
                b.clearHighlight();
            }
        }
    }
```

- [ ] **Step 5: Fire `onChange` after every thread render; drop the draft guard**

Replace `focus()`:
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
with (drafts now live in the panel, not the island — no band guard):
```ts
    focus(): void {
        (this.diffEditor ?? this.editor)?.focus();
        // a re-focused pane is often stale — the agent kept working. Thread
        // drafts live in the panel (chrome), so refetch is always safe here.
        if (!this.monaco || Date.now() - this.fetchedAt <= STALE_MS) return;
        if (this.opts.kind === "review") void this.refresh();
        else void this.refetchThreads();
    }
```

In `refetchThreads()`, add an `emitChange()` after the bands render:
```ts
    private async refetchThreads(): Promise<void> {
        await this.fetchThreads();
        if (this.disposed) return;
        const path = this.currentPath();
        if (!path) return;
        for (const b of this.bands) b.render(this.threadsAll, path);
        this.emitChange();
    }
```

In `refresh()` and `loadFile()`, the inline `void this.fetchThreads().then(...)` blocks render the bands — add `this.emitChange()` there too. Replace, in **both** methods, this block:
```ts
            void this.fetchThreads().then(() => {
                const p = this.currentPath();
                if (this.disposed || !p) return;
                for (const b of this.bands) b.render(this.threadsAll, p);
            });
```
with:
```ts
            void this.fetchThreads().then(() => {
                const p = this.currentPath();
                if (this.disposed || !p) return;
                for (const b of this.bands) b.render(this.threadsAll, p);
                this.emitChange();
            });
```

- [ ] **Step 6: Remove `bandHooks`; emit compose + marker click; simplify `rebuildBands`**

Delete the entire `bandHooks(side)` method (the `reply/resolve/reopen/create` block).

Replace the `run:` body of `addCommentAction`:
```ts
            run: () => {
                const band = this.bands.find((b) => b.editor === ed);
                const sel = ed.getSelection();
                if (!band || !sel) return;
                let end = sel.endLineNumber;
                // a full-line drag ends at column 1 of the NEXT line — not a line
                if (end > sel.startLineNumber && sel.endColumn === 1) end--;
                band.openComposer(sel.startLineNumber, end);
            },
```
with:
```ts
            run: () => {
                const band = this.bands.find((b) => b.editor === ed);
                const sel = ed.getSelection();
                if (!band || !sel) return;
                let end = sel.endLineNumber;
                // a full-line drag ends at column 1 of the NEXT line — not a line
                if (end > sel.startLineNumber && sel.endColumn === 1) end--;
                for (const cb of this.composeCbs) cb(sel.startLineNumber, end, band.side);
            },
```

Replace `rebuildBands()` in full:
```ts
    /** Editors persist across file navs but models don't — decorations
     *  live on the model/view, so bands rebuild per nav. */
    private rebuildBands(): void {
        for (const b of this.bands) b.dispose();
        this.bands = [];
        const m = this.monaco;
        const path = this.currentPath();
        if (!m || !path) return;
        const onMarker = (line: number, side: Side, ids: number[]) => {
            for (const cb of this.markerCbs) cb(line, side, ids);
        };
        if (this.diffEditor) {
            this.bands = [
                new ThreadBand(m, this.diffEditor.getOriginalEditor(), "original", onMarker),
                new ThreadBand(m, this.diffEditor.getModifiedEditor(), "modified", onMarker),
            ];
        } else if (this.editor) {
            this.bands = [new ThreadBand(m, this.editor, "modified", onMarker)];
        }
        for (const b of this.bands) b.render(this.threadsAll, path);
        this.emitChange();
    }
```

- [ ] **Step 7: Wire `onActivate` on editor focus**

In `ensureDiffEditor()`, after the two `addCommentAction(...)` calls, add:
```ts
            this.diffEditor.getOriginalEditor().onDidFocusEditorText(() => this.activate());
            this.diffEditor.getModifiedEditor().onDidFocusEditorText(() => this.activate());
```
In `ensureEditor()`, after `this.addCommentAction(this.editor);`, add:
```ts
            this.editor.onDidFocusEditorText(() => this.activate());
```
Add the helper (next to `reveal`):
```ts
    private activate(): void {
        this.opts.onActivate?.(this.seam);
    }
```

- [ ] **Step 8: Type-check**

Run: `cd frontend && pnpm check`
Expected: PASS (no references to removed `BandHooks`/`openComposer`/`hasDraft`/`openThreadIds` remain). If `svelte-check` flags an unused import or symbol, remove it.

- [ ] **Step 9: Lint, format, commit (Tasks 2+3 together — the tree type-checks now)**

```bash
cd frontend && pnpm format && pnpm lint && pnpm check && pnpm test
git add frontend/src/term/threads.ts frontend/src/term/editor.ts
git commit -m "frontend: editor island becomes a read-only decoration + seam layer"
```

---

## Task 4: Side-pane slot, app state, layout, toggle

Ship the empty toggleable right pane and its keybinding — no thread content yet.

**Files:**
- Modify: `frontend/src/state.svelte.ts`
- Create: `frontend/src/SidePane.svelte`
- Modify: `frontend/src/keymap.ts`
- Modify: `frontend/src/App.svelte`
- Modify: `frontend/src/app.css`

**Interfaces:**
- Produces: `app.threadPaneOpen: boolean`; `SidePane` component with props `{side: "left" | "right"; visible: boolean; title: string; onclose: () => void; children}`; command id `threads.toggle`.

- [ ] **Step 1: Add `threadPaneOpen` state**

In `frontend/src/state.svelte.ts`, add after `prefixArmed = $state(false);`:
```ts
    /** the workbench side pane (VS Code-style); threads are its first tenant */
    threadPaneOpen = $state(true);
```
(This is a workbench pane, not a modal overlay — deliberately **not** added to `anyOverlayOpen`/`closeOverlays`, so it stays open under the palette/picker/etc.)

- [ ] **Step 2: Create `frontend/src/SidePane.svelte`**

```svelte
<!-- A workbench side pane (VS Code-style secondary side bar): a generic,
     placement-agnostic slot. It knows a side, a visibility, and a title —
     nothing about its tenant. The thread panel is this slice's only
     tenant; a left pane / more panels drop in without touching it. -->
<script lang="ts">
    import type {Snippet} from "svelte";

    interface Props {
        side: "left" | "right";
        visible: boolean;
        title: string;
        onclose: () => void;
        children: Snippet;
    }

    let {side, visible, title, onclose, children}: Props = $props();
</script>

{#if visible}
    <aside class="side-pane side-pane-{side}">
        <header class="side-pane-head">
            <span class="side-pane-title">{title}</span>
            <button class="editor-btn" title="close pane" onclick={onclose}>×</button>
        </header>
        <div class="side-pane-body">
            {@render children()}
        </div>
    </aside>
{/if}
```

- [ ] **Step 3: Add the toggle keybinding default**

In `frontend/src/keymap.ts`, in the `DEFAULTS` array, add after `["e", "file.open"],`:
```ts
    ["t", "threads.toggle"],
```
(Bare `` ` t`` in the leader layer — `t` is unused there; `cmd+t` is a separate slot.)

- [ ] **Step 4: Register the command + track the active editor + lay out the workbench**

In `frontend/src/App.svelte`:

(a) Add imports near the other component imports:
```ts
    import SidePane from "./SidePane.svelte";
    import ThreadPanel from "./ThreadPanel.svelte";
    import type {EditorSeam} from "./term/editor";
```

(b) Add reactive state near the top of the `<script>` (with the other `let` declarations):
```ts
    let activeEditor = $state<EditorSeam | null>(null);
    // focusing a terminal (activeId set by the manager) idles the panel
    $effect(() => {
        if (app.activeId) activeEditor = null;
    });
```

(c) In `openEditorPane`, pass `onActivate` and clear on close. Replace the `new EditorPane(...)` options object:
```ts
                    new EditorPane(api, {
                        workspace: app.workspace,
                        kind,
                        path,
                        font: paneFont,
                        onFlash: flash,
                        onClose: () => void mgr.closeActive(),
                    }),
```
with:
```ts
                    new EditorPane(api, {
                        workspace: app.workspace,
                        kind,
                        path,
                        font: paneFont,
                        onFlash: flash,
                        onClose: () => void mgr.closeActive(),
                        onActivate: (seam) => (activeEditor = seam),
                    }),
```

(d) Register the command — add to the `registry.register(...)` call, next to the `review.changes` entry:
```ts
        {
            id: "threads.toggle",
            title: "Toggle thread pane",
            category: "View",
            keys: keymap.display("threads.toggle"),
            run: () => {
                app.threadPaneOpen = !app.threadPaneOpen;
            },
        },
```

(e) Lay out the workbench. Replace:
```svelte
    <div id="terminals" bind:this={terminalsEl}>
        {#if fatal}
            <div id="fatal">{fatal}</div>
        {/if}
        {#if app.dashVisible}
            <Dashboard
                {api}
                onjump={(id) => mgr.switchToId(id)}
                runCmd={(id) => registry.run(id)}
                onwork={workIssue}
            />
        {/if}
    </div>
```
with:
```svelte
    <div id="workbench">
        <div id="terminals" bind:this={terminalsEl}>
            {#if fatal}
                <div id="fatal">{fatal}</div>
            {/if}
            {#if app.dashVisible}
                <Dashboard
                    {api}
                    onjump={(id) => mgr.switchToId(id)}
                    runCmd={(id) => registry.run(id)}
                    onwork={workIssue}
                />
            {/if}
        </div>
        <SidePane
            side="right"
            visible={app.threadPaneOpen}
            title="Threads"
            onclose={() => (app.threadPaneOpen = false)}
        >
            <ThreadPanel {api} editor={activeEditor} />
        </SidePane>
    </div>
```

> Note: `ThreadPanel.svelte` is created in Task 5. To keep this task's tree compiling, create a one-line stub now and flesh it out next:
> ```svelte
> <!-- frontend/src/ThreadPanel.svelte (stub — filled in Task 5) -->
> <script lang="ts">
>     import type {HostAPI} from "./hostapi";
>     import type {EditorSeam} from "./term/editor";
>     let {api, editor}: {api: HostAPI; editor: EditorSeam | null} = $props();
>     void api;
> </script>
> <div class="thread-panel-empty">{editor ? "no thread selected" : "focus a review pane"}</div>
> ```

- [ ] **Step 5: Add the workbench + side-pane CSS**

Append to `frontend/src/app.css`:
```css
/* workbench = terminals + the side pane, side by side */
#workbench {
    display: flex;
    flex: 1;
    min-height: 0;
    min-width: 0;
}
#workbench #terminals {
    flex: 1;
    min-width: 0;
}
.side-pane {
    display: flex;
    flex-direction: column;
    width: 22rem;
    min-width: 16rem;
    background: var(--bg, #1e1e1e);
    border-left: 1px solid var(--border, #333);
}
.side-pane-left {
    border-left: none;
    border-right: 1px solid var(--border, #333);
    order: -1;
}
.side-pane-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0.25rem 0.5rem;
    border-bottom: 1px solid var(--border, #333);
}
.side-pane-title {
    font-size: 0.75rem;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    opacity: 0.7;
}
.side-pane-body {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
}
.thread-panel-empty {
    padding: 1rem;
    opacity: 0.6;
    font-size: 0.85rem;
}
```
> If `#terminals` had layout rules of its own in `app.css` (e.g. `flex`/size), reconcile them with the `#workbench` flex parent — search `app.css` for `#terminals` and ensure it lives inside the flex row without a fixed width.

- [ ] **Step 6: Verify the empty pane toggles**

Run: `cd frontend && pnpm check && pnpm lint && pnpm build:dev`
Expected: builds clean. Then a manual smoke check (Seth): launch rook, `` ` g`` opens a review pane, the **Threads** pane shows on the right; `` ` t`` toggles it closed/open; the × closes it.

- [ ] **Step 7: Format + commit**

```bash
cd frontend && pnpm format
git add frontend/src/state.svelte.ts frontend/src/SidePane.svelte frontend/src/ThreadPanel.svelte frontend/src/keymap.ts frontend/src/App.svelte frontend/src/app.css
git commit -m "frontend: global toggleable side pane (VS Code-style) + threads.toggle"
```

---

## Task 5: `ThreadPanel` — the conversation tenant

Fill the stub with the real three-state panel wired to the active editor's seam.

**Files:**
- Modify (replace stub): `frontend/src/ThreadPanel.svelte`
- Modify: `frontend/src/app.css` (thread-card styles)

**Interfaces:**
- Consumes: `HostAPI` (thread methods), `EditorSeam` (Task 3), `threadStack`/`pickFromStack`/`cycleStack`/`contextKey` (Task 1), `ThreadInfo`/`ThreadComment` (`hostapi.ts`), `Side` (`threadview.ts`).

- [ ] **Step 1: Replace `frontend/src/ThreadPanel.svelte` in full**

```svelte
<!-- The thread conversation, the side pane's first tenant. Placement-
     agnostic (knows nothing about left/right): it takes the active editor
     pane's seam + hostapi and renders one thread at a time. Marker clicks
     and ⌘⇧M come UP through the seam; reveal/highlight go DOWN. Drafts live
     here in chrome, so a background refetch never eats them. -->
<script lang="ts">
    import type {HostAPI, ThreadInfo} from "./hostapi";
    import type {EditorSeam} from "./term/editor";
    import {contextKey, cycleStack, pickFromStack, threadStack, type Side} from "./term/threadview";

    let {api, editor}: {api: HostAPI; editor: EditorSeam | null} = $props();

    type Sel =
        | {mode: "empty"}
        | {mode: "composer"; startLine: number; endLine: number; side: Side}
        | {mode: "thread"; id: number};

    let threads = $state<ThreadInfo[]>([]);
    let sel = $state<Sel>({mode: "empty"});
    let draft = $state(""); // reply / new-comment text — never clobbered by refetch
    let err = $state("");
    let busy = $state(false);
    let ctxKey = ""; // last-seen file identity; selection resets when it changes

    // (Re)bind to the active editor whenever the prop changes.
    $effect(() => {
        const seam = editor;
        if (!seam) {
            threads = [];
            sel = {mode: "empty"};
            ctxKey = "";
            return;
        }
        sync();
        const offChange = seam.onChange(sync);
        const offMarker = seam.onMarkerClick((line, side, _ids) => selectAt(line, side));
        const offCompose = seam.onCompose((s, e, side) => {
            draft = "";
            err = "";
            sel = {mode: "composer", startLine: s, endLine: e, side};
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
        // file-nav / workspace switch → drop the selection
        const key = contextKey(editor.context());
        if (key !== ctxKey) {
            ctxKey = key;
            sel = {mode: "empty"};
            draft = "";
            err = "";
        }
    }

    function selectAt(line: number, side: Side): void {
        const ctx = editor?.context();
        if (!ctx) return;
        const stack = threadStack(threads, ctx.path, side, line);
        const active = sel.mode === "thread" ? sel.id : undefined;
        const pick = pickFromStack(stack, active);
        if (!pick) return;
        draft = "";
        err = "";
        sel = {mode: "thread", id: pick.thread.id};
        editor?.reveal(pick.thread);
    }

    // The active thread (or null) + its N-of-Y position within the line stack.
    let active = $derived.by(() => {
        if (sel.mode !== "thread") return null;
        const t = threads.find((x) => x.id === (sel as {id: number}).id);
        if (!t) return null;
        const line = Math.max(1, t.currentStart);
        const stack = threadStack(threads, t.path, t.side, line);
        const pick = pickFromStack(stack, t.id);
        return {thread: t, stack, index: pick?.index ?? 0, count: pick?.count ?? 1};
    });

    function cycle(dir: 1 | -1): void {
        if (!active) return;
        const id = cycleStack(active.stack, active.thread.id, dir);
        if (id == null) return;
        const t = threads.find((x) => x.id === id);
        sel = {mode: "thread", id};
        draft = "";
        if (t) editor?.reveal(t);
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
        if (!body || !ctx || sel.mode !== "composer") return;
        const {startLine, endLine, side} = sel;
        await run(async () => {
            const t = await api.createThread(ctx.workspace, {
                path: ctx.path,
                startLine,
                endLine,
                side,
                base: side === "original" ? ctx.base : undefined,
                body,
            });
            draft = "";
            sel = {mode: "thread", id: t.id};
            editor?.reveal(t);
        });
    }

    async function reply(): Promise<void> {
        const body = draft.trim();
        if (!body || !active) return;
        const id = active.thread.id;
        await run(async () => {
            await api.threadComment(id, body);
            draft = "";
        });
    }

    async function resolve(): Promise<void> {
        if (!active) return;
        const id = active.thread.id;
        await run(() => api.threadResolve(id));
    }

    async function reopen(): Promise<void> {
        if (!active) return;
        const id = active.thread.id;
        await run(() => api.threadReopen(id));
    }

    function cancel(): void {
        sel = {mode: "empty"};
        draft = "";
        err = "";
        editor?.clearHighlight();
    }

    function keydown(e: KeyboardEvent, submit: () => void): void {
        if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
            e.preventDefault();
            submit();
        } else if (e.key === "Escape") {
            cancel();
        }
    }

    function fmtRange(a: number, b: number): string {
        return a === b ? `L${a}` : `L${a}–${b}`;
    }
</script>

{#if !editor}
    <div class="thread-panel-empty">focus a review or file pane to see its threads</div>
{:else if sel.mode === "composer"}
    <div class="thread-card">
        <div class="thread-meta">
            new thread on {fmtRange(sel.startLine, sel.endLine)}{sel.side === "original"
                ? " (original side)"
                : ""}
        </div>
        <textarea
            class="thread-input"
            rows="3"
            placeholder="start a thread… (⌘⏎ comments · esc cancels)"
            bind:value={draft}
            onkeydown={(e) => keydown(e, submitComposer)}
        ></textarea>
        {#if err}<div class="thread-err">{err}</div>{/if}
        <div class="thread-row">
            <button class="editor-btn thread-act" disabled={busy} onclick={submitComposer}>
                comment
            </button>
            <button class="editor-btn thread-act" onclick={cancel}>cancel</button>
        </div>
    </div>
{:else if active}
    <div class="thread-card">
        <div class="thread-row">
            <span class="thread-state thread-state-{active.thread.state}">{active.thread.state}</span
            >
            <span class="thread-meta">
                #{active.thread.id} · {fmtRange(
                    active.thread.currentStart,
                    active.thread.currentEnd,
                )}{active.thread.outdated ? " · outdated" : ""}{active.thread.resolvedBy
                    ? ` · by ${active.thread.resolvedBy}`
                    : ""}
            </span>
            {#if active.count > 1}
                <span class="thread-nav">
                    <button class="editor-btn" title="previous thread here" onclick={() => cycle(-1)}
                        >‹</button
                    >
                    {active.index + 1} of {active.count}
                    <button class="editor-btn" title="next thread here" onclick={() => cycle(1)}
                        >›</button
                    >
                </span>
            {/if}
        </div>
        {#if active.thread.outdated && active.thread.anchorText}
            <pre class="thread-anchor">{active.thread.anchorText}</pre>
        {/if}
        {#each active.thread.comments as c (c.id)}
            <div class="thread-comment">
                <span class="thread-author thread-author-{c.author}">{c.author}</span>
                <div class="thread-body">{c.body}</div>
            </div>
        {/each}
        {#if err}<div class="thread-err">{err}</div>{/if}
        <div class="thread-reply">
            <textarea
                class="thread-input"
                rows="1"
                placeholder="reply… (⌘⏎ sends · esc closes)"
                bind:value={draft}
                onkeydown={(e) => keydown(e, reply)}
            ></textarea>
            <div class="thread-row">
                <button class="editor-btn thread-act" disabled={busy} onclick={reply}>reply</button>
                {#if active.thread.state === "resolved"}
                    <button class="editor-btn thread-act" disabled={busy} onclick={reopen}
                        >reopen</button
                    >
                {:else}
                    <button class="editor-btn thread-act" disabled={busy} onclick={resolve}
                        >resolve</button
                    >
                {/if}
            </div>
        </div>
    </div>
{:else}
    <div class="thread-panel-empty">
        select a gutter marker, or select code and ⌘⇧M to comment
    </div>
{/if}
```

- [ ] **Step 2: Move the thread-card CSS into `app.css`**

The existing `.thread-*` card rules (used by the old view-zone widgets) already live in `app.css` and are reused verbatim by the panel — verify they exist (`.thread-card`, `.thread-input`, `.thread-row`, `.thread-meta`, `.thread-state*`, `.thread-author*`, `.thread-body`, `.thread-comment`, `.thread-anchor`, `.thread-err`, `.thread-reply`, `.thread-act`). Add the two new rules:
```css
.thread-nav {
    margin-left: auto;
    font-size: 0.75rem;
    opacity: 0.8;
    white-space: nowrap;
}
.thread-active-line {
    background: color-mix(in srgb, var(--accent, #4a9eff) 18%, transparent);
}
```
> The `.thread-zone` rule (the old view-zone wrapper) is now dead — leave it for the sweep in Task 6.

- [ ] **Step 3: Type-check + build**

Run: `cd frontend && pnpm check && pnpm lint && pnpm build:dev`
Expected: clean.

- [ ] **Step 4: Manual GUI checklist (Seth)**

Launch rook, `` ` g`` a workspace with agent changes:
- Gutter markers render on both diff sides.
- Click a marker → panel loads that thread, Monaco jumps + highlights the anchor lines.
- A line with 2+ threads shows `‹ N of Y ›`; the arrows cycle and re-jump.
- Select code + ⌘⇧M → composer; **comment** creates a pending thread and the panel flips to it; a pending gutter marker appears.
- Reply, resolve, reopen each round-trips and re-renders.
- Type a reply, let a background refetch fire (or `⟳`): the draft is **not** eaten.
- An outdated thread shows its `anchorText` and still jumps to the mapped line.
- Navigate files (`‹`/`›`): the panel resets to empty.
- Focus a terminal: the panel idles to "focus a review or file pane".
- `` ` t`` toggles the pane; the head × closes it.
- `submit N` in the editor head still works.

- [ ] **Step 5: Format + commit**

```bash
cd frontend && pnpm format && pnpm test
git add frontend/src/ThreadPanel.svelte frontend/src/app.css
git commit -m "frontend: ThreadPanel — the side pane's conversation tenant"
```

---

## Task 6: Dead-code sweep + final verification

**Files:**
- Modify: `frontend/src/app.css` (remove dead `.thread-zone` rule if unused)
- Verify: `frontend/src/term/threadview.ts` exports all still consumed

- [ ] **Step 1: Find dead thread CSS/exports**

Run:
```bash
cd frontend && grep -rn "thread-zone" src && grep -rn "openThreadIds\|BandHooks\|openComposer\|focusReply\|zoneBusy\|hasDraft" src
```
Expected: no matches in `src/**` except possibly `.thread-zone` in `app.css`. If `.thread-zone` (and any `.thread-zone *` descendant rules) are unreferenced, delete them.

- [ ] **Step 2: Confirm `threadview.ts` has no unused exports**

Run:
```bash
cd frontend && for f in bandThreads markerLines glyphClass threadStack pickFromStack cycleStack contextKey submitLabel pendingCount awaitingAgent; do printf "%s: " "$f"; grep -rl "$f" src --include=*.ts --include=*.svelte | grep -v threadview.ts | grep -v threadview.spec.ts | head -1 || echo "UNUSED"; done
```
Expected: each has a consumer. `pendingCount`/`awaitingAgent` are used by `submitLabel`; `submitLabel` by `editor.ts`. If any prints `UNUSED` and isn't a `submitLabel` helper, either it's wired wrong (fix the consumer) or genuinely dead (remove it).

- [ ] **Step 3: Full gate**

Run: `cd frontend && pnpm format:check && pnpm lint && pnpm check && pnpm test && pnpm build:dev`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/app.css frontend/src/term/threadview.ts
git commit -m "frontend: drop the dead view-zone thread styles"
```

---

## Self-review — spec coverage

- **Move conversation out of Monaco / island = decoration + seam** → Tasks 2, 3.
- **Global SidePane (VS Code-style), placement-agnostic ThreadPanel tenant; right slot only; left/registry deferred** → Task 4 (`SidePane` side-param, no threads ref) + Task 5 (`ThreadPanel` no side ref).
- **Seam: 3 signals out (marker/compose/change) + reveal/clear in; BandHooks up to chrome** → Task 3 `EditorSeam`, Task 5 mutations via `api` + `seam.refetch()`.
- **Active-editor binding (most-recently-focused; terminal idles)** → Task 3 `onActivate`, Task 4 `activeEditor` + `$effect`.
- **Three states empty/composer/thread; outdated renders anchorText + jumps** → Task 5 template.
- **Gutter↔panel single-select; stacked line = top-ranked + `‹ N of Y ›`** → Task 1 helpers + Task 5 `cycle`.
- **File-nav clears; draft safety trivial (chrome-owned text)** → Task 5 `contextKey` reset + `draft` local state.
- **Submit stays in editor head** → untouched in `editor.ts`.
- **Toggle: header affordance + keybinding** → Task 4 × button + `threads.toggle`/`["t", …]`.
- **vitest for the view-model; manual checklist for DOM/seam** → Task 1 + Task 5 Step 4.
- **Fail-open on 404** → inherited: `editor.ts` `fail()`/`fetchThreads` swallow; panel `err` surfaces mutation failures.

No placeholders; types (`EditorSeam`, `Side`, helper signatures) match across Tasks 1/3/5.
