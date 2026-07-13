// The Monaco pane — the second PaneContent kind, framework-free like the
// rest of the imperative island. Read-only by design in this slice: a
// diff review of the workspace's changes (` g) or a single-file viewer
// (` e) — "inspect an agent's work without leaving rook". Monaco itself
// arrives through await import("./monaco"), so nothing here lands in the
// boot bundle.

import type {ChangedFile, HostAPI, ThreadInfo} from "../hostapi";
import type {PaneContent} from "./manager";
import type * as monacoTypes from "monaco-editor";
import {ThreadBand, type BandHooks} from "./threads";

type Monaco = typeof import("./monaco").monaco;

export interface EditorPaneOpts {
    workspace: string;
    kind: "review" | "file";
    /** file mode: the repo-top-relative path to view */
    path?: string;
    /** the terminal's font — the pane should read like the rest of rook */
    font: {family: string; size: number};
    /** surface a failure where the user is looking (titlebar flash) */
    onFlash: (msg: string) => void;
    /** the × button; the caller routes it to closeActive() */
    onClose: () => void;
}

/** How stale a review may be before a re-focus refetches it. */
const STALE_MS = 2000;

export class EditorPane implements PaneContent {
    readonly el: HTMLElement;
    /** not a terminal: kill/jump/cwd-from all skip this pane */
    readonly sessionId = null;

    private body: HTMLElement;
    private statusEl: HTMLElement;
    private pathEl: HTMLElement;
    private noteEl: HTMLElement;
    private counterEl: HTMLElement | null = null;
    private baseBtn: HTMLButtonElement | null = null;

    private monaco: Monaco | null = null;
    private diffEditor: monacoTypes.editor.IStandaloneDiffEditor | null = null;
    private editor: monacoTypes.editor.IStandaloneCodeEditor | null = null;
    private models: {dispose(): void}[] = [];

    /** undefined until the host answers — it decides the default base */
    private base: "head" | "branch" | undefined;
    private files: ChangedFile[] = [];
    private idx = 0;
    private fetchedAt = 0;
    private disposed = false;
    /** model URIs must be unique for the pane's whole life */
    private seq = 0;

    /** every thread in the workspace — bands slice per (path, side) */
    private threadsAll: ThreadInfo[] = [];
    private bands: ThreadBand[] = [];

    constructor(
        private api: HostAPI,
        private opts: EditorPaneOpts,
    ) {
        // DOM is built synchronously — the projector needs el immediately;
        // Monaco and the data arrive behind load()
        this.el = document.createElement("div");
        this.el.className = "editor-wrap";
        const head = document.createElement("div");
        head.className = "editor-head";
        if (opts.kind === "review") {
            this.baseBtn = this.btn("vs …", "toggle diff base (branch ⇄ HEAD)", () => {
                this.base = this.base === "branch" ? "head" : "branch";
                void this.refresh();
            });
            const prev = this.btn("‹", "previous changed file", () => this.step(-1));
            const next = this.btn("›", "next changed file", () => this.step(1));
            this.counterEl = this.span("editor-counter", "");
            head.append(this.baseBtn, prev, next, this.counterEl);
        }
        this.pathEl = this.span("editor-path", opts.kind === "file" ? (opts.path ?? "") : "");
        this.noteEl = this.span("editor-note", "");
        head.append(this.pathEl, this.noteEl);
        head.append(
            this.btn(
                "⟳",
                "refresh",
                () => void (opts.kind === "file" ? this.loadFile() : this.refresh()),
            ),
            this.btn("×", "close pane", () => opts.onClose()),
        );
        this.body = document.createElement("div");
        this.body.className = "editor-body";
        this.statusEl = document.createElement("div");
        this.statusEl.className = "editor-status";
        this.statusEl.hidden = true;
        this.body.appendChild(this.statusEl);
        this.el.append(head, this.body);
        void this.load();
    }

    get title(): string {
        if (this.opts.kind === "file") {
            const p = this.opts.path ?? "";
            return p.slice(p.lastIndexOf("/") + 1) || "file";
        }
        return `⎇ ${this.opts.workspace}`;
    }

