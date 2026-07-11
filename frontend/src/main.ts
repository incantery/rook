import {Terminal} from "@xterm/xterm";
import {FitAddon} from "@xterm/addon-fit";
import {WebglAddon} from "@xterm/addon-webgl";
import "@xterm/xterm/css/xterm.css";
import {Service as Session} from "../bindings/github.com/incantery/rook/internal/session";

// Renderer A/B switch: WebGL showed stale-frame artifacts in WKWebView after
// window resizes, so the DOM renderer is the default until that's understood.
// In devtools: localStorage.setItem("rook.renderer", "webgl"); location.reload()
const useWebgl = localStorage.getItem("rook.renderer") === "webgl";

// Theme + font mirror the ghostty config (Material Ocean, Hack Nerd Font
// Mono 18, 4px padding) — the parity bar is muscle memory, eyes included.
const term = new Terminal({
    allowProposedApi: true,
    cursorBlink: true,
    fontFamily: '"Hack Nerd Font Mono", Menlo, ui-monospace, monospace',
    fontSize: 18,
    scrollback: 10_000,
    macOptionIsMeta: true,
    theme: {
        background: "#0f111a",
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
term.open(document.getElementById("terminal")!);
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

// PTY bytes flow over a localhost WebSocket (binary frames, TCP ordering) —
// the Wails event bus drops messages under flood and a terminal can't
// tolerate that. Bindings carry only low-rate control: spawn and resize.
let ws: WebSocket | null = null;
let sessionId: string | null = null;
let spawnedAt = 0;

async function spawn() {
    sessionId = null;
    spawnedAt = Date.now();
    const endpoint = await Session.Endpoint();
    const id = await Session.Spawn(term.cols, term.rows);

    const socket = new WebSocket(`${endpoint}/session/${id}`);
    socket.binaryType = "arraybuffer";
    socket.onopen = () => {
        sessionId = id;
        ws = socket;
        term.focus();
    };
    socket.onmessage = (e: MessageEvent<ArrayBuffer>) => {
        term.write(new Uint8Array(e.data));
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

term.onResize(({cols, rows}) => {
    if (sessionId !== null) void Session.Resize(sessionId, cols, rows);
});

window.addEventListener("resize", () => fit.fit());

void spawn();
