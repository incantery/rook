// The Monaco pane — the second PaneContent kind, framework-free like the
// rest of the imperative island. Read-only by design in this slice: a
// diff review of the workspace's changes (` g) or a single-file viewer
// (` e) — "inspect an agent's work without leaving rook". Monaco itself
// arrives through await import("./monaco"), so nothing here lands in the
// boot bundle.

import type {ChangedFile, HostAPI, ThreadInfo} from "../hostapi";
import type {PaneContent} from "./manager";
import type * as monacoTypes from "monaco-editor";
import {ThreadBand} from "./threads";
import {submitLabel, type Side} from "./threadview";

type Monaco = typeof import("./monaco").monaco;

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
    /** the pane calls this when a Monaco editor gains focus, so chrome can
     *  bind the thread panel to the active editor */
    onActivate?: (seam: EditorSeam) => void;
    /** the pane calls this on dispose, iff a seam was ever handed out, so
     *  chrome can drop a reference to what's now a disposed seam */
    onDispose?: (seam: EditorSeam) => void;
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
    private submitBtn: HTMLButtonElement;

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

    // seam subscribers (chrome side)
    private markerCbs: ((line: number, side: Side, ids: number[]) => void)[] = [];
    private composeCbs: ((s: number, e: number, side: Side) => void)[] = [];
    private changeCbs: (() => void)[] = [];
    private _seam: EditorSeam | null = null;

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
        this.submitBtn = this.btn(
            "",
            "send review comments to the workspace's claude",
            () => void this.submit(),
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
        // a re-focused pane is often stale — the agent kept working. Thread
        // drafts live in the panel (chrome), so refetch is always safe here.
        if (!this.monaco || Date.now() - this.fetchedAt <= STALE_MS) return;
        if (this.opts.kind === "review") void this.refresh();
        else void this.refetchThreads();
    }

    /** The manager calls this exactly when geometry changes (activate,
     *  divider drag, resize) — automaticLayout stays off. */
    fit(): void {
        this.diffEditor?.layout();
        this.editor?.layout();
    }

    dispose(): void {
        this.disposed = true;
        if (this._seam) this.opts.onDispose?.(this._seam);
        for (const b of this.bands) b.dispose();
        this.disposeModels();
        this.diffEditor?.dispose();
        this.editor?.dispose();
        this.el.remove();
    }

    // ---- the seam (chrome ↔ island) ----

    get seam(): EditorSeam {
        return (this._seam ??= {
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
        });
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

    private activate(): void {
        this.opts.onActivate?.(this.seam);
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
                this.emitChange();
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
                this.emitChange();
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
            this.fetchedAt = Date.now();
        } catch (err) {
            console.warn("editor pane: threads unavailable:", err);
        }
        this.updateSubmit();
    }

    private currentPath(): string | undefined {
        return this.opts.kind === "file" ? this.opts.path : this.files[this.idx]?.path;
    }

    /** Mutations refetch and re-render — the pane's data is always the
     *  host's answer, never locally patched. */
    private async refetchThreads(): Promise<void> {
        await this.fetchThreads();
        if (this.disposed) return;
        const path = this.currentPath();
        if (!path) return;
        for (const b of this.bands) b.render(this.threadsAll, path);
        this.emitChange();
    }

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

    /** ⌘⇧M / right-click → composer on the invoking editor's selection.
     *  Registered once per editor; the keybinding lives inside Monaco's
     *  own layer, so the backtick prefix is untouched. */
    // Note: typed IStandaloneCodeEditor, not the brief's ICodeEditor — addAction
    // only exists on the standalone interface (monaco-editor 0.55.1 editor.api.d.ts);
    // every caller (both diff-child editors and the single-file editor) is a
    // standalone editor, so this is a widening-free correction, not a design change.
    private addCommentAction(ed: monacoTypes.editor.IStandaloneCodeEditor): void {
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
                for (const cb of this.composeCbs) cb(sel.startLineNumber, end, band.side);
            },
        });
    }

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
            this.addCommentAction(this.diffEditor.getOriginalEditor());
            this.addCommentAction(this.diffEditor.getModifiedEditor());
            this.diffEditor.getOriginalEditor().onDidFocusEditorText(() => this.activate());
            this.diffEditor.getModifiedEditor().onDidFocusEditorText(() => this.activate());
        }
        return this.diffEditor;
    }

    private ensureEditor(): monacoTypes.editor.IStandaloneCodeEditor {
        if (!this.editor) {
            this.editor = this.monaco!.editor.create(this.body, this.editorOpts());
            this.addCommentAction(this.editor);
            this.editor.onDidFocusEditorText(() => this.activate());
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
