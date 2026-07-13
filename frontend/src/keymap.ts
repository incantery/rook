// The keybinding table: the tmux-derived defaults, overlaid with the
//
//
//
//
// config file's `keybind = <trigger>=<command>` lines. Two layers, same
// as the ladder in App.svelte — bare-key triggers act after the backtick
// prefix, modifier chords act directly. This module only builds the
// lookup tables and the palette's display strings; App.svelte owns
// dispatch. Config edits arrive through ` r (reload re-runs main()).
//
// Fail open on user input: a trigger that doesn't parse, or one that's
// reserved, drops with a console.warn — it never breaks the defaults
// around it. Reserved and not rebindable: digits (window switching and
// the dashboard slot are computed from dashboard-tab) and the prefix
// backtick (the literal-` escape).

export interface Keymap {
  /** prefix layer: e.key → command id (case-sensitive, so `H` binds shift-h) */
  prefix: Map<string, string>;
  /** chord layer: modifier signature (see sigOf) → command id */
  chords: Map<string, string>;
  /** display-only hint for the palette, e.g. "` h" or "⌘⇧]" */
  display(command: string): string | undefined;
}

// Every default binding, in display order (display() shows a command's
// FIRST binding, which is why ⌘K precedes ` k). A config override on the
// same trigger replaces the entry; `keybind = <trigger>=` removes it.
export const DEFAULTS: [string, string][] = [
  ["cmd+k", "palette.toggle"],
  ["c", "session.new"],
  ["x", "session.close"],
  ["r", "config.reload"],
  ["k", "palette.toggle"],
  ["s", "workspace.switch"],
  ["a", "attention.inbox"],
  ["n", "agent.spawn"],
  ["h", "workspace.manager"],
  [".", "workspace.set-root"],
  ["d", "workspace.dashboard"],
  ["cmd+t", "session.new"],
  ["cmd+shift+]", "session.next"],
  ["cmd+shift+[", "session.prev"],
  ["cmd+shift+,", "config.reload"],
  ["cmd+,", "config.settings"],
  // panes — tmux-faithful: % splits right, " splits down, o cycles,
  // arrows move focus, z zooms; ⌘D/⌘⇧D as the native-feeling chords
  ["%", "pane.split-right"],
  ['"', "pane.split-down"],
  ["o", "pane.next"],
  ["left", "pane.focus-left"],
  ["right", "pane.focus-right"],
  ["up", "pane.focus-up"],
  ["down", "pane.focus-down"],
  ["z", "pane.zoom"],
  // the Monaco panes: review diff and read-only file viewer
  ["g", "review.changes"],
  ["e", "file.open"],
  ["cmd+d", "pane.split-right"],
  ["cmd+shift+d", "pane.split-down"],
];

interface Bind {
  layer: "prefix" | "chord";
  /** the lookup key: e.key for prefix, sigOf-shaped for chords */
  key: string;
  command: string;
  disp: string;
}

/** The chord lookup key for a live event — must mirror parseChord. */
export function sigOf(e: KeyboardEvent): string {
  return (
    (e.metaKey ? "M" : "") +
    (e.ctrlKey ? "C" : "") +
    (e.altKey ? "A" : "") +
    (e.shiftKey ? "S" : "") +
    ":" +
    e.code
  );
}

// Chords match on KeyboardEvent.code (layout-independent, and shift can't
// rewrite it the way it rewrites e.key: shift+] must not become "}").
const NAMED_CODES: Record<string, string> = {
  "[": "BracketLeft",
  "]": "BracketRight",
  ",": "Comma",
  ".": "Period",
  ";": "Semicolon",
  "'": "Quote",
  "/": "Slash",
  "\\": "Backslash",
  "-": "Minus",
  "=": "Equal",
  "`": "Backquote",
  enter: "Enter",
  tab: "Tab",
  space: "Space",
  escape: "Escape",
  backspace: "Backspace",
  up: "ArrowUp",
  down: "ArrowDown",
  left: "ArrowLeft",
  right: "ArrowRight",
};

const KEY_DISP: Record<string, string> = {
  enter: "↩",
  tab: "⇥",
  space: "␣",
  escape: "⎋",
  backspace: "⌫",
  up: "↑",
  down: "↓",
  left: "←",
  right: "→",
};

function keyToCode(key: string): string | null {
  if (/^[a-z]$/i.test(key)) return "Key" + key.toUpperCase();
  if (/^[0-9]$/.test(key)) return "Digit" + key;
  return NAMED_CODES[key.toLowerCase()] ?? null;
}

