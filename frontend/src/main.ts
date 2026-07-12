import {Terminal} from "@xterm/xterm";
import {FitAddon} from "@xterm/addon-fit";
import {WebglAddon} from "@xterm/addon-webgl";
import "@xterm/xterm/css/xterm.css";
import {Call} from "@wailsio/runtime";
import {Service as Config} from "../bindings/github.com/incantery/rook/internal/config";
import {Service as Host} from "../bindings/github.com/incantery/rook/internal/hostclient";
import {HostAPI} from "./hostapi";
import {Tabs} from "./tabs";
import {Registry} from "./registry";
import {Palette} from "./palette";
import {WorkspacePicker} from "./picker";
import {Home} from "./home";
import {Dashboard} from "./dashboard";
import {Inbox} from "./inbox";
import {KeyModal} from "./settings";
import {shellQuote, SpawnModal} from "./spawn";

// Renderer A/B switch: WebGL showed stale-frame artifacts in WKWebView, so
// the DOM renderer is the default until that's re-judged.
// devtools: localStorage.setItem("rook.renderer", "webgl"); location.reload()
const useWebgl = localStorage.getItem("rook.renderer") === "webgl";

// Material Ocean, matching the ghostty theme. Background fully transparent:
// the page body paints the tint once, full-bleed, at the config's opacity.
const THEME = {
    background: "#00000000",
    foreground: "#8f93a2",
    cursor: "#ffcc00",
    selectionBackground: "#717cb4",
    black: "#546e7a",
    red: "#ff5370",
    green: "#c3e88d",
    yellow: "#ffcb6b",
    blue: "#82aaff",
    magenta: "#c792ea",
    cyan: "#89ddff",
    white: "#eeffff",
    brightBlack: "#546e7a",
    brightRed: "#ff5370",
    brightGreen: "#c3e88d",
    brightYellow: "#ffcb6b",
    brightBlue: "#82aaff",
    brightMagenta: "#c792ea",
    brightCyan: "#89ddff",
    brightWhite: "#ffffff",
};

function fatal(msg: string): void {
    const el = document.createElement("div");
    el.id = "fatal";
    el.textContent = msg;
    document.getElementById("terminals")!.appendChild(el);
}