    focus(): void {
        (this.diffEditor ?? this.editor)?.focus();
        // a re-focused review is often stale — the agent kept working
        if (this.opts.kind === "review" && this.monaco && Date.now() - this.fetchedAt > STALE_MS) {
            void this.refresh();
        }
    }

    /** The manager calls this exactly when geometry changes (activate,
     *  divider drag, resize) — automaticLayout stays off. */
    fit(): void {
        this.diffEditor?.layout();
        this.editor?.layout();
    }

    dispose(): void {
        this.disposed = true;
        for (const b of this.bands) b.dispose();
        this.disposeModels();
        this.diffEditor?.dispose();
        this.editor?.dispose();
        this.el.remove();
    }

    // ---- data flow ----

    private async load(): Promise<void> {
        // stage-named statuses: a hang must say WHERE it hangs (the
        // monaco chunk is the app's first big lazy import — new asset-
        // serving territory for the webview)
        this.showStatus("loading Monaco…");
        const watchdog = setTimeout(() => {
            this.showStatus(
                "still loading Monaco (3.6 MB chunk)… — if this never finishes, the asset serving is stuck; check the console",
            );
        }, 8000);
        try {
            const t0 = performance.now();
            this.monaco = (await import("./monaco")).monaco;
            console.info(`editor pane: monaco loaded in ${Math.round(performance.now() - t0)}ms`);
        } catch (err) {
            console.error("monaco failed to load", err);
            this.showStatus(`Monaco failed to load: ${err}`);
            return;
        } finally {
            clearTimeout(watchdog);
        }
        if (this.disposed) return;
        this.showStatus(this.opts.kind === "file" ? "reading file…" : "fetching changes…");
        await (this.opts.kind === "file" ? this.loadFile() : this.refresh());
    }

    private async refresh(): Promise<void> {
        if (!this.monaco) return;
        const keep = this.files[this.idx]?.path;
        try {
            // threads ride the same cycle but never gate it — a hanging
            // /threads must not stall a diff the pane already has
            void this.fetchThreads().then(() => {
                const p = this.currentPath();
                if (this.disposed || !p) return;
                for (const b of this.bands) b.render(this.threadsAll, p);
            });
            const res = await this.api.changes(this.opts.workspace, this.base);
            if (this.disposed) return;
            this.fetchedAt = Date.now();
            // the host decides the default and reports what it diffed —
            // the header reflects the answer, not the ask
            this.base = res.base;
            if (this.baseBtn) this.baseBtn.textContent = `vs ${res.baseName}`;
            this.noteEl.textContent = res.fallback ?? "";
            this.files = res.files;
            if (this.files.length === 0) {
                if (this.counterEl) this.counterEl.textContent = "0/0";
                this.pathEl.textContent = "";
                this.showStatus(
                    res.base === "branch" ? `no changes vs ${res.baseName}` : "working tree clean",
                );
                return;
            }
            const i = keep ? this.files.findIndex((f) => f.path === keep) : 0;
            await this.open(i === -1 ? 0 : i);
        } catch (err) {
            this.fail("loading changes", err);
        }
    }

    private step(d: number): void {
        const n = this.files.length;
        if (n === 0) return;
        void this.open((this.idx + d + n) % n);
    }

    private async open(i: number): Promise<void> {
        const m = this.monaco;
        const f = this.files[i];
        if (!m || !f) return;
        this.idx = i;
        if (this.counterEl) this.counterEl.textContent = `${i + 1}/${this.files.length}`;
        this.pathEl.textContent =
            (f.oldPath ? `${f.oldPath} → ` : "") +
            f.path +
            (f.status !== "modified" ? ` · ${f.status}` : "");
        try {
            const d = await this.api.fileDiff(this.opts.workspace, f.path, this.base);
            if (this.disposed || this.files[this.idx] !== f) return; // user moved on
            if (d.binary) {
                this.showStatus(`${f.path}: binary file`);
                return;
            }
            if (d.truncated) this.pathEl.textContent += " · truncated at 2 MB";
            this.clearStatus();
            this.disposeModels();
            const original = m.editor.createModel(d.original, undefined, this.uri(f.path));
            const modified = m.editor.createModel(d.modified, undefined, this.uri(f.path));
            this.models.push(original, modified);
            this.ensureDiffEditor().setModel({original, modified});
            this.fit();
            this.rebuildBands();
        } catch (err) {
            this.fail(`diffing ${f.path}`, err);
        }
    }

