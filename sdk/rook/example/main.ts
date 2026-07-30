// Seth's config as a TypeScript environment — the parity probe.
//
// Same environment as main.go, byte-identical output required
// (docs/environments/IR.md, "Canonical bytes"). Runs under bun or
// node (--experimental-strip-types). A real TS SDK arrives when
// demand does; this measures emit time and keeps the canon honest.

type Node = Record<string, unknown> & { id: string };

const nodes: Node[] = [];

function put(n: Node) {
  const i = nodes.findIndex((e) => e.id === n.id);
  if (i >= 0) nodes[i] = n;
  else nodes.push(n);
}

function option(scope: string, key: string, value: unknown) {
  put({ id: `option:${scope}:${key}`, kind: "option", scope, key, value });
}
const set = (key: string, value: unknown) => option("app", key, value);
const host = (key: string, value: unknown) => option("host", key, value);

function table(name: string, entries: Record<string, unknown>) {
  const sorted = Object.fromEntries(
    Object.entries(entries).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)),
  );
  put({ id: `table:host:${name}`, kind: "table", scope: "host", name, entries: sorted });
}

const leader = (key: string) =>
  put({ id: "leader:app", kind: "leader", scope: "app", key });
const editorLeader = (key: string) =>
  put({ id: "leader:editor", kind: "leader", scope: "editor", key });

function bind(chord: string, command: string) {
  put({ id: `keybind:app:${chord}`, kind: "keybind", scope: "app", chord, command });
}
function editorBind(mode: string, chord: string, command: string) {
  const scope = `editor.${mode}`;
  put({ id: `keybind:${scope}:${chord}`, kind: "keybind", scope, chord, command });
}

// ---- the environment (mirror of main.go) ----

set("font-family", "Hack Nerd Font Mono");
set("font-size", 18);
set("background-opacity", 1);
set("window-padding", 4);
set("theme", "Nocturne");

leader("`");
editorLeader(",");

bind('<leader>"', "app.split.horizontal");
bind("<leader>v", "app.split.vertical");
bind("<leader>c", "tab.new");
bind("<leader>m", "workspace.manager");

editorBind("normal", "<leader>TAB", "explorer.toggle");
editorBind("normal", "<leader>o", "explorer.reveal");

host("coder", "claude");
host("workspace-allow", ["rook", "rook-cloud", "rook-site", "presentation"]);
table("agent", { enabled: true, engine: "auto", model: "", "daily-cap-usd": 1 });
table("lsp", { enable: ["go", "typescript", "svelte"] });
table("cloud", { url: "https://api.rookide.com" });

process.stdout.write(JSON.stringify({ rookEnvironment: 1, nodes }) + "\n");
