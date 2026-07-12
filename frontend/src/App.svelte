<!-- The app shell: screens (manager ⇄ workspace terminals), overlays, the
     command registry, the two-layer keybinding ladder, and the host polls.
     The terminal runtime is created here but lives outside Svelte — this
     component renders the container div once and never conditionally
     unmounts it (screen switches are the `hidden` attribute, i.e. CSS). -->
<script lang="ts">
    import {onMount, tick} from "svelte";
    import {Call} from "@wailsio/runtime";
    import type {HostAPI} from "./hostapi";
    import {TermManager, type TermFactory} from "./term/manager";
    import {Registry} from "./registry";
    import {app} from "./state.svelte";
    import {shellQuote} from "./util";
    import Titlebar from "./Titlebar.svelte";
    import Dashboard from "./Dashboard.svelte";
    import Home from "./Home.svelte";
    import Palette from "./Palette.svelte";
    import Picker from "./Picker.svelte";
    import Inbox from "./Inbox.svelte";
    import SpawnModal from "./SpawnModal.svelte";
    import KeyModal from "./KeyModal.svelte";

    interface Props {
        api: HostAPI;
        mkTerm: TermFactory;
        dashTab: number;
    }
    let {api, mkTerm, dashTab}: Props = $props();
    // svelte-ignore state_referenced_locally — dashTab is config, fixed for the app's lifetime
    app.dashTab = dashTab;

    let terminalsEl: HTMLElement;
    let home = $state<Home | null>(null);
    let fatal = $state("");
    // assigned once in onMount, before any interaction can read it
    let mgr: TermManager = $state() as unknown as TermManager;
    const registry = new Registry();

    // resolved when the manager has attached every live session — opening a
    // workspace before that could double-create its window
    let initDone: Promise<void> = Promise.resolve();

    // ==== screens: home (workspace manager) ⇄ workspace terminals ====
    async function showWorkspace(name: string): Promise<void> {
        try {
            await initDone;
            app.screen = "app";
            // Flush the hidden attr: openWorkspace's activate() fits and
            // focuses, and both silently no-op on a display:none subtree.
            await tick();
            await mgr.openWorkspace(name);
        } catch (err) {
            console.error("failed to open workspace", name, err);
            showHome();
            await tick(); // Home remounts before it can show the error
            home?.showError(`Couldn't open "${name}": ${err}`);
        }
    }
    function showHome(): void {
        app.dashVisible = false;
        app.screen = "home"; // Home remounts and refreshes itself
    }

    function toggleDash(): void {
        app.dashVisible = !app.dashVisible;
        if (!app.dashVisible) mgr.focusActive();
    }

    const focusBack = () => mgr.focusActive();

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

    registry.register(
        {id: "palette.toggle", title: "Command palette", category: "View", keys: "⌘K", run: () => {
            app.paletteOpen = !app.paletteOpen;
        }},
        {id: "session.new", title: "New window (inherits cwd)", category: "Session", keys: "` c", run: () => void mgr.newSession()},
        {id: "session.close", title: "Kill window", category: "Session", keys: "` x", run: () => void mgr.closeActive()},
        {id: "session.next", title: "Next window", category: "Session", keys: "⌘⇧]", run: () => mgr.next()},
        {id: "session.prev", title: "Previous window", category: "Session", keys: "⌘⇧[", run: () => mgr.prev()},
        {id: "config.reload", title: "Reload config", category: "Config", keys: "` r", run: () => location.reload()},
        {id: "config.openai-key", title: "Set OpenAI API key (agent)", category: "Config", run: () => {
            app.keyOpen = true;
        }},
        {id: "workspace.switch", title: "Switch workspace…", category: "Workspace", keys: "` s", run: () => {
            app.pickerOpen = true;
        }},
        {id: "workspace.manager", title: "Workspace manager", category: "Workspace", keys: "` h", run: showHome},
        {id: "workspace.dashboard", title: "Workspace dashboard", category: "Workspace", keys: "` d", run: toggleDash},
        {id: "attention.inbox", title: "Attention inbox", category: "View", keys: "` a", run: () => {
            app.inboxOpen = !app.inboxOpen;
        }},
        {id: "agent.spawn", title: "New agent session (claude on a task)", category: "Session", keys: "` n", run: () => {
            app.spawnOpen = true;
        }},
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
                void showWorkspace(`scratch-${n}`);
            },
        },
        {
            id: "workspace.set-root",
            title: "Set workspace root to shell's directory",
            category: "Workspace",
            keys: "` .",
            run: async () => {
                const id = mgr.activeId;
                if (!id) return;
                // failures must be VISIBLE: this flow once died silently on
                // a stale daemon 404ing the cwd endpoint
                const flash = (msg: string) => {
                    const prev = app.workspace;
                    app.workspace = msg;
                    setTimeout(() => (app.workspace = prev), 2500);
                };
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
    //    next key acts. `` sends a literal backtick. `c new window,
    //    `r reload config, `1-9 select window.
    // 2. macOS chords (⌘K palette etc.) as a native-feeling complement.
    function onKeydown(e: KeyboardEvent): void {
        if (app.inboxOpen) return; // inbox's capture handler owns keys
        if (app.keyOpen || app.spawnOpen) return; // modals own their keys
        if (app.paletteOpen) {
            if (e.metaKey && e.code === "KeyK") {
                e.preventDefault();
                app.paletteOpen = false;
            }
            return; // palette's own input handles the rest
        }
        if (app.pickerOpen) return; // picker's own input handles keys
        if (app.screen === "home") {
            // no terminal on screen: only the palette chord and the
            // workspace switcher make sense here
            if (e.metaKey && e.code === "KeyK") {
                e.preventDefault();
                registry.run("palette.toggle");
            }
            return;
        }

        if (app.prefixArmed) {
            if (e.key === "Shift" || e.key === "Meta" || e.key === "Alt" || e.key === "Control") return;
            e.preventDefault();
            e.stopPropagation();
            app.prefixArmed = false;
            if (e.key === "`") mgr.sendToActive("`");
            else if (e.key === "c") registry.run("session.new");
            else if (e.key === "x") registry.run("session.close");
            else if (e.key === "r") registry.run("config.reload");
            else if (e.key === "k") registry.run("palette.toggle");
            else if (e.key === "s") registry.run("workspace.switch");
            else if (e.key === "a") registry.run("attention.inbox");
            else if (e.key === "n") registry.run("agent.spawn");
            else if (e.key === "h") registry.run("workspace.manager");
            else if (e.key === ".") registry.run("workspace.set-root");
            else if (e.key === "d" || e.key === String(dashTab)) registry.run("workspace.dashboard");
            else if (/^[0-9]$/.test(e.key) && Number(e.key) > dashTab) mgr.switchTo(Number(e.key) - dashTab - 1);
            // anything else: prefix consumed, key ignored — tmux behavior
            return;
        }
        if (e.key === "`" && !e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey) {
            e.preventDefault();
            e.stopPropagation();
            app.prefixArmed = true;
            return;
        }

        if (!e.metaKey) return;
        let id: string | null = null;
        if (e.code === "KeyK" && !e.shiftKey) id = "palette.toggle";
        else if (e.code === "KeyT" && !e.shiftKey) id = "session.new";
        else if (e.code === "BracketRight" && e.shiftKey) id = "session.next";
        else if (e.code === "BracketLeft" && e.shiftKey) id = "session.prev";
        else if (e.code === "Comma" && e.shiftKey) id = "config.reload";
        else if (/^Digit[0-9]$/.test(e.code) && !e.shiftKey) {
            e.preventDefault();
            e.stopPropagation();
            const n = Number(e.code.slice(5));
            if (n === dashTab) registry.run("workspace.dashboard");
            else if (n > dashTab) mgr.switchTo(n - dashTab - 1);
            return;
        }
        if (id) {
            e.preventDefault();
            e.stopPropagation();
            registry.run(id);
        }
    }

    // ==== host polls: attention (5s) and usage/costs (30s), into the
    // store — every surface reads the same snapshot. Pure plumbing, no
    // model anywhere in the app (docs/agent.md milestone 1). ====
    const seenAsks = new Set<string>(); // one notification per ask, ever
    const notify = (title: string, body: string) =>
        Call.ByName("github.com/incantery/rook/internal/notify.Service.Notify", title, body).catch((err: unknown) =>
            console.warn("notification failed", err),
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
        const attnTimer = setInterval(() => void pollAttention(), 5000);
        const moneyTimer = setInterval(() => void pollMoney(), 30_000);

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
        };
    });
</script>

{#if app.screen === "home"}
    <Home {api} bind:this={home} onopen={(name) => void showWorkspace(name)} />
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
            <Dashboard {api} onjump={(i) => mgr.switchTo(i)} runCmd={(id) => registry.run(id)} />
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
        onpick={(name) => void showWorkspace(name)}
        onmanager={showHome}
        onclose={() => {
            app.pickerOpen = false;
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
