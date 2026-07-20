// The Monaco pane — the second PaneContent kind, framework-free like the
// rest of the imperative island. Two modes: a diff review of the
// workspace's changes (` g, read-only) and a single-file editor (` e).
// The file editor is where "code editing" lives — vim keybindings, and
// :w / ⌘S save straight to the workspace file (POST …/write). Both Monaco
// and monaco-vim arrive through await import(), so nothing here lands in
// the boot bundle. Editing is enabled only for files that loaded WHOLE:
// a truncated (>2 MB) or binary read stays read-only, because saving a
// truncated buffer would overwrite the tail with nothing.

import type {ChangedFile, HostAPI, LspLocation, ThreadInfo} from "../hostapi";
import type {PaneContent} from "./manager";
import type * as monacoTypes from "monaco-editor";
import {legendModifiers, legendTypes, unifyTokens} from "../highlight/semantic";
import {ThreadBand} from "./threads";
import {submitLabel, type Side} from "./threadview";

type Monaco = typeof import("./monaco").monaco;
type VimLib = typeof import("monaco-vim");
type VimAdapter = ReturnType<VimLib["initVimMode"]>;

// monaco-vim is loaded once, lazily, the first time any file editor mounts.
// The ex-command handlers (:w, :q, :qa …) are GLOBAL — registered on the one
// shared Vim singleton — so they route to the right pane at call time:
//   paneByEditor  the focused editor → its pane (:w/:q act on that editor;
//                 the command is typed INTO that editor, so cm.editor is it)
//   livePanes     every editor pane, because :qa spans panes and windows
let vimLib: VimLib | null = null;
const paneByEditor = new WeakMap<object, EditorPane>();
const livePanes = new Set<EditorPane>();
let exCommandsDefined = false;

