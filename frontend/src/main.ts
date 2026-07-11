import {Terminal} from "@xterm/xterm";
import {FitAddon} from "@xterm/addon-fit";
import {WebglAddon} from "@xterm/addon-webgl";
import "@xterm/xterm/css/xterm.css";
import {Events} from "@wailsio/runtime";
import {Service as Session} from "../bindings/github.com/incantery/rook/internal/session";

const term = new Terminal({
    allowProposedApi: true,
    cursorBlink: true,
    fontFamily: "Menlo, Monaco, ui-monospace, monospace",
    fontSize: 13,
    scrollback: 10_000,
    macOptionIsMeta: true,
    theme: {
        background: "#06070f",
        foreground: "#d6deeb",
        cursor: "#82aaff",
        selectionBackground: "#2d3f57",
    },
});

const fit = new FitAddon();
term.loadAddon(fit);
term.open(document.getElementById("terminal")!);
try {
    const webgl = new WebglAddon();
    // WKWebView can reclaim the GL context; xterm falls back to the canvas
    // renderer once the addon is disposed.
    webgl.onContextLoss(() => webgl.dispose());
    term.loadAddon(webgl);
} catch (err) {
    console.warn("WebGL addon failed, falling back to canvas renderer", err);
}
fit.fit();

// PTY output is base64-encoded raw bytes (chunks can split UTF-8 mid-rune);
// xterm's own decoder reassembles them.
const decode = (b64: string) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));

interface DataEvent {
    id: string;
    data: string;
}

let sessionId: string | null = null;
let spawnedAt = 0;
// Output emitted between Spawn() returning in Go and the id landing here
// would race past the filter below — hold it until the id is known.
let preSpawn: DataEvent[] = [];

function onData(e: DataEvent) {
    if (e.id !== sessionId) return;
    term.write(decode(e.data));
}

async function spawn() {
    sessionId = null;
    preSpawn = [];
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
