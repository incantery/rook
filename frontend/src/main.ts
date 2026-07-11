import {Terminal} from "@xterm/xterm";
import {FitAddon} from "@xterm/addon-fit";
import {WebglAddon} from "@xterm/addon-webgl";
import "@xterm/xterm/css/xterm.css";
import {Service as Session} from "../bindings/github.com/incantery/rook/internal/session";
import {Service as Config} from "../bindings/github.com/incantery/rook/internal/config";

// Renderer A/B switch: WebGL showed stale-frame artifacts in WKWebView after
// window resizes, so the DOM renderer is the default until that's understood.
// In devtools: localStorage.setItem("rook.renderer", "webgl"); location.reload()
const useWebgl = localStorage.getItem("rook.renderer") === "webgl";
// localStorage.setItem("rook.debug", "1") logs the first PTY chunks per
// session — the tool for "where did that stray glyph come from" questions.
const debug = localStorage.getItem("rook.debug") === "1";

// Material Ocean, matching the ghostty theme. The background is fully
// transparent: the page body paints the tint (once, full-bleed, with the
// config's background-opacity); xterm only paints non-default cell
// backgrounds over it.
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

let term!: Terminal;
let fit!: FitAddon;
let ws: WebSocket | null = null;
let sessionId: string | null = null;
let spawnedAt = 0;
let lastSentSize = "";

// The single authority on terminal size. fit() derives the grid from the
// container and *measured* cell metrics; the PTY is then told, explicitly.
// Relying on term.onResize dropped syncs in two ways: resizes while the
// socket was still connecting were discarded, and a PTY spawned from stale
// (fallback-font) metrics never re-synced because xterm's own size hadn't
// changed. Divergence looks like: fzf "full screen" ending mid-window
// (PTY rows < grid rows), zsh's PROMPT_SP % mark surviving on its own line
// (PTY cols > grid cols).
function syncSize(force = false) {
    fit.fit();
    if (sessionId === null) return;
    const key = `${sessionId}:${term.cols}x${term.rows}`;
    if (!force && key === lastSentSize) return;
    lastSentSize = key;
    Session.Resize(sessionId, term.cols, term.rows).catch((err) => {
        console.error("resize failed", err);
    });
}

async function spawn() {
    sessionId = null;
    spawnedAt = Date.now();
    const endpoint = await Session.Endpoint();
    const id = await Session.Spawn(term.cols, term.rows);
    let debugChunks = debug ? 3 : 0;

    const socket = new WebSocket(`${endpoint}/session/${id}`);
    socket.binaryType = "arraybuffer";
    socket.onopen = () => {
        sessionId = id;
        ws = socket;
        // Authoritative size sync: the window may have resized while the
        // socket was connecting, and spawn-time metrics may have been stale.
        syncSize(true);
        term.focus();
    };
    socket.onmessage = (e: MessageEvent<ArrayBuffer>) => {
        const bytes = new Uint8Array(e.data);
        if (debugChunks > 0) {
            debugChunks--;
            console.debug(`pty[${id}] chunk:`, JSON.stringify(new TextDecoder().decode(bytes)));
        }
        term.write(bytes);
    };
    socket.onclose = () => {
        if (sessionId !== id) return; // superseded by a newer session
        sessionId = null;
        ws = null;
        // Instant exit means the shell itself is broken — don't respawn-loop.
        if (Date.now() - spawnedAt < 1000) {
            term.writeln("\r\n\x1b[31m[shell exited immediately — not restarting]\x1b[0m");
            return;
        }
        term.writeln("\r\n\x1b[90m[shell exited — restarting]\x1b[0m");
        void spawn();
    };
}

async function main() {
    // ~/.config/rook/config; re-read on every page reload (cmd+r applies
    // edits without an app restart).
    const cfg = await Config.Get();
    console.info("config loaded:", JSON.stringify(cfg));
    const font = `"${cfg.fontFamily}", Menlo, ui-monospace, monospace`;

    document.body.style.background = `rgba(15, 17, 26, ${cfg.backgroundOpacity})`;

    const container = document.getElementById("terminal")!;
    // Top inset stays fixed: it's the drag region under the traffic lights
    // (InvisibleTitleBarHeight in main.go), not user padding.
    container.style.inset = `34px ${cfg.windowPaddingX}px ${cfg.windowPaddingY}px`;

    // Measure with the real font: fit() before it loads would compute the
    // grid from fallback-font cell metrics and spawn the PTY at the wrong
    // size.
    try {
        await document.fonts.load(`${cfg.fontSize}px ${font}`);
    } catch {
        // fall through — worst case the onopen sync corrects the grid
    }

    term = new Terminal({
        allowProposedApi: true,
        allowTransparency: true,
        cursorBlink: true,
        fontFamily: font,
        fontSize: cfg.fontSize,
        scrollback: 10_000,
        macOptionIsMeta: true,
        theme: THEME,
    });
    fit = new FitAddon();
    term.loadAddon(fit);
    term.open(container);
    if (useWebgl) {
        try {
            const webgl = new WebglAddon();
            webgl.onContextLoss(() => webgl.dispose());
            term.loadAddon(webgl);
            console.info("renderer: webgl");
        } catch (err) {
            console.warn("WebGL addon failed, falling back to DOM renderer", err);
        }
    } else {
        console.info("renderer: dom (set localStorage rook.renderer=webgl to A/B)");
    }
    fit.fit();

    term.onData((data) => {
        ws?.send(data);
    });

    // cmd+shift+, reloads the page — ghostty's reload_config binding. The
    // whole frontend re-runs, so Config.Get() picks up file edits. Caveat
    // until the PTY host split: the shell session restarts with it.
    // e.code, not e.key: shift+comma *is* "<" on a US layout, so matching
    // e.key === "," can never fire with shift held.
    window.addEventListener("keydown", (e) => {
        if (e.metaKey && e.shiftKey && e.code === "Comma") {
            e.preventDefault();
            location.reload();
        }
    });

    new ResizeObserver(() => syncSize()).observe(container);
    await spawn();
}

void main();
