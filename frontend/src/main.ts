// Boot: load config, size the theme, discover the host daemon, and mount
// the Svelte app. The terminal factory lives here because it needs the
// config's font before any component exists.

import {mount} from "svelte";
import "./app.css";
import {Service as Config} from "../bindings/github.com/incantery/rook/internal/config";
import {Service as Host} from "../bindings/github.com/incantery/rook/internal/hostclient";
import {HostAPI} from "./hostapi";
import {loadCanvasFonts} from "./term/vt/registry";
import {themeService} from "./theme/service";
import App from "./App.svelte";

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

    // The terminal renderer (term/vt) reads its font from these; set once, on
    // :root, so every pane inherits it. Colors come from the theme's --term-*.
    const root = document.documentElement.style;
    root.setProperty("--vt-font", font);
    root.setProperty("--vt-font-size", `${cfg.fontSize}px`);

    // The CHROME follows the configured size too: every Tailwind text/size
    // utility (and the app.css chrome islands) is rem-based, so the root
    // font-size is the one scale knob — the whole chrome zooms coherently,
    // text and geometry together. Terminal + Monaco take their px size
    // directly (above / paneFont) and are untouched by this. Clamped so a
    // typo'd config can't render the chrome unusable.
    document.documentElement.style.fontSize = `${Math.min(28, Math.max(10, cfg.fontSize))}px`;

    // WebGL only: hand the canvas a FontFace copy of the terminal font —
    // WebKit's fillText can't see user-installed fonts (see registry.ts).
    // Must land before the atlas rasterizes, i.e. before any pane exists.
    await loadCanvasFonts(cfg.fontFamily);

    // Measure with the real font: a grid computed from fallback-font cell
    // metrics spawns PTYs at the wrong size.
    try {
        await document.fonts.load(`${cfg.fontSize}px ${font}`);
    } catch {
        // onopen size sync corrects the grid if this races
    }

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
            keybinds: cfg.keybinds ?? {},
            leader: cfg.leader,
            editorLeader: cfg.editorLeader,
            editorKeybinds: cfg.editorKeybinds?.normal ?? {},
            commandAliases: cfg.commands ?? {},
            paneFont: {family: font, size: cfg.fontSize},
        },
    });
}

void main();