function parseChord(trigger: string): Bind | null {
  const parts = trigger
    .split("+")
    .map((p) => p.trim().toLowerCase())
    .filter((p) => p !== "");
  const key = parts.pop();
  if (!key) return null;
  let meta = false,
    ctrl = false,
    alt = false,
    shift = false;
  for (const p of parts) {
    if (p === "cmd" || p === "meta" || p === "super") meta = true;
    else if (p === "ctrl" || p === "control") ctrl = true;
    else if (p === "alt" || p === "opt" || p === "option") alt = true;
    else if (p === "shift") shift = true;
    else return null;
  }
  // shift alone can't carry a chord — it would shadow plain typing
  if (!meta && !ctrl && !alt) return null;
  const code = keyToCode(key);
  if (!code) return null;
  const sig =
    (meta ? "M" : "") +
    (ctrl ? "C" : "") +
    (alt ? "A" : "") +
    (shift ? "S" : "") +
    ":" +
    code;
  const disp =
    (meta ? "⌘" : "") +
    (ctrl ? "⌃" : "") +
    (alt ? "⌥" : "") +
    (shift ? "⇧" : "") +
    (KEY_DISP[key] ?? key.toUpperCase());
  return { layer: "chord", key: sig, command: "", disp };
}

// Named prefix keys: the trigger name → the e.key the prefix branch
// matches on. Arrows only for now — other named keys (enter, tab, …)
// stay chord-only until a binding wants them.
const PREFIX_NAMED: Record<string, string> = {
  up: "ArrowUp",
  down: "ArrowDown",
  left: "ArrowLeft",
  right: "ArrowRight",
};

function parseTrigger(trigger: string): Bind | null {
  // "+" itself stays a bindable prefix key; anything longer with a "+"
  // reads as a chord
  if (trigger.includes("+") && trigger !== "+") return parseChord(trigger);
  const named = PREFIX_NAMED[trigger.toLowerCase()];
  if (named) {
    return {
      layer: "prefix",
      key: named,
      command: "",
      disp: "` " + KEY_DISP[trigger.toLowerCase()],
    };
  }
  if (trigger.length !== 1) return null;
  return { layer: "prefix", key: trigger, command: "", disp: "` " + trigger };
}

function reserved(b: Bind): boolean {
  if (b.layer === "prefix") return b.key === "`" || /^[0-9]$/.test(b.key);
  return /^M:Digit[0-9]$/.test(b.key); // bare ⌘1-9 switch windows
}

// The leader (tmux prefix): the key or chord that arms the bare-key layer.
// A single key like the backtick default matches on e.key with no modifiers;
// a chord like `ctrl+b` (the tmux default) matches on the sigOf signature.
export interface Leader {
  /** does this keydown fire the leader? */
  matches(e: KeyboardEvent): boolean;
  /** what to pass to the terminal when the leader is pressed twice ("" = swallow) */
  literal: string;
  /** display glyph for the pill/palette, e.g. "`" or "⌃B" */
  disp: string;
}

// A ctrl+<letter> leader passes its control byte through on the double-press,
// the way tmux sends C-b when you hit the prefix twice. Other chords have no
// natural passthrough, so they swallow it.
function controlLiteral(trigger: string): string {
  const parts = trigger
    .split("+")
    .map((p) => p.trim().toLowerCase())
    .filter((p) => p !== "");
  const key = parts.pop();
  const onlyCtrl =
    parts.length === 1 && (parts[0] === "ctrl" || parts[0] === "control");
  if (onlyCtrl && key && /^[a-z]$/.test(key)) {
    return String.fromCharCode(key.toUpperCase().charCodeAt(0) - 64);
  }
  return "";
}

const BACKTICK_LEADER: Leader = {
  matches: (e) =>
    e.key === "`" && !e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey,
  literal: "`",
  disp: "`",
};

export function parseLeader(trigger: string | undefined): Leader {
  const t = (trigger ?? "").trim();
  if (t.includes("+") && t !== "+") {
    const chord = parseChord(t);
    if (chord) {
      const sig = chord.key;
      return {
        matches: (e) => sigOf(e) === sig,
        literal: controlLiteral(t),
        disp: chord.disp,
      };
    }
    return BACKTICK_LEADER; // unparseable chord → fall back
  }
  if (t.length === 1) {
    return {
      matches: (e) =>
        e.key === t && !e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey,
      literal: t,
      disp: t,
    };
  }
  return BACKTICK_LEADER;
}