async function loadVim(): Promise<VimLib> {
    if (!vimLib) vimLib = await import("monaco-vim");
    if (!exCommandsDefined) {
        // VimMode (= CMAdapter) carries the Vim API on a static the shipped
        // types don't describe — hence the cast. defineEx(name, prefix, fn)
        // requires prefix to be a literal prefix of name, so :qa pairs with
        // "qall", not "quitall".
        const vim = (vimLib.VimMode as unknown as {Vim: VimApi}).Vim;
        const paneOf = (cm: ExCm) => (cm?.editor ? paneByEditor.get(cm.editor) : undefined);
        // the bang (:q!, :qa!) parses into argString, never the command name
        const forced = (p: ExParams) => (p?.argString ?? "").trim().startsWith("!");
        vim.defineEx("write", "w", (cm) => void paneOf(cm)?.save());
        vim.defineEx("quit", "q", (cm, p) => paneOf(cm)?.exQuit(forced(p)));
        vim.defineEx("wq", "wq", (cm) => void paneOf(cm)?.exSaveQuit());
        vim.defineEx("xit", "x", (cm) => void paneOf(cm)?.exSaveQuit());
        vim.defineEx("qall", "qa", (cm, p) => paneOf(cm)?.exQuitAll(forced(p)));
        vim.defineEx("wqall", "wqa", (cm) => void paneOf(cm)?.exSaveQuitAll());
        vim.defineEx("xall", "xa", (cm) => void paneOf(cm)?.exSaveQuitAll());
        // gd/gr/K — vim's navigation verbs onto the host's LSP surface.
        // defineAction/mapCommand ride the same undocumented static as
        // defineEx; a monaco-vim bump that drops them must not take the
        // editor down, so the whole block is a nicety behind try/catch.
        try {
            vim.defineAction("rookDef", (cm) => void paneOf(cm)?.goToDefinition());
            vim.defineAction("rookRefs", (cm) => void paneOf(cm)?.showReferences());
            vim.defineAction("rookHover", (cm) => paneOf(cm)?.showHover());
            vim.mapCommand("gd", "action", "rookDef", {}, {context: "normal"});
            vim.mapCommand("gr", "action", "rookRefs", {}, {context: "normal"});
            vim.mapCommand("K", "action", "rookHover", {}, {context: "normal"});
            // ⌃O/⌃I — the workbench jumplist (chrome's, at the openFile
            // seam), overriding monaco-vim's single-buffer walk: rook's
            // jumps cross files, so the list must live above the pane.
            vim.defineAction("rookJumpBack", (cm) => paneOf(cm)?.jump("back"));
            vim.defineAction("rookJumpForward", (cm) => paneOf(cm)?.jump("forward"));
            vim.mapCommand("<C-o>", "action", "rookJumpBack", {}, {context: "normal"});
            vim.mapCommand("<C-i>", "action", "rookJumpForward", {}, {context: "normal"});
            // ⌃P/⌃G/⌃S — telescope muscle memory, scoped to the editor so
            // terminals keep shell history (⌃P) and flow control (⌃S).
            vim.defineAction("rookFindFile", (cm) => paneOf(cm)?.findFile());
            vim.defineAction("rookGrep", (cm) => paneOf(cm)?.openGrep());
            vim.defineAction("rookGrepWord", (cm) => {
                const p = paneOf(cm);
                p?.openGrep(p.wordAtCursor() ?? undefined);
            });
            vim.mapCommand("<C-p>", "action", "rookFindFile", {}, {context: "normal"});
            vim.mapCommand("<C-g>", "action", "rookGrep", {}, {context: "normal"});
            vim.mapCommand("<C-s>", "action", "rookGrepWord", {}, {context: "normal"});
        } catch (err) {
            console.warn("editor pane: vim lsp maps unavailable:", err);
        }
        // clipboard=unnamedplus, write side: any yank/delete/change into the
        // unnamed register mirrors to the system clipboard. The read side (p
        // pasting FROM other apps) stays vim-internal — navigator.clipboard
        // reads are async and permission-gated, so they can't back a register.
        try {
            const vim = (vimLib.VimMode as unknown as {Vim: VimApi}).Vim;
            const rc = vim.getRegisterController();
            const proto = Object.getPrototypeOf(rc) as {
                pushText(name: unknown, op: string, text: string, ...rest: unknown[]): unknown;
            };
            const orig = proto.pushText;
            proto.pushText = function (name, op, text, ...rest) {
                // named registers ("ay, and internal "0 pushes) opt out
                if (name == null || name === "" || name === "+") {
                    const linewise = rest[0] === true;
                    const t = linewise && !text.endsWith("\n") ? text + "\n" : text;
                    void navigator.clipboard?.writeText(t).catch(() => {});
                }
                return orig.call(this, name, op, text, ...rest);
            };
        } catch (err) {
            console.warn("editor pane: clipboard mirror unavailable:", err);
        }
        exCommandsDefined = true;
    }
    return vimLib;
}

type ExCm = {editor?: object};
type ExParams = {argString?: string};
interface VimApi {
    defineEx(name: string, prefix: string, fn: (cm: ExCm, params: ExParams) => void): void;
    defineAction(name: string, fn: (cm: ExCm) => void): void;
    mapCommand(
        keys: string,
        type: string,
        name: string,
        args?: object,
        extra?: {context?: string},
    ): void;
    getRegisterController(): object;
}

// ---- LSP: hover provider + the model→pane bridge ----
// Providers are global per-language in Monaco; rook registers ONE hover
// provider for '*' and routes through the model→pane map, so the host stays
// the router ("no server for .txt" is the host's empty+note answer, not a
// frontend filetype list). Definition/references skip Monaco's own goto
// contrib entirely — cross-model targets would need a text-model service the
// zero-language-services build doesn't have; the pane drives the openFile
// ladder instead.
const paneByModel = new WeakMap<object, EditorPane>();
let lspProvidersRegistered = false;

