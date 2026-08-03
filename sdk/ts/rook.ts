// The TypeScript SDK for describing a rook development environment —
// sdk/rook's Go API, mirrored. The program importing this runs once,
// at apply time, and emits the IR graph (docs/environments/IR.md);
// rook materializes the graph at launch and hot-reloads it live.
//
// Emission is canonical (IR.md "Canonical bytes"): byte-identical to
// the Go SDK for the same environment — parity is `diff`, and the
// preset goldens in rook.test.ts pin the bundles to the same values
// the Go golden and the app's e2e presetparity scenario pin.
//
// Runs under node (v23+ type stripping) or bun. No dependencies.

import { writeFileSync } from "node:fs";

type Node = { id: string } & Record<string, unknown>;

export class Env {
  private nodes: Node[] = [];

  // Append, or replace in place when the id exists — the later call
  // wins at the earlier call's position ("config lines replace
  // defaults", which is what makes base-then-overrides composition
  // mean something).
  private put(n: Node): this {
    const i = this.nodes.findIndex((e) => e.id === n.id);
    if (i >= 0) this.nodes[i] = n;
    else this.nodes.push(n);
    return this;
  }

  option(scope: string, key: string, value: unknown): this {
    return this.put({ id: `option:${scope}:${key}`, kind: "option", scope, key, value });
  }
  set(key: string, value: unknown): this {
    return this.option("app", key, value);
  }
  host(key: string, value: unknown): this {
    return this.option("host", key, value);
  }
  // Declare a plugin: what to run, when, and what it may do.
  //
  // This is where the plugin system meets configuration, and it is the
  // USER-facing half of it. Writing a plugin is the protocol
  // (rook-demos/sdk/go/plugin); declaring one is this, and a plugin rook
  // was never told about does not exist.
  //
  // DECLARED vs GRANTED is the load-bearing distinction. The plugin's own
  // `describe` says what it WANTS; this says what it MAY HAVE. The gap is
  // what preview shows before anything runs — adopting a stranger's
  // environment tells you which plugins it adds and what they asked for.
  //
  // `load` is WHEN: "lazy" (default) spawns on first use, because a
  // surface nobody opened must cost nothing; "eager" spawns at launch,
  // for a plugin that has to be watching before you look.
  plugin(
    name: string,
    command: string[],
    load: "lazy" | "eager" = "lazy",
    grants: string[] = [],
  ): this {
    // Key order is the canon — it must match the Go SDK's emitter
    // exactly, since parity is a byte diff. grants is ALWAYS an array,
    // never null: absent and empty mean the same thing, and a reader
    // handling both shapes will get one wrong.
    return this.put({
      id: `plugin:${name}`,
      kind: "plugin",
      scope: "app",
      name,
      command,
      load,
      grants,
    });
  }

  // Declare a plugin by WHERE IT COMES FROM, and let rook do the rest: it
  // downloads the binary into its own cache on first use, and nothing in
  // your config names a path. The name is the source's last segment.
  //
  // https only. Executing something downloaded over plain http is not a
  // thing to make easy.
  pluginFrom(source: string, grants: string[] = []): this {
    return this.put(pluginNode(source, grants));
  }

  // pluginFrom with the artifact's sha256 nailed down — the strong form,
  // and the one to use once you know the hash. It travels with the config
  // and is reviewable in a diff. rook prints the hash it saw on first
  // download; paste it here.
  pluginPinned(source: string, sha256: string, grants: string[] = []): this {
    const n = pluginNode(source, grants) as Record<string, unknown>;
    // After `source`, before `load` — key order is the canon, and parity
    // with the Go emitter is a byte diff.
    return this.put({
      id: n.id,
      kind: n.kind,
      scope: n.scope,
      name: n.name,
      source: n.source,
      sha256,
      load: n.load,
      grants: n.grants,
    });
  }


  // Declare a named directory rook treats as a workspace: the palette
  // lists it, a space launched inside it wears its name, and worktree
  // tooling anchors on its root. Declared, not registered — a root can
  // be computed per machine rather than remembered. Leading "~/" is
  // expanded by rook against $HOME. Worktrees are deliberately absent:
  // rook derives them from git, not from a second list you keep in step.
  workspace(name: string, root: string): this {
    // Key order is the canon — must match the Go emitter byte-for-byte.
    return this.put({ id: `workspace:${name}`, kind: "workspace", scope: "app", name, root });
  }

