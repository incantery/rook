// The keybinding table: the tmux-derived defaults, overlaid with the
// config file's [keybinds] table. Triggers carry an explicit scope:
// "<leader>m" acts after the leader prefix, a modifier chord
// ("cmd+shift+k") acts directly, and a bare key or sequence ("K", "gd")
// is reserved for direct dispatch — carried in config but not dispatched
// at the app layer yet, so it drops here with a warn. (The legacy flat
// file's implicit bare-key convention is normalized to <leader> form by
// the Go parser before it reaches us.) Two layers, same as the ladder in
// App.svelte. This module only builds the lookup tables and the palette's
// display strings; App.svelte owns dispatch. Config edits arrive through
// ` r (reload re-runs main()).
//
// Fail open on user input: a trigger that doesn't parse, or one that's
// reserved, drops with a console.warn — it never breaks the defaults
// around it. Reserved and not rebindable: digits (window switching) and
// the prefix backtick (the literal-` escape).

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
    ["<leader>c", "session.new"],
    ["<leader>x", "session.close"],
    ["<leader>r", "config.reload"],
    ["<leader>k", "palette.toggle"],
    ["<leader>s", "workspace.switch"],
    ["<leader>a", "attention.inbox"],
    ["<leader>n", "agent.spawn"],
    ["<leader>v", "agent.view"],
    ["<leader>h", "workspace.manager"],
    ["<leader>.", "workspace.set-root"],
    ["<leader>d", "workspace.dashboard"],
    ["cmd+t", "session.new"],
    ["cmd+shift+]", "session.next"],
    ["cmd+shift+[", "session.prev"],
    ["cmd+shift+,", "config.reload"],
    ["cmd+,", "config.settings"],
    // panes — tmux-faithful: % splits right, " splits down, o cycles,
    // arrows move focus, z zooms; ⌘D/⌘⇧D as the native-feeling chords
    ["<leader>%", "pane.split-right"],
    ['<leader>"', "pane.split-down"],
    ["<leader>o", "pane.next"],
    // vim-navigator chords, listed BEFORE the arrows so the palette
    // advertises these — they're the primary binding now. They also cross
    // into an open side pane at the layout's edge, which ` arrows do too.
    // A full-screen app (vim, less) keeps them; see mgr.focusedInAltScreen.
    // Cost, inherited from vim-tmux-navigator: ⌃L no longer clears the
    // screen and ⌃H no longer backspaces at a shell prompt. Unbind with
    // `keybind = ctrl+l=` to take them back.
    ["ctrl+h", "pane.focus-left"],
    ["ctrl+j", "pane.focus-down"],
    ["ctrl+k", "pane.focus-up"],
    ["ctrl+l", "pane.focus-right"],
    ["<leader>left", "pane.focus-left"],
    ["<leader>right", "pane.focus-right"],
    ["<leader>up", "pane.focus-up"],
    ["<leader>down", "pane.focus-down"],
    ["<leader>z", "pane.zoom"],
    // the Monaco panes: review diff and read-only file viewer
    ["<leader>g", "review.changes"],
    // telescope muscle memory, workbench-wide — a full-screen TUI keeps
    // them (vim's ⌃P completion), same yield as the navigator chords
    ["ctrl+p", "file.open"],
    ["ctrl+g", "grep.open"],
    ["<leader>e", "file.open"],
    ["<leader>/", "grep.open"],
    ["<leader>i", "explore.trail"],
    ["<leader>t", "threads.toggle"],
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
        (meta ? "M" : "") + (ctrl ? "C" : "") + (alt ? "A" : "") + (shift ? "S" : "") + ":" + code;
    const disp =
        (meta ? "⌘" : "") +
        (ctrl ? "⌃" : "") +
        (alt ? "⌥" : "") +
        (shift ? "⇧" : "") +
        (KEY_DISP[key] ?? key.toUpperCase());
    return {layer: "chord", key: sig, command: "", disp};
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

/** Strips a leading <leader> scope marker; null when the trigger has none. */
export function stripLeader(trigger: string): string | null {
    const m = /^<leader>/i.exec(trigger);
    return m ? trigger.slice(m[0].length) : null;
}

function parseTrigger(trigger: string): Bind | null {
    // "<leader>x" is the prefix layer, explicitly scoped
    const rest = stripLeader(trigger);
    if (rest !== null) {
        const named = PREFIX_NAMED[rest.toLowerCase()];
        if (named) {
            return {
                layer: "prefix",
                key: named,
                command: "",
                disp: "` " + KEY_DISP[rest.toLowerCase()],
            };
        }
        if (rest.length !== 1) return null;
        return {layer: "prefix", key: rest, command: "", disp: "` " + rest};
    }
    // a modifier chord fires directly ("+" itself can only be bound
    // through <leader>+ now that bare keys mean direct dispatch)
    if (trigger.includes("+")) return parseChord(trigger);
    // bare keys and sequences ("K", "gd") are direct-dispatch triggers —
    // an editor-scope concept the app layer doesn't dispatch yet
    return null;
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
    const onlyCtrl = parts.length === 1 && (parts[0] === "ctrl" || parts[0] === "control");
    if (onlyCtrl && key && /^[a-z]$/.test(key)) {
        return String.fromCharCode(key.toUpperCase().charCodeAt(0) - 64);
    }
    return "";
}

