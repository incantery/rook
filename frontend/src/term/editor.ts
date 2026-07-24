// The Monaco pane — the second PaneContent kind, framework-free like the
// rest of the imperative island. Two modes: a diff review of the
// workspace's changes (` g, read-only) and a single-file editor (` e).
// The file editor is where "code editing" lives — vim keybindings, and
// :w / ⌘S save straight to the workspace file (POST …/write). Both Monaco
// and monaco-vim arrive through await import(), so nothing here lands in
// the boot bundle. Editing is enabled only for files that loaded WHOLE:
// a truncated (>2 MB) or binary read stays read-only, because saving a
// truncated buffer would overwrite the tail with nothing.

import type {ChangedFile, GutterHunk, HostAPI, LspLocation, ThreadInfo} from "../hostapi";
import type {PaneContent} from "./manager";
import type * as monacoTypes from "monaco-editor";
import {legendModifiers, legendTypes, unifyTokens} from "../highlight/semantic";
import {ThreadBand} from "./threads";
import {vimbar} from "./vimbar.svelte";
import {RookVimStatusBar} from "./vimstatus";
import {hoverPreview, pickFromStack, threadsCovering, type Side} from "./threadview";

type Monaco = typeof import("./monaco").monaco;
type VimLib = typeof import("monaco-vim");
type VimAdapter = ReturnType<VimLib["initVimMode"]>;

// monaco-vim is loaded once, lazily, the first time any file editor mounts.
// The ex-command handlers (:w, :q, :qa …) are GLOBAL — registered on the one
// shared Vim singleton — so they route to the right pane at call time via
// paneByEditor: the command is typed INTO an editor, cm.editor names it.
// Even :qa fans out only through the pane's own opts.cohort (its window) —
// no module-level registry of every pane exists, on purpose: each editor
// place answers for itself, and a global set is how ":qa killed every
// editor in the app" happened.
let vimLib: VimLib | null = null;
const paneByEditor = new WeakMap<object, EditorPane>();

// Model URIs must be unique across EVERY pane, not just within one:
// Monaco's model registry is global, and two panes opening the SAME file
// with a per-pane counter minted the same rook://1/<path> — createModel
// threw, the second editor never loaded, never took the keyboard, and the
// user's :q executed in whichever editor still held focus (the "quitting
// closes my other editors" dogfood bug, in its second body).
let uriSeq = 0;
let exCommandsDefined = false;

// The :Command bridge — registry commands as ex commands (:ThreadAsk runs
// thread.ask). Frontend-only dispatch sugar, NOT the host plugin system:
// App pushes the registry's map here at boot, and loadVim registers each
// name on the shared Vim singleton with its FULL name as its own prefix,
// so nothing collides with vim's abbreviations (:w, :q) or the fixed
// commands above. Names are vim's user-command shape (leading uppercase),
// which also keeps them out of the built-ins' namespace.
let registryExCommands = new Map<string, () => void>();

export function setExCommands(map: Map<string, () => void>): void {
    registryExCommands = map;
    applyExCommands();
}

function applyExCommands(): void {
    if (!vimApi) return; // loadVim applies the stored map when the chunk lands
    for (const [name, run] of registryExCommands) {
        try {
            vimApi.defineEx(name, name, () => run());
        } catch (err) {
            console.warn("editor pane: ex command unavailable:", name, err);
        }
    }
}