  table(name: string, entries: Record<string, unknown>): this {
    const sorted = Object.fromEntries(
      Object.entries(entries).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)),
    );
    return this.put({ id: `table:host:${name}`, kind: "table", scope: "host", name, entries: sorted });
  }

  leader(key: string): this {
    return this.put({ id: "leader:app", kind: "leader", scope: "app", key });
  }
  editorLeader(key: string): this {
    return this.put({ id: "leader:editor", kind: "leader", scope: "editor", key });
  }
  bind(chord: string, command: string): this {
    return this.put({ id: `keybind:app:${chord}`, kind: "keybind", scope: "app", chord, command });
  }
  editorBind(mode: string, chord: string, command: string): this {
    const scope = `editor.${mode}`;
    return this.put({ id: `keybind:${scope}:${chord}`, kind: "keybind", scope, chord, command });
  }

  // ---- named app options ----

  fontFamily(name: string): this { return this.set("font-family", name); }
  fontSize(pts: number): this { return this.set("font-size", pts); }
  theme(name: string): this { return this.set("theme", name); }
  backgroundOpacity(v: number): this { return this.set("background-opacity", v); }
  backgroundBlur(mode: string): this { return this.set("background-blur", mode); }
  windowPadding(pts: number): this { return this.set("window-padding", pts); }
  bell(mode: string): this { return this.set("bell", mode); }
  clipboardWrite(mode: string): this { return this.set("clipboard-write", mode); }
  bufferLine(on: boolean): this { return this.set("buffer-line", on); }
  // The three-way form: "off", "multiple" (default), "always" (VS Code's).
  bufferLineMode(mode: string): this { return this.set("buffer-line", mode); }
  cursorBlink(on: boolean): this { return this.set("cursor-blink", on); }
  // Fade unfocused panes toward their background, 0 (off) to 0.9.
  paneDim(amount: number): this { return this.set("pane-dim", amount); }
  scrollback(size: string): this { return this.set("scrollback", size); }

  // ---- chrome arrangement ----

  topBar(...segments: string[]): this { return this.set("top-bar", segments); }
  statusLeft(...segments: string[]): this { return this.set("status-left", segments); }
  statusRight(...segments: string[]): this { return this.set("status-right", segments); }
  tabStyle(style: string): this { return this.set("tab-style", style); }
  editorMode(mode: string): this { return this.set("editor-mode", mode); }
  activityBar(on: boolean): this { return this.set("activity-bar", on); }
  explorerAuto(on: boolean): this { return this.set("explorer-auto", on); }

  // ---- presets: identities as bundles ----
  // Expanded at emit time so the graph shows every knob a preset set.
  // Must match sdk/rook (Go golden) and config.zig's applyPreset (e2e
  // presetparity) — three definitions, three guards.

  presetTmuxNeovim(): this {
    this.topBar();
    this.statusLeft("tabs");
    this.statusRight("workspace", "branch", "cwd");
    this.tabStyle("index-name");
    this.bufferLine(false);
    return this;
  }

  presetVSCode(): this {
    this.topBar();
    this.statusLeft("tabs", "branch");
    this.statusRight("cwd", "hints");
    this.tabStyle("current");
    this.bufferLineMode("always");
    this.theme("vscode-dark");
    this.editorMode("insert");
    this.activityBar(true);
    this.explorerAuto(true);
    return this;
  }

  // ---- emission ----

  json(): string {
    // JSON.stringify happens to agree with the canon (minimal string
    // escaping, no HTML escaping, integral floats as integers) as
    // long as object keys are built in canonical order — which put()
    // and the literals above guarantee.
    return JSON.stringify({ rookEnvironment: 1, nodes: this.nodes }) + "\n";
  }

  // The program's main: stdout by default, `--out PATH` writes the
  // file (the app reads ~/.config/rook/environment.json).
  run(): void {
    const args = process.argv.slice(2);
    const i = args.indexOf("--out");
    if (i >= 0 && args[i + 1]) {
      writeFileSync(args[i + 1], this.json());
      return;
    }
    process.stdout.write(this.json());
  }
}

function pluginNode(source: string, grants: string[]) {
  const name = source.slice(source.lastIndexOf("/") + 1);
  return {
    id: `plugin:${name}`,
    kind: "plugin",
    scope: "app",
    name,
    source,
    load: "lazy",
    grants,
  };
}

export function env(): Env {
  return new Env();
}