export function buildKeymap(
  overrides: Record<string, string | undefined>,
  leaderDisp = "`",
): Keymap {
  const binds: Bind[] = [];
  const apply = (trigger: string, command: string, fromConfig: boolean) => {
    const b = parseTrigger(trigger);
    if (!b || (fromConfig && reserved(b))) {
      if (fromConfig)
        console.warn("keybind ignored (bad or reserved trigger):", trigger);
      return;
    }
    // prefix disp is built as "` " + key; swap in the configured leader
    if (b.layer === "prefix" && leaderDisp !== "`")
      b.disp = leaderDisp + b.disp.slice(1);
    // one action per trigger: rebinding replaces, "" just unbinds
    const i = binds.findIndex((x) => x.layer === b.layer && x.key === b.key);
    if (i !== -1) binds.splice(i, 1);
    if (command !== "") binds.push({ ...b, command });
  };
  for (const [t, c] of DEFAULTS) apply(t, c, false);
  for (const [t, c] of Object.entries(overrides)) {
    if (typeof c === "string") apply(t.trim(), c, true);
  }

  const prefix = new Map<string, string>();
  const chords = new Map<string, string>();
  for (const b of binds)
    (b.layer === "prefix" ? prefix : chords).set(b.key, b.command);
  return {
    prefix,
    chords,
    display: (command) => binds.find((b) => b.command === command)?.disp,
  };
}

export interface KeybindRow {
  trigger: string;
  command: string;
}

// A stable identity for a trigger: two triggers collide iff they resolve to
// the same layer+lookup key (e.g. "cmd+d" and "cmd+D" without shift). null
// means the trigger doesn't parse (the editor shows it as invalid).
export function triggerSig(trigger: string): string | null {
  const b = parseTrigger(trigger.trim());
  if (!b) return null;
  return b.layer + ":" + b.key;
}

// True if the trigger is reserved (digits, the literal backtick) — buildKeymap
// drops these from config, so the editor must flag them instead of saving.
export function isReservedTrigger(trigger: string): boolean {
  const b = parseTrigger(trigger.trim());
  return b ? reserved(b) : false;
}

// Turn the editor's desired binding rows into the minimal config `keybind`
// override map (trigger -> command; "" command = unbind a default). Triggers
// are compared by PARSED identity (triggerSig), not raw text, so a row that
// re-spells a default (case/alias variant) is recognized as the same slot
// instead of double-emitting an add + a stale unbind. buildKeymap applies
// DEFAULTS then these overrides, so we emit only the diff.
export function computeKeybindOverrides(rows: KeybindRow[]): Record<string, string> {
  const overrides: Record<string, string> = {};
  const defCmdBySig = new Map<string, string>(); // slot signature -> default command
  const defTriggerBySig = new Map<string, string>(); // slot signature -> default trigger string
  for (const [t, c] of DEFAULTS) {
    const sig = triggerSig(t);
    if (sig == null) continue;
    defCmdBySig.set(sig, c);
    defTriggerBySig.set(sig, t);
  }
  const rowSigs = new Set<string>();
  for (const { trigger, command } of rows) {
    const t = trigger.trim();
    if (!t || !command) continue;
    const sig = triggerSig(t);
    if (sig == null) continue; // unparseable — the editor blocks these before save
    rowSigs.add(sig);
    if (defCmdBySig.get(sig) !== command) overrides[t] = command; // new or changed slot
  }
  for (const [sig, t] of defTriggerBySig) {
    if (!rowSigs.has(sig)) overrides[t] = ""; // a default slot with no surviving row → unbind
  }
  return overrides;
}

// The current bindings as editable rows — DEFAULTS overlaid with config
// overrides, one row per bound trigger (multi-trigger commands yield multiple
// rows, so an unrelated save never silently drops a binding). The exact inverse
// of computeKeybindOverrides, mirroring buildKeymap's apply order.
export function effectiveKeybindRows(
  overrides: Record<string, string | undefined>,
): KeybindRow[] {
  const bySig = new Map<string, KeybindRow>(); // slot signature -> row (insertion-ordered)
  const apply = (trigger: string, command: string, fromConfig: boolean) => {
    const sig = triggerSig(trigger);
    if (sig == null || (fromConfig && isReservedTrigger(trigger))) return;
    if (command === "") bySig.delete(sig);
    else bySig.set(sig, { trigger, command });
  };
  for (const [t, c] of DEFAULTS) apply(t, c, false);
  for (const [t, c] of Object.entries(overrides))
    if (typeof c === "string") apply(t.trim(), c, true);
  return [...bySig.values()];
}
