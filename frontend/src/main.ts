import {Terminal} from "@xterm/xterm";
import {FitAddon} from "@xterm/addon-fit";
import {WebglAddon} from "@xterm/addon-webgl";
import "@xterm/xterm/css/xterm.css";
import {Service as Config} from "../bindings/github.com/incantery/rook/internal/config";
import {Service as Host} from "../bindings/github.com/incantery/rook/internal/hostclient";
import {HostAPI} from "./hostapi";
import {Tabs} from "./tabs";
import {Registry} from "./registry";
import {Palette} from "./palette";

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

    const registry = new Registry();
    const palette = new Palette(registry, () => tabs.focusActive());
    registry.register(
        {id: "palette.toggle", title: "Command palette", category: "View", keys: "⌘K", run: () => palette.toggle()},
        {id: "session.new", title: "New session", category: "Session", keys: "⌘T", run: () => tabs.newSession()},
        {id: "session.close", title: "Close session", category: "Session", run: () => tabs.closeActive()},
        {id: "session.next", title: "Next session", category: "Session", keys: "⌘⇧]", run: () => tabs.next()},
        {id: "session.prev", title: "Previous session", category: "Session", keys: "⌘⇧[", run: () => tabs.prev()},
        {id: "config.reload", title: "Reload config", category: "Config", keys: "⌘⇧,", run: () => location.reload()},
    );
    document.getElementById("palette-btn")!.addEventListener("click", () => registry.run("palette.toggle"));

    // Keybindings dispatch commands — nothing acts directly. e.code for
    // physical keys (shift+comma is "<", shift+] is "}" in e.key terms).
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
