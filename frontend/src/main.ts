// Boot: load config, size the theme, discover the host daemon, and mount
// the Svelte app. The terminal factory lives here because it needs the
// config's font before any component exists.

import {mount} from "svelte";
import {Terminal} from "@xterm/xterm";
import {FitAddon} from "@xterm/addon-fit";
import {WebglAddon} from "@xterm/addon-webgl";
import "@xterm/xterm/css/xterm.css";
import "./app.css";
import {Service as Config} from "../bindings/github.com/incantery/rook/internal/config";
import {Service as Host} from "../bindings/github.com/incantery/rook/internal/hostclient";
import {HostAPI} from "./hostapi";
import {themeService} from "./theme/service";
import App from "./App.svelte";

// Renderer A/B switch: WebGL showed stale-frame artifacts in WKWebView, so
// the DOM renderer is the default until that's re-judged.
// devtools: localStorage.setItem("rook.renderer", "webgl"); location.reload()
const useWebgl = localStorage.getItem("rook.renderer") === "webgl";

function fatal(msg: string): void {
    const el = document.createElement("div");
    el.id = "fatal";
    el.textContent = msg;
    document.getElementById("app")!.appendChild(el);
}

async function main() {
    const cfg = await Config.Get();
    console.info("config loaded:", JSON.stringify(cfg));
    const font = `"${cfg.fontFamily}", Menlo, ui-monospace, monospace`;
    // paint chrome + the body tint from the active theme before anything mounts
    themeService.setOpacity(cfg.backgroundOpacity);
    themeService.apply(cfg.theme); // no-op if the name is unknown
    themeService.applyChrome(); // idempotent; guarantees the paint either way

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
            theme: themeService.xtermTheme(),
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

    mount(App, {
        target: document.getElementById("app")!,
        props: {
            api,
            mkTerm,
            keybinds: cfg.keybinds ?? {},
            leader: cfg.leader,
            paneFont: {family: font, size: cfg.fontSize},
        },
    });
}

void main();