    private async loadFile(): Promise<void> {
        const m = this.monaco;
        const path = this.opts.path ?? "";
        if (!m) return;
        try {
            // same non-gating fetch as refresh()
            void this.fetchThreads().then(() => {
                const p = this.currentPath();
                if (this.disposed || !p) return;
                for (const b of this.bands) b.render(this.threadsAll, p);
            });
            const res = await this.api.readFile(this.opts.workspace, path);
            if (this.disposed) return;
            if (res.binary) {
                this.showStatus(`${path}: binary file`);
                return;
            }
            this.pathEl.textContent = path + (res.truncated ? " · truncated at 2 MB" : "");
            this.clearStatus();
            this.disposeModels();
            const model = m.editor.createModel(res.content, undefined, this.uri(path));
            this.models.push(model);
            this.ensureEditor().setModel(model);
            this.fit();
            this.rebuildBands();
        } catch (err) {
            this.fail(`reading ${path}`, err);
        }
    }

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

    // ---- monaco plumbing ----

    private editorOpts(): monacoTypes.editor.IStandaloneEditorConstructionOptions {
        return {
            readOnly: true,
            glyphMargin: true,
            automaticLayout: false, // the manager's fit() is the resize signal
            theme: "rook",
            fontFamily: this.opts.font.family,
            fontSize: this.opts.font.size,
            minimap: {enabled: false},
            scrollBeyondLastLine: false,
        };
    }

    private ensureDiffEditor(): monacoTypes.editor.IStandaloneDiffEditor {
        if (!this.diffEditor) {
            this.diffEditor = this.monaco!.editor.createDiffEditor(this.body, {
                ...this.editorOpts(),
                renderSideBySide: true,
            });
        }
        return this.diffEditor;
    }

    private ensureEditor(): monacoTypes.editor.IStandaloneCodeEditor {
        if (!this.editor) {
            this.editor = this.monaco!.editor.create(this.body, this.editorOpts());
        }
        return this.editor;
    }

    /** Unique model URI whose path still carries the file's extension —
     *  that's what language inference reads. */
    private uri(path: string): monacoTypes.Uri {
        return this.monaco!.Uri.parse(`rook://${++this.seq}/${path}`);
    }

    private disposeModels(): void {
        for (const mdl of this.models) mdl.dispose();
        this.models = [];
    }

    // ---- labeled states (binary, clean, errors) — never a crash ----

    private showStatus(msg: string): void {
        this.statusEl.textContent = msg;
        this.statusEl.hidden = false;
    }

    private clearStatus(): void {
        this.statusEl.hidden = true;
    }

    private fail(what: string, err: unknown): void {
        console.error(`editor pane: ${what}:`, err);
        const msg = String(err);
        if (msg.includes(" 404 ")) {
            // protocol skew: this daemon predates the review endpoints —
            // fail open and say so (rook-host outlives app installs)
            this.opts.onFlash("review needs a newer rook-host — relaunch rook");
            this.showStatus(
                "this rook-host predates the review pane — relaunch rook to replace the daemon",
            );
        } else {
            this.showStatus(`${what} failed: ${msg}`);
        }
    }

    // ---- tiny DOM helpers ----

    private btn(label: string, title: string, onClick: () => void): HTMLButtonElement {
        const b = document.createElement("button");
        b.className = "editor-btn";
        b.textContent = label;
        b.title = title;
        b.addEventListener("click", onClick);
        return b;
    }

    private span(cls: string, text: string): HTMLElement {
        const s = document.createElement("span");
        s.className = cls;
        s.textContent = text;
        return s;
    }
}
