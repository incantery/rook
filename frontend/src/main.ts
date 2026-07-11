import {Terminal} from "@xterm/xterm";
import {FitAddon} from "@xterm/addon-fit";
import {WebglAddon} from "@xterm/addon-webgl";
import "@xterm/xterm/css/xterm.css";
import {Service as Session} from "../bindings/github.com/incantery/rook/internal/session";

// Renderer A/B switch: WebGL showed stale-frame artifacts in WKWebView after
// window resizes, so the DOM renderer is the default until that's understood.
// In devtools: localStorage.setItem("rook.renderer", "webgl"); location.reload()
const useWebgl = localStorage.getItem("rook.renderer") === "webgl";
// localStorage.setItem("rook.debug", "1") logs the first PTY chunks per
// session — the tool for "where did that stray glyph come from" questions.
const debug = localStorage.getItem("rook.debug") === "1";

// Theme + font mirror the ghostty config (Material Ocean, Hack Nerd Font
// Mono 18, 4px padding) — the parity bar is muscle memory, eyes included.
const FONT = '"Hack Nerd Font Mono", Menlo, ui-monospace, monospace';
const term = new Terminal({
    allowProposedApi: true,
    allowTransparency: true,
    cursorBlink: true,
    fontFamily: FONT,
    fontSize: 18,
    scrollback: 10_000,
    macOptionIsMeta: true,
    theme: {
        // Material Ocean at ghostty's background-opacity 0.95 (f2 ≈ 0.95).
        background: "#0f111af2",
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
    },
});
const fit = new FitAddon();
term.loadAddon(fit);

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

term.onData((data) => {
    ws?.send(data);
});

async function main() {
    // Measure with the real font: fit() before the Nerd Font loads would
    // compute the grid from fallback-font cell metrics and spawn the PTY
    // with the wrong size.
    try {
        await document.fonts.load(`18px ${FONT}`);
    } catch {
        // fall through — worst case the onopen sync corrects the grid
    }

    const container = document.getElementById("terminal")!;
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

    new ResizeObserver(() => syncSize()).observe(container);
    await spawn();
}

void main();