async function main() {
    const cfg = await Config.Get();
    console.info("config loaded:", JSON.stringify(cfg));
    const font = `"${cfg.fontFamily}", Menlo, ui-monospace, monospace`;
    document.body.style.background = `rgba(15, 17, 26, ${cfg.backgroundOpacity})`;

    // Measure with the real font: a grid computed from fallback-font cell
    // metrics spawns PTYs at the wrong size.
    try {
        await document.fonts.load(`${cfg.fontSize}px ${font}`);
    } catch {
        // onopen size sync corrects the grid if this races
    }

    const mkTerm = () => {
        const term = new Terminal({
            allowProposedApi: true,
            allowTransparency: true,
            cursorBlink: true,
            fontFamily: font,
            fontSize: cfg.fontSize,
            scrollback: 10_000,
            macOptionIsMeta: true,
            theme: THEME,
        });
        const fit = new FitAddon();
        term.loadAddon(fit);
        if (useWebgl) {
            try {
                const webgl = new WebglAddon();
                webgl.onContextLoss(() => webgl.dispose());
                term.loadAddon(webgl);
            } catch (err) {
                console.warn("WebGL addon failed, DOM renderer", err);
            }
        }
        return {term, fit};
    };

    // The host daemon owns the shells; the app only discovers it. Sessions
    // (and your scrollback tail) survive app restarts and config reloads.
    let api: HostAPI;
    try {
        const info = await Host.Info();
        api = new HostAPI(info.endpoint, info.token);
    } catch (err) {
        fatal(`rook-host unavailable:\n${err}`);
        return;
    }

    const tabs = new Tabs(document.getElementById("tabs")!, document.getElementById("terminals")!, api, mkTerm);
    // Where the dashboard sits in the strip (config dashboard-tab, default
    // 1); shell windows number from the next slot, and ` <n> / ⌘<n> follow.
    const dashTab = cfg.dashboardTab;
    tabs.dashTab = dashTab;
    const appScreen = document.getElementById("app-screen")!;

    // ==== screens: home (workspace manager) ⇄ workspace terminals ====
    const home = new Home(api, (name) => void showWorkspace(name));
    async function showWorkspace(name: string): Promise<void> {
        home.hide();
        appScreen.hidden = false; // visible before openWorkspace: fit needs real dimensions
        try {
            await tabs.openWorkspace(name);
        } catch (err) {
            console.error("failed to open workspace", name, err);
            showHome();
            home.showError(`Couldn't open "${name}": ${err}`);
        }
    }
    function showHome(): void {
        dash.hide();
        appScreen.hidden = true;
        void home.show();
    }
    // A workspace's last shell exiting lands you back in the manager.
    tabs.onWorkspaceGone = showHome;

    const registry = new Registry();
    // Window 0 of every workspace: the dashboard. Activating any real
    // window dismisses it.
    const dash = new Dashboard(api, tabs, (id) => void registry.run(id));
    dash.onJump = (i) => tabs.switchTo(i);
    tabs.onActivate = () => dash.hide();
    tabs.onDashboard = () => dash.toggle();
    const palette = new Palette(registry, () => tabs.focusActive());
    const picker = new WorkspacePicker(
        tabs,
        (name) => void showWorkspace(name),
        showHome,
        () => tabs.focusActive(),
    );
    // The attention inbox: cross-workspace "who's waiting on you", with the
    // drafter's replies once rook-agent runs (docs/agent.md).
    const inbox = new Inbox(
        api,
        (sessionId) => {
            home.hide();
            appScreen.hidden = false;
            if (!tabs.switchToId(sessionId)) console.warn("inbox jump: window is gone", sessionId);
        },
        () => tabs.focusActive(),
    );
    inbox.dashTab = dashTab;
    const keyModal = new KeyModal(() => tabs.focusActive());
    const spawnModal = new SpawnModal(
        () => tabs.workspace,
        async (task, workspace) => {
            home.hide();
            appScreen.hidden = false;
            const id = await tabs.spawnIn(workspace);
            // let the shell come up before typing the command
            setTimeout(() => {
                api.sendInput(id, `claude ${shellQuote(task)}\r`).catch((err) => {
                    console.error("spawn: sending claude command failed", err);
                });
            }, 400);
        },
        () => tabs.focusActive(),
    );

    // Titlebar breadcrumb: current workspace, click to switch (design's
    // workspace switcher affordance).
    const wsLabel = document.getElementById("ws-label")!;
    tabs.onChange = () => {
        wsLabel.textContent = tabs.workspace;
    };
    wsLabel.addEventListener("click", () => picker.open());
    registry.register(
        {id: "palette.toggle", title: "Command palette", category: "View", keys: "⌘K", run: () => palette.toggle()},
        {id: "session.new", title: "New window (inherits cwd)", category: "Session", keys: "` c", run: () => tabs.newSession()},
        {id: "session.close", title: "Kill window", category: "Session", keys: "` x", run: () => tabs.closeActive()},
        {id: "session.next", title: "Next window", category: "Session", keys: "⌘⇧]", run: () => tabs.next()},
        {id: "session.prev", title: "Previous window", category: "Session", keys: "⌘⇧[", run: () => tabs.prev()},
        {id: "config.reload", title: "Reload config", category: "Config", keys: "` r", run: () => location.reload()},
        {id: "config.openai-key", title: "Set OpenAI API key (agent)", category: "Config", run: () => keyModal.open()},
        {id: "workspace.switch", title: "Switch workspace…", category: "Workspace", keys: "` s", run: () => picker.open()},
        {id: "workspace.manager", title: "Workspace manager", category: "Workspace", keys: "` h", run: showHome},
        {id: "workspace.dashboard", title: "Workspace dashboard", category: "Workspace", keys: "` d", run: () => dash.toggle()},
        {id: "attention.inbox", title: "Attention inbox", category: "View", keys: "` a", run: () => inbox.toggle()},
        {id: "agent.spawn", title: "New agent session (claude on a task)", category: "Session", keys: "` n", run: () => spawnModal.open()},
        {id: "workspace.scratch", title: "New scratch shell", category: "Workspace", run: () => home.scratch()},
        {
            id: "workspace.set-root",
            title: "Set workspace root to shell's directory",
            category: "Workspace",
            keys: "` .",
            run: async () => {
                const id = tabs.activeId;
                if (!id) return;
                // failures must be VISIBLE: this flow once died silently on
                // a stale daemon 404ing the cwd endpoint
                const flash = (msg: string) => {
                    const prev = tabs.workspace;
                    wsLabel.textContent = msg;
                    setTimeout(() => (wsLabel.textContent = prev), 2500);
                };
                try {
                    const cwd = await api.sessionCwd(id);
                    if (!cwd) throw new Error("host couldn't resolve the shell's cwd");
                    await api.createWorkspace(tabs.workspace, cwd); // upsert keeps everything else
                    flash(`root → ${cwd}`);
                } catch (err) {
                    console.error("set-root failed", err);
                    flash("set-root failed — see console");
                }
            },
        },
    );
    document.getElementById("palette-btn")!.addEventListener("click", () => registry.run("palette.toggle"));

    // ==== keybindings — two layers, both dispatching registry commands ====
    //
    // 1. The backtick prefix, straight from the tmux config (`set -g
    //    prefix \``): ` arms, the next key acts. `` sends a literal
    //    backtick (tmux `bind \` send-prefix`). `c new window (cwd
    //    inherited), `r reload config, `1-9 select window.
    // 2. macOS chords (⌘K palette etc.) as a native-feeling complement.
    const pill = document.getElementById("prefix-pill")!;
    let prefixArmed = false;
    const setPrefix = (v: boolean) => {
        prefixArmed = v;
        pill.hidden = !v;
    };

    window.addEventListener(
        "keydown",
        (e) => {
            if (inbox.visible) return; // inbox's capture handler owns keys
            if (keyModal.visible || spawnModal.visible) return; // modals own their keys
            if (palette.visible) {
                if (e.metaKey && e.code === "KeyK") {
                    e.preventDefault();
                    palette.close();
                }
                return; // palette's own input handles the rest
            }
            if (picker.visible) return; // picker's own input handles keys
            if (home.visible) {
                // no terminal on screen: only the palette chord and the
                // workspace switcher make sense here
                if (e.metaKey && e.code === "KeyK") {
                    e.preventDefault();
                    registry.run("palette.toggle");
                }
                return;
            }

            if (prefixArmed) {
                if (e.key === "Shift" || e.key === "Meta" || e.key === "Alt" || e.key === "Control") return;
                e.preventDefault();
                e.stopPropagation();
                setPrefix(false);
                if (e.key === "`") tabs.sendToActive("`");
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
                else if (/^[0-9]$/.test(e.key) && Number(e.key) > dashTab) tabs.switchTo(Number(e.key) - dashTab - 1);
                // anything else: prefix consumed, key ignored — tmux behavior
                return;
            }
            if (e.key === "`" && !e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey) {
                e.preventDefault();
                e.stopPropagation();
                setPrefix(true);
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
                else if (n > dashTab) tabs.switchTo(n - dashTab - 1);
                return;
            }
            if (id) {
                e.preventDefault();
                e.stopPropagation();
                registry.run(id);
            }
        },
        {capture: true},
    );

    new ResizeObserver(() => tabs.syncSize()).observe(document.getElementById("terminals")!);

    // Attention poll, global: one GET /attention feeds every surface —
    // the pulsing strip numbers, the titlebar chip, the manager's cards,
    // the dashboard's draft hints, and macOS notifications. This is the
    // attention router's surface (docs/agent.md milestone 1) — pure
    // plumbing, no model anywhere in the app.
    const attnChip = document.getElementById("attn-chip")!;
    attnChip.addEventListener("click", () => inbox.toggle());
    // one notification per ask, ever — (sessionId, askSeq) is the identity
    const seenAsks = new Set<string>();
    const notify = (title: string, body: string) =>
        Call.ByName("github.com/incantery/rook/internal/notify.Service.Notify", title, body).catch(
            (err: unknown) => console.warn("notification failed", err),
        );
    setInterval(async () => {
        let items;
        try {
            items = await api.attention();
        } catch {
            return; // host briefly unreachable — keep the last known state
        }
        tabs.setAttention(
            new Set(items.filter((i) => i.workspace === tabs.workspace).map((i) => i.rookSession)),
        );
        attnChip.hidden = items.length === 0;
        attnChip.textContent = `◉ ${items.length}`;
        const counts = new Map<string, number>();
        for (const it of items) counts.set(it.workspace, (counts.get(it.workspace) ?? 0) + 1);
        home.setAttention(counts);
        dash.setAttention(items);
        for (const it of items) {
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
        const live = new Set(items.map((i) => `${i.agentSession}:${i.askSeq}`));
        for (const k of seenAsks) if (!live.has(k)) seenAsks.delete(k);
    }, 5000);

    // Usage chip: the tightest subscription window, from the host's
    // cost-weighted prober. The chip shows the worst number; hover for all
    // windows and their reset times. Hidden until the first probe lands
    // (or forever, on API billing / no claude on PATH).
    const usageChip = document.getElementById("usage-chip")!;
    const shortWindow = (label: string) =>
        label === "session" ? "5h" : label.startsWith("week (all") ? "wk" : label.replace(/^week \((.+)\)$/i, "$1").toLowerCase();
    const pollUsage = async () => {
        let u;
        try {
            u = await api.usage();
        } catch {
            return; // host briefly unreachable — keep the last known chip
        }
        if (!u.windows.length) {
            usageChip.hidden = true;
            return;
        }
        const worst = u.windows.reduce((a, b) => (b.pct > a.pct ? b : a));
        usageChip.hidden = false;
        usageChip.textContent = `${worst.pct}% ${shortWindow(worst.label)}`;
        usageChip.title = u.windows.map((w) => `${w.label}: ${w.pct}% — resets ${w.resets}`).join("\n");
        usageChip.classList.toggle("warn", worst.pct >= 70 && worst.pct < 90);
        usageChip.classList.toggle("hot", worst.pct >= 90);
    };
    void pollUsage();
    setInterval(pollUsage, 60_000);

    try {
        await tabs.init(); // attach live sessions (background-warm)
    } catch (err) {
        fatal(`failed to open sessions:\n${err}`);
        return;
    }
    // Land on the manager — the app opens to an overview of your work,
    // not into a shell.
    showHome();
}

void main();
