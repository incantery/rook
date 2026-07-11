import {Terminal} from "@xterm/xterm";
import {FitAddon} from "@xterm/addon-fit";
import {WebglAddon} from "@xterm/addon-webgl";
import "@xterm/xterm/css/xterm.css";
import {Window} from "@wailsio/runtime";
import {Service as Config} from "../bindings/github.com/incantery/rook/internal/config";
import {Service as Host} from "../bindings/github.com/incantery/rook/internal/hostclient";
import {HostAPI} from "./hostapi";
import {Tabs} from "./tabs";
import {Registry} from "./registry";
import {Palette} from "./palette";
import {WorkspacePicker} from "./picker";

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
    // Last session ended → the client ends, like tmux. Shell exits fully
    // discard their session; nothing respawns behind your back.
    tabs.onEmpty = () => void Window.Close();

    const registry = new Registry();
    const palette = new Palette(registry, () => tabs.focusActive());
    const picker = new WorkspacePicker(tabs, () => tabs.focusActive());

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
        {id: "workspace.switch", title: "Switch workspace…", category: "Workspace", keys: "` s", run: () => picker.open()},
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
            if (palette.visible) {
                if (e.metaKey && e.code === "KeyK") {
                    e.preventDefault();
                    palette.close();
                }
                return; // palette's own input handles the rest
            }
            if (picker.visible) return; // picker's own input handles keys

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
                else if (/^[1-9]$/.test(e.key)) tabs.switchTo(Number(e.key) - 1);
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
            else if (/^Digit[1-9]$/.test(e.code) && !e.shiftKey) {
                e.preventDefault();
                e.stopPropagation();
                tabs.switchTo(Number(e.code.slice(5)) - 1);
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

    try {
        await tabs.init();
    } catch (err) {
        fatal(`failed to open sessions:\n${err}`);
    }
}

void main();
