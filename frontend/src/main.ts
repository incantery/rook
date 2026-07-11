import {Terminal} from "@xterm/xterm";
import {FitAddon} from "@xterm/addon-fit";
import {WebglAddon} from "@xterm/addon-webgl";
import "@xterm/xterm/css/xterm.css";
import {Events} from "@wailsio/runtime";
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

// PTY output is base64-encoded raw bytes (chunks can split UTF-8 mid-rune);
// xterm's own decoder reassembles them.
const decode = (b64: string) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));

interface DataEvent {
    id: string;
    seq: number;
    data: string;
}

let sessionId: string | null = null;
let spawnedAt = 0;
let lastSeq = 0;
// Output emitted between Spawn() returning in Go and the id landing here
// would race past the filter below — hold it until the id is known.
let preSpawn: DataEvent[] = [];

function onData(e: DataEvent) {
    if (e.id !== sessionId) return;
    // A gap or reorder here corrupts the escape-sequence stream — if the
    // screen ever garbles, this console line is the first thing to check.
    if (e.seq !== lastSeq + 1) {
        console.error(`pty:data sequence break: expected ${lastSeq + 1}, got ${e.seq}`);
    }
    lastSeq = e.seq;
    term.write(decode(e.data));
}

async function spawn() {
    sessionId = null;
    preSpawn = [];
    lastSeq = 0;
    spawnedAt = Date.now();
    sessionId = await Session.Spawn(term.cols, term.rows);
    preSpawn.forEach(onData);
    preSpawn = [];
}

Events.On("pty:data", (e: {data: DataEvent}) => {
    if (sessionId === null) {
        preSpawn.push(e.data);
        return;
    }
    onData(e.data);
});

Events.On("pty:exit", (e: {data: {id: string}}) => {
    if (e.data.id !== sessionId) return;
    // Instant exit means the shell itself is broken — don't respawn-loop.
    if (Date.now() - spawnedAt < 1000) {
        term.writeln("\r\n\x1b[31m[shell exited immediately — not restarting]\x1b[0m");
        return;
    }
    term.writeln("\r\n\x1b[90m[shell exited — restarting]\x1b[0m");
    void spawn();
});

term.onData((data) => {
    if (sessionId !== null) void Session.Write(sessionId, data);
});

term.onResize(({cols, rows}) => {
    if (sessionId !== null) void Session.Resize(sessionId, cols, rows);
});

window.addEventListener("resize", () => fit.fit());

void spawn().then(() => term.focus());