const BACKTICK_LEADER: Leader = {
    matches: (e) => e.key === "`" && !e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey,
    literal: "`",
    disp: "`",
};

// The CONTEXT leader (vim's maplocalleader): where the backtick is the IDE's
// leader (workbench-global verbs), this one prefixes the verbs of the CURRENT
// quickfix context. The comma default now rides config — [editor] leader —
// through the same parseLeader path the IDE leader rides; this constant is
// the fallback when config doesn't set one.
export const CONTEXT_LEADER_KEY = ",";

// The context layer's bindings: deliberately tiny — the doors into the
// current context. q = its list (quickfix), a = its verbs (quick actions),
// c/? = say something about the code under the cursor.
//
// c and ? are the two halves of the review loop, and they are separate keys
// rather than one key plus a modifier because they mean genuinely different
// things: c is the whiteboard (land it pending, keep moving), ? interrupts
// the agent about THIS line. Conflating them behind a modifier makes the
// louder of the two an easy mis-press.
export const CONTEXT_PREFIX = new Map<string, string>([
    ["q", "quickfix.toggle"],
    ["a", "quickaction.toggle"],
    ["c", "editor.comment"],
    ["?", "editor.ask"],
    // t = every thread in the workspace, as a finder. The thread under the
    // cursor is gt (a motion, and it lives with gd/gr where it belongs);
    // the leader is for the surfaces you reach for without a cursor.
    ["t", "threads.find"],
    // the file tree is editor furniture (vim: netrw/NvimTree live inside
    // vim) — moved here from the app leader when the editor got isolated
    ["b", "explorer.toggle"],
    ["f", "explorer.reveal"],
]);

// Named keys a context trigger may use after <leader>, vim-spelling
// tolerant ("<leader>TAB", "<leader>cr") — mapped to the KeyboardEvent.key
// value the dispatch matches on.
const CONTEXT_NAMED: Record<string, string> = {
    tab: "Tab",
    space: " ",
    enter: "Enter",
    cr: "Enter",
    escape: "Escape",
    esc: "Escape",
    backspace: "Backspace",
    bs: "Backspace",
    up: "ArrowUp",
    down: "ArrowDown",
    left: "ArrowLeft",
    right: "ArrowRight",
};

// buildContextMap overlays config's [editor.keybinds.normal] table on the
// CONTEXT_PREFIX defaults. "<leader>x" and "<leader>TAB"-style named keys
// land here — bare sequences ("gd") and chords in the editor scope are
// carried in config but wait on modal dispatch, so they drop with a warn.
// "" unbinds, same as the app scope. Modes other than normal are ignored
// here (fail open toward configs written for a newer rook).
export function buildContextMap(normalBinds: Record<string, string | undefined>): Map<string, string> {
    const map = new Map(CONTEXT_PREFIX);
    for (const [t, c] of Object.entries(normalBinds)) {
        if (typeof c !== "string") continue;
        const rest = stripLeader(t.trim());
        const key = rest === null ? null : rest.length === 1 ? rest : CONTEXT_NAMED[rest.toLowerCase()] ?? null;
        if (key === null) {
            console.warn("editor keybind carried but not dispatchable yet:", t);
            continue;
        }
        if (c === "") map.delete(key);
        else map.set(key, c);
    }
    return map;
}

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
            matches: (e) => e.key === t && !e.metaKey && !e.ctrlKey && !e.altKey && !e.shiftKey,
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
            if (fromConfig) console.warn("keybind ignored (bad or reserved trigger):", trigger);
            return;
        }
        // prefix disp is built as "` " + key; swap in the configured leader
        if (b.layer === "prefix" && leaderDisp !== "`") b.disp = leaderDisp + b.disp.slice(1);
        // one action per trigger: rebinding replaces, "" just unbinds
        const i = binds.findIndex((x) => x.layer === b.layer && x.key === b.key);
        if (i !== -1) binds.splice(i, 1);
        if (command !== "") binds.push({...b, command});
    };
    for (const [t, c] of DEFAULTS) apply(t, c, false);
    for (const [t, c] of Object.entries(overrides)) {
        if (typeof c === "string") apply(t.trim(), c, true);
    }

    const prefix = new Map<string, string>();
    const chords = new Map<string, string>();
    for (const b of binds) (b.layer === "prefix" ? prefix : chords).set(b.key, b.command);
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

// The current bindings as editable rows — DEFAULTS overlaid with config
// overrides, one row per bound trigger (multi-trigger commands yield multiple
// rows, so an unrelated save never silently drops a binding). The exact inverse
// of computeKeybindOverrides, mirroring buildKeymap's apply order.
export function effectiveKeybindRows(overrides: Record<string, string | undefined>): KeybindRow[] {
    const bySig = new Map<string, KeybindRow>(); // slot signature -> row (insertion-ordered)
    const apply = (trigger: string, command: string, fromConfig: boolean) => {
        const sig = triggerSig(trigger);
        if (sig == null || (fromConfig && isReservedTrigger(trigger))) return;
        if (command === "") bySig.delete(sig);
        else bySig.set(sig, {trigger, command});
    };
    for (const [t, c] of DEFAULTS) apply(t, c, false);
    for (const [t, c] of Object.entries(overrides))
        if (typeof c === "string") apply(t.trim(), c, true);
    return [...bySig.values()];
}