async function loadVim(): Promise<VimLib> {
    if (!vimLib) vimLib = await import("monaco-vim");
    if (!exCommandsDefined) {
        // VimMode (= CMAdapter) carries the Vim API on a static the shipped
        // types don't describe — hence the cast. defineEx(name, prefix, fn)
        // requires prefix to be a literal prefix of name, so :qa pairs with
        // "qall", not "quitall".
        const vim = (vimLib.VimMode as unknown as {Vim: VimApi}).Vim;
        vimApi = vim;
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
        // :cq — vim's quit-with-error. In an `re` takeover this is the
        // abort signal (git commit reads the nonzero exit); no dirty
        // guard, exactly like vim.
        vim.defineEx("cquit", "cq", (cm) => paneOf(cm)?.exAbort());
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
            // gt — go to the thread under the cursor. It sits with gd/gr
            // because it IS that verb: jump to the thing attached to this
            // symbol. It moved here from ,t when the context leader took
            // over as the door to the thread LIST, which is the one that
            // wants a leader (it's a workspace-wide surface, not a motion).
            vim.defineAction("rookThread", (cm) => paneOf(cm)?.openThreadAtCursor());
            vim.mapCommand("gt", "action", "rookThread", {}, {context: "normal"});
            // visual too: gt CREATES when nothing covers the cursor, and a
            // range comment starts life as a visual selection
            vim.mapCommand("gt", "action", "rookThread", {}, {context: "visual"});
            // A thread buffer's verbs are ex commands, not chords: they read
            // as what they do, need no keymap layer inside the buffer, and
            // route per-pane through the same paneByEditor map :w uses.
            // (:ThreadNote / :ThreadAsk arrive through the registry bridge.)
            vim.defineEx("resolve", "res", (cm) => void paneOf(cm)?.threadSetState(true));
            vim.defineEx("reopen", "reo", (cm) => void paneOf(cm)?.threadSetState(false));
            vim.defineEx("source", "sou", (cm) => paneOf(cm)?.threadGoToSource());
            vim.mapCommand("K", "action", "rookHover", {}, {context: "normal"});
            // ⌃O/⌃I — the workbench jumplist (chrome's, at the openFile
            // seam), overriding monaco-vim's single-buffer walk: rook's
            // jumps cross files, so the list must live above the pane.
            vim.defineAction("rookJumpBack", (cm) => paneOf(cm)?.jump("back"));
            vim.defineAction("rookJumpForward", (cm) => paneOf(cm)?.jump("forward"));
            vim.mapCommand("<C-o>", "action", "rookJumpBack", {}, {context: "normal"});
            vim.mapCommand("<C-i>", "action", "rookJumpForward", {}, {context: "normal"});
            // ]c/[c — vim's change-hunk motions, onto the git gutter
            vim.defineAction("rookNextHunk", (cm) => paneOf(cm)?.jumpHunk(1));
            vim.defineAction("rookPrevHunk", (cm) => paneOf(cm)?.jumpHunk(-1));
            vim.mapCommand("]c", "action", "rookNextHunk", {}, {context: "normal"});
            vim.mapCommand("[c", "action", "rookPrevHunk", {}, {context: "normal"});
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
        // :set wrap — soft wrap, window-local, exactly as vim scopes it.
        //
        // A pane IS a window here, so the local scope is the pane and the
        // global one is the default a newly-opened pane starts from. `:set`
        // with no scope calls this twice, global then local, which is vim's
        // own semantics: the pane you typed in changes now, and the panes you
        // open later inherit it.
        try {
            vim.defineOption("wrap", undefined, "boolean", [], (value, cm) => {
                const pane = cm ? paneOf(cm) : undefined;
                if (value === undefined) return pane ? pane.getWrap() : defaultWrap;
                if (!cm) defaultWrap = !!value;
                else pane?.setWrap(!!value);
                return undefined;
            });
        } catch (err) {
            console.warn("editor pane: :set wrap unavailable:", err);
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
        // the registry map may have arrived before the vim chunk did
        applyExCommands();
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
    /** CodeMirror's option registry, which monaco-vim inherits wholesale and
     *  its types omit. The callback is BOTH getter and setter: value===undefined
     *  is a read, and cm===undefined means the global scope rather than one
     *  buffer's. `:set`/`:setlocal` already parse no-prefix, `?` and `=` on top
     *  of it, so defining an option is all that stands between us and the
     *  whole family of spellings. */
    defineOption(
        name: string,
        defaultValue: unknown,
        type: "boolean" | "string" | "number",
        aliases?: string[],
        callback?: (value: unknown, cm?: ExCm) => unknown,
    ): void;
    getRegisterController(): object;
    /** monaco-vim's VimMode IS the CodeMirror adapter (its keymap module
     *  default-exports CodeMirror), so the pane's own `vim` handle is the `cm`
     *  this wants. Optional because a monaco-vim bump could drop it. */
    exitVisualMode?(cm: unknown, moveHead?: boolean): void;
}

/** The Vim singleton, captured when the lazy chunk loads. loadVim() reaches
 *  it to register ex commands; the panes need it too, for the one thing that
 *  isn't a binding — putting an editor back into NORMAL after a range verb. */
let vimApi: VimApi | null = null;

/** 'wrap' at global scope: what a pane opens with. Off, like vim and like
 *  Monaco — code has columns and a wrapped line hides that it is long. The
 *  thread buffer overrides it for itself; prose has no columns to
 *  preserve. */
let defaultWrap = false;

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

/** The narrow door between the editor island and the thread panel (chrome).
 *  Signals out (marker click, change), calls in (reveal/clear). */
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
    /** gt's chrome twin — go to the thread under the cursor, or CREATE one
     *  anchored there when none covers it. False means there was nothing to
     *  act on (no model yet), so chrome can say so. */
    openThread(): boolean;
    onMarkerClick(cb: (line: number, side: Side, ids: number[]) => void): () => void;
    onChange(cb: () => void): () => void;
}

export interface EditorPaneOpts {
    workspace: string;
    kind: "review" | "file" | "thread";
    /** file mode: the repo-top-relative path to view */
    path?: string;
    /** thread mode: which thread this buffer renders */
    thread?: {id: number};
    /** a thread buffer wants its source shown — chrome routes through the
     *  openFile ladder so ⌃O comes back here */
    onOpenThreadSource?: (path: string, line: number) => void;
    /** gt — open (or just-created) thread as a buffer */
    onOpenThread?: (threadId: number) => void;
    /** what the git gutter diffs against: undefined = HEAD; "branch" or an
     *  explicit ref when a review is open (chrome knows, the pane asks) */
    gutterBase?: () => string | undefined;
    /** the active review root, if one is open — a gt-created thread carries
     *  it so the host can auto-link (leaf in-hunk, parent elsewhere) */
    reviewTask?: () => number | undefined;
    /** the terminal's font — the pane should read like the rest of rook */
    font: {family: string; size: number};
    /** surface a failure where the user is looking (titlebar flash) */
    onFlash: (msg: string) => void;
    /** the × button; the caller routes it to closeActive() */
    onClose: () => void;
    /** :cq — abort. Only an `re` takeover pane sets this (the shell gets a
     *  nonzero exit); elsewhere :cq flashes and does nothing. */
    onAbort?: () => void;
    /** :qa's blast radius — the editor panes sharing this pane's PLACE
     *  (chrome answers with the pane's window). Vim: :qa quits ONE vim
     *  instance, not every vim on the machine; absent, it's just this pane. */
    cohort?: () => EditorPane[];
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

/** The imperative twin of Kbd.svelte: the drawer headers are built outside
 *  Svelte, so they need their own keycap. Static strings only — this writes
 *  innerHTML. */
function keyHints(pairs: [string, string][]): string {
    return pairs
        .map(([k, label]) => `<kbd class="editor-key">${k}</kbd>&nbsp;${label}`)
        .join('<span class="editor-hint-sep">·</span>');
}

/** How stale a review may be before a re-focus refetches it. */
const STALE_MS = 2000;

/** A thread buffer is prose too, but a NAVIGABLE one — it keeps line numbers
 *  so vim motions have coordinates to land on, and the cursor line so you can
 *  see where you are while reading. */
const THREAD_OPTS = {
    lineNumbers: "on",
    glyphMargin: false,
    folding: true, // a long conversation folds by ## heading
    wordWrap: "on",
    overviewRulerLanes: 0,
    padding: {top: 8, bottom: 8},
} as const satisfies monacoTypes.editor.IEditorOptions;

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

    // ---- file-mode editing (` e only) ----
    /** the monaco host (fills the body under the head); vimBar sits below */
    private mount: HTMLElement;
    private vimBar: HTMLElement | null = null;
    private vim: VimAdapter | null = null;
    /** the thread this buffer is showing — the ex verbs act on it */
    private threadShown: ThreadInfo | null = null;
    /** thread mode: the rendered prefix from the last load/save — the
     *  read-only history through the scissors line; below it is the tail */
    private threadPrefix = "";
    /** thread mode: the full server-side doc (prefix + stored draft).
     *  dirty means "the buffer differs from this". */
    private threadServerDoc = "";
    private threadResolved = false;
    /** editable iff the file loaded whole — truncated/binary stays read-only */
    private editable = false;
    /** 'wrap', window-local. Seeded from the global default at construction,
     *  then owned by this pane — `:set wrap` here must not reach across the
     *  split to the file you are reading beside it. */
    private wrap = defaultWrap;
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

    /** every thread in the workspace — bands slice per (path, side) */
    private threadsAll: ThreadInfo[] = [];
    private bands: ThreadBand[] = [];

    /** the git gutter (file mode): stripes vs the base, and the hunk list
     *  ]c/[c walk. One decorations collection, replaced wholesale. */
    private gutterDecs: monacoTypes.editor.IEditorDecorationsCollection | null = null;
    private gutterHunks: GutterHunk[] = [];

    // seam subscribers (chrome side)
    private markerCbs: ((line: number, side: Side, ids: number[]) => void)[] = [];
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
        head.append(
            this.btn("⟳", "refresh", () => {
                if (opts.kind === "file") void this.loadFile();
                else if (opts.kind === "thread") void this.loadThread();
                else void this.refresh();
            }),
        );
        head.append(this.btn("×", "close pane", () => this.requestClose()));
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
        // the mode line + `:` prompt. A thread buffer needs it as much as a
        // file does — it's where :w lands, and it's the signal that this
        // really is a buffer rather than a form that happens to look like
        // one. The node is created here (monaco-vim will hold it) but NOT
        // parked under the editor: the global status bar adopts the focused
        // pane's node (vimbar.svelte.ts) — one command line, vim's own model.
        if (opts.kind === "file" || opts.kind === "thread") {
            this.vimBar = document.createElement("div");
            this.vimBar.className = "editor-vim";
        }
        this.el.append(head, this.body);
        void this.load();
    }

    get title(): string {
        if (this.opts.kind === "thread") {
            const name = `#${this.opts.thread?.id ?? ""}`;
            return this.dirty ? `● ${name}` : name;
        }
        if (this.opts.kind === "file") {
            const p = this.opts.path ?? "";
            const name = p.slice(p.lastIndexOf("/") + 1) || "[No Name]";
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
        else if (this.opts.kind === "file") {
            void this.refetchThreads();
            void this.refreshGutter(); // the tree may have moved underneath
        }
    }

    /** Honor a focus() that landed before the editor existed — unless the
     *  keyboard has moved on since.
     *
     *  The latch is asynchronous by nature: it is set when the manager
     *  focuses a pane whose Monaco is still loading, and applied at the end
     *  of the load, after a fetch and attachVim. That is long enough for the
     *  user to have gone somewhere else. Opening a thread and clicking
     *  straight back into the code does it — the thread's text appears a few
     *  ms before the latch resolves, so the click lands first and the latch
     *  then yanks the caret back out of the source buffer.
     *
     *  The manager owns focus and records it as .focused on the pane's cell,
     *  updated from a CAPTURE-phase mousedown — so by the time any click has
     *  moved the keyboard, the class already says so. Honor the latch only
     *  while this pane is still the one the manager means. */
    private applyPendingFocus(): void {
        if (!this.wantFocus) return;
        const ed = this.diffEditor ?? this.editor;
        if (!ed) return;
        this.wantFocus = false;
        const cell = this.el.closest(".pane");
        // No cell means the pane isn't mounted in a window yet (the side-pane
        // tenants), where nothing competes for focus — fail open and focus.
        if (cell && !cell.classList.contains("focused")) return;
        // The furniture isn't a pane, so the cell still reads focused while
        // the keyboard sits in the tree (`re .` lands there, netrw-style) —
        // the latch must not yank it out of a side pane either.
        if (document.activeElement?.closest?.(".side-pane")) return;
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
        vimbar.retract(this.vimBar); // free the status bar's command line
        if (this._seam) this.opts.onDispose?.(this._seam);
        for (const b of this.bands) b.dispose();
        this.changeSub?.dispose();
        this.vim?.dispose();
        if (this.editor) paneByEditor.delete(this.editor);
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
            openThread: () => this.openThreadAtCursor(),
            onMarkerClick: (cb) => this.sub(this.markerCbs, cb),
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
        // the status bar's command line follows editor focus — a review diff
        // has no vim node, so focusing one clears the slot instead of leaving
        // another pane's mode indicator lying about where the keyboard is
        vimbar.publish(this.vimBar);
        // seed the bar's Ln/Col with where this pane's cursor already is —
        // the change listener below only speaks on movement
        const pos = this.editor?.getPosition();
        if (pos) vimbar.setPos(this.vimBar, {ln: pos.lineNumber, col: pos.column});
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
        if (this.opts.kind === "thread") {
            await this.loadThread();
            return;
        }
        this.showStatus(this.opts.kind === "file" ? "reading file…" : "fetching changes…");
        await (this.opts.kind === "file" ? this.loadFile() : this.refresh());
    }

    /** A thread as an EDITABLE document (host threaddoc.go).
     *
     *  Deliberately a BUFFER and not a view zone: a view zone occupies screen
     *  rows without occupying buffer lines, so j/k, ⌃D, zz and relative
     *  numbers all stop agreeing with the document — and it could never be a
     *  jump target. Here the conversation scrolls, searches and yanks like
     *  anything else, and ⌃O walks back to the code.
     *
     *  The content is the host's projection: history through the scissors
     *  line (read-only by CONTRACT — the save's prefix check enforces it, no
     *  region locking here), then the tail, which is yours. A watch-stream
     *  reload re-fetches and splices any unsaved local tail under the new
     *  prefix, so an agent reply can land mid-sentence without conflict. */
    private async loadThread(): Promise<void> {
        const m = this.monaco;
        const id = this.opts.thread?.id;
        if (!m || id == null) return;
        if (!this.editor?.getModel()) this.showStatus("reading thread…");
        let doc: import("../hostapi").ThreadDoc;
        let t: ThreadInfo | undefined;
        try {
            // the doc renders the buffer; the thread row still feeds the head
            // (anchor mapping is chrome, never the document — the prefix must
            // not rot as the file underneath moves)
            [doc, t] = await Promise.all([
                this.api.threadDoc(id),
                this.api.threads(this.opts.workspace).then((ts) => ts.find((x) => x.id === id)),
            ]);
        } catch (err) {
            if (String(err).includes(" 404 ")) {
                this.showStatus(`thread #${id} is gone`);
            } else {
                this.fail("thread", err);
            }
            return;
        }
        if (this.disposed) return;
        const draft = doc.draft ?? "";
        const prefix = doc.content.slice(0, doc.content.length - draft.length);
        const grew = prefix.length > this.threadPrefix.length;
        if (t) this.threadShown = t;
        this.threadResolved = doc.resolved === true;
        this.clearStatus();
        const existing = this.editor?.getModel();
        if (existing && !existing.isDisposed()) {
            // Splice, don't clobber: an unsaved tail survives the reload by
            // riding under the fresh prefix. A clean buffer just takes the
            // server doc (which already carries the stored draft).
            const next = this.dirty ? prefix + this.localTail(existing.getValue()) : doc.content;
            if (existing.getValue() !== next) {
                existing.setValue(next);
                if (this.dirty) this.opts.onFlash("thread updated — draft carried forward");
            }
            // A grown PREFIX means someone spoke — show the newest word; in a
            // short split it would otherwise land below the fold.
            if (grew) this.editor?.revealLine(existing.getLineCount());
        } else {
            const model = m.editor.createModel(
                doc.content,
                "markdown",
                m.Uri.parse(`rook-thread://${++uriSeq}/${id}`),
            );
            this.models.push(model);
            paneByModel.set(model, this);
            this.ensureEditor().setModel(model);
            this.changeSub?.dispose();
            this.changeSub = model.onDidChangeContent(() =>
                this.setDirty(model.getValue() !== this.threadServerDoc),
            );
            // land where you write: the line below the scissors (end of the
            // buffer). Reading history is scrolling up, replying is typing —
            // the second is the one worth a saved motion.
            if (!this.threadResolved) {
                const ed = this.ensureEditor();
                const last = model.getLineCount();
                ed.setPosition({lineNumber: last, column: model.getLineMaxColumn(last)});
                ed.revealLine(last);
            }
        }
        this.threadPrefix = prefix;
        this.threadServerDoc = doc.content;
        this.editable = !this.threadResolved;
        const ed = this.ensureEditor();
        ed.updateOptions({readOnly: this.threadResolved, ...THREAD_OPTS});
        if (t) {
            this.pathEl.textContent = `thread #${t.id} · ${t.path}:${
                t.currentStart === t.currentEnd
                    ? t.currentStart
                    : `${t.currentStart}-${t.currentEnd}`
            }${t.outdated ? " · outdated" : ""}`;
        }
        this.noteEl.innerHTML = keyHints(
            this.threadResolved
                ? [
                      [":reopen", "reopen"],
                      [":q", "close"],
                  ]
                : [
                      [":w", "save draft"],
                      [":ThreadAsk", "ask"],
                      [":ThreadNote", "note"],
                      [":resolve", "done"],
                  ],
        );
        this.setDirty((this.editor?.getModel()?.getValue() ?? "") !== this.threadServerDoc);
        this.fit();
        await this.attachVim(ed);
        // Through the LATCH, never unconditionally: reloadThreads() routes
        // every watch-stream event back through here, and an unconditional
        // focus meant any thread changing anywhere in the workspace yanked
        // the keyboard out of whatever you were typing in.
        this.applyPendingFocus();
    }

    /** The buffer's tail — everything below the last-known prefix. Falls back
     *  to scanning for the scissors when the head was hand-edited (the save
     *  will 409 there anyway; this only decides what to carry forward). */
    private localTail(value: string): string {
        if (this.threadPrefix && value.startsWith(this.threadPrefix)) {
            return value.slice(this.threadPrefix.length);
        }
        const i = value.indexOf("\n-- ✂ --");
        if (i === -1) return "";
        const nl = value.indexOf("\n", i + 1);
        return nl === -1 ? "" : value.slice(nl + 1);
    }

    /** :w on a thread — POST the whole buffer; the host prefix-checks and
     *  stores the tail as the draft. Silent on success (a draft is private
     *  until :ThreadNote / :ThreadAsk crystallize it). A 409 means history
     *  moved underneath: splice the local tail under the fresh prefix and
     *  stay dirty — nothing is lost, and the next :w lands. */
    private async saveThreadDoc(): Promise<boolean> {
        const model = this.editor?.getModel();
        const id = this.opts.thread?.id;
        if (!model || id == null) return true;
        if (this.threadResolved) return true; // read-only — nothing to save
        if (!this.dirty) return true;
        if (this.saving) return false;
        this.saving = true;
        try {
            const content = model.getValue();
            const res = await this.api.saveThreadDoc(id, content);
            if (this.disposed) return true;
            if (res.ok) {
                this.threadServerDoc = content;
                this.threadPrefix = content.slice(
                    0,
                    content.length - this.localTail(content).length,
                );
                this.setDirty(false);
                return true;
            }
            const draft = res.draft ?? "";
            const tail = this.localTail(content);
            this.threadPrefix = res.content.slice(0, res.content.length - draft.length);
            this.threadServerDoc = res.content;
            model.setValue(this.threadPrefix + tail);
            this.opts.onFlash("thread updated underneath — draft carried forward, :w again");
            return false;
        } catch (err) {
            const msg = String(err);
            this.opts.onFlash(
                msg.includes(" 404 ")
                    ? "thread buffers need a newer rook-host — relaunch rook"
                    : `save failed: ${msg}`,
            );
            return false;
        } finally {
            this.saving = false;
        }
    }

    /** :ThreadNote / :ThreadAsk — save first (the tail IS the message), then
     *  crystallize it as a comment. ask also nudges the responder and closes
     *  the pane: the question is with the agent now, and an open buffer
     *  would say otherwise. */
    async threadNote(): Promise<void> {
        const id = this.opts.thread?.id;
        if (this.opts.kind !== "thread" || id == null) return;
        if (!(await this.saveThreadDoc())) return;
        try {
            await this.api.threadNote(id);
            this.opts.onFlash(`noted on #${id}`);
        } catch (err) {
            this.verbFail("note", err);
        }
    }

    async threadAsk(): Promise<void> {
        const id = this.opts.thread?.id;
        if (this.opts.kind !== "thread" || id == null) return;
        if (!(await this.saveThreadDoc())) return;
        try {
            const res = await this.api.threadAsk(id);
            this.opts.onFlash(
                res.mode === "typed"
                    ? "asked — nudged the live claude session"
                    : "asked — spawned a responder",
            );
            this.opts.onClose();
        } catch (err) {
            this.verbFail("ask", err);
        }
    }

    private verbFail(what: string, err: unknown): void {
        const msg = String(err);
        this.opts.onFlash(
            msg.includes(" 400 ")
                ? "nothing to send — write below the scissors first"
                : msg.includes(" 404 ")
                  ? "thread buffers need a newer rook-host — relaunch rook"
                  : `${what} failed: ${msg}`,
        );
    }

    /** :resolve / :reopen — act, then close: the thread is off your plate,
     *  and leaving its buffer open would say otherwise. */
    async threadSetState(resolved: boolean): Promise<void> {
        const t = this.threadShown;
        if (!t) return;
        try {
            if (resolved) await this.api.threadResolve(t.id);
            else await this.api.threadReopen(t.id);
            this.opts.onFlash(resolved ? `resolved #${t.id}` : `reopened #${t.id}`);
            this.opts.onClose();
        } catch (err) {
            this.opts.onFlash(`${resolved ? "resolve" : "reopen"} failed: ${String(err)}`);
        }
    }

    /** The source this thread annotates — chrome opens it through the
     *  openFile ladder, so ⌃O returns to the thread. */
    threadGoToSource(): void {
        const t = this.threadShown;
        if (t) this.opts.onOpenThreadSource?.(t.path, t.currentStart);
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
        if (!path) {
            // vim's empty buffer — `re` with nothing to open. Editable,
            // unnamed; :w flashes for a name, ⌃P retargets this pane onto a
            // real file (the openFile ladder finds any file pane, this one
            // included).
            this.editable = true;
            this.pathEl.textContent = "[No Name]";
            this.clearStatus();
            this.disposeModels();
            const model = m.editor.createModel("", undefined, this.uri(""));
            this.models.push(model);
            paneByModel.set(model, this);
            const ed = this.ensureEditor();
            ed.setModel(model);
            ed.updateOptions({readOnly: false, wordWrap: this.wrap ? "on" : "off"});
            this.savedVersionId = model.getAlternativeVersionId();
            this.setDirty(false);
            this.changeSub?.dispose();
            this.changeSub = model.onDidChangeContent(() =>
                this.setDirty(model.getAlternativeVersionId() !== this.savedVersionId),
            );
            this.fit();
            // vim BEFORE the pending focus: initVimMode rewires the editor's
            // input handling, and doing that to an already-focused editor
            // drops focus to body when the vim chunk is cache-fast — the
            // keyboard then types into whatever held focus before, which in
            // a second takeover is the FIRST editor's vim (:q closed it).
            await this.attachVim(ed);
            this.applyPendingFocus();
            return;
        }
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
            // Restated on every load rather than set once, because a file
            // pane retargets in place (:e) and outlives any one file. Monaco
            // does retain updateOptions across setModel, so this is belt and
            // braces — but it makes the pane's own field the thing that
            // decides, instead of whatever the editor was last told.
            ed.updateOptions({
                readOnly: !this.editable,
                wordWrap: this.wrap ? "on" : "off",
            });
            this.savedVersionId = model.getAlternativeVersionId();
            this.setDirty(false);
            this.changeSub?.dispose();
            this.changeSub = model.onDidChangeContent(() =>
                this.setDirty(model.getAlternativeVersionId() !== this.savedVersionId),
            );
            this.fit();
            this.rebuildBands();
            // vim rides every file editor (motions work read-only too); the
            // :w saver is registered only when the buffer is editable. It
            // attaches BEFORE the pending focus/position: initVimMode
            // rewires the editor's input handling, and doing that to an
            // already-focused editor drops focus to body when the vim
            // chunk is cache-fast — the keyboard then types into whatever
            // held focus before, which in a second takeover is the FIRST
            // editor's vim (its :q closed the wrong editor).
            await this.attachVim(ed);
            this.applyPendingFocus();
            this.applyPendingPos();
            void this.refreshGutter(); // never gates the load
        } catch (err) {
            this.fail(`reading ${path}`, err);
        }
    }

    /** The git gutter: stripes in the line-decorations margin — added green,
     *  modified accent, a marker on each deletion boundary — so review
     *  reading needs no special diff mode. Base is HEAD unless chrome says a
     *  review is open (opts.gutterBase). Fails open: an older daemon has no
     *  gutter route, and a bare margin beats a broken pane. */
    private async refreshGutter(): Promise<void> {
        if (this.opts.kind !== "file" || !this.opts.path || !this.monaco) return;
        const path = this.opts.path;
        let hunks: GutterHunk[];
        try {
            hunks = (await this.api.gutter(this.opts.workspace, path, this.opts.gutterBase?.()))
                .hunks;
        } catch (err) {
            console.warn("editor pane: gutter unavailable:", err);
            return;
        }
        // the pane may have retargeted (:e) while the fetch was in flight
        if (this.disposed || this.opts.path !== path) return;
        const ed = this.editor;
        const m = this.monaco;
        if (!ed?.getModel()) return;
        this.gutterHunks = hunks;
        this.gutterDecs ??= ed.createDecorationsCollection();
        this.gutterDecs.set(
            hunks.map((h) => ({
                range: new m.Range(h.start, 1, h.end, 1),
                options: {
                    isWholeLine: true,
                    linesDecorationsClassName:
                        h.kind === "added"
                            ? "rook-gutter-add"
                            : h.kind === "deleted"
                              ? "rook-gutter-del"
                              : "rook-gutter-mod",
                },
            })),
        );
    }

    /** ]c / [c — jump to the next/previous change stripe. No wrap, like vim. */
    jumpHunk(dir: 1 | -1): void {
        if (this.opts.kind !== "file") return;
        const ed = this.editor;
        const pos = ed?.getPosition();
        if (!ed || !pos) return;
        const starts = this.gutterHunks.map((h) => h.start).sort((a, b) => a - b);
        const line =
            dir === 1
                ? starts.find((s) => s > pos.lineNumber)
                : [...starts].reverse().find((s) => s < pos.lineNumber);
        if (line == null) {
            this.opts.onFlash(dir === 1 ? "no change below" : "no change above");
            return;
        }
        ed.setPosition({lineNumber: line, column: 1});
        ed.revealLineInCenterIfOutsideViewport(line);
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
        // rook's own status bar class: colored mode badge in the global
        // status bar, `:`/`/` prompts in a modal (vimstatus.ts)
        this.vim = lib.initVimMode(
            ed,
            this.vimBar,
            RookVimStatusBar as unknown as Parameters<VimLib["initVimMode"]>[2],
        );
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
        if (this.opts.kind === "thread") {
            // silent on success — :w stores the draft, wakes no agent; the
            // history only grows on :ThreadNote / :ThreadAsk
            await this.doSave();
            return;
        }
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
        if (this.opts.kind === "thread") return this.saveThreadDoc();
        if (this.opts.kind === "file" && !this.opts.path) {
            // vim: E32 No file name. ⌃P retargets this pane onto a real file.
            this.opts.onFlash("no file name — ⌃P opens one into this pane");
            return false;
        }
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
            void this.refreshGutter(); // the tree just changed under the base
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

    /** :q — close this pane; refuse (vim-style) on unsaved edits. A thread
     *  buffer that never grew content — gt-created, nothing said, nothing
     *  saved — deletes itself on the way out: the abort path. The host
     *  guards (409 on anything with comments or a stored draft), so a
     *  mistaken fire loses nothing. */
    exQuit(force: boolean): void {
        if (!force && this.dirty) {
            this.opts.onFlash("unsaved changes — :w to save, or :q! to discard");
            return;
        }
        const id = this.opts.thread?.id;
        if (
            this.opts.kind === "thread" &&
            id != null &&
            !this.threadResolved &&
            (this.threadShown?.comments.length ?? 0) === 0
        ) {
            void this.api.deleteThread(id).catch(() => {});
        }
        this.opts.onClose();
    }

    /** :cq — vim's quit-with-error, no dirty guard. The takeover's abort
     *  path; a pane the shell isn't waiting on has nothing to signal. */
    exAbort(): void {
        if (this.opts.onAbort) this.opts.onAbort();
        else this.opts.onFlash(":cq aborts an `re` edit — this pane wasn't opened by one");
    }

    /** :wq / :x — save, then close only if the write succeeded. */
    async exSaveQuit(): Promise<void> {
        if (await this.doSave()) this.opts.onClose();
    }

    /** :qa — close every editor pane in THIS pane's place (its window),
     *  refusing if any holds unsaved edits. NOT app-global: another
     *  window's editor is another vim, and vim's :qa never reaches across
     *  processes. Same-class access lets this read siblings' state. */
    exQuitAll(force: boolean): void {
        const panes = this.opts.cohort?.() ?? [this];
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
        const panes = this.opts.cohort?.() ?? [this];
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
    /** Hover = the thread PREVIEW plus whatever the language server says.
     *
     *  contents is an array of markdown blocks that Monaco stacks with
     *  separators, so the two sources compose instead of competing — which is
     *  the whole reason preview lives here rather than in a view zone. Threads
     *  come first: they're the rarer, more surprising thing on a line, and an
     *  LSP hover can be long enough to push them out of sight.
     *
     *  This is also why rook does NOT put threads on the LSP server it exposes
     *  to nvim (see the comments-lsp spec): clients merge diagnostics across
     *  servers but arbitrate hover, so only the editor that owns BOTH sources
     *  can do this. */
    async hoverAt(line: number, col: number): Promise<monacoTypes.languages.Hover | null> {
        const contents: {value: string}[] = [];
        const path = this.currentPath();

        // Threads work in the review diff too, where they matter most — the
        // LSP half stays file-only, since a diff pane has no single buffer for
        // a server to answer about.
        if (path) {
            const side = this.bands.find((b) => b.editor.hasTextFocus())?.side ?? "modified";
            for (const t of threadsCovering(this.threadsAll, path, side, line)) {
                contents.push({value: hoverPreview(t, Date.now())});
            }
        }

        if (this.opts.kind === "file" && this.opts.path) {
            try {
                const res = await this.api.lspHover(
                    this.opts.workspace,
                    this.opts.path,
                    line,
                    col,
                    this.lspText(),
                );
                if (res.contents) contents.push({value: res.contents});
            } catch {
                // hover is ambient — never flash from it, and a dead server
                // must not swallow the thread preview beside it
            }
        }
        return contents.length > 0 ? {contents} : null;
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
    }

    private currentPath(): string | undefined {
        return this.opts.kind === "file" ? this.opts.path : this.files[this.idx]?.path;
    }

    /** Re-read whatever this pane shows about threads — the fan-out target for
     *  the thread-watch stream. A thread buffer re-renders its markdown; every
     *  other kind refetches the anchors its gutter draws. */
    async reloadThreads(): Promise<void> {
        if (this.opts.kind === "thread") await this.loadThread();
        else await this.refetchThreads();
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

    /** 'wrap' for this pane. Applied to whatever is showing right now — a
     *  thread buffer included, so `:set nowrap` works while reading one even
     *  though prose opens wrapped. */
    setWrap(on: boolean): void {
        this.wrap = on;
        const opts = {wordWrap: on ? ("on" as const) : ("off" as const)};
        this.editor?.updateOptions(opts);
        this.diffEditor?.updateOptions(opts);
    }

    getWrap(): boolean {
        return this.wrap;
    }

    /** gt — DUAL, like gd: go to the thread under the cursor, or create one.
     *
     *  A covering thread opens (multiple threads can anchor to one region;
     *  take the top of the stack — most-demanding state, exactly what the
     *  gutter glyph is already showing). No covering thread → create one
     *  anchored at the cursor/selection and open its buffer, cursor below
     *  the scissors. One gesture, one model — this replaced ,c/,?/:reply. */
    openThreadAtCursor(): boolean {
        const band =
            this.bands.find((b) => b.editor.hasTextFocus()) ??
            this.bands.find((b) => b.side === "modified") ??
            this.bands[0];
        const path = this.currentPath();
        const line = band?.editor.getPosition()?.lineNumber;
        if (!band || !path || !line) return false;
        const pick = pickFromStack(threadsCovering(this.threadsAll, path, band.side, line));
        if (pick) {
            this.opts.onOpenThread?.(pick.thread.id);
            return true;
        }
        void this.createThreadAt(band, path);
        return true;
    }

    /** The create half of gt: anchor captured NOW (what the cursor/selection
     *  is on, exactly as composing did), an empty thread minted, its buffer
     *  opened. The anchor rule stays painted so the buffer names a range you
     *  can still see. */
    private async createThreadAt(band: ThreadBand, path: string): Promise<void> {
        const sel = band.editor.getSelection();
        if (!sel) return;
        let end = sel.endLineNumber;
        // a full-line drag ends at column 1 of the NEXT line — not a line
        if (end > sel.startLineNumber && sel.endColumn === 1) end--;
        for (const b of this.bands) b.clearHighlight();
        band.highlight(sel.startLineNumber, end);
        this.exitVisual();
        // Collapse to the start of the range, as vim does after an operator.
        // exitVisualMode leaves vim's idea of the mode right but Monaco still
        // PAINTS the old selection, which competes with the anchor rule for
        // saying what the thread is about.
        band.editor.setPosition({lineNumber: sel.startLineNumber, column: 1});
        try {
            const t = await this.api.createThread(this.opts.workspace, {
                path,
                startLine: sel.startLineNumber,
                endLine: end,
                side: band.side,
                base: band.side === "original" ? this.base : undefined,
                body: "", // the first words arrive as the buffer's tail
                rookTaskId: this.opts.reviewTask?.(),
            });
            if (this.disposed) return;
            this.opts.onOpenThread?.(t.id);
        } catch (err) {
            const msg = String(err);
            this.opts.onFlash(
                msg.includes(" 400 ") && msg.toLowerCase().includes("body")
                    ? "thread buffers need a newer rook-host — relaunch rook"
                    : `thread failed: ${msg}`,
            );
        }
    }

    /** Put this editor back into NORMAL after a range verb consumed the
     *  selection — what vim does after any operator.
     *
     *  Not cosmetic. Left in VISUAL, the NEXT motion extends the stale
     *  selection instead of moving the cursor, so the following comment
     *  silently anchors to the previous one's range. The e2e caught that;
     *  reasoning about it had not. */
    private exitVisual(): void {
        try {
            if (this.vim) vimApi?.exitVisualMode?.(this.vim, false);
        } catch (err) {
            console.warn("editor pane: could not leave visual mode:", err);
        }
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
            // Monaco defaults this ON since ~0.45: the enclosing function
            // pins itself over the top lines. That row lies about what's
            // under the cursor for vim jumps (H, line numbers) — off.
            stickyScroll: {enabled: false},
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
            this.editor.onDidFocusEditorText(() => this.activate());
            // the status bar's Ln/Col — vimbar drops updates from any pane
            // that doesn't currently hold the slot
            this.editor.onDidChangeCursorPosition((e) =>
                vimbar.setPos(this.vimBar, {ln: e.position.lineNumber, col: e.position.column}),
            );
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
        return this.monaco!.Uri.parse(`rook://${++uriSeq}/${path}`);
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
