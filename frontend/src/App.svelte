<!-- The app shell: screens (manager ⇄ workspace terminals), overlays, the
     command registry, the two-layer keybinding ladder, and the host polls.
     The terminal runtime is created here but lives outside Svelte — this
     component renders the container div once and never conditionally
     unmounts it (screen switches are the `hidden` attribute, i.e. CSS). -->
<script lang="ts">
    import {onMount, tick} from "svelte";
    import {Call} from "@wailsio/runtime";
    import type {HostAPI, IssueInfo} from "./hostapi";
    import {TermManager, type TermFactory} from "./term/manager";
    import type {Edge, PaneRef} from "./term/layout";
    import {themeService} from "./theme/service";
    import {Registry} from "./registry";
    import {buildKeymap, parseLeader, sigOf} from "./keymap";
    import {app, MODES, type Mode} from "./state.svelte";
    import {shellQuote} from "./util";
    import Titlebar from "./Titlebar.svelte";
    import Dashboard from "./Dashboard.svelte";
    import Home from "./Home.svelte";
    import Palette from "./Palette.svelte";
    import Picker from "./Picker.svelte";
    import FilePicker from "./FilePicker.svelte";
    import Inbox from "./Inbox.svelte";
    import SpawnModal from "./SpawnModal.svelte";
    import Settings from "./Settings.svelte";
    import SidePane from "./SidePane.svelte";
    import ThreadPanel from "./ThreadPanel.svelte";
    import FileExplorer from "./FileExplorer.svelte";
    import type {EditorSeam} from "./term/editor";

    interface Props {
        api: HostAPI;
        mkTerm: TermFactory;
        keybinds: Record<string, string | undefined>;
        /** the tmux-style prefix: a key ("`") or chord ("ctrl+b") */
        leader: string;
        /** the config font, for the Monaco pane (terminals get it via mkTerm) */
        paneFont: {family: string; size: number};
    }
    let {api, mkTerm, keybinds, leader: leaderCfg, paneFont}: Props = $props();
    // config-fixed: the leader reloads the page, which re-reads it
    // svelte-ignore state_referenced_locally
    const leader = parseLeader(leaderCfg);
    // svelte-ignore state_referenced_locally
    const keymap = buildKeymap(keybinds, leader.disp);

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

    // ==== mode: what surface owns the viewport, and its chrome defaults ====
    // Home wins; then a focused editor pane names the mode by its kind; else a
    // terminal holds focus. Derived, so it only actually changes on transition.
    const currentMode = $derived<Mode>(
        app.screen === "home" ? "home" : activeEditor ? activeEditorKind : "terminal",
    );
    $effect(() => {
        app.mode = currentMode;
    });
    // Entering a mode (re)applies its right-pane default; this reads only
    // app.mode, so a manual toggle (threads.toggle) within a mode survives
    // until the next transition. Review is the only mode that opens it today.
    $effect(() => {
        app.threadPaneOpen = MODES[app.mode].rightPaneDefault;
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

    const focusBack = () => mgr.focusActive();

    /** Transient message in the titlebar's workspace slot — failures must
     *  be VISIBLE (set-root once died silently on a stale daemon 404). */
    function flash(msg: string): void {
        const prev = app.workspace;
        app.workspace = msg;
        setTimeout(() => (app.workspace = prev), 2500);
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

    /** Promote a path to most-recent. Bounded: this is a working set, not
     *  history — the picker searches the whole repo anyway. */
    function touchBuffer(path: string): void {
        app.buffers = [path, ...app.buffers.filter((p) => p !== path)].slice(0, 50);
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
                onClose: () => mgr.closePane(leafId),
                onActivate: (seam) => {
                    activeEditor = seam;
                    activeEditorKind = kind;
                },
                onDispose: (seam) => {
                    editorPanes.delete(leafId);
                    if (activeEditor === seam) activeEditor = null;
                },
            });
            editorPanes.set(leafId, pane);
            return pane;
        });
    }

    /** Open a file as a BUFFER, not a window. The ladder, in vim's terms:
     *    1. already displayed → `:b` — go to it, don't open a second copy
     *    2. a file pane exists → `:e` — retarget it in place, keeping the
     *       pane's id, position, focus and Monaco instance
     *    3. nothing to reuse → mint one window, ONCE
     *  Step 3 used to be the only step, which is why every file minted a
     *  numbered slot in a strip that means "layout". */
    async function openFile(path: string): Promise<void> {
        try {
            await initDone;
            touchBuffer(path);
            const open = mgr.findPane((c) => c.type === "file" && c.path === path);
            if (open) {
                app.screen = "app";
                await tick();
                mgr.revealPane(open);
                return;
            }
            const reusable = mgr.findPane((c) => c.type === "file");
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
                    return;
                }
            }
            await newEditorWindow("file", path);
        } catch (err) {
            console.error("editor pane failed", err);
            flash("editor pane failed — see console");
        }
    }

    /** The review is a singleton surface, not a document: one walker over the
     *  whole changed set. A second ` g goes to the one you have. */
    async function openReview(): Promise<void> {
        try {
            await initDone;
            const at = mgr.findPane((c) => c.type === "review");
            if (at) {
                app.screen = "app";
                await tick();
                mgr.revealPane(at);
                return;
            }
            await newEditorWindow("review");
        } catch (err) {
            console.error("editor pane failed", err);
            flash("editor pane failed — see console");
        }
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
            run: () => {
                app.spawnOpen = true;
            },
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
            id: "threads.toggle",
            title: "Toggle thread pane",
            category: "View",
            keys: keymap.display("threads.toggle"),
            run: () => {
                app.threadPaneOpen = !app.threadPaneOpen;
            },
        },
        {
            id: "explorer.toggle",
            title: "Toggle file explorer",
            category: "View",
            keys: keymap.display("explorer.toggle"),
            run: () => {
                app.explorerOpen = !app.explorerOpen;
            },
        },
        {
            id: "file.open",
            title: "Open file (read-only)",
            category: "View",
            keys: keymap.display("file.open"),
            run: () => {
                app.filePickerOpen = true;
            },
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
        if (mgr.focusPane(dir)) return; // moved inside the layout tree
        if (dir === "left" && app.explorerOpen) app.focusZone = "left";
        else if (dir === "right" && app.threadPaneOpen) app.focusZone = "right";
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
        app.focusZone = pane ? (pane.dataset.side === "left" ? "left" : "right") : "terms";
    }

    // A side pane that closes under a focus that lives in it would strand the
    // keyboard in a detached node; hand focus back instead.
    $effect(() => {
        if (app.focusZone === "left" && !app.explorerOpen) toTerms();
        if (app.focusZone === "right" && !app.threadPaneOpen) toTerms();
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
        if (app.pickerOpen || app.filePickerOpen) return; // pickers' own inputs handle keys

        const tgt = e.target as HTMLElement | null;
        const inSidePane = tgt?.closest?.(".side-pane") != null;

        // The vim-navigator chords resolve BEFORE the side-pane guard below:
        // they're the workbench's own movement keys, and a pane you can enter
        // but never leave is a trap. They stay out of the way of real typing —
        // a side pane's text inputs keep them (⌃H is a backspace there).
        if (app.screen !== "home") {
            const nav = keymap.chords.get(sigOf(e));
            if (nav && NAV.has(nav) && !(inSidePane && isTyping(tgt))) {
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
        // .side-pane is guarded — xterm's and Monaco's hidden textareas live
        // in #terminals, NOT .side-pane, so the prefix keeps working there.
        if (inSidePane) return;
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
            e.preventDefault();
            e.stopPropagation();
            app.prefixArmed = false;
            if (leader.matches(e)) {
                // leader pressed twice: tmux passthrough (a literal ` or a control byte)
                if (leader.literal) mgr.sendToActive(leader.literal);
            } else if (/^[0-9]$/.test(e.key)) {
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
        if (leader.matches(e)) {
            e.preventDefault();
            e.stopPropagation();
            app.prefixArmed = true;
            return;
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
    }

    onMount(() => {
        mgr = new TermManager(terminalsEl, api, mkTerm, {
            changed: () => {
                app.tabs = mgr.currentTabs();
                app.activeId = mgr.activeId;
                app.focusedSessionId = mgr.focusedSessionId;
                // buffer paths are repo-relative, so they mean nothing in
                // another workspace — drop them at the boundary
                if (app.workspace !== mgr.workspace) app.buffers = [];
                app.workspace = mgr.workspace;
            },
            workspaceGone: showHome,
            activated: () => (app.dashVisible = false),
        });

        // live theme swaps re-color every terminal (chrome + Monaco re-theme
        // through their own subscriptions in the service)
        const unTheme = themeService.onXterm((t) => mgr.setTerminalTheme(t));

        window.addEventListener("keydown", onKeydown, {capture: true});
        // focusin (not focus) — it bubbles, so one listener sees every pane,
        // side pane and Monaco/xterm textarea in the app
        window.addEventListener("focusin", onFocusIn);
        const ro = new ResizeObserver(() => mgr.syncSize());
        ro.observe(terminalsEl);

        void pollAttention();
        void pollMoney();
        void pollWorkspaces();
        const attnTimer = setInterval(() => void pollAttention(), 5000);
        const moneyTimer = setInterval(() => void pollMoney(), 30_000);
        const wsTimer = setInterval(() => void pollWorkspaces(), 15_000);

        initDone = (async () => {
            try {
                await mgr.init(); // attach live sessions (background-warm)
            } catch (err) {
                fatal = `failed to open sessions:\n${err}`;
                app.screen = "app"; // the fatal element lives in #terminals
                throw err;
            }
            // The app lands on the manager (screen starts at "home") — an
            // overview of your work, not a shell.
        })();

        return () => {
            unTheme();
            window.removeEventListener("keydown", onKeydown, {capture: true});
            window.removeEventListener("focusin", onFocusIn);
            ro.disconnect();
            clearInterval(attnTimer);
            clearInterval(moneyTimer);
            clearInterval(wsTimer);
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
    />
{/if}

<!-- always mounted: terminals live here; visibility is a display toggle,
     never {#if}. flex/hidden are toggled explicitly so exactly one display
     utility is ever active (a raw [hidden] attr would lose to .flex). -->
<div class={["min-h-0 flex-1 flex-col", app.screen === "app" ? "flex" : "hidden"]}>
    <Titlebar
        onpicker={() => (app.pickerOpen = true)}
        ondashboard={toggleDash}
        oninbox={() => (app.inboxOpen = !app.inboxOpen)}
        onactivate={(id) => mgr.activateId(id)}
        onnew={() => void mgr.newSession()}
        onpalette={() => registry.run("palette.toggle")}
    />
    <div class="flex min-h-0 min-w-0 flex-1">
        <SidePane
            side="left"
            visible={app.explorerOpen}
            title="Explorer"
            onclose={() => (app.explorerOpen = false)}
        >
            <FileExplorer
                {api}
                workspace={app.workspace}
                active={app.focusZone === "left"}
                onopen={(path) => void openFile(path)}
            />
        </SidePane>
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
</div>

{#if app.paletteOpen}
    <Palette
        {registry}
        onclose={() => {
            app.paletteOpen = false;
            focusBack();
        }}
    />
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
    <FilePicker
        {api}
        onopen={(path) => void openFile(path)}
        onclose={() => {
            app.filePickerOpen = false;
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
        currentWorkspace={app.workspace}
        onspawn={spawn}
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