function ensureLspProviders(m: Monaco): void {
    if (lspProvidersRegistered) return;
    lspProvidersRegistered = true;
    m.languages.registerHoverProvider("*", {
        provideHover: async (model, position) => {
            const pane = paneByModel.get(model);
            if (!pane) return null;
            return pane.hoverAt(position.lineNumber, position.column);
        },
    });
    // Semantic tokens LAYER OVER the TextMate grammar: the grammar paints
    // instantly and everywhere, the server then repaints what it actually
    // knows (this identifier is a type, that one's a parameter — the
    // distinction no regex can make). Where there's no server, or it's slow,
    // or it declines, the grammar's answer simply stands.
    //
    // The legend is per-SERVER, but Monaco wants one legend per provider, so
    // the provider publishes the union of every legend seen so far and
    // remaps indices into it. In practice one language means one server, so
    // the remap is usually the identity — it exists so a second server can't
    // silently miscolor through a legend that isn't its own.
    m.languages.registerDocumentSemanticTokensProvider("*", {
        getLegend: () => semanticLegend(),
        releaseDocumentSemanticTokens: () => {},
        provideDocumentSemanticTokens: async (model) => {
            const pane = paneByModel.get(model);
            if (!pane) return null;
            return pane.semanticTokens();
        },
    });
}

function semanticLegend(): monacoTypes.languages.SemanticTokensLegend {
    return {tokenTypes: legendTypes, tokenModifiers: legendModifiers};
}

export interface EditorContext {
    workspace: string;
    path: string;
    base: "head" | "branch" | undefined;
}

/** What the user meant by opening the composer.
 *   note — the whiteboard: land it pending, keep reviewing, batch it later.
 *   ask  — this one, now: submit just this thread and nudge the responder. */
export type ComposeMode = "note" | "ask";

/** The narrow door between the editor island and the thread panel (chrome).
 *  Signals out (marker click, compose, change), calls in (reveal/clear). */
export interface EditorSeam {
    context(): EditorContext | null;
    threads(): ThreadInfo[];
    refetch(): Promise<void>;
    reveal(t: ThreadInfo): void;
    /** Jump to an arbitrary file+range (the review pane driving itself from a
     *  hunk list). No-op on a pane whose changed set doesn't hold `path`. */
    revealAt(path: string, startLine: number, endLine: number, side: Side): void;
    /** Cancel a latched open-focus so a list-driven reveal doesn't steal the
     *  keyboard when Monaco finishes loading (the diff is a passive detail
     *  view; the hunk list keeps focus). */
    releaseFocus(): void;
    clearHighlight(): void;
    /** ,c / ,? — chrome asking the pane to open the composer on the current
     *  selection. The inbound twin of onCompose. False means there was
     *  nothing to comment on (no model yet), so chrome can say so. */
    compose(mode: ComposeMode): boolean;
    onMarkerClick(cb: (line: number, side: Side, ids: number[]) => void): () => void;
    onCompose(
        cb: (startLine: number, endLine: number, side: Side, mode: ComposeMode) => void,
    ): () => void;
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
    /** cross-file gd target — chrome routes it through the openFile ladder
     *  (reveal → retarget → mint), then reveals the position */
    onOpenLocation?: (path: string, line: number, col: number) => void;
    /** gr results — chrome hands them to the refs quickfix context */
    onReferences?: (locations: LspLocation[]) => void;
    /** a jump is about to happen INSIDE this pane (same-file gd) — chrome
     *  records the current position; cross-pane jumps record at openFile */
    onRecordJump?: () => void;
    /** ⌃O/⌃I — chrome owns the jumplist and drives the openFile ladder */
    onJump?: (dir: "back" | "forward") => void;
    /** ⌃P — open chrome's file picker */
    onFindFile?: () => void;
    /** ⌃G/⌃S — open chrome's grep picker, seeded with the word under the
     *  cursor when ⌃S asked for it */
    onGrep?: (seed?: string) => void;
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

