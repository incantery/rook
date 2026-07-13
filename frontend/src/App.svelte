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
    import {Registry} from "./registry";
    import {buildKeymap, sigOf} from "./keymap";
    import {app} from "./state.svelte";
    import {shellQuote} from "./util";
    import Titlebar from "./Titlebar.svelte";
    import Dashboard from "./Dashboard.svelte";
    import Home from "./Home.svelte";
    import Palette from "./Palette.svelte";
    import Picker from "./Picker.svelte";
    import FilePicker from "./FilePicker.svelte";
    import Inbox from "./Inbox.svelte";
    import SpawnModal from "./SpawnModal.svelte";
    import KeyModal from "./KeyModal.svelte";

    interface Props {
        api: HostAPI;
        mkTerm: TermFactory;
        dashTab: number;
        keybinds: Record<string, string | undefined>;
        /** the config font, for the Monaco pane (terminals get it via mkTerm) */
        paneFont: {family: string; size: number};
    }
    let {api, mkTerm, dashTab, keybinds, paneFont}: Props = $props();
    // svelte-ignore state_referenced_locally — dashTab is config, fixed for the app's lifetime
    app.dashTab = dashTab;
    // config-fixed like dashTab: ` r reloads the page, which re-reads it
    // svelte-ignore state_referenced_locally
    const keymap = buildKeymap(keybinds);

    let terminalsEl: HTMLElement;
    let home = $state<Home | null>(null);
    let fatal = $state("");
    // assigned once in onMount, before any interaction can read it
    let mgr: TermManager = $state() as unknown as TermManager;
    const registry = new Registry();

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

    /** Open a Monaco pane as a NEW window on the strip (it's a pane, so
     *  ` % splits a terminal in beside it). The EditorPane is constructed
     *  here — the manager stays Monaco-free. */
    async function openEditorPane(kind: "review" | "file", path?: string): Promise<void> {
        try {
            await initDone;
            // the showWorkspace dance: activation fits and focuses, and
            // both silently no-op on a display:none subtree
            app.screen = "app";
            await tick();
            const {EditorPane} = await import("./term/editor");
            mgr.openPaneWindow(
                () =>
                    new EditorPane(api, {
                        workspace: app.workspace,
                        kind,
                        path,
                        font: paneFont,
                        onFlash: flash,
                        onClose: () => void mgr.closeActive(),
                    }),
            );
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
            run: () => mgr.focusPane("left"),
        },
        {
            id: "pane.focus-right",
            title: "Focus pane right",
            category: "Pane",
            keys: keymap.display("pane.focus-right"),
            run: () => mgr.focusPane("right"),
        },
        {
            id: "pane.focus-up",
            title: "Focus pane up",
            category: "Pane",
            keys: keymap.display("pane.focus-up"),
            run: () => mgr.focusPane("up"),
        },
        {
            id: "pane.focus-down",
            title: "Focus pane down",
            category: "Pane",
            keys: keymap.display("pane.focus-down"),
            run: () => mgr.focusPane("down"),
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
            id: "config.openai-key",
            title: "Set OpenAI API key (agent)",
            category: "Config",
            run: () => {
                app.keyOpen = true;
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
            run: () => void openEditorPane("review"),
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

    // ==== keybindings — two layers, both dispatching registry commands ====
    //
    // 1. The backtick prefix, straight from the tmux config: ` arms, the
    //    next key acts. `` sends a literal backtick. `1-9 select window.
    // 2. macOS chords (⌘K palette etc.) as a native-feeling complement.
    // Both layers resolve through the keymap (defaults + config `keybind`
    // overrides); only the digit keys and `` stay hardwired here.
    function onKeydown(e: KeyboardEvent): void {
        if (app.inboxOpen) return; // inbox's capture handler owns keys
        if (app.keyOpen || app.spawnOpen) return; // modals own their keys
        if (app.paletteOpen) {
            if (keymap.chords.get(sigOf(e)) === "palette.toggle") {
                e.preventDefault();
                app.paletteOpen = false;
            }
            return; // palette's own input handles the rest
        }
        if (app.pickerOpen || app.filePickerOpen) return; // pickers' own inputs handle keys
        if (app.screen === "home") {
            // the prefix works here too, so ` h toggles back to the
            // workspace you left — but never while typing in a modal input
            const el = e.target as HTMLElement | null;
            const typing =
                el != null &&
                (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.isContentEditable);
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
            if (!typing && e.key === "`" && !e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey) {
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
            if (e.key === "`") mgr.sendToActive("`");
            else if (/^[0-9]$/.test(e.key)) {
                // reserved: the strip digits are computed from dashboard-tab
                if (Number(e.key) === dashTab) registry.run("workspace.dashboard");
                else if (Number(e.key) > dashTab) mgr.switchTo(Number(e.key) - dashTab - 1);
            } else {
                const cmd = keymap.prefix.get(e.key);
                if (cmd) registry.run(cmd);
                // unbound: prefix consumed, key ignored — tmux behavior
            }
            return;
        }
        if (e.key === "`" && !e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey) {
            e.preventDefault();
            e.stopPropagation();
            app.prefixArmed = true;
            return;
        }

        // chords need a real modifier; everything else belongs to the shell
        if (!e.metaKey && !e.ctrlKey && !e.altKey) return;
        if (e.metaKey && !e.shiftKey && !e.ctrlKey && !e.altKey && /^Digit[0-9]$/.test(e.code)) {
            // reserved: ⌘digits mirror the strip, computed from dashboard-tab
            e.preventDefault();
            e.stopPropagation();
            const n = Number(e.code.slice(5));
            if (n === dashTab) registry.run("workspace.dashboard");
            else if (n > dashTab) mgr.switchTo(n - dashTab - 1);
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
                    `${it.workspace} window ${dashTab + 1 + it.window} needs you`,
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
                app.workspace = mgr.workspace;
            },
            workspaceGone: showHome,
            activated: () => (app.dashVisible = false),
        });

        window.addEventListener("keydown", onKeydown, {capture: true});
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
            window.removeEventListener("keydown", onKeydown, {capture: true});
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

<!-- always mounted: terminals live here; visibility is CSS, never {#if} -->
<div id="app-screen" hidden={app.screen !== "app"}>
    <Titlebar
        onpicker={() => (app.pickerOpen = true)}
        ondashboard={toggleDash}
        oninbox={() => (app.inboxOpen = !app.inboxOpen)}
        onactivate={(id) => mgr.activateId(id)}
        onnew={() => void mgr.newSession()}
        onpalette={() => registry.run("palette.toggle")}
    />
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
        onopen={(path) => void openEditorPane("file", path)}
        onclose={() => {
            app.filePickerOpen = false;
            focusBack();
        }}
    />
{/if}
{#if app.inboxOpen}
    <Inbox
        {api}
        {dashTab}
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
{#if app.keyOpen}
    <KeyModal
        onclose={() => {
            app.keyOpen = false;
            focusBack();
        }}
    />
{/if}
