<!-- The app shell: screens (manager ⇄ workspace terminals), overlays, the
     command registry, the two-layer keybinding ladder, and the host polls.
     The terminal runtime is created here but lives outside Svelte — this
     component renders the container div once and never conditionally
     unmounts it (screen switches are the `hidden` attribute, i.e. CSS). -->
<script lang="ts">
    import {onMount, tick, untrack} from "svelte";
    import {Call} from "@wailsio/runtime";
    import type {HostAPI, IssueInfo, ThreadInfo} from "./hostapi";
    import {TermManager} from "./term/manager";
    // STATIC, not a lazy import: `:` in the tree has to raise the prompt in
    // the same task as the keypress. Awaiting a chunk — even a cached one —
    // lets the keys after the colon land on the listing instead, so typing
    // `:q` at speed opened the file under the cursor. vimstatus imports
    // nothing (no Monaco behind it), so this costs a few KB and no chunk.
    import {promptEx} from "./term/vimstatus";
    import type {AskRequest, EditRequest, PaneAt} from "./term/manager";
    import type {Edge, PaneRef} from "./term/layout";
    import {themeService} from "./theme/service";
    import {rgb} from "./theme/color";
    import type {Palette as ThemePalette} from "./theme/palette";
    import {encodePalette} from "./term/vt/framed";
    import {preloadRenderer} from "./term/vt/registry";
    import {Registry, type Command} from "./registry";
    import {buildContextMap, buildKeymap, CONTEXT_LEADER_KEY, parseLeader, sigOf} from "./keymap";
    import {app, type Mode} from "./state.svelte";
    import {shellQuote} from "./util";
    import StatusBar from "./StatusBar.svelte";
    import Titlebar from "./Titlebar.svelte";
    import Dashboard from "./Dashboard.svelte";
    import Home from "./Home.svelte";
    import Palette from "./Palette.svelte";
    import Picker from "./Picker.svelte";
    import Finder from "./Finder.svelte";
    import {filesSource, grepSource, threadsSource} from "./finderSources";
    import Inbox from "./Inbox.svelte";
    import SpawnModal from "./SpawnModal.svelte";
    import Settings from "./Settings.svelte";
    import SidePane from "./SidePane.svelte";
    import FileExplorer from "./FileExplorer.svelte";
    import {fly} from "svelte/transition";
    import QuickfixPanel from "./QuickfixPanel.svelte";
    import QuickActionModal from "./QuickActionModal.svelte";
    import {qf, qfStoreFor, setActiveQfWindow, pruneQf} from "./quickfix.svelte";
    import {chromeFor, pruneChrome} from "./winchrome.svelte";
    import {Jumplist} from "./jumplist";
    import ExploreModal from "./ExploreModal.svelte";
    import {makeExploreContext} from "./exploreContext";
    import {makeRefsContext, toRefHits} from "./refsContext";
    import {makeThreadsContext} from "./threadsContext";
    import {makeReviewContext} from "./reviewContext";
    import type {EditorSeam} from "./term/editor";

    interface Props {
        api: HostAPI;
        keybinds: Record<string, string | undefined>;
        /** the tmux-style prefix: a key ("`") or chord ("ctrl+b") */
        leader: string;
        /** the editor scope's own leader ([editor] leader, comma default) */
        editorLeader?: string;
        /** the editor scope's normal-mode bindings ([editor.keybinds.normal]) */
        editorKeybinds?: Record<string, string | undefined>;
        /** [commands] — ex-command aliases onto registry command ids */
        commandAliases?: Record<string, string | undefined>;
        /** the config font, for the Monaco pane and the terminal renderer */
        paneFont: {family: string; size: number};
    }
    let {
        api,
        keybinds,
        leader: leaderCfg,
        editorLeader: editorLeaderCfg,
        editorKeybinds = {},
        commandAliases = {},
        paneFont,
    }: Props = $props();
    // config-fixed: the leader reloads the page, which re-reads it
    // svelte-ignore state_referenced_locally
    const leader = parseLeader(leaderCfg);
    // svelte-ignore state_referenced_locally
    const keymap = buildKeymap(keybinds, leader.disp);
    // the context leader (vim's maplocalleader) — see keymap.ts
    // svelte-ignore state_referenced_locally
    const contextLeader = parseLeader(editorLeaderCfg || CONTEXT_LEADER_KEY);
    // svelte-ignore state_referenced_locally
    const contextMap = buildContextMap(editorKeybinds);
    /** the context leader armed; the next key dispatches CONTEXT_PREFIX.
     *  Plain let: nothing renders it yet (the pill is the IDE leader's). */
    let ctxArmed = false;

    let terminalsEl: HTMLElement;
    let home = $state<Home | null>(null);
    let fatal = $state("");
    // assigned once in onMount, before any interaction can read it
    let mgr: TermManager = $state() as unknown as TermManager;
    const registry = new Registry();

    let activeEditor = $state<EditorSeam | null>(null);
    // the active editor's kind rides alongside the seam so chrome can tell
    // review mode from file mode (the seam itself stays kind-agnostic)
    let activeEditorKind = $state<"review" | "file">("review");
    // focusing a terminal idles the panel; focusedSessionId is null when an
    // editor pane (Monaco) holds focus, so switching back onto a review pane
    // keeps its seam bound
    $effect(() => {
        if (app.focusedSessionId) activeEditor = null;
    });

    // Thread changes push; the panes refetch. ONE subscription for the whole
    // workspace, fanned out — a browser caps concurrent connections per
    // origin, so an EventSource per editor pane would starve the API itself.
    //
    // This is what makes an agent's reply appear. Before it, threads refetched
    // only when a pane regained focus, so you could ask a question, watch
    // claude answer in its own window, and rook would still show your comment
    // alone until you clicked back in.
    $effect(() => {
        const ws = app.workspace;
        if (!ws) return;
        void refreshThreads();
        return api.watchThreads(ws, () => {
            void refreshThreads();
            for (const p of editorPanes.values()) void p.reloadThreads();
        });
    });

    /** gt's palette twin — go to the thread under the cursor, or create one
     *  anchored there. The pane owns the whole gesture (editor.thread). */
    function goToThread(): void {
        if (mgr.focusedContent()?.type === "thread") {
            flash("already in a thread — :q closes it");
            return;
        }
        const seam = activeEditor;
        if (!seam) {
            flash("no editor focused");
            return;
        }
        if (!seam.openThread()) flash("nothing to anchor to here");
    }

    /** The pane the keyboard is in, iff it's a thread buffer — the target
     *  of thread.note / thread.ask (and so of :ThreadNote / :ThreadAsk via
     *  the ex bridge, though those also route per-pane). */
    function focusedThreadPane(): import("./term/editor").EditorPane | null {
        const c = mgr.focusedContent();
        if (c?.type !== "thread") return null;
        const at = mgr.findPane((x) => x === c);
        return at ? (editorPanes.get(at.leafId) ?? null) : null;
    }

    /** The pane the keyboard is in, iff it's an editor of any kind — the
     *  target of editor.comment. Wider than focusedThreadPane on purpose: a
     *  thread buffer is a document too, and commenting one is meaningful. */
    function focusedEditorPane(): import("./term/editor").EditorPane | null {
        const c = mgr.focusedContent();
        if (c?.type !== "file" && c?.type !== "thread") return null;
        const at = mgr.findPane((x) => x === c);
        return at ? (editorPanes.get(at.leafId) ?? null) : null;
    }

    /** A thread as a BUFFER, gd-shaped: the same ladder openFile walks.
     *    1. already displayed → reveal it
     *    2. an editor pane exists → retarget it IN PLACE (the pane gt was
     *       typed in, by construction the focused one) — the keyboard never
     *       moves, which is the entire focus story
     *    3. nothing to reuse (review diff, dirty buffer) → mint one window
     *  recordJump first, so ⌃O walks back to the code you came from. */
    async function openThreadBuffer(id: number): Promise<void> {
        // Yield first, always. Opening from the quick-action modal runs
        // closeQuickActions() right after this, which pulls focus back to the
        // strip — so a SYNCHRONOUS reveal lost the race while the retarget
        // path (async by nature) won it, and the same key did two different
        // things depending on whether the thread happened to be open already.
        await tick();
        const open = mgr.findPane((c) => c.type === "thread" && c.id === id);
        if (open) {
            mgr.revealPane(open);
            return;
        }
        recordJump();
        // The FOCUSED pane first — gd navigates the current window, and in a
        // two-file split "a file pane" is not necessarily the one gt was
        // typed in. Then any file pane, then any thread pane (a click from
        // the finder shouldn't steal a thread mid-read when a file pane sits
        // right there).
        const focused = mgr.focusedContent();
        const reusable =
            (focused && (focused.type === "file" || focused.type === "thread")
                ? mgr.findPane((c) => c === focused)
                : null) ??
            mgr.findPane((c) => c.type === "file") ??
            mgr.findPane((c) => c.type === "thread");
        if (reusable) {
            // was this the focused pane when the ask started? gt's pane is,
            // and it already holds the keyboard — revealing it AFTER the
            // async load would yank focus back from wherever the user moved
            // it mid-load. Reveal only the finder/list path, where the pane
            // may sit in another window and showing it is the whole point.
            const wasFocused = mgr.focusedContent() === reusable.content;
            const pane = editorPanes.get(reusable.leafId);
            if (pane && (await pane.setThread(id))) {
                mgr.retargetPane(reusable, {type: "thread", id});
                if (wasFocused) {
                    // The model swap drops DOM focus to <body> (Monaco tears
                    // the view down with the disposed model). Take it back —
                    // this is the pane gt was typed in — UNLESS the keyboard
                    // moved somewhere real while the doc loaded: revealing
                    // must never yank a caret out of a shell mid-thought.
                    const el = document.activeElement;
                    if (!el || el === document.body || pane.el.contains(el)) pane.focus();
                } else {
                    app.screen = "app";
                    await tick();
                    mgr.revealPane(reusable);
                }
                return;
            }
        }
        const {EditorPane} = await import("./term/editor");
        app.screen = "app";
        await tick();
        mgr.openPaneWindow({type: "thread", id}, (leafId) => {
            const pane = new EditorPane(api, {
                workspace: app.workspace,
                kind: "thread",
                thread: {id},
                font: paneFont,
                onFlash: flash,
                cohort: () => editorCohort(leafId),
                onClose: () => mgr.closePane(leafId),
                // same bookkeeping as a file window — this pane can be
                // retargeted onto a file later (⌃O, ⌃P), so it must announce
                // itself like one
                onActivate: (seam) => {
                    activeEditor = seam;
                    activeEditorKind = "file";
                    jumpPane = pane;
                },
                onDispose: (seam) => {
                    editorPanes.delete(leafId);
                    if (activeEditor === seam) activeEditor = null;
                    if (jumpPane === pane) jumpPane = null;
                },
                onOpenLocation: (p, line, col) => void openFile(p, {line, col}),
                onReferences: showReferences,
                onRecordJump: recordJump,
                onJump: jumpNav,
                onFindFile: () => {
                    scopeDir = undefined;
                    app.filePickerOpen = true;
                },
                onGrep: (seed) => {
                    grepSeed = seed ?? "";
                    scopeDir = undefined;
                    app.grepOpen = true;
                },
                onOpenThread: (tid) => void openThreadBuffer(tid),
                onOpenThreadSource: (path, line) => void openFile(path, {line, col: 1}),
                onThreadDone: () => jumpNav("back"),
                gutterBase: reviewGutterBase,
                reviewTask: () => app.reviewRoot?.id,
            });
            editorPanes.set(leafId, pane);
            return pane;
        });
    }

    // ==== mode: what surface owns the viewport, and its chrome defaults ====
    // Home wins; then a focused editor pane names the mode by its kind; else a
    // terminal holds focus. Derived, so it only actually changes on transition.
    const currentMode = $derived<Mode>(
        app.screen === "home" ? "home" : activeEditor ? activeEditorKind : "terminal",
    );
    $effect(() => {
        app.mode = currentMode;
    });

    // (re)load the review when its list is open and the workspace changes
    $effect(() => {
        void app.workspace;
        if (qf.listOpen && qf.context?.id === "review") void loadReview();
    });

    // Closing the quick-action modal hands the keyboard back to the quickfix
    // surface it acted ON — the hero if it's up (it refocuses itself), else
    // the open strip — never to whichever pane the leader happened to fire
    // from. Without this, esc out of the modal strands j/k.
    function closeQuickActions(): void {
        app.quickActionOpen = false;
        if (qf.detailOpen) return; // ReviewItem's own effect reclaims focus
        if (qf.listOpen) {
            app.focusZone = "bottom";
            document.getElementById("quickfix-list")?.focus();
            return;
        }
        focusBack();
    }

    // Closing the hero hands the keyboard back to the strip — esc out of a
    // hunk should land you on j/k, not in focus limbo (the hero held DOM
    // focus, so the zone read "terms" while it was up). The "o" editor action
    // also passes through here, but the editor's own focus lands later and
    // wins — which is what "take me to the editor" means.
    let heroWasOpen = false;
    $effect(() => {
        const open = qf.detailOpen;
        if (heroWasOpen && !open && qf.listOpen) app.focusZone = "bottom";
        heroWasOpen = open;
    });

    // resolved when the manager has attached every live session — opening a
    // workspace before that could double-create its window
    let initDone: Promise<void> = Promise.resolve();

    // ==== screens: home (mission control) ⇄ workspace terminals ====
    async function showWorkspace(name: string): Promise<void> {
        try {
            await initDone;
            app.screen = "app";
            // Flush the hidden attr: openWorkspace's activate() fits and
            // focuses, and both silently no-op on a display:none subtree.
            await tick();
            // a session-less workspace lands on its dashboard, ready to
            // open a window (` c) — switching mustn't force a shell in
            if (!mgr.openWorkspace(name)) app.dashVisible = true;
        } catch (err) {
            console.error("failed to open workspace", name, err);
            showHome();
            await tick(); // Home remounts before it can show the error
            home?.showError(`Couldn't open "${name}": ${err}`);
        }
    }

    /** The create doors (picker's new name, scratch shells, the create
     *  modal) still go straight into a first shell — the host registers
     *  the workspace on spawn and seeds cwd from its root. */
    async function spawnShell(workspace: string): Promise<void> {
        try {
            await initDone;
            app.screen = "app";
            await tick(); // spawnIn activates: fit/focus need a visible DOM
            await mgr.spawnIn(workspace);
        } catch (err) {
            console.error("failed to open workspace", workspace, err);
            showHome();
            await tick(); // Home remounts before it can show the error
            home?.showError(`Couldn't open "${workspace}": ${err}`);
        }
    }
    function showHome(): void {
        app.dashVisible = false;
        app.screen = "home"; // Home remounts and refreshes itself
    }

    /** ` h from a terminal shows mission control; ` h on mission control
     *  returns to the workspace you left — a toggle, one muscle memory.
     *  No-op on home when there's nowhere to go back to (fresh app, the
     *  workspace was deleted). */
    function toggleHome(): void {
        if (app.screen !== "home") {
            showHome();
            return;
        }
        if (mgr.activeId || app.workspaces.some((w) => w.name === app.workspace)) {
            void showWorkspace(app.workspace);
        }
    }

    function toggleDash(): void {
        app.dashVisible = !app.dashVisible;
        if (!app.dashVisible) mgr.focusActive();
    }

    /** Hand focus back when an overlay closes — to whatever owns the screen.
     *
     *  Screen-aware because it has to be. mgr.focusActive() focuses a TERMINAL
     *  pane, and every overlay here (palette, picker, inbox, spawn, settings)
     *  can be opened over mission control. Closing one there used to hand the
     *  keyboard to the shell you last had open — the deck's own focus fix,
     *  undone by the modal on top of it. On a fresh boot the terminals are
     *  display:none, so focus() silently no-ops and strands focus on <body>
     *  instead: j/k just stop working, with nothing to see. */
    const focusBack = () => {
        if (app.screen === "home") home?.focusDeck();
        else mgr.focusActive();
    };

    /** Transient message in the titlebar's workspace slot — failures must
     *  be VISIBLE (set-root once died silently on a stale daemon 404). */
    // Flash rides its own slot, NEVER app.workspace: the old swap-the-name
    // trick meant any API call inside the 2.5s window used the flash TEXT
    // as the workspace ("saved x" → GET /workspaces/saved x/files).
    let flashTimer: ReturnType<typeof setTimeout> | undefined;
    function flash(msg: string): void {
        app.flashMsg = msg;
        clearTimeout(flashTimer);
        flashTimer = setTimeout(() => (app.flashMsg = null), 2500);
    }

    // ==== buffers ====
    //
    // A file is a BUFFER: it exists independently of any pane, and a pane is
    // a viewport onto one (vim's buffer/window split; VS Code's editor/group
    // split is the same thing with the list drawn as tabs). The strip is for
    // LAYOUTS — tmux windows — so a file must never mint one.
    //
    // `buffers` is the open set, most-recent first: `:ls`, and what the ⌘P
    // picker offers before it offers the whole repo. It deliberately outlives
    // the panes — retarget a pane off a file and the file is still open, which
    // is the difference between buffers and a single-file viewer.

    /** leafId → the EditorPane in it. The manager holds these as opaque
     *  PaneContent (it stays Monaco-free), but retargeting needs the real
     *  thing, so chrome keeps the index. */
    const editorPanes = new Map<string, import("./term/editor").EditorPane>();
    /** leafId → "open this path HERE" for a start screen. The greeter holds
     *  a `re` takeover, so an open from anywhere must be able to hand that
     *  takeover to the editor rather than mint a second pane beside it. */
    const startHandoff = new Map<string, (path: string) => void>();

    /** :qa's blast radius — the registered editor panes sharing a pane's
     *  WINDOW. Another window's editor is another vim: :qa never crosses.
     *  (Drafts aren't registered, so a :qa can't discard an unsent comment.) */
    function editorCohort(leafId: string): import("./term/editor").EditorPane[] {
        const win = mgr.paneWindow(leafId);
        if (!win) return [];
        return [...editorPanes.entries()]
            .filter(([id]) => mgr.paneWindow(id) === win)
            .map(([, p]) => p);
    }

    // ==== the jumplist (⌃O/⌃I) ====
    //
    // One list for the workbench, recorded at the openFile seam — every
    // navigation (gd, a grep hit, a picker open, a refs `o`) flows through
    // there, so that's where "where was I" gets written down. Same-file gd
    // never reaches openFile; the pane's onRecordJump covers it.
    const jumps = new Jumplist();
    /** the last file-mode editor pane to hold focus — where a jump departs
     *  from. Focus may sit in a terminal when a picker opens a file; the
     *  last editor position is still the right thing to return to. */
    let jumpPane: import("./term/editor").EditorPane | null = null;

    function recordJump(): void {
        jumps.push(jumpPane?.position() ?? null);
    }

    function jumpNav(dir: "back" | "forward"): void {
        const cur = jumpPane?.position() ?? null;
        const loc = dir === "back" ? jumps.back(cur) : jumps.forward();
        if (!loc) {
            flash(dir === "back" ? "at oldest jump" : "at newest jump");
            return;
        }
        void openFile(loc.path, {line: loc.line, col: loc.col}, {recordJump: false});
    }

    // ==== investigations (the explore work-type) ====
    //
    // An investigation is a durable RookTask whose children are breadcrumbs:
    // code anchors visited through the opener seam while it was open. The
    // host owns the trail; app.exploreTask mirrors it for the quickfix.

    /** Resume the newest open investigation — boot and workspace switch. */
    async function loadExplore(): Promise<void> {
        try {
            const roots = await api.reviewTasks(app.workspace, "explore");
            app.exploreTask = roots.find((t) => t.state === "open") ?? null;
        } catch {
            app.exploreTask = null; // old daemon — investigations just absent
        }
    }

    async function startExplore(title: string): Promise<void> {
        try {
            const t = await api.createExplore(app.workspace, title);
            t.children = [];
            app.exploreTask = t;
            flash(`investigating: ${title}`);
        } catch (err) {
            console.error("explore start failed", err);
            flash(
                String(err).includes(" 404 ")
                    ? "investigations need a newer rook-host — relaunch rook"
                    : "couldn't start investigation — see console",
            );
        }
    }

    async function finishExplore(): Promise<void> {
        const t = app.exploreTask;
        if (!t) {
            flash("no open investigation");
            return;
        }
        try {
            await api.setTaskState(t.id, "done");
            app.exploreTask = null;
            if (qf.context?.id === "explore") qf.listOpen = false;
            flash(`done — ${t.title ?? "investigation"} (${t.children?.length ?? 0} breadcrumbs)`);
        } catch (err) {
            console.error("explore finish failed", err);
            flash("couldn't finish investigation — see console");
        }
    }

    /** Refresh the mirror after a host-side trail change. */
    async function refreshExplore(): Promise<void> {
        const t = app.exploreTask;
        if (!t) return;
        const full = await api.task(t.id);
        if (app.exploreTask?.id === t.id) {
            app.exploreTask = full;
            qf.clamp();
        }
    }

    /** The opener seam writes the trail — fire-and-forget so navigation
     *  never waits on the ledger. */
    function recordVisit(path: string, line: number, col: number): void {
        const t = app.exploreTask;
        if (!t) return;
        void api
            .visitTask(t.id, path, line, col)
            .then(refreshExplore)
            .catch((err) => console.warn("breadcrumb failed", err));
    }

    function showTrail(): void {
        qf.set(exploreCtx);
        qf.listOpen = true;
    }

    const exploreCtx = makeExploreContext({
        // walking your own trail records the jump but not a new breadcrumb
        open: (path, line, col) => void openFile(path, {line, col}, {recordVisit: false}),
        star: async (id) => {
            const b = app.exploreTask?.children?.find((c) => c.id === id);
            if (!b) return;
            await api.setTaskState(id, b.state === "starred" ? "visited" : "starred");
            await refreshExplore();
        },
    });

    /** leafId → the AgentPane in it. Same reason as editorPanes, and the same
     *  discipline: entries are deleted on dispose, because a map that only
     *  grows is exactly the leak WatchMonitor gauges. */
    const agentPanes = new Map<string, import("./term/agentpane.svelte").AgentPane>();

    /** Jump from a conversation to the live pty it is a view of — the 10%
     *  escape hatch the whole surface is predicated on.
     *
     *  Looked up at click time rather than mirrored: the claude↔pty pairing
     *  lives in the host's correlate(), /workspaces/{ws}/status is where it
     *  surfaces, and one request on a click beats a fourth poll that is
     *  usually wrong. A session with no live window is normal — claude
     *  outlives the terminal it was started in. */
    function jumpToPty(session: string): () => Promise<void> {
        return async () => {
            try {
                const st = await api.workspaceStatus(app.workspace);
                const s = st.sessions.find((x) => x.agent?.sessionId === session);
                if (s) {
                    app.screen = "app";
                    await tick();
                    if (mgr.switchToId(s.id)) return;
                }
                flash("no live terminal for this session");
            } catch (err) {
                console.error("jump to pty failed", err);
                flash("no live terminal for this session");
            }
        };
    }

    /** Raw attach from the deck — straight to the pty behind a row.
     *
     *  No correlate lookup, unlike jumpToPty: the deck's rows come from
     *  /overview, which now carries the pty id per agent, so the id is
     *  already in hand. switchToId crosses windows AND workspaces on its own,
     *  which matters here in a way it doesn't for ` v — the deck lists every
     *  workspace at once, so the row you press R on is routinely not in the
     *  one you're standing in. */
    async function openPty(id: string): Promise<void> {
        const prev = app.screen;
        try {
            await initDone;
            // The switch has to happen first — switchToId activates, and
            // fit/focus no-op on a display:none subtree — so put it back if
            // the pty turns out to be gone. A row whose terminal died since
            // the last poll should cost you nothing; without this it dumps you
            // out of the deck onto an unrelated terminal, with a 2.5s titlebar
            // flash as the only explanation.
            app.screen = "app";
            await tick();
            if (!mgr.switchToId(id)) {
                app.screen = prev;
                flash("no live terminal for this session");
            }
        } catch (err) {
            console.error("raw attach failed", err);
            app.screen = prev;
            flash("no live terminal for this session");
        }
    }

    /** ` v — watch the agent session you are looking at.
     *
     *  Which session that is comes from the host's correlate(), read at
     *  command time: the pty in front of you, then whatever needs you, then
     *  any agent in the workspace. NOT from app.attention — that only lists
     *  sessions that need something, so keying off it would make ` v do
     *  nothing for a session that is happily working, which is most of them. */
    async function viewAgent(): Promise<void> {
        try {
            const st = await api.workspaceStatus(app.workspace);
            const focused = st.sessions.find((s) => s.id === app.focusedSessionId && s.agent);
            const target =
                focused?.agent?.sessionId ??
                st.sessions.find((s) => s.agent?.state === "needs_input")?.agent?.sessionId ??
                st.sessions.find((s) => s.agent)?.agent?.sessionId;
            if (!target) {
                flash("no agent session in this workspace");
                return;
            }
            await openAgent(target);
        } catch (err) {
            console.error("agent view failed", err);
            flash("agent view failed — see console");
        }
    }

    /** Open a claude session as a conversation. The same ladder as openFile:
     *    1. already displayed → go to it
     *    2. an agent pane exists → retarget it in place
     *    3. nothing to reuse → mint one window, ONCE
     *  A session is a document too. */
    async function openAgent(session: string): Promise<void> {
        try {
            await initDone;
            const shown = mgr.findPane((c) => c.type === "agent" && c.session === session);
            if (shown) {
                app.screen = "app";
                await tick();
                mgr.revealPane(shown);
                return;
            }
            const reusable = mgr.findPane((c) => c.type === "agent");
            if (reusable) {
                const pane = agentPanes.get(reusable.leafId);
                if (pane) {
                    pane.retarget(session, jumpToPty(session));
                    mgr.retargetPane(reusable, {type: "agent", session});
                    app.screen = "app";
                    await tick();
                    mgr.revealPane(reusable);
                    return;
                }
            }
            // the showWorkspace dance: activation fits and focuses, and both
            // silently no-op on a display:none subtree
            app.screen = "app";
            await tick();
            const {AgentPane} = await import("./term/agentpane.svelte");
            mgr.openPaneWindow({type: "agent", session}, (leafId) => {
                const pane = new AgentPane({
                    api,
                    session,
                    onjump: jumpToPty(session),
                    onDispose: () => agentPanes.delete(leafId),
                });
                agentPanes.set(leafId, pane);
                return pane;
            });
        } catch (err) {
            console.error("agent pane failed", err);
            flash("agent pane failed — see console");
        }
    }

    /** The performance pane, from the footprint chip. A surface with no
     *  identity, so it's a singleton per workspace: reveal the existing one
     *  before opening another. */
    async function openMonitor(): Promise<void> {
        app.screen = "app";
        await tick();
        const at = mgr.findPane((c) => c.type === "monitor");
        if (at) {
            mgr.revealPane(at);
            return;
        }
        const {MonitorPane} = await import("./term/monitorpane.svelte");
        mgr.openPaneWindow({type: "monitor"}, () => new MonitorPane({api}));
    }

    /** Promote a path to most-recent. Bounded: this is a working set, not
     *  history — the picker searches the whole repo anyway.
     *
     *  Also the one place a recent is RECORDED: this fires when a pane
     *  actually opens a document, which is narrower than every /file read
     *  (that would fold in Finder previews and gutter refetches) and is
     *  exactly what the start screen wants to list. Best-effort — the host
     *  copy is a convenience, and app.buffers is still the session truth. */
    function touchBuffer(path: string): void {
        app.buffers = [path, ...app.buffers.filter((p) => p !== path)].slice(0, 50);
        if (app.workspace && path) void api.noteRecent(app.workspace, path);
    }

    /** The start screen's action rows: real registry commands carrying their
     *  live keycaps, so a rebind in config shows up on the greeter and every
     *  chord it advertises is one that actually works. Unknown ids drop
     *  silently — the same fail-open rule the keymap uses. */
    const START_ACTIONS = [
        "file.open",
        "palette.toggle",
        "grep.open",
        "review.changes",
        "quickfix.toggle",
        "workspace.dashboard",
    ];
    function startActions(): {cmd: Command; keys: string}[] {
        const all = registry.all();
        return START_ACTIONS.flatMap((id) => {
            const cmd = all.find((c) => c.id === id);
            if (!cmd) return [];
            return [{cmd, keys: keymap.display(id) || cmd.keys || ""}];
        });
    }

    async function newEditorWindow(kind: "review" | "file", path?: string): Promise<void> {
        // the showWorkspace dance: activation fits and focuses, and
        // both silently no-op on a display:none subtree
        app.screen = "app";
        await tick();
        const {EditorPane} = await import("./term/editor");
        const ref: PaneRef =
            kind === "review" ? {type: "review"} : {type: "file", path: path ?? ""};
        mgr.openPaneWindow(ref, (leafId) => {
            const pane = new EditorPane(api, {
                workspace: app.workspace,
                kind,
                path,
                font: paneFont,
                onFlash: flash,
                cohort: () => editorCohort(leafId),
                onClose: () => mgr.closePane(leafId),
                onActivate: (seam) => {
                    activeEditor = seam;
                    activeEditorKind = kind;
                    if (kind === "file") jumpPane = pane;
                },
                onDispose: (seam) => {
                    editorPanes.delete(leafId);
                    if (activeEditor === seam) activeEditor = null;
                    if (jumpPane === pane) jumpPane = null;
                },
                // gd across files rides the openFile ladder; gr fills the
                // refs quickfix (vim: the last producer owns the list)
                onOpenLocation: (p, line, col) => void openFile(p, {line, col}),
                onReferences: showReferences,
                onRecordJump: recordJump,
                onJump: jumpNav,
                // telescope muscle memory, editor-scoped (⌃P/⌃G/⌃S) — no
                // shell focused here, so the scope is the workspace root
                onFindFile: () => {
                    scopeDir = undefined;
                    app.filePickerOpen = true;
                },
                onGrep: (seed) => {
                    grepSeed = seed ?? "";
                    scopeDir = undefined;
                    app.grepOpen = true;
                },
                onOpenThread: (id) => void openThreadBuffer(id),
                onOpenThreadSource: (p, line) => void openFile(p, {line, col: 1}),
                onThreadDone: () => jumpNav("back"),
                gutterBase: reviewGutterBase,
                reviewTask: () => app.reviewRoot?.id,
            });
            editorPanes.set(leafId, pane);
            return pane;
        });
    }

    /** What the file panes' git gutter diffs against: the active review's
     *  scope base while one is open (its detail carries the resolved ref —
     *  merge-base sha, commit parent, or HEAD), else HEAD by omission. */
    function reviewGutterBase(): string | undefined {
        return app.reviewRoot?.detail?.base;
    }

    /** `re` takeovers in flight: editID → where the shell goes back. */
    const takeovers = new Map<string, {at: PaneAt; sessionId: string}>();

    /** The editor's furniture (tree, quickfix, ,-leader verbs) exists only
     *  within the editor — an editor pane focused, or one of the editor's
     *  own side surfaces already holding the keyboard. */
    function editorFocused(): boolean {
        if (app.focusZone === "left" || app.focusZone === "bottom") return true;
        const c = mgr.focusedContent();
        return c != null && c.type !== "term";
    }

    /** The furniture is PER WINDOW (vim's tab page: each layout carries its
     *  own tree and list) — and per-window means per-INSTANCE, not one
     *  side pane costume-changed between windows: the tree renders one
     *  FileExplorer per window (winchrome.svelte.ts holds each window's
     *  open/anchor state), and the quickfix `qf` import is a facade over
     *  per-window stores (quickfix.svelte.ts). `chrome` is the ACTIVE
     *  window's tree state, for the keyboard/command paths. */
    const chrome = $derived(chromeFor(app.activeId));

    /** That ask is over, and this rook didn't decide it (host ask.go pushes
     *  msgAskDone on every settle). Usually the phone: you walked away, the
     *  question escalated to the relay, and you answered it from the garden.
     *  The pane stands down without delivering — a close that posted a
     *  dismissal would land on top of the answer you just gave. */
    function handleAskSettled(askId: string): void {
        const at = mgr.findPaneAll((c) => c.type === "ask" && c.id === askId);
        if (!at) return;
        const pane = mgr.paneObject(at.leafId) as {settleElsewhere?: () => void} | null;
        pane?.settleElsewhere?.();
        mgr.closePane(at.leafId);
        flash("answered elsewhere");
    }

    /** An agent's question off the session's frame socket
     *  (manager.onAskRequest): open the form in a split to the RIGHT of the
     *  pane that asked — the agent keeps its window, the question gets its
     *  own — and settle the blocked asker with the answer (or a dismissal)
     *  exactly once, whichever way the pane closes. */
    async function handleAskRequest(
        sessionId: string,
        _workspace: string,
        req: AskRequest,
    ): Promise<void> {
        await initDone;
        if (!Array.isArray(req.questions) || req.questions.length === 0) {
            void api.askAnswer(req.id, {canceled: true, reason: "no questions"}).catch(() => {});
            return;
        }
        // the host re-pushes pending asks on every fresh attach (reload,
        // reconnect) — an ask already on screen is revealed, not twinned
        const open = mgr.findPaneAll((c) => c.type === "ask" && c.id === req.id);
        if (open) {
            void api.askAck(req.id).catch(() => {});
            mgr.revealPane(open);
            return;
        }
        const at = mgr.findPaneAll((c) => c.type === "term" && c.session === sessionId);
        if (!at) {
            // no pane shows this session (stale layout) — fail the asker fast
            void api.askAnswer(req.id, {canceled: true, reason: "no pane"}).catch(() => {});
            return;
        }
        void api.askAck(req.id).catch(() => {});
        app.screen = "app";
        await tick();
        const {AskPane} = await import("./term/askpane.svelte");
        let leaf = "";
        const ok = mgr.splitPane(at, "row", {type: "ask", id: req.id}, (leafId) => {
            leaf = leafId;
            return new AskPane({
                questions: req.questions,
                onAnswer: (answers) => {
                    void api.askAnswer(req.id, {answers}).catch(() => {});
                    flash("answered — claude has it");
                    mgr.closePane(leaf);
                },
                onCancel: () => {
                    void api.askAnswer(req.id, {canceled: true}).catch(() => {});
                    mgr.closePane(leaf);
                },
            });
        });
        if (!ok) {
            void api.askAnswer(req.id, {canceled: true, reason: "no pane"}).catch(() => {});
        }
    }

    /** An `re` ask off the session's frame socket (manager.onEditRequest):
     *  vim's contract — take over the pane the command was typed in, give
     *  it back on :q, and the blocked rookctl exits with the editor's code. */
    async function handleEditRequest(
        sessionId: string,
        workspace: string,
        req: EditRequest,
    ): Promise<void> {
        await initDone;
        const at = mgr.findPaneAll((c) => c.type === "term" && c.session === sessionId);
        if (!at) {
            // no pane shows this session (stale layout) — fail the shell fast
            void api.editDone(req.id, 1).catch(() => {});
            return;
        }
        void api.editAck(req.id).catch(() => {});
        const paths = req.paths ?? [];
        // vim's contract, all three shapes: `re file` opens it, bare `re` is
        // the greeter, `re .` is the greeter with the tree beside it — every
        // one of them lands IN the editor immediately
        await performTakeover(
            req.id,
            sessionId,
            workspace,
            at,
            paths[0] ?? "",
            paths.slice(1),
            req.dir,
        );
        if (req.tree) {
            const c = chromeFor(at.winId);
            c.explorerDir = req.dir || undefined;
            c.explorerOpen = true;
            app.focusZone = "left"; // netrw: you land on the listing
        }
    }

    async function performTakeover(
        editID: string,
        sessionId: string,
        workspace: string,
        at: PaneAt,
        path: string,
        extra: string[],
        cwd: string,
    ): Promise<void> {
        app.screen = "app";
        await tick();
        // NO FILE NAMED — bare `re`, or `re .`. vim would give you an empty
        // buffer; rook gives you the start screen, which is the same nothing
        // with somewhere to go. It holds the SAME takeover, so the blocked
        // rookctl waits on this pane either way.
        //
        // `re .` gets the greeter too, which it didn't when the tree was a
        // window and WAS the answer. As a sidebar the tree can't be the
        // whole pane, so something has to sit behind it — and the greeter is
        // strictly better there than an empty buffer. It doesn't read as a
        // menu in front of netrw either, because focus lands on the LISTING
        // (focusZone = "left", set by the caller): the greeter is what you
        // see past the tree, not what you have to get through.
        if (!path) {
            await mountStart(editID, sessionId, workspace, at, cwd);
            return;
        }
        await mountEditor(editID, sessionId, workspace, at, path, extra, cwd);
    }

    /** The greeter half of a takeover. Picking a recent hands off to
     *  mountEditor under the same editID — one `re`, one pane, one exit
     *  code, however many screens it passed through. */
    async function mountStart(
        editID: string,
        sessionId: string,
        workspace: string,
        at: PaneAt,
        cwd: string,
    ): Promise<void> {
        const {StartPane} = await import("./term/startpane.svelte");
        let pane: InstanceType<typeof StartPane> | null = null;
        // A deliberate hand-off to the editor disposes this pane, and that
        // must NOT settle the edit — only a real close (` x) does.
        let handingOff = false;
        const handoff = (p: string) => {
            handingOff = true;
            pane?.dispose();
            pane = null;
            void mountEditor(editID, sessionId, workspace, at, p, [], cwd);
        };
        const ok = mgr.takeoverPane(at, {type: "start"}, (leafId) => {
            startHandoff.set(leafId, handoff);
            pane = new StartPane({
                api,
                workspace,
                dir: cwd || undefined,
                actions: startActions,
                onOpen: handoff,
                onQuit: () => finishTakeover(editID, 0),
                onDispose: () => {
                    startHandoff.delete(leafId);
                    // closed without q and without picking anything — the
                    // shell is still blocked on us; settle the exit code
                    if (handingOff) return;
                    if (takeovers.has(editID)) {
                        takeovers.delete(editID);
                        void api.editDone(editID, 0).catch(() => {});
                    }
                },
            });
            return pane;
        });
        if (!ok) {
            void api.editDone(editID, 1).catch(() => {});
            return;
        }
        takeovers.set(editID, {at, sessionId});
        if (cwd) chromeFor(at.winId).explorerDir = cwd;
    }

    async function mountEditor(
        editID: string,
        sessionId: string,
        workspace: string,
        at: PaneAt,
        path: string,
        extra: string[],
        cwd: string,
    ): Promise<void> {
        const {EditorPane} = await import("./term/editor");
        // the rest of the argv joins the buffer list (vim: `nvim a b c`
        // opens a, and b c wait in :ls — here, in ` e's Open buffers tier)
        for (const p of extra) touchBuffer(p);
        if (path) touchBuffer(path);
        const ok = mgr.takeoverPane(at, {type: "file", path}, (leafId) => {
            const pane = new EditorPane(api, {
                workspace,
                kind: "file",
                path,
                // the anchor `re` launched from — this pane's pickers scope
                // to it, and it outlives the terminal the takeover replaced
                dir: cwd || undefined,
                font: paneFont,
                onFlash: flash,
                cohort: () => editorCohort(leafId),
                // :q hands the pane back to the shell; :cq does too, but the
                // waiting `re` exits 1 (git commit reads that as an abort)
                onClose: () => finishTakeover(editID, 0),
                onAbort: () => finishTakeover(editID, 1),
                onActivate: (seam) => {
                    activeEditor = seam;
                    activeEditorKind = "file";
                    jumpPane = pane;
                },
                onDispose: (seam) => {
                    editorPanes.delete(leafId);
                    if (activeEditor === seam) activeEditor = null;
                    if (jumpPane === pane) jumpPane = null;
                    // disposed without :q/:cq (` x closed the pane) — the
                    // shell is still blocked on us; settle the exit code.
                    // No restore: the leaf is mid-removal (re-entrant
                    // dispose), and the session stays reachable in the deck.
                    if (takeovers.has(editID)) {
                        takeovers.delete(editID);
                        void api.editDone(editID, 0).catch(() => {});
                    }
                },
                onOpenLocation: (p, line, col) => void openFile(p, {line, col}),
                onReferences: showReferences,
                onRecordJump: recordJump,
                onJump: jumpNav,
                // ⌃P/⌃G inside a takeover scope to the shell's cwd — the
                // anchor `re` launched from, not the workspace root
                onFindFile: () => {
                    scopeDir = cwd || undefined;
                    app.filePickerOpen = true;
                },
                onGrep: (seed) => {
                    grepSeed = seed ?? "";
                    scopeDir = cwd || undefined;
                    app.grepOpen = true;
                },
                onOpenThread: (id) => void openThreadBuffer(id),
                onOpenThreadSource: (p, line) => void openFile(p, {line, col: 1}),
                onThreadDone: () => jumpNav("back"),
                gutterBase: reviewGutterBase,
                reviewTask: () => app.reviewRoot?.id,
            });
            editorPanes.set(leafId, pane);
            return pane;
        });
        if (!ok) {
            void api.editDone(editID, 1).catch(() => {});
            return;
        }
        takeovers.set(editID, {at, sessionId});
        // the takeover's cwd anchors ITS window's tree — a later ,b roots
        // where `re` was launched from, not wherever some other shell sits
        if (cwd) chromeFor(at.winId).explorerDir = cwd;
    }

    /** The return leg: shell back into the pane, exit code back to `re`.
     *  The editor's furniture leaves with it — you exited the place. Only
     *  the takeover's OWN window is touched: a :qa can end a takeover in a
     *  background window without disturbing the one you see. */
    function finishTakeover(editID: string, code: number): void {
        const t = takeovers.get(editID);
        takeovers.delete(editID);
        if (t) mgr.restoreTermPane(t.at, t.sessionId);
        const c = chromeFor(t?.at.winId ?? app.activeId);
        c.explorerOpen = false;
        c.explorerDir = undefined;
        const s = qfStoreFor(t?.at.winId ?? app.activeId);
        s.listOpen = false;
        s.detailOpen = false;
        void api.editDone(editID, code).catch(() => {});
    }

    /** Open a file as a BUFFER, not a window. The ladder, in vim's terms:
     *    1. already displayed → `:b` — go to it, don't open a second copy
     *    2. a file pane exists → `:e` — retarget it in place, keeping the
     *       pane's id, position, focus and Monaco instance
     *    3. nothing to reuse → mint one window, ONCE
     *  Step 3 used to be the only step, which is why every file minted a
     *  numbered slot in a strip that means "layout". */
    async function openFile(
        path: string,
        at?: {line: number; col: number},
        opts?: {recordJump?: boolean; recordVisit?: boolean},
    ): Promise<void> {
        try {
            await initDone;
            // ⌃O/⌃I traversal must not rewrite the history it walks
            if (opts?.recordJump !== false) recordJump();
            // …and an open investigation gets a breadcrumb (never during
            // traversal — walking history must not rewrite the trail either;
            // never for external absolute paths — the trail anchors inside
            // the workspace, and the visit endpoint confines)
            if (
                opts?.recordJump !== false &&
                opts?.recordVisit !== false &&
                !path.startsWith("/")
            ) {
                recordVisit(path, at?.line ?? 1, at?.col ?? 1);
            }
            touchBuffer(path);
            // Opening a file means the keyboard belongs in it — and leaving
            // the explorer holding it is not a no-op you can ignore, because
            // Monaco's init latch deliberately DECLINES to yank focus off
            // somewhere real (it only claims from <body> or from inside
            // itself). So a tree that keeps DOM focus keeps it forever, and
            // `re .` + Enter lands you in an editor you cannot type into.
            //
            // toTerms both drops the zone (the listing focuses itself from
            // an $effect on `active`, so the zone has to go too) and moves
            // focus onto the pane — which is what lets each rung's own focus
            // below, or Monaco's latch, actually land.
            if (app.focusZone === "left") toTerms();
            // `at` is a position to land the cursor on (gd's target, a refs
            // hit) — revealPosition latches on a pane that's still loading.
            const landOn = (leafId: string) => {
                if (at) editorPanes.get(leafId)?.revealPosition(at.line, at.col);
            };
            const open = mgr.findPane((c) => c.type === "file" && c.path === path);
            if (open) {
                app.screen = "app";
                await tick();
                mgr.revealPane(open);
                landOn(open.leafId);
                return;
            }
            // The start screen is a takeover wearing a greeter: opening a
            // file from ANYWHERE (⌃P, the palette, its own rows) has to hand
            // that takeover to the editor in place. Minting a pane instead
            // would leave the greeter holding a `re` nobody can reach.
            // Ahead of the reusable rung because the greeter is where you
            // are looking — a file pane in some other split is not.
            const greeter = mgr.findPane((c) => c.type === "start");
            const hand = greeter && startHandoff.get(greeter.leafId);
            if (greeter && hand) {
                app.screen = "app";
                await tick();
                hand(path);
                return;
            }
            // thread panes are reusable too — gt navigates in place, so ⌃O
            // (and any open) must be able to navigate back out of one. File
            // panes first: opening a file shouldn't steal a thread mid-read
            // when a file pane sits right there.
            const reusable =
                mgr.findPane((c) => c.type === "file") ?? mgr.findPane((c) => c.type === "thread");
            if (reusable) {
                const pane = editorPanes.get(reusable.leafId);
                // A dirty pane refuses (vim's `:e` without a bang). Don't nag
                // and don't discard — fall through and give the file its own
                // pane, so the click still does something.
                if (pane && (await pane.setFile(path))) {
                    mgr.retargetPane(reusable, {type: "file", path});
                    app.screen = "app";
                    await tick();
                    mgr.revealPane(reusable);
                    landOn(reusable.leafId);
                    return;
                }
            }
            await newEditorWindow("file", path);
            const minted = mgr.findPane((c) => c.type === "file" && c.path === path);
            if (minted) landOn(minted.leafId);
        } catch (err) {
            console.error("editor pane failed", err);
            flash("editor pane failed — see console");
        }
    }

    /** The review is a singleton surface, not a document: one walker over the
     *  whole changed set. A second ` g goes to the one you have.
     *
     *  `target` is a hunk to jump to (the review pane driving itself from the
     *  ReviewPanel): we open/reveal the pane, then call revealAt on ITS seam
     *  directly — not activeEditor, which may not be this pane yet. A pane
     *  that's still loading stashes the reveal and applies it after refresh. */
    async function openReview(target?: {
        path: string;
        startLine: number;
        endLine: number;
        side: "modified" | "original";
    }): Promise<void> {
        try {
            await initDone;
            let at = mgr.findPane((c) => c.type === "review");
            if (at) {
                app.screen = "app";
                await tick();
                mgr.revealPane(at);
            } else {
                await newEditorWindow("review");
                at = mgr.findPane((c) => c.type === "review");
            }
            if (target && at) {
                const seam = editorPanes.get(at.leafId)?.seam;
                seam?.revealAt(target.path, target.startLine, target.endLine, target.side);
                seam?.releaseFocus(); // the diff is a detail view; keep the list's keyboard
            }
        } catch (err) {
            console.error("editor pane failed", err);
            flash("editor pane failed — see console");
        }
    }

    // ---- review work-type (RookTask): data on `app`, traversal in `qf` ----

    async function loadReview(): Promise<void> {
        try {
            const roots = await api.reviewTasks(app.workspace, "review");
            app.reviewRoot = roots[0] ?? null;
        } catch {
            app.reviewRoot = null;
        }
        qf.clamp(); // the items changed under the cursor
    }

    async function prepareReview(): Promise<void> {
        try {
            await api.prepareReview(app.workspace, "unstaged");
            await loadReview();
        } catch (err) {
            flash(String(err));
        }
    }

    async function disposeHunk(id: number, state: string): Promise<void> {
        try {
            await api.setTaskState(id, state);
            await loadReview();
        } catch (err) {
            flash(String(err));
        }
    }

    /** The review jump opens the REAL file, at the leaf's reanchored range —
     *  the gutter (base = the review's scope base) supplies the change
     *  context the diff pane used to. currentStart falls back to startLine
     *  on leaves from an older host. */
    function openHunkInEditor(id: number): void {
        const h = app.reviewHunks.find((x) => x.id === id);
        if (!h?.path || !h.startLine) return;
        void openFile(h.path, {line: h.currentStart || h.startLine, col: 1});
    }

    // Trigger the host's triage fan-out and poll scores into the store as
    // they land. The poll also self-starts when a CLI-triggered run is seen
    // (loadReview reads scoring=true), so the UI never goes stale mid-triage.
    let triagePoll: number | null = null;
    function ensureTriagePoll(): void {
        triagePoll ??= window.setInterval(async () => {
            await loadReview();
            if (!app.reviewRoot?.scoring && triagePoll != null) {
                clearInterval(triagePoll);
                triagePoll = null;
            }
        }, 2000);
    }
    async function triggerTriage(): Promise<void> {
        const root = app.reviewRoot;
        if (!root || root.scoring) return;
        try {
            await api.scoreReview(root.id);
        } catch (err) {
            flash(String(err));
            return;
        }
        await loadReview(); // pick up scoring=true at once
        ensureTriagePoll();
    }
    $effect(() => {
        if (app.reviewRoot?.scoring) ensureTriagePoll();
    });

    // the review quickfix context — rows/hero/verbs (reviewContext.ts).
    // api is mount-fixed (one HostAPI per app lifetime), so capturing it here
    // is deliberate — same rationale as the leader above.
    // svelte-ignore state_referenced_locally
    const reviewCtx = makeReviewContext({
        api,
        prepare: prepareReview,
        dispose: disposeHunk,
        openInEditor: openHunkInEditor,
        triage: triggerTriage,
    });

    // gr's landing: fill the refs store, claim the quickfix, open the list.
    // The editor keeps its keyboard — the list is there when you want it
    // (` q / :cnext muscle memory), not a focus steal mid-thought.
    const refsCtx = makeRefsContext({
        open: (path, line, col) => void openFile(path, {line, col}),
        flash,
    });

    /** Every thread in the workspace, for the quickfix list. The panes fetch
     *  their own for the gutter; this is chrome's copy, and the list outlives
     *  whichever pane has focus. */
    async function refreshThreads(): Promise<void> {
        if (!app.workspace) return;
        try {
            app.threads = await api.threads(app.workspace);
        } catch (err) {
            console.warn("threads list unavailable:", err); // fail open
        }
    }

    const threadsCtx = makeThreadsContext({
        open: (id) => void openThreadBuffer(id),
        source: (id) => {
            const t = app.threads.find((x) => x.id === id);
            if (t) void openFile(t.path, {line: t.currentStart, col: 1});
        },
        resolve: async (id) => {
            await api.threadResolve(id);
            await refreshThreads();
        },
        reopen: async (id) => {
            await api.threadReopen(id);
            await refreshThreads();
        },
        flash,
    });
    function showReferences(locations: import("./hostapi").LspLocation[]): void {
        app.refHits = toRefHits(locations);
        app.refTitle = "References";
        qf.set(refsCtx);
        qf.listOpen = true;
    }

    /** ⌃S seeds the grep picker with the word under the cursor; the picker
     *  remounts per open, so the seed is read once at init. */
    let grepSeed = $state("");

    /** The focused shell's cwd, resolved when a scoped surface opens — vim's
     *  cwd experience: pickers and the explorer root where the shell stands.
     *  undefined (no terminal focused, or the host can't say) = workspace
     *  root, which is also the answer when the cwd IS the root. */
    let scopeDir = $state<string | undefined>();
    async function shellDir(): Promise<string | undefined> {
        // An editor holding the keyboard answers with ITS anchor. ⌃P resolves
        // globally (TUI_YIELD), so it lands here even when the editor's own
        // vim mapping would have called onFindFile — and a takeover has no
        // session left to ask: it replaced the terminal whose cwd we want.
        const anchored = activeEditor?.anchorDir();
        if (anchored) return anchored;
        const id = mgr.focusedSessionId;
        if (!id) return undefined;
        try {
            return (await api.sessionCwd(id)) || undefined;
        } catch {
            return undefined; // older host / dead session — fall back to root
        }
    }

    /** The `:Command` bridge's map, kept here as well as pushed into the
     *  editor module: a registry command typed at the TREE's prompt has to
     *  reach the same place it does inside Monaco. */
    let exCommands = new Map<string, () => void>();

    /** `:` from the file tree.
     *
     *  The tree holds the keyboard but has no Monaco behind it, and every ex
     *  command is registered on the shared Vim singleton and routed by a
     *  WeakMap keyed by the editor you typed INTO. So none of them can be
     *  reached from here — `:` in the tree was a key that did nothing, which
     *  is the one key every vim reflex starts with. This is the door.
     *
     *  `:q` closes the TREE: netrw's reading, where the thing you are in is
     *  the thing that quits. The window verbs (:qa, :wqa) fan out over the
     *  editors beside it through the same cohort a Monaco pane would use —
     *  and the tree goes with them on its own, because it is the editor's
     *  furniture and always has been. */
    function treeEx(line: string): void {
        const m = /^\s*:?\s*([a-zA-Z]+)\s*(!?)\s*(.*)$/.exec(line);
        if (!m) return; // a bare `:` then Enter is a no-op, as in vim
        const name = m[1];
        // the bang parses into either half depending on the spacing
        const force = m[2] === "!" || m[3].trim().startsWith("!");
        /** any editor pane in THIS window — exQuitAll fans out from it */
        const anyEditor = (): import("./term/editor").EditorPane | null => {
            for (const [leafId, pane] of editorPanes)
                if (mgr.paneWindow(leafId) === app.activeId) return pane;
            return null;
        };
        switch (name) {
            case "q":
            case "quit":
                chrome.explorerOpen = false;
                toTerms();
                return;
            case "qa":
            case "qall":
            case "quitall": {
                const ed = anyEditor();
                if (ed) ed.exQuitAll(force);
                else toTerms();
                return;
            }
            case "wqa":
            case "wqall":
            case "xa":
            case "xall": {
                const ed = anyEditor();
                if (ed) void ed.exSaveQuitAll();
                else toTerms();
                return;
            }
            case "w":
            case "write":
                flash("nothing to write — the tree is a listing, not a buffer");
                return;
        }
        const run = exCommands.get(name);
        if (run) run();
        else flash(`E492: Not an editor command: ${name}`);
    }

    /** Raise the command line over the tree, and put the keyboard back on
     *  the listing afterwards unless the command took it somewhere. */
    function openTreeEx(): void {
        const win = app.activeId;
        if (!win) return;
        const back = () => explorerRefs[win]?.focus();
        promptEx((line) => {
            treeEx(line);
            // the command may have taken the keyboard somewhere (:q, :qa) —
            // only claim it back if the tree still holds the zone
            if (app.focusZone === "left") back();
        }, back);
    }

    /** ` f — nvim's NvimTreeFindFile: open the explorer with its cursor on
     *  the file you're editing (last file pane, else newest buffer). */
    /** one FileExplorer INSTANCE per window — bound by window id, so each
     *  window's tree keeps its own listing, cursor and expansion */
    let explorerRefs = $state<
        Record<string, {revealPath: (path: string) => void; focus: () => void} | undefined>
    >({});
    async function revealInExplorer(): Promise<void> {
        const path = jumpPane?.position()?.path ?? app.buffers[0];
        if (!path) {
            flash("no file to reveal — open one first (` e)");
            return;
        }
        chrome.explorerDir = undefined; // the target is workspace-relative
        chrome.explorerOpen = true;
        await tick(); // the pane mounts before the ref exists
        if (app.activeId) explorerRefs[app.activeId]?.revealPath(path);
        app.focusZone = "left";
    }

    // grep ⌃Q — the picker's hits become the location list (same context as
    // gr; vim: the last producer owns it). The picker closes itself first.
    function grepToQuickfix(hits: import("./hostapi").GrepHit[], query: string): void {
        app.refHits = hits.map((h, i) => ({
            id: i + 1,
            path: h.path,
            line: h.line,
            col: h.col,
            text: h.text,
        }));
        app.refTitle = `Grep — ${query}`;
        qf.set(refsCtx);
        qf.listOpen = true;
        app.focusZone = "bottom"; // ⌃Q asked for the list — hand it the keyboard
    }

    // ,t's ⌃Q — the matched threads become the location list. Same door as
    // grep's: one quickfix, many producers, the last one owns it.
    function threadsToQuickfix(threads: ThreadInfo[], query: string): void {
        app.refHits = threads.map((t, i) => ({
            id: i + 1,
            path: t.path,
            line: Math.max(1, t.currentStart),
            col: 1,
            text: t.comments[0]?.body ?? "",
        }));
        app.refTitle = query ? `Threads — ${query}` : "Threads";
        qf.set(refsCtx);
        qf.listOpen = true;
        app.focusZone = "bottom";
    }

    async function spawn(task: string, workspace: string, worktree: boolean): Promise<void> {
        // worktree isolation: carve a fresh checkout+branch off the target
        // workspace's repo and land the session there instead
        if (worktree) workspace = (await api.createWorktree(workspace)).name;
        app.screen = "app";
        await tick(); // spawnIn activates: fit/focus need a visible DOM
        const id = await mgr.spawnIn(workspace);
        // let the shell come up before typing the command
        setTimeout(() => {
            api.sendInput(id, `claude ${shellQuote(task)}\r`).catch((err) => {
                console.error("spawn: sending claude command failed", err);
            });
        }, 400);
    }

    /** The workspace the spawn modal opens on. The deck names it (you're
     *  looking at rook's agents, so n means "another one of those"); every
     *  other door falls back to the workspace you're standing in. */
    let spawnWs = $state("");

    function openSpawn(workspace = app.workspace): void {
        spawnWs = workspace;
        app.spawnOpen = true;
    }

    /** Spawn from the deck: host-side, no window, you stay on the deck.
     *
     *  spawn() above mints a terminal and drops you into it, which is the
     *  opposite of what this screen is for — you came to START work, not to
     *  go sit and watch it. POST /workspaces/{ws}/spawn is the same actuator
     *  the conflicts chip and the workflow stages already use: the host owns
     *  the pty, types the coder command, and the claim hook correlates the
     *  session on its own. The row appears on the next 5s poll.
     *
     *  The pty is born 100x30 with nobody attached, and that cost lands on
     *  the RAW view alone: scrollback rendered at 100 columns reflows when
     *  you finally attach wider, while the transcript reader never touches a
     *  pty. Background spawning is only tolerable BECAUSE the conversation
     *  view exists — before it, an unattended session's only record was a
     *  100-column ring. */
    async function spawnBackground(
        task: string,
        workspace: string,
        worktree: boolean,
    ): Promise<void> {
        if (worktree) workspace = (await api.createWorktree(workspace)).name;
        await api.spawnTask(workspace, {task});
        await home?.refresh(); // don't make them wait out the poll for their own action
    }

    // The issue→worktree→session loop, invoked from the dashboard (current
    // workspace) or mission control (any workspace's queue): isolate in a
    // fresh worktree when the workspace has a repo, else land in the
    // workspace itself — the queue must work for non-repo roots too.
    async function workIssue(issue: IssueInfo, from = app.workspace): Promise<void> {
        let workspace = from;
        try {
            workspace = (
                await api.createWorktree(from, {
                    tracker: issue.tracker,
                    key: issue.key,
                    title: issue.title,
                })
            ).name;
        } catch (err) {
            console.warn("worktree isolation unavailable — spawning in the workspace", err);
        }
        app.screen = "app";
        await tick(); // spawnIn activates: fit/focus need a visible DOM
        const id = await mgr.spawnIn(workspace);
        setTimeout(() => {
            api.sendInput(id, `claude ${shellQuote(issue.task)}\r`).catch((err) => {
                console.error("work: sending claude command failed", err);
            });
        }, 400);
    }

    // keys hints come from the keymap so the palette reflects rebinds
    registry.register(
        {
            id: "palette.toggle",
            title: "Command palette",
            category: "View",
            keys: keymap.display("palette.toggle"),
            run: () => {
                app.paletteOpen = !app.paletteOpen;
            },
        },
        {
            id: "session.new",
            title: "New window (inherits cwd)",
            category: "Session",
            keys: keymap.display("session.new"),
            run: () => void mgr.newSession(),
        },
        {
            // id unchanged (rebinds survive); it kills the FOCUSED PANE —
            // a single-pane window still leaves the strip with it
            id: "session.close",
            title: "Kill pane",
            category: "Session",
            keys: keymap.display("session.close"),
            run: () => void mgr.closeActive(),
        },
        {
            id: "pane.split-right",
            title: "Split pane right (inherits cwd)",
            category: "Pane",
            keys: keymap.display("pane.split-right"),
            run: () => void mgr.splitFocused("row"),
        },
        {
            id: "pane.split-down",
            title: "Split pane down (inherits cwd)",
            category: "Pane",
            keys: keymap.display("pane.split-down"),
            run: () => void mgr.splitFocused("col"),
        },
        {
            id: "pane.next",
            title: "Next pane",
            category: "Pane",
            keys: keymap.display("pane.next"),
            run: () => mgr.cyclePane(),
        },
        {
            id: "pane.focus-left",
            title: "Focus pane left",
            category: "Pane",
            keys: keymap.display("pane.focus-left"),
            run: () => focusDir("left"),
        },
        {
            id: "pane.focus-right",
            title: "Focus pane right",
            category: "Pane",
            keys: keymap.display("pane.focus-right"),
            run: () => focusDir("right"),
        },
        {
            id: "pane.focus-up",
            title: "Focus pane up",
            category: "Pane",
            keys: keymap.display("pane.focus-up"),
            run: () => focusDir("up"),
        },
        {
            id: "pane.focus-down",
            title: "Focus pane down",
            category: "Pane",
            keys: keymap.display("pane.focus-down"),
            run: () => focusDir("down"),
        },
        {
            id: "pane.zoom",
            title: "Zoom pane (toggle)",
            category: "Pane",
            keys: keymap.display("pane.zoom"),
            run: () => mgr.toggleZoom(),
        },
        {
            id: "session.next",
            title: "Next window",
            category: "Session",
            keys: keymap.display("session.next"),
            run: () => mgr.next(),
        },
        {
            id: "session.prev",
            title: "Previous window",
            category: "Session",
            keys: keymap.display("session.prev"),
            run: () => mgr.prev(),
        },
        {
            id: "config.reload",
            title: "Reload config",
            category: "Config",
            keys: keymap.display("config.reload"),
            run: () => location.reload(),
        },
        {
            id: "config.settings",
            title: "Settings…",
            category: "Config",
            keys: keymap.display("config.settings"),
            run: () => {
                app.settingsOpen = true;
            },
        },
        {
            id: "workspace.switch",
            title: "Switch workspace…",
            category: "Workspace",
            keys: keymap.display("workspace.switch"),
            run: () => {
                app.pickerOpen = true;
            },
        },
        {
            id: "workspace.manager",
            title: "Mission control (toggle)",
            category: "Workspace",
            keys: keymap.display("workspace.manager"),
            run: toggleHome,
        },
        {
            id: "workspace.dashboard",
            title: "Workspace dashboard",
            category: "Workspace",
            keys: keymap.display("workspace.dashboard"),
            run: toggleDash,
        },
        {
            id: "attention.inbox",
            title: "Attention inbox",
            category: "View",
            keys: keymap.display("attention.inbox"),
            run: () => {
                app.inboxOpen = !app.inboxOpen;
            },
        },
        {
            id: "agent.spawn",
            title: "New agent session (claude on a task)",
            category: "Session",
            keys: keymap.display("agent.spawn"),
            run: () => openSpawn(),
        },
        {
            id: "workspace.scratch",
            title: "New scratch shell",
            category: "Workspace",
            // independent of the Home component — must work from the
            // palette while a terminal is on screen
            run: async () => {
                const taken = new Set((await api.listWorkspaces()).map((w) => w.name));
                let n = 1;
                while (taken.has(`scratch-${n}`)) n++;
                await api.createWorkspace(`scratch-${n}`, "", true);
                // a shell must exist — the host discards a scratch
                // workspace when its last session exits
                void spawnShell(`scratch-${n}`);
            },
        },
        {
            id: "review.changes",
            title: "Review changes (diff)",
            category: "View",
            keys: keymap.display("review.changes"),
            run: () => void openReview(),
        },
        {
            id: "agent.view",
            title: "Watch agent session (conversation)",
            category: "View",
            keys: keymap.display("agent.view"),
            run: () => void viewAgent(),
        },
        {
            id: "threads.toggle",
            title: "Threads: toggle list",
            category: "View",
            keys: keymap.display("threads.toggle"),
            run: () => {
                if (qf.listOpen && qf.context?.id === "threads") {
                    qf.listOpen = false;
                    return;
                }
                qf.set(threadsCtx);
                void refreshThreads();
                qf.listOpen = true;
                app.focusZone = "bottom";
            },
        },
        {
            id: "threads.find",
            title: "Threads: find",
            category: "View",
            keys: keymap.display("threads.find"),
            run: () => {
                // the store is what the source reads; make sure it's warm
                void refreshThreads();
                app.threadFinderOpen = true;
            },
        },
        {
            id: "explorer.toggle",
            title: "Toggle file explorer",
            category: "View",
            keys: ", b",
            run: async () => {
                // editor furniture — the tree has no meaning over a shell
                if (!chrome.explorerOpen && !editorFocused()) {
                    flash("the file tree lives in the editor — re, ` g or ⌃P first");
                    return;
                }
                // a takeover anchored this window's tree already (its cwd);
                // otherwise the focused shell's cwd, else the workspace root
                const opening = !chrome.explorerOpen;
                if (opening && !chrome.explorerDir) {
                    chrome.explorerDir = await shellDir();
                }
                chrome.explorerOpen = opening;
                // Opening the tree puts you IN it — netrw and nerdtree both
                // land you on the listing, and a tree you have to ⌃H into is
                // one you press ,b twice for. Closing it while it holds the
                // keyboard hands that back rather than leaving the zone
                // pointing at a pane that isn't there.
                if (opening) app.focusZone = "left";
                else if (app.focusZone === "left") toTerms();
            },
        },
        {
            id: "explorer.reveal",
            title: "Explorer: reveal current file",
            category: "View",
            keys: ", f",
            run: () => {
                if (!editorFocused()) {
                    flash("the file tree lives in the editor — re, ` g or ⌃P first");
                    return;
                }
                void revealInExplorer();
            },
        },
        {
            id: "review.toggle",
            title: "Toggle review pane",
            category: "View",
            run: () => {
                // toggling review OPEN claims the quickfix list for the review
                // context (vim: whoever fills the list owns it)
                if (qf.listOpen && qf.context?.id === "review") {
                    qf.listOpen = false;
                    return;
                }
                qf.set(reviewCtx);
                qf.listOpen = true;
                app.focusZone = "bottom"; // opening the list hands it the keyboard
                void loadReview();
            },
        },
        // quickfix traversal as registry commands — palette-visible now, and
        // the seam that makes list traversal agent-invokable later
        {
            id: "editor.thread",
            title: "Thread under cursor: open or create (gt)",
            category: "Review",
            run: goToThread,
        },
        // gc is the daily surface; this is the same verb for the palette, the
        // ex bridge (:EditorComment), and a config keybind. Line-scoped, since
        // a registry command has no motion to take.
        {
            id: "editor.comment",
            title: "Editor: toggle comment on the current line (gcc)",
            category: "Editor",
            keys: "gcc",
            run: () => {
                const p = focusedEditorPane();
                if (p) p.toggleComment();
                else flash("not in an editor");
            },
        },
        // The thread buffer's crystallizing verbs. Registry commands so the
        // palette lists them and the ex bridge derives :ThreadNote /
        // :ThreadAsk; both resolve to the FOCUSED thread pane, which is
        // where a colon command is typed by construction.
        {
            id: "thread.note",
            title: "Thread: commit draft as note (no nudge)",
            category: "Review",
            run: () => {
                const p = focusedThreadPane();
                if (p) void p.threadNote();
                else flash("not in a thread buffer — gt opens one");
            },
        },
        {
            id: "thread.ask",
            title: "Thread: commit draft and ask the agent",
            category: "Review",
            run: () => {
                const p = focusedThreadPane();
                if (p) void p.threadAsk();
                else flash("not in a thread buffer — gt opens one");
            },
        },
        {
            id: "quickfix.toggle",
            title: "Quickfix: toggle list",
            category: "View",
            keys: ", q",
            run: () => {
                if (qf.listOpen) {
                    qf.listOpen = false;
                    return;
                }
                // editor furniture, same as the tree
                if (!editorFocused()) {
                    flash("quickfix lives in the editor — re, ` g or ⌃P first");
                    return;
                }
                if (!qf.context) {
                    qf.set(reviewCtx); // no producer ran yet — claim review
                    void loadReview();
                }
                qf.listOpen = true;
                app.focusZone = "bottom";
            },
        },
        {
            id: "quickaction.toggle",
            title: "Quick actions (current context)",
            category: "View",
            run: () => {
                if (app.quickActionOpen) {
                    closeQuickActions();
                    return;
                }
                if (!qf.context) {
                    qf.set(reviewCtx);
                    void loadReview();
                }
                app.closeOverlays();
                app.quickActionOpen = true;
            },
        },
        {
            id: "quickfix.next",
            title: "Quickfix: next item",
            category: "View",
            run: () => qf.move(1),
        },
        {
            id: "quickfix.prev",
            title: "Quickfix: previous item",
            category: "View",
            run: () => qf.move(-1),
        },
        {
            id: "quickfix.open",
            title: "Quickfix: open list",
            category: "View",
            run: () => {
                // :copen — reopen the current list, keyboard included. With no
                // context claimed yet, claim review (the only producer today;
                // when a second tenant lands this becomes "the LAST list").
                if (!qf.context) {
                    qf.set(reviewCtx);
                    void loadReview();
                }
                qf.listOpen = true;
                app.focusZone = "bottom";
            },
        },
        {
            id: "quickfix.close",
            title: "Quickfix: close",
            category: "View",
            run: () => {
                if (qf.detailOpen) qf.detailOpen = false;
                else qf.listOpen = false;
            },
        },
        // the review verbs, agent-invokable: same qf.act path as the keys
        {
            id: "review.approve",
            title: "Review: approve current hunk",
            category: "View",
            run: () => void qf.act("a"),
        },
        {
            id: "review.reject",
            title: "Review: reject current hunk",
            category: "View",
            run: () => void qf.act("r"),
        },
        {
            id: "review.defer",
            title: "Review: defer current hunk",
            category: "View",
            run: () => void qf.act("d"),
        },
        {
            id: "file.open",
            title: "Open file",
            category: "View",
            keys: keymap.display("file.open"),
            run: async () => {
                scopeDir = await shellDir();
                app.filePickerOpen = true;
            },
        },
        {
            id: "grep.open",
            title: "Grep workspace",
            category: "View",
            keys: keymap.display("grep.open"),
            run: async () => {
                grepSeed = ""; // a stale ⌃S seed must not leak into ` /
                scopeDir = await shellDir();
                app.grepOpen = true;
            },
        },
        {
            id: "explore.start",
            title: "Explore: start investigation",
            category: "View",
            run: () => {
                app.exploreOpen = true;
            },
        },
        {
            id: "explore.trail",
            title: "Explore: show trail",
            category: "View",
            keys: keymap.display("explore.trail"),
            run: showTrail,
        },
        {
            id: "explore.finish",
            title: "Explore: finish investigation",
            category: "View",
            run: () => void finishExplore(),
        },
        {
            id: "workspace.set-root",
            title: "Set workspace root to shell's directory",
            category: "Workspace",
            keys: keymap.display("workspace.set-root"),
            run: async () => {
                const id = mgr.focusedSessionId;
                if (!id) return;
                try {
                    const cwd = await api.sessionCwd(id);
                    if (!cwd) throw new Error("host couldn't resolve the shell's cwd");
                    await api.createWorkspace(app.workspace, cwd); // upsert keeps everything else
                    flash(`root → ${cwd}`);
                } catch (err) {
                    console.error("set-root failed", err);
                    flash("set-root failed — see console");
                }
            },
        },
    );

    // The :Command bridge — every registry command doubles as an ex command
    // in the editor (:ThreadAsk runs thread.ask), plus config's [commands]
    // aliases. Pushed once at boot: config.reload is a page reload, so the
    // map rebuilds with it. The dynamic import loads only the editor module,
    // never Monaco (that stays behind the pane's own lazy import).
    void import("./term/editor").then((m) => {
        exCommands = registry.exNames(commandAliases);
        m.setExCommands(exCommands);
    });

    // ==== workbench-level directional focus ====
    //
    // mgr.focusPane walks the terminal layout tree; it returns false at the
    // tree's edge. That edge is where the workbench takes over: to the left
    // and right of the terminals sit the side panes, which are Svelte chrome
    // and not in the tree at all. So the two models compose — pane, pane,
    // pane, …, then across the boundary into an open pane. A CLOSED side pane
    // is not a target: the edge just stops, as tmux does (no wrap).
    const NAV: Set<string> = new Set([
        "pane.focus-left",
        "pane.focus-right",
        "pane.focus-up",
        "pane.focus-down",
    ]);

    /** Chords that resolve early like NAV and yield to a full-screen TUI the
     *  same way: ⌃P/⌃G open the pickers from anywhere in the workbench, but
     *  vim in a terminal keeps ⌃P completion and less keeps its keys. */
    const TUI_YIELD: Set<string> = new Set(["file.open", "grep.open"]);

    /** Is this element somewhere text is being entered? Such a target keeps
     *  its own keys — we never steal from a caret. */
    function isTyping(el: HTMLElement | null): boolean {
        return (
            el != null &&
            (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.isContentEditable)
        );
    }

    function focusDir(dir: Edge): void {
        if (app.focusZone === "left") {
            // the explorer owns up/down (its own rows); only l leaves it
            if (dir === "right") toTerms();
            return;
        }
        if (app.focusZone === "right") {
            if (dir === "left") toTerms();
            return;
        }
        if (app.focusZone === "bottom") {
            // the quickfix strip owns j/k (its own rows); only up leaves it
            if (dir === "up") toTerms();
            return;
        }
        if (mgr.focusPane(dir)) return; // moved inside the layout tree
        if (dir === "left" && chrome.explorerOpen) app.focusZone = "left";
        else if (dir === "down" && qf.listOpen) app.focusZone = "bottom";
        // else: at the workbench edge with nothing beyond it — stay put
    }

    function toTerms(): void {
        app.focusZone = "terms";
        mgr.refocusPane();
    }

    /** Keep the zone honest with where the keyboard ACTUALLY is.
     *
     *  focusDir/toTerms set the zone as an intent — entering the explorer has
     *  to work that way, since the pane focuses itself from an $effect on the
     *  prop. But plenty of things move focus without going through them, and
     *  a hand-maintained zone desyncs the moment one does: opening a file from
     *  the explorer focuses Monaco, and the zone was left saying "left", so
     *  ⌃h read as "already at the left edge, nothing to do" and did nothing
     *  until a ⌃l resynced it. The zone is a PROJECTION of DOM focus; this is
     *  what projects it. Clicks into a pane and reveals both land here too. */
    function onFocusIn(e: FocusEvent): void {
        // an overlay borrows focus and gives it back — the zone waits it out
        if (app.anyOverlayOpen) return;
        const el = e.target as HTMLElement | null;
        if (!el?.closest) return;
        const pane = el.closest<HTMLElement>(".side-pane");
        const side = pane?.dataset.side;
        app.focusZone = side === "left" || side === "right" || side === "bottom" ? side : "terms";
    }

    // A side pane that closes under a focus that lives in it would strand the
    // keyboard in a detached node; hand focus back instead.
    $effect(() => {
        if (app.focusZone === "left" && !chrome.explorerOpen) toTerms();
        if (app.focusZone === "bottom" && !qf.listOpen) toTerms();
    });

    // ==== keybindings — two layers, both dispatching registry commands ====
    //
    // 1. The leader prefix (config `leader`, backtick by default, or a tmux
    //    ctrl+b-style chord): the leader arms, the next key acts. Pressing
    //    the leader twice passes it through. leader-digit selects a window.
    // 2. macOS chords (⌘K palette etc.) as a native-feeling complement.
    // Both layers resolve through the keymap (defaults + config `keybind`
    // overrides); only the digit keys and the leader stay hardwired here.
    function onKeydown(e: KeyboardEvent): void {
        if (app.inboxOpen) return; // inbox's capture handler owns keys
        if (app.spawnOpen || app.settingsOpen) return; // modals own their keys
        if (app.paletteOpen) {
            if (keymap.chords.get(sigOf(e)) === "palette.toggle") {
                e.preventDefault();
                app.paletteOpen = false;
            }
            return; // palette's own input handles the rest
        }
        if (app.pickerOpen || app.filePickerOpen || app.grepOpen) return; // pickers' own inputs handle keys

        const tgt = e.target as HTMLElement | null;
        const inSidePane = tgt?.closest?.(".side-pane") != null;

        // A bare text input OUTSIDE the side panes (the hero's note box) owns
        // its keys completely — leaders and chords must not eat a comma or a
        // backtick mid-sentence. The terminal (.vt-screen) and Monaco are the
        // exception: they ARE how panes receive the workbench's keys.
        if (isTyping(tgt) && !tgt?.closest(".vt-screen, .monaco-editor")) return;

        // The vim-navigator chords resolve BEFORE the side-pane guard below:
        // they're the workbench's own movement keys, and a pane you can enter
        // but never leave is a trap. They stay out of the way of real typing —
        // a side pane's text inputs keep them (⌃H is a backspace there).
        if (app.screen !== "home") {
            const nav = keymap.chords.get(sigOf(e));
            if (nav && (NAV.has(nav) || TUI_YIELD.has(nav)) && !(inSidePane && isTyping(tgt))) {
                // A full-screen app in the focused terminal owns these — this
                // is vim-tmux-navigator's is_vim check, read off the alternate
                // screen buffer instead of grepping ps. Only the terminals
                // zone can yield: a side pane isn't running vim.
                if (!(app.focusZone === "terms" && mgr.focusedInAltScreen)) {
                    e.preventDefault();
                    e.stopPropagation();
                    registry.run(nav);
                    return;
                }
                return; // hand it to the TUI, untouched
            }
        }

        // the thread panel owns its keys: comments about code are full of
        // backticks, and the capture-phase prefix must not eat them. Only
        // .side-pane is guarded — the terminal and Monaco surfaces live in
        // #terminals, NOT .side-pane, so the prefix keeps working there.
        // The bottom strip is exempt: it has no text inputs, and without the
        // exemption `,a` from the strip would drop the comma and feed a bare
        // `a` to the strip's action keys — a stray approve.
        //
        // The file TREE is exempt on the same grounds, and it became load
        // bearing the moment opening the tree started landing the keyboard
        // in it: without this, ` could not switch windows and ,b could not
        // close the tree you were standing in — a surface you can enter and
        // never leave. Its own text inputs still win, via isTyping.
        const exemptPane =
            tgt?.closest?.('[data-side="bottom"]') != null ||
            (tgt?.closest?.('[data-side="left"]') != null && !isTyping(tgt));
        if (inSidePane && !exemptPane) return;
        if (app.screen === "home") {
            // the prefix works here too, so ` h toggles back to the
            // workspace you left — but never while typing in a modal input
            const el = e.target as HTMLElement | null;
            const typing = isTyping(el);
            if (app.prefixArmed) {
                if (e.key === "Shift" || e.key === "Meta" || e.key === "Alt" || e.key === "Control")
                    return;
                app.prefixArmed = false;
                if (typing) return;
                e.preventDefault();
                e.stopPropagation();
                if (keymap.prefix.get(e.key) === "workspace.manager")
                    registry.run("workspace.manager");
                // anything else: prefix consumed, key ignored — tmux behavior
                return;
            }
            if (!typing && leader.matches(e)) {
                e.preventDefault();
                e.stopPropagation();
                app.prefixArmed = true;
                return;
            }
            if (e.metaKey || e.ctrlKey || e.altKey) {
                const id = keymap.chords.get(sigOf(e));
                // only the commands that make sense without a terminal
                if (id === "palette.toggle" || id === "workspace.manager") {
                    e.preventDefault();
                    registry.run(id);
                }
            }
            return;
        }

        if (app.prefixArmed) {
            if (e.key === "Shift" || e.key === "Meta" || e.key === "Alt" || e.key === "Control")
                return;
            app.prefixArmed = false;
            // Leader twice = tmux's send-prefix. Let the SECOND press through
            // untouched and the pane that has focus decides what it means:
            // xterm writes it to the PTY, Monaco hands it to vim, which reads
            // it in ITS mode — insert inserts a backtick, normal jumps to a
            // mark. That mode is the reason nothing is synthesised here. The
            // old path wrote leader.literal to the focused SESSION's socket,
            // which an editor pane doesn't have (its sessionId is null), so
            // the one escape from a prefix key was dead in the one pane made
            // of text. A leader with no natural literal (a chord like ⌘⇧X)
            // has nothing to pass through: swallow it, as before.
            if (leader.matches(e)) {
                if (!leader.literal) {
                    e.preventDefault();
                    e.stopPropagation();
                }
                return;
            }
            e.preventDefault();
            e.stopPropagation();
            if (/^[0-9]$/.test(e.key)) {
                // reserved: the strip digits ARE the windows, 1-based. The
                // dashboard no longer takes a slot — it isn't a layout (` d).
                mgr.switchTo(Number(e.key) - 1);
            } else {
                const cmd = keymap.prefix.get(e.key);
                if (cmd) registry.run(cmd);
                // unbound: prefix consumed, key ignored — tmux behavior
            }
            return;
        }
        if (ctxArmed) {
            if (e.key === "Shift" || e.key === "Meta" || e.key === "Alt" || e.key === "Control")
                return;
            ctxArmed = false;
            // context leader twice = send-prefix, the IDE leader's contract:
            // the second press passes through untouched and the focused pane
            // decides what a comma means.
            if (contextLeader.matches(e)) return;
            e.preventDefault();
            e.stopPropagation();
            const cmd = contextMap.get(e.key);
            // a typo'd command id in [editor.keybinds] must say so where
            // the user is looking — the palette lists the real ids
            if (cmd && !registry.has(cmd)) flash(`unknown command: ${cmd} (⌘K lists ids)`);
            else if (cmd) registry.run(cmd);
            // unbound: prefix consumed, key ignored — tmux behavior
            return;
        }
        if (leader.matches(e)) {
            e.preventDefault();
            e.stopPropagation();
            app.prefixArmed = true;
            return;
        }
        if (contextLeader.matches(e)) {
            // The editor's leader arms ONLY inside the editor's own
            // surfaces — a Monaco pane, its bottom quickfix strip, the file
            // tree, or the greeter. A comma in a shell is a comma: the
            // editor is a place, and its keys don't leak out of it.
            //
            // The tree and the greeter count because they ARE the editor:
            // one is its furniture, the other is what `re` lands on when you
            // name no file. Leaving either out is a trap rather than a
            // restriction — opening the tree lands you in it, so `,b` has to
            // close the thing you are standing in, and a greeter where the
            // leader is dead is a first screen with no verbs on it.
            if (
                tgt?.closest?.(
                    '.editor-mount, [data-side="bottom"], [data-side="left"], .start-wrap',
                ) != null
            ) {
                e.preventDefault();
                e.stopPropagation();
                ctxArmed = true;
                return;
            }
            // not the editor: fall through — the terminal keeps the key
        }

        // chords need a real modifier; everything else belongs to the shell
        if (!e.metaKey && !e.ctrlKey && !e.altKey) return;
        if (e.metaKey && !e.shiftKey && !e.ctrlKey && !e.altKey && /^Digit[0-9]$/.test(e.code)) {
            // reserved: ⌘digits mirror the strip
            e.preventDefault();
            e.stopPropagation();
            const n = Number(e.code.slice(5));
            mgr.switchTo(n - 1);
            return;
        }
        const id = keymap.chords.get(sigOf(e));
        if (id) {
            e.preventDefault();
            e.stopPropagation();
            registry.run(id);
        }
        // unbound chords fall through untouched (ctrl-c and friends)
    }

    // ==== host polls: attention (5s) and usage/costs (30s), into the
    // store — every surface reads the same snapshot. Pure plumbing, no
    // model anywhere in the app (docs/agent.md milestone 1). ====
    const seenAsks = new Set<string>(); // one notification per ask, ever
    const notify = (title: string, body: string) =>
        Call.ByName("github.com/incantery/rook/internal/notify.Service.Notify", title, body).catch(
            (err: unknown) => console.warn("notification failed", err),
        );

    async function pollAttention(): Promise<void> {
        try {
            app.attention = await api.attention();
        } catch {
            return; // host briefly unreachable — keep the last known state
        }
        for (const it of app.attention) {
            const k = `${it.agentSession}:${it.askSeq}`;
            if (seenAsks.has(k)) continue;
            seenAsks.add(k); // an ask first seen while focused stays silent
            if (!document.hasFocus()) {
                // "window N" is the host's per-workspace creation index —
                // once windows hold panes it can drift from the strip slot.
                // Accepted: the label orients, the jump (by session id) is
                // what must stay correct.
                void notify(
                    `${it.workspace} window ${it.window + 1} needs you`,
                    it.ask?.replace(/\n/g, " ") ?? "",
                );
            }
        }
        // asks that resolved can be forgotten (keeps the set bounded)
        const live = new Set(app.attention.map((i) => `${i.agentSession}:${i.askSeq}`));
        for (const k of seenAsks) if (!live.has(k)) seenAsks.delete(k);
    }

    /** Registry snapshot into the store — the lineage data (worktreeOf /
     *  branch) behind the task-tree treatment on every surface. */
    async function pollWorkspaces(): Promise<void> {
        try {
            app.workspaces = await api.listWorkspaces();
        } catch {
            // host briefly unreachable — keep the last known state
        }
    }

    /** The current workspace's live status (per-pane agent chips + git) —
     *  the titlebar's tab dots and the status bar's left/center zones.
     *  App-screen only: mission control has the richer overview poll, and
     *  a hidden chrome reading a stale snapshot is worse than none. */
    async function pollWsStatus(): Promise<void> {
        if (app.screen !== "app") return;
        // a snapshot of the PREVIOUS workspace is wrong, not stale — drop it
        if (app.wsStatus && app.wsStatus.name !== app.workspace) app.wsStatus = null;
        try {
            app.wsStatus = await api.workspaceStatus(app.workspace);
        } catch {
            // host briefly unreachable — keep the last known state
        }
    }

    // eager on entering the app screen or switching workspaces; the 10s
    // interval only keeps a standing view fresh
    $effect(() => {
        void app.screen;
        void app.workspace;
        // untracked: pollWsStatus reads app.wsStatus synchronously (the
        // stale-workspace guard) and writes it on completion — tracked, the
        // write re-runs this effect and the poll loops at request speed
        void untrack(() => pollWsStatus());
    });

    async function pollMoney(): Promise<void> {
        try {
            app.usage = await api.usage();
        } catch {
            // host briefly unreachable — keep the last known state
        }
        try {
            app.costs = await api.costs();
        } catch {
            // costs are independent of usage — keep last known
        }
        try {
            app.runtime = await api.runtime();
        } catch {
            // diagnostics must never cost a surface — keep last known
        }
        try {
            app.update = await api.update();
        } catch {
            // old hosts have no /update — no chip, never an error
        }
    }

    onMount(() => {
        mgr = new TermManager(terminalsEl, api, {
            changed: () => {
                app.tabs = mgr.currentTabs();
                app.activeId = mgr.activeId;
                app.focusedSessionId = mgr.focusedSessionId;
                // buffer paths are repo-relative, so they mean nothing in
                // another workspace — drop them (and the jumplist that
                // holds them) at the boundary; the new workspace's open
                // investigation resumes from the host AFTER the name flips
                // (loadExplore reads app.workspace)
                const switched = app.workspace !== mgr.workspace;
                if (switched) {
                    app.buffers = [];
                    jumps.clear();
                    app.exploreTask = null;
                }
                app.workspace = mgr.workspace;
                if (switched) void loadExplore();
                // furniture follows the window (vim tab page): pre-create
                // each window's chrome/quickfix stores so template reads
                // never mutate reactive maps mid-render, point the qf
                // facade at the active window, and drop dead windows' state
                for (const t of app.tabs) {
                    chromeFor(t.id);
                    qfStoreFor(t.id);
                }
                setActiveQfWindow(mgr.activeId);
                pruneChrome((id) => mgr.hasWindow(id));
                pruneQf((id) => mgr.hasWindow(id));
            },
            workspaceGone: showHome,
            activated: () => {
                app.dashVisible = false;
                setActiveQfWindow(mgr.activeId);
            },
        });
        mgr.onEditRequest = (sessionId, workspace, req) =>
            void handleEditRequest(sessionId, workspace, req);
        mgr.onAskRequest = (sessionId, workspace, req) =>
            void handleAskRequest(sessionId, workspace, req);
        mgr.onAskSettled = (askId) => handleAskSettled(askId);

        // The terminal renderer reads its colors from --term-* CSS variables,
        // which the theme service writes onto :root on every swap. But the host
        // emulator also needs the palette, to answer a program's OSC color
        // queries (vim reading the background) — push it now and on every swap.
        const sendPalette = (p: ThemePalette) =>
            mgr.setPalette(
                encodePalette(rgb(p.editorFg), rgb(p.bg), rgb(p.cursor), p.ansi.map(rgb)),
            );
        sendPalette(themeService.active().palette);
        const unPalette = themeService.onPalette(sendPalette);

        window.addEventListener("keydown", onKeydown, {capture: true});
        // focusin (not focus) — it bubbles, so one listener sees every pane,
        // side pane and the terminal/Monaco surface in the app
        window.addEventListener("focusin", onFocusIn);
        const ro = new ResizeObserver(() => mgr.syncSize());
        ro.observe(terminalsEl);

        void pollAttention();
        void pollMoney();
        void pollWorkspaces();
        void loadExplore(); // resume an open investigation across restarts
        const attnTimer = setInterval(() => void pollAttention(), 5000);
        const moneyTimer = setInterval(() => void pollMoney(), 30_000);
        const wsTimer = setInterval(() => void pollWorkspaces(), 15_000);
        const wsStatusTimer = setInterval(() => void pollWsStatus(), 10_000);

        initDone = (async () => {
            try {
                // the configured renderer's WASM (if any) must be live before
                // the first terminal mounts; fails open to the DOM renderer
                await preloadRenderer();
                await mgr.init(); // attach live sessions (background-warm)
            } catch (err) {
                fatal = `failed to open sessions:\n${err}`;
                app.screen = "app"; // the fatal element lives in #terminals
                throw err;
            }
            // Boot lands in a shell — opening rook is opening a terminal,
            // like ghostty or iterm; mission control stays one ` h away.
            // The last-used workspace wins if it still has windows, then
            // any live one; a fresh install spawns a first shell (the host
            // upserts the workspace and a rootless one opens in $HOME).
            // Can't route through showWorkspace/spawnShell: they await
            // initDone, which is this very promise.
            try {
                const last = localStorage.getItem("rook.workspace") ?? app.workspace;
                const live = mgr.workspaces();
                const target = live.some((w) => w.name === last) ? last : live[0]?.name;
                if (target) mgr.openWorkspace(target);
                else await mgr.spawnIn(last);
            } catch (err) {
                console.error("boot landing failed", err);
                showHome(); // fail open to the deck, never a broken boot
            }
        })();

        return () => {
            unPalette();
            window.removeEventListener("keydown", onKeydown, {capture: true});
            window.removeEventListener("focusin", onFocusIn);
            ro.disconnect();
            clearInterval(attnTimer);
            clearInterval(moneyTimer);
            clearInterval(wsTimer);
            clearInterval(wsStatusTimer);
        };
    });