    // ---- file-mode editing (` e only) ----
    /** the monaco host (fills the body under the head); vimBar sits below */
    private mount: HTMLElement;
    private vimBar: HTMLElement | null = null;
    private vim: VimAdapter | null = null;
    /** editable iff the file loaded whole — truncated/binary stays read-only */
    private editable = false;
    private dirty = false;
    private saving = false;
    /** the model version at the last load/save — dirty is a diff against it,
     *  so undoing back to a saved state reads clean again */
    private savedVersionId = 0;
    private changeSub: {dispose(): void} | null = null;
    /** a dirty × click arms discard; a second click within the window closes */
    private closeArmed = false;
    /** focus() fired before the editor existed — apply it once it does */
    private wantFocus = false;
    /** a revealPosition() that landed before the model did (gd into a pane
     *  that's still loading) — applied at the end of loadFile */
    private pendingPos: {line: number; col: number} | null = null;

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
    private composeCbs: ((s: number, e: number, side: Side, mode: ComposeMode) => void)[] = [];
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
            this.btn("×", "close pane", () => this.requestClose()),
        );
        this.body = document.createElement("div");
        this.body.className = "editor-body";
        this.statusEl = document.createElement("div");
        this.statusEl.className = "editor-status";
        this.statusEl.hidden = true;
        // monaco fills .editor-mount (flex:1); the vim status line sits under
        // it (file mode only). The status overlay covers the whole body.
        this.mount = document.createElement("div");
        this.mount.className = "editor-mount";
        this.body.append(this.statusEl, this.mount);
        if (opts.kind === "file") {
            this.vimBar = document.createElement("div");
            this.vimBar.className = "editor-vim";
            this.body.appendChild(this.vimBar);
        }
        this.el.append(head, this.body);
        livePanes.add(this); // :qa closes every editor pane, this one included
        void this.load();
    }

    get title(): string {
        if (this.opts.kind === "file") {
            const p = this.opts.path ?? "";
            const name = p.slice(p.lastIndexOf("/") + 1) || "file";
            return this.dirty ? `● ${name}` : name;
        }
        return `⎇ ${this.opts.workspace}`;
    }

    focus(): void {
        const ed = this.diffEditor ?? this.editor;
        // On open, the manager focuses this pane while the Monaco chunk is
        // still loading — there's no editor to take focus yet. Latch the
        // request so the load path focuses it the moment it exists (else the
        // user has to click in before vim/typing works).
        if (ed) ed.focus();
        else this.wantFocus = true;
        // a re-focused pane is often stale — the agent kept working. Thread
        // drafts live in the panel (chrome), so refetch is always safe here.
        if (!this.monaco || Date.now() - this.fetchedAt <= STALE_MS) return;
        if (this.opts.kind === "review") void this.refresh();
        else void this.refetchThreads();
    }

    /** Honor a focus() that landed before the editor existed. */
    private applyPendingFocus(): void {
        if (!this.wantFocus) return;
        const ed = this.diffEditor ?? this.editor;
        if (!ed) return;
        this.wantFocus = false;
        ed.focus();
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
        this.changeSub?.dispose();
        this.vim?.dispose();
        if (this.editor) paneByEditor.delete(this.editor);
        livePanes.delete(this);
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
            revealAt: (path, s, e, side) => void this.revealAt(path, s, e, side),
            releaseFocus: () => {
                this.wantFocus = false;
            },
            clearHighlight: () => {
                for (const b of this.bands) b.clearHighlight();
            },
            compose: (mode) => this.compose(mode),
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

    private pendingReveal: {path: string; s: number; e: number; side: Side} | null = null;

    /** Navigate this (review) pane to path, then highlight+scroll to the
     *  range — the hunk list driving the diff. If path isn't in the changed
     *  set (different scope/base) it's a no-op, so the list still works even
     *  when the pane can't show that file. */
    private async revealAt(
        path: string,
        startLine: number,
        endLine: number,
        side: Side,
    ): Promise<void> {
        // the pane may still be loading its changed set (just opened from a
        // hunk click) — stash and let refresh() apply it once files land.
        if (this.files.length === 0) {
            this.pendingReveal = {path, s: startLine, e: endLine, side};
            return;
        }
        const i = this.files.findIndex((f) => f.path === path);
        if (i === -1) return;
        if (i !== this.idx) await this.open(i);
        if (this.disposed) return;
        for (const b of this.bands) {
            if (b.side === side) {
                b.highlight(startLine, endLine);
                b.editor.revealLinesInCenterIfOutsideViewport(
                    Math.max(1, startLine),
                    Math.max(1, endLine),
                );
                // deliberately NOT b.editor.focus() (unlike reveal): the hunk
                // list keeps the keyboard so j/k/a/r/d stay live while the diff
                // scrolls alongside.
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
            ensureLspProviders(this.monaco);
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
            // a reveal that arrived before the changed set loaded (hunk click
            // opened this pane) — apply it now that this.files is populated.
            if (this.pendingReveal) {
                const p = this.pendingReveal;
                this.pendingReveal = null;
                void this.revealAt(p.path, p.s, p.e, p.side);
            }
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
            this.applyPendingFocus();
        } catch (err) {
            this.fail(`diffing ${f.path}`, err);
        }
    }

    /** Point this pane at a different file — `:e`, the whole reason buffers
     *  work. The pane keeps its id, its place in the layout and its Monaco
     *  instance; only the model underneath changes. Cheap, because loadFile()
     *  already rebuilds the model, head, bands and vim from opts.path.
     *
     *  Refuses a dirty buffer the way vim refuses `:e` without a bang —
     *  silently discarding someone's edits to service a click in the explorer
     *  is never the right trade. Returns whether it moved, so the caller can
     *  fall back to another pane rather than appear to do nothing.
     *
     *  file-mode only: a review pane is a walker over the changed set, not a
     *  document, and its head/editor are a different shape entirely. */
    async setFile(path: string): Promise<boolean> {
        if (this.opts.kind !== "file" || this.disposed) return false;
        if (this.opts.path === path) return true; // already here
        if (this.dirty) {
            this.opts.onFlash(`${this.opts.path ?? "buffer"} has unsaved changes`);
            return false;
        }
        this.opts.path = path;
        this.closeArmed = false;
        this.editable = false; // until the read says otherwise
        this.showStatus("reading file…");
        await this.loadFile();
        this.emitChange(); // the strip's title + the thread panel's file context
        return true;
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
            // A whole file is editable; a truncated one stays read-only —
            // saving its 2 MB prefix would erase everything past it. External
            // (outside-workspace) reads are read-only by design: the write
            // door confines to the workspace.
            this.editable = !res.truncated && !res.external;
            this.pathEl.textContent =
                path +
                (res.truncated
                    ? " · truncated at 2 MB · read-only"
                    : res.external
                      ? " · external · read-only"
                      : "");
            this.clearStatus();
            this.disposeModels();
            const model = m.editor.createModel(res.content, undefined, this.uri(path));
            this.models.push(model);
            paneByModel.set(model, this); // hover routes model → this pane
            const ed = this.ensureEditor();
            ed.setModel(model);
            ed.updateOptions({readOnly: !this.editable});
            this.savedVersionId = model.getAlternativeVersionId();
            this.setDirty(false);
            this.changeSub?.dispose();
            this.changeSub = model.onDidChangeContent(() =>
                this.setDirty(model.getAlternativeVersionId() !== this.savedVersionId),
            );
            this.fit();
            this.rebuildBands();
            this.applyPendingFocus();
            this.applyPendingPos();
            // vim rides every file editor (motions work read-only too); the
            // :w saver is registered only when the buffer is editable.
            await this.attachVim(ed);
        } catch (err) {
            this.fail(`reading ${path}`, err);
        }
    }

    // ---- file-mode editing: vim, dirty tracking, save ----

    /** Attach vim once, wiring this editor's :w/⌘S saver into the global
     *  Vim ex map. Read-only (truncated) files still get motions, just no
     *  saver — a :w there is a harmless no-op. */
    private async attachVim(ed: monacoTypes.editor.IStandaloneCodeEditor): Promise<void> {
        if (this.vim) return;
        let lib: VimLib;
        try {
            lib = await loadVim();
        } catch (err) {
            // vim is a nicety, never a gate — the editor works without it
            console.warn("editor pane: monaco-vim failed to load:", err);
            return;
        }
        if (this.disposed || this.editor !== ed) return;
        // route :w/:q typed in this editor back to this pane (save() itself
        // no-ops when the buffer isn't editable — a read-only :w is harmless)
        paneByEditor.set(ed, this);
        this.vim = lib.initVimMode(ed, this.vimBar);
    }

    private setDirty(dirty: boolean): void {
        if (this.dirty === dirty) return;
        this.dirty = dirty;
        this.closeArmed = false; // any edit/save resets the discard arm
        // the pane tab reads title on change; nudge the counter/path too
        this.emitChange();
    }

    /** :w / ⌘S — save with user feedback. Public: the global vim ex map and
     *  the ⌘S command both call it. */
    async save(): Promise<void> {
        if (!this.editable) {
            this.opts.onFlash(`${this.opts.path ?? "file"} is read-only`);
            return;
        }
        if (!this.dirty) {
            this.opts.onFlash(`${this.opts.path ?? ""} — nothing to save`);
            return;
        }
        await this.doSave();
    }

    /** The write itself — silent, so quit paths don't spam flashes. Returns
     *  true when the buffer is clean afterward (safe to quit): a non-editable
     *  or already-clean pane is trivially clean; a failed write is not. */
    private async doSave(): Promise<boolean> {
        const model = this.editor?.getModel();
        if (!this.editable || !model || !this.dirty) return true;
        if (this.saving) return false;
        this.saving = true;
        const versionId = model.getAlternativeVersionId();
        try {
            await this.api.writeFile(this.opts.workspace, this.opts.path ?? "", model.getValue());
            if (this.disposed) return true;
            this.savedVersionId = versionId;
            this.setDirty(model.getAlternativeVersionId() !== versionId);
            this.opts.onFlash(`saved ${this.opts.path ?? ""}`);
            return !this.dirty;
        } catch (err) {
            const msg = String(err);
            this.opts.onFlash(
                msg.includes(" 404 ")
                    ? "saving needs a newer rook-host — relaunch rook"
                    : `save failed: ${msg}`,
            );
            return false;
        } finally {
            this.saving = false;
        }
    }

    /** :q — close this pane; refuse (vim-style) on unsaved edits. */
    exQuit(force: boolean): void {
        if (!force && this.dirty) {
            this.opts.onFlash("unsaved changes — :w to save, or :q! to discard");
            return;
        }
        this.opts.onClose();
    }

    /** :wq / :x — save, then close only if the write succeeded. */
    async exSaveQuit(): Promise<void> {
        if (await this.doSave()) this.opts.onClose();
    }

    /** :qa — close every editor pane; refuse if any holds unsaved edits.
     *  Same-class access lets this read siblings' state and close them. */
    exQuitAll(force: boolean): void {
        const panes = [...livePanes];
        if (!force) {
            const dirty = panes.filter((p) => p.dirty).length;
            if (dirty > 0) {
                this.opts.onFlash(
                    `unsaved changes in ${dirty} editor(s) — :wqa to save, or :qa! to discard`,
                );
                return;
            }
        }
        for (const p of panes) p.opts.onClose();
    }

    /** :wqa / :xa — save every editable pane, then close the ones now clean;
     *  a pane whose write failed stays open with its own error flash. */
    async exSaveQuitAll(): Promise<void> {
        const panes = [...livePanes];
        const saved = await Promise.all(panes.map(async (p) => [p, await p.doSave()] as const));
        let failed = 0;
        for (const [p, ok] of saved) {
            if (ok) p.opts.onClose();
            else failed++;
        }
        if (failed > 0) this.opts.onFlash(`${failed} editor(s) still unsaved — left open`);
    }

    /** The × button: a dirty pane arms discard on the first click and closes
     *  on the second — so unsaved edits are never lost to a stray click. */
    private requestClose(): void {
        if (this.dirty && !this.closeArmed) {
            this.closeArmed = true;
            this.opts.onFlash("unsaved changes — ⌘S to save, or × again to discard");
            setTimeout(() => (this.closeArmed = false), 3000);
            return;
        }
        this.opts.onClose();
    }

    // ---- LSP: gd / gr / K against the host's language servers ----

    /** The dirty buffer rides the query so unsaved code resolves; a clean
     *  buffer lets the host serve from disk (didOpen dedup stays warm). */
    private lspText(): string | undefined {
        if (!this.dirty) return undefined;
        return this.editor?.getModel()?.getValue();
    }

    /** file-mode position + path, or null (never the diff pane — its
     *  original side is a historical blob). Public: chrome's jumplist
     *  reads it to record where a jump left from. */
    position(): {path: string; line: number; col: number} | null {
        if (this.opts.kind !== "file" || !this.editor) return null;
        const pos = this.editor.getPosition();
        const path = this.opts.path;
        if (!pos || !path) return null;
        return {path, line: pos.lineNumber, col: pos.column};
    }

    private lspAt(): {path: string; line: number; col: number} | null {
        return this.position();
    }

    /** ⌃O/⌃I land here from vim — the list is chrome's, not this pane's. */
    jump(dir: "back" | "forward"): void {
        this.opts.onJump?.(dir);
    }

    /** ⌃P — chrome's file picker; the pane just rings the bell. */
    findFile(): void {
        this.opts.onFindFile?.();
    }

    /** ⌃G / ⌃S — chrome's grep picker, optionally seeded (word under cursor). */
    openGrep(seed?: string): void {
        this.opts.onGrep?.(seed);
    }

    wordAtCursor(): string | null {
        const pos = this.editor?.getPosition();
        if (!pos) return null;
        return this.editor?.getModel()?.getWordAtPosition(pos)?.word ?? null;
    }

    private lspFail(what: string, err: unknown): void {
        const msg = String(err);
        this.opts.onFlash(
            msg.includes(" 404 ")
                ? "code intelligence needs a newer rook-host — relaunch rook"
                : `${what} failed: ${msg}`,
        );
    }

    /** gd / F12. One target: jump (same file) or hand chrome the open;
     *  external (stdlib/deps) is a labeled dead end until the file surface
     *  can serve outside-workspace paths. */
    async goToDefinition(): Promise<void> {
        const at = this.lspAt();
        if (!at) return;
        try {
            const res = await this.api.lspQuery(
                this.opts.workspace,
                "definition",
                at.path,
                at.line,
                at.col,
                this.lspText(),
            );
            const loc = res.locations[0];
            if (!loc) {
                this.opts.onFlash(res.note ?? "no definition found");
                return;
            }
            // external (stdlib/deps) rides the same ladder — loc.path is
            // absolute there and the file surface serves it read-only
            if (loc.path === this.opts.path) {
                // same-file jumps never reach openFile — record here
                this.opts.onRecordJump?.();
                this.revealPosition(loc.startLine, loc.startCol);
                return;
            }
            this.opts.onOpenLocation?.(loc.path, loc.startLine, loc.startCol);
        } catch (err) {
            this.lspFail("definition", err);
        }
    }

    /** gr / ⇧F12 — the whole list goes to chrome's quickfix (vim's shape). */
    async showReferences(): Promise<void> {
        const at = this.lspAt();
        if (!at) return;
        try {
            const res = await this.api.lspQuery(
                this.opts.workspace,
                "references",
                at.path,
                at.line,
                at.col,
                this.lspText(),
            );
            if (res.locations.length === 0) {
                this.opts.onFlash(res.note ?? "no references found");
                return;
            }
            this.opts.onReferences?.(res.locations);
        } catch (err) {
            this.lspFail("references", err);
        }
    }

    /** K — Monaco's hover widget at the cursor; the provider does the fetch.
     *  Deferred a tick: the hover controller hides on any keydown that isn't
     *  a hover shortcut, so triggering inside K's own keystroke shows a hover
     *  the same event then kills. */
    showHover(): void {
        setTimeout(() => this.editor?.trigger("rook", "editor.action.showHover", {}), 0);
    }

    /** The semantic-token provider's callback (module-level, routed here by
     *  model). Returns null on anything that isn't a live file buffer with a
     *  server behind it — null means "no semantic layer", and the TextMate
     *  grammar's colors stand unchanged. */
    async semanticTokens(): Promise<monacoTypes.languages.SemanticTokens | null> {
        const path = this.opts.kind === "file" ? this.opts.path : undefined;
        if (!path) return null;
        try {
            const res = await this.api.lspSemanticTokens(this.opts.workspace, path, this.lspText());
            if (!res.data.length || !res.types.length) return null;
            return {data: unifyTokens(res.data, res.types, res.modifiers)};
        } catch {
            return null; // ambient like hover — never flash, never break paint
        }
    }

    /** The hover provider's callback (module-level, routed here by model). */
    async hoverAt(line: number, col: number): Promise<monacoTypes.languages.Hover | null> {
        const path = this.opts.kind === "file" ? this.opts.path : undefined;
        if (!path) return null;
        try {
            const res = await this.api.lspHover(
                this.opts.workspace,
                path,
                line,
                col,
                this.lspText(),
            );
            if (!res.contents) return null;
            return {contents: [{value: res.contents}]};
        } catch {
            return null; // hover is ambient — never flash from it
        }
    }

    /** Jump the cursor (1-based) — gd's landing, and the refs list's `o`.
     *  Latches when the model hasn't loaded yet (gd into a fresh pane). */
    revealPosition(line: number, col: number): void {
        if (this.opts.kind !== "file") return;
        const ed = this.editor;
        if (!ed || !ed.getModel()) {
            this.pendingPos = {line, col};
            return;
        }
        ed.setPosition({lineNumber: line, column: col});
        ed.revealPositionInCenterIfOutsideViewport({lineNumber: line, column: col});
        ed.focus();
    }

    private applyPendingPos(): void {
        if (!this.pendingPos) return;
        const p = this.pendingPos;
        this.pendingPos = null;
        this.revealPosition(p.line, p.col);
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
            // Monaco hands this action its own editor, so no focus guessing
            run: () => void this.composeOn(this.bands.find((b) => b.editor === ed), "note"),
        });
    }

    /** ,c / ,? — the composer on whatever the user has selected. Unlike the
     *  ⌘⇧M action, which Monaco hands the invoking editor, a keystroke that
     *  arrives from chrome has to work out WHICH editor holds the cursor: a
     *  diff pane has two, and a comment composed against the wrong one
     *  anchors to the wrong side's blob. */
    compose(mode: ComposeMode): boolean {
        const band =
            this.bands.find((b) => b.editor.hasTextFocus()) ??
            // focus sat in chrome: `modified` is what a review is about, and
            // it's the only side a plain file pane has
            this.bands.find((b) => b.side === "modified") ??
            this.bands[0];
        return this.composeOn(band, mode);
    }

    private composeOn(band: ThreadBand | undefined, mode: ComposeMode): boolean {
        const sel = band?.editor.getSelection();
        if (!band || !sel) return false;
        let end = sel.endLineNumber;
        // a full-line drag ends at column 1 of the NEXT line — not a line
        if (end > sel.startLineNumber && sel.endColumn === 1) end--;
        for (const cb of this.composeCbs) cb(sel.startLineNumber, end, band.side, mode);
        return true;
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
            // Must be explicit. The default is "configuredByTheme", and
            // standalone Monaco hardcodes its theme's semanticHighlighting
            // to false (standaloneThemeService.js) — so the default means
            // OFF, and the provider would be registered but never called.
            "semanticHighlighting.enabled": true,
        };
    }

    private ensureDiffEditor(): monacoTypes.editor.IStandaloneDiffEditor {
        if (!this.diffEditor) {
            this.diffEditor = this.monaco!.editor.createDiffEditor(this.mount, {
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
            this.editor = this.monaco!.editor.create(this.mount, {
                ...this.editorOpts(),
                // vim motions count lines relative to the cursor (5j); the
                // cursor line shows its absolute number. File pane only —
                // the diff stays absolute, its numbers are read, not jumped.
                lineNumbers: "relative",
            });
            this.addCommentAction(this.editor);
            this.editor.onDidFocusEditorText(() => this.activate());
            // ⌘S saves from any mode, so non-vim users get a save too; the
            // vim :w path routes through the same save().
            this.editor.addCommand(
                this.monaco!.KeyMod.CtrlCmd | this.monaco!.KeyCode.KeyS,
                () => void this.save(),
            );
            // F12/⇧F12 mirror gd/gr for non-vim hands (and the context menu)
            this.editor.addAction({
                id: "rook.def",
                label: "Go to definition",
                keybindings: [this.monaco!.KeyCode.F12],
                contextMenuGroupId: "9_rook",
                contextMenuOrder: 2,
                run: () => void this.goToDefinition(),
            });
            this.editor.addAction({
                id: "rook.refs",
                label: "Find references",
                keybindings: [this.monaco!.KeyMod.Shift | this.monaco!.KeyCode.F12],
                contextMenuGroupId: "9_rook",
                contextMenuOrder: 3,
                run: () => void this.showReferences(),
            });
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