</script>

{#if app.screen === "home"}
    <Home
        {api}
        bind:this={home}
        onopen={(name) => void showWorkspace(name)}
        onspawn={(name) => void spawnShell(name)}
        onwork={(ws, issue) => workIssue(issue, ws)}
        onagent={(session) => void openAgent(session)}
        onraw={(id) => void openPty(id)}
        onnew={(ws) => openSpawn(ws || app.workspace)}
    />
{/if}

<!-- always mounted: terminals live here; visibility is a display toggle,
     never {#if}. flex/hidden are toggled explicitly so exactly one display
     utility is ever active (a raw [hidden] attr would lose to .flex). -->
<!-- data-workspace names the workspace currently on screen. The titlebar
     already shows it, but as TEXT that flash messages borrow — so it can't be
     waited on. This is the stable answer to "which workspace am I looking
     at", which is what tells a test the switch has finished. -->
<div
    class={["min-h-0 flex-1 flex-col", app.screen === "app" ? "flex" : "hidden"]}
    data-workspace={app.workspace}
>
    <Titlebar
        onpicker={() => (app.pickerOpen = true)}
        ondashboard={toggleDash}
        oninbox={() => (app.inboxOpen = !app.inboxOpen)}
        onactivate={(id) => mgr.activateId(id)}
        onnew={() => void mgr.newSession()}
        onpalette={() => registry.run("palette.toggle")}
        onmonitor={() => void openMonitor()}
    />
    <div class="flex min-h-0 min-w-0 flex-1">
        <!-- one tree INSTANCE per window (vim's tab page): each keeps its
             own listing, cursor and expansion. display:contents lets the
             active window's SidePane sit in this flex row as if direct;
             hidden windows' trees stay mounted but display:none. -->
        {#each app.tabs as t (t.id)}
            {@const c = chromeFor(t.id)}
            <!-- data-win mirrors the class for ADDRESSABILITY: a hidden
                 window's chrome is display:none but still mounted and still
                 matches a bare selector, so "the tree" has to be sayable as
                 "the active window's tree" or a test reaches a stale one. -->
            <div
                class={t.id === app.activeId ? "contents" : "hidden"}
                data-win={t.id === app.activeId ? "active" : "hidden"}
            >
                <SidePane
                    side="left"
                    visible={c.explorerOpen}
                    title="Explorer"
                    onclose={() => (c.explorerOpen = false)}
                >
                    <FileExplorer
                        bind:this={explorerRefs[t.id]}
                        {api}
                        workspace={t.workspace}
                        dir={c.explorerDir}
                        active={t.id === app.activeId && app.focusZone === "left"}
                        onopen={(path) => void openFile(path)}
                        onex={openTreeEx}
                    />
                </SidePane>
            </div>
        {/each}
        <div class="relative min-h-0 min-w-0 flex-1" bind:this={terminalsEl}>
            {#if fatal}
                <div class="whitespace-pre-wrap p-6 font-mono text-sm text-red">{fatal}</div>
            {/if}
            {#if app.dashVisible}
                <Dashboard
                    {api}
                    onjump={(id) => mgr.switchToId(id)}
                    runCmd={(id) => registry.run(id)}
                    onwork={workIssue}
                />
            {/if}
            {#if qf.detailOpen && qf.context?.Detail && qf.currentId != null}
                {@const Detail = qf.context.Detail}
                <!-- the hero flies in over the viewport — chrome motion, the
                     webview dividend; the hunk swap inside stays instant so
                     rapid j/j/j triage never waits on animation -->
                <div class="absolute inset-0 z-20" transition:fly={{y: 12, duration: 160}}>
                    <Detail
                        id={qf.currentId}
                        pos={{i: qf.cursor + 1, n: qf.ids.length}}
                        {...qf.context.detailProps?.() ?? {}}
                    />
                </div>
            {/if}
        </div>
    </div>
    <!-- the quickfix strip: vim's bottom window, full width under the
         workbench row (list + hero coexist — the hero overlays the center
         while the strip stays visible below it). The `qf` facade reads the
         ACTIVE window's store; {#key} remounts on window switch so the
         slide animation only ever plays for a toggle IN this window, never
         for another window's state arriving. -->
    {#key app.activeId}
        <SidePane
            side="bottom"
            visible={qf.listOpen && !!qf.context}
            title={qf.context?.title ?? "Quickfix"}
            onclose={() => (qf.listOpen = false)}
        >
            <QuickfixPanel active={app.focusZone === "bottom"} />
        </SidePane>
    {/key}
</div>

<!-- the one global bottom strip — both screens end in the same instrument
     panel, which is what makes its numbers ambient instead of chrome -->
<StatusBar />

{#if app.paletteOpen}
    <Palette
        {registry}
        onclose={() => {
            app.paletteOpen = false;
            focusBack();
        }}
    />
{/if}
{#if app.quickActionOpen}
    <QuickActionModal onclose={closeQuickActions} />
{/if}
{#if app.pickerOpen}
    <Picker
        workspaces={mgr.workspaces()}
        current={app.workspace}
        onpick={(name, create) => void (create ? spawnShell(name) : showWorkspace(name))}
        onmanager={showHome}
        onclose={() => {
            app.pickerOpen = false;
            focusBack();
        }}
    />
{/if}
{#if app.filePickerOpen}
    <Finder
        {api}
        workspace={app.workspace}
        source={filesSource({
            api,
            workspace: app.workspace,
            dir: scopeDir,
            buffers: () => app.buffers,
            open: (path) => void openFile(path),
        })}
        onclose={() => {
            app.filePickerOpen = false;
            focusBack();
        }}
    />
{/if}
{#if app.grepOpen}
    <Finder
        {api}
        workspace={app.workspace}
        seed={grepSeed}
        source={grepSource({
            api,
            workspace: app.workspace,
            dir: scopeDir,
            open: (path, line, col) => void openFile(path, {line, col}),
            quickfix: grepToQuickfix,
        })}
        onclose={() => {
            app.grepOpen = false;
            grepSeed = "";
            focusBack();
        }}
    />
{/if}
{#if app.threadFinderOpen}
    <Finder
        {api}
        workspace={app.workspace}
        source={threadsSource({
            threads: () => app.threads,
            open: (id) => void openThreadBuffer(id),
            source: (path, line) => void openFile(path, {line, col: 1}),
            quickfix: threadsToQuickfix,
        })}
        onclose={() => {
            app.threadFinderOpen = false;
            focusBack();
        }}
    />
{/if}
{#if app.exploreOpen}
    <ExploreModal
        onstart={(title) => void startExplore(title)}
        onclose={() => {
            app.exploreOpen = false;
            focusBack();
        }}
    />
{/if}
{#if app.inboxOpen}
    <Inbox
        {api}
        onjump={async (sessionId) => {
            app.screen = "app";
            await tick(); // switchToId activates: fit/focus need a visible DOM
            if (!mgr.switchToId(sessionId)) console.warn("inbox jump: window is gone", sessionId);
        }}
        onclose={() => {
            app.inboxOpen = false;
            focusBack();
        }}
    />
{/if}
{#if app.spawnOpen}
    <SpawnModal
        currentWorkspace={spawnWs}
        background={app.screen === "home"}
        onspawn={app.screen === "home" ? spawnBackground : spawn}
        onclose={() => {
            app.spawnOpen = false;
            focusBack();
        }}
    />
{/if}
{#if app.settingsOpen}
    <Settings
        onclose={() => {
            app.settingsOpen = false;
            focusBack();
        }}
    />
{/if}
