//! The command registry — every action rook can take, named once.
//!
//! This is the spine the wails app had (`frontend/src/registry.ts`) and
//! the cutover left behind: keybinds dispatch commands, the palette
//! lists commands, ctl runs commands by name, and the agent's tool
//! surface IS this table. One place to add a capability, four surfaces
//! that pick it up for free.
//!
//! Deliberately pure data + string logic, with no import of the app: it
//! gets its own test root for the same reason paste.zig and config.zig
//! do, and `config.zig` can depend on it without a cycle.
//!
//! A command is NOT registered until it does something. The webview
//! keymap has ~30 names and rook implements a subset; listing the rest
//! as dead palette rows would make the palette lie about what the app
//! can do. They arrive with their features — see app/PARITY.md §1.

const std = @import("std");

/// What a command actually does. `macos.zig`'s `dispatch` is the one
/// switch over this, which is what keeps the table honest: adding a
/// value here fails the build until it is handled.
pub const Action = enum {
    split_right,
    split_down,
    focus_left,
    focus_right,
    focus_up,
    focus_down,
    /// ⌘W — SIGHUP for a terminal, :q semantics for an editor.
    pane_close,
    /// tmux zoom: the focused pane takes the whole tab.
    pane_zoom,
    /// tmux copy mode: keys scroll the focused terminal's viewport.
    copy_mode,
    tab_new,
    tab_next,
    tab_prev,
    /// Jump to tab `arg` (1-based).
    tab_select,
    /// The workspace picker (reads rook.db).
    workspace_switch,
    /// The command palette — this table, over the same widget.
    palette_commands,
    /// The file finder: the repo's files, over the same widget.
    palette_files,
    palette_plugins,
    env_apply,
    plugin_pin,
    config_preview,
    config_edit,
    config_setup,
    /// Find in files — the search panel, a side-pane tenant.
    panel_search,
    /// Lay the focused editor's file out, through its language server.
    editor_format,
    app_fullscreen,
    /// The workspace's threads.
    /// The review: the changes list and the gate.
    /// Thread verbs, on whichever thread the focused pane holds. Reached
    /// as :ThreadNote / :ThreadAsk / :ThreadResolve through the
    /// ex-command bridge, which is exactly what that bridge is for.
    /// Bring a pending question back. Without this, switching panels
    /// while an ask is open strands it: the form still holds the ask, so
    /// the poller will not offer another, and nothing shows it.
    /// Move the side pane to the other edge — panels are placement-
    /// agnostic, so this is a property of the container, not the tenant.
    panel_flip,
    /// Close the side pane — search does not toggle, so this is the
    /// only way out of it.
    panel_close,
    /// The workspace's changes as a unified diff, in a pane. A view, not
    /// a panel: it is a DOCUMENT — scrolled, searched and navigated with
    /// the editor's own keys — and the side panes are for lists.
    /// The file tree, IN the focused pane (netrw's heir — no global
    /// panel; every pane can hold its own). Toggle puts back whatever
    /// the tree replaced: the file it covered, or the parked shell.
    tree_toggle,
    /// The tree opened ON the focused pane's current file: ancestors
    /// unfolded, cursor on it.
    tree_reveal,
    /// The resource monitor, in the focused pane. A takeover like the
    /// tree's, not a panel: it is a TABLE, and the side panes are for
    /// lists.
    monitor_open,
};

pub const Spec = struct { action: Action, arg: u8 = 0 };

pub const Command = struct {
    /// Canonical name. Dotted, lowercase, hyphenated within a segment —
    /// the wails registry's convention, because a shared config file is
    /// already written in it.
    id: []const u8,
    /// Human-facing, and what the palette filters on first.
    title: []const u8,
    category: []const u8,
    action: Action,
    arg: u8 = 0,
    /// Display-only key hint. Not a binding — config owns those, and a
    /// rebind does not update this string.
    keys: []const u8 = "",
    /// Listed in the palette. False for commands that are addressable by
    /// name and bindable, but noise in a list — the nine tab.select-N
    /// entries would be a third of the palette.
    palette: bool = true,
};

pub const commands = [_]Command{
    .{ .id = "pane.split-right", .title = "Split Right", .category = "Pane", .action = .split_right, .keys = "⌘D" },
    .{ .id = "pane.split-down", .title = "Split Down", .category = "Pane", .action = .split_down, .keys = "⌘⇧D" },
    .{ .id = "pane.focus-left", .title = "Focus Left", .category = "Pane", .action = .focus_left, .keys = "⌃H" },
    .{ .id = "pane.focus-down", .title = "Focus Down", .category = "Pane", .action = .focus_down, .keys = "⌃J" },
    .{ .id = "pane.focus-up", .title = "Focus Up", .category = "Pane", .action = .focus_up, .keys = "⌃K" },
    .{ .id = "pane.focus-right", .title = "Focus Right", .category = "Pane", .action = .focus_right, .keys = "⌃L" },
    .{ .id = "pane.close", .title = "Close Pane", .category = "Pane", .action = .pane_close, .keys = "⌘W" },
    .{ .id = "pane.zoom", .title = "Zoom Pane", .category = "Pane", .action = .pane_zoom, .keys = "<leader>z" },
    .{ .id = "pane.scrollback", .title = "Copy Mode / Scrollback", .category = "Pane", .action = .copy_mode, .keys = "<leader>[" },
    .{ .id = "tab.new", .title = "New Tab", .category = "Tab", .action = .tab_new, .keys = "⌘T" },
    .{ .id = "tab.next", .title = "Next Tab", .category = "Tab", .action = .tab_next, .keys = "⌘⇧]" },
    .{ .id = "tab.prev", .title = "Previous Tab", .category = "Tab", .action = .tab_prev, .keys = "⌘⇧[" },
    .{ .id = "workspace.switch", .title = "Switch Workspace", .category = "Workspace", .action = .workspace_switch, .keys = "<leader>s" },
    .{ .id = "palette.commands", .title = "Command Palette", .category = "App", .action = .palette_commands, .keys = "⌘K" },
    .{ .id = "palette.files", .title = "Go to File", .category = "App", .action = .palette_files, .keys = "⌘P" },
    // The one door to a plugin that is not the ctl socket. Plugins are
    // declared at RUNTIME and this table is compiled in, so the command
    // is "pick one" rather than one command per plugin.
    .{ .id = "plugin.open", .title = "Open a Plugin", .category = "Plugin", .action = .palette_plugins, .keys = "<leader>p" },
    // Apply is a DECISION, so it is a command you run rather than
    // something that happens to you. `ctl env` is the preview it is worth
    // reading first.
    .{ .id = "plugin.pin", .title = "Copy Plugin Pin", .category = "Plugin", .action = .plugin_pin },
    .{ .id = "config.preview", .title = "Preview Pending Config", .category = "Config", .action = .config_preview },
    .{ .id = "config.apply", .title = "Apply Pending Config", .category = "Config", .action = .env_apply },
    // Config is a program, and rook is an editor. Nobody should have to
    // leave rook, or remember a path, to change how rook behaves.
    .{ .id = "config.edit", .title = "Edit Config", .category = "Config", .action = .config_edit },
    .{ .id = "config.setup", .title = "Set Up Config", .category = "Config", .action = .config_setup },
    .{ .id = "panel.search", .title = "Find in Files", .category = "App", .action = .panel_search, .keys = "⌘⇧F" },
    // `:Format` inside the editor, and a palette entry outside it. No
    // default key: which chord a formatter deserves is a matter of
    // taste, and format-on-save is the answer for most people anyway.
    .{ .id = "editor.format", .title = "Format Document", .category = "Editor", .action = .editor_format },
    .{ .id = "app.fullscreen", .title = "Toggle Fullscreen", .category = "App", .action = .app_fullscreen },
    .{ .id = "panel.flip", .title = "Move Side Pane to Other Edge", .category = "Panel", .action = .panel_flip },
    .{ .id = "panel.close", .title = "Close Side Pane", .category = "Panel", .action = .panel_close },
    .{ .id = "tree.toggle", .title = "File Tree", .category = "Pane", .action = .tree_toggle, .keys = "<leader>⇥" },
    .{ .id = "tree.reveal", .title = "File Tree: Reveal File", .category = "Pane", .action = .tree_reveal, .keys = "<leader>o" },
    .{ .id = "monitor.open", .title = "Resource Monitor: CPU, memory and disk", .category = "Pane", .action = .monitor_open },
};

/// Alternate spellings that resolve to a command. Kept apart from the
/// table on purpose: the table stays one row per capability (so the
/// palette never shows the same thing twice), while a config written in
/// tmux's or the wails keymap's vocabulary still parses.
const aliases = [_]struct { name: []const u8, id: []const u8 }{
    .{ .name = "app.split.vertical", .id = "pane.split-right" }, // vim :vsplit sense
    .{ .name = "app.split.horizontal", .id = "pane.split-down" },
    .{ .name = "session.new", .id = "tab.new" }, // the wails keymap's name
    .{ .name = "session.close", .id = "pane.close" },
    .{ .name = "copy-mode", .id = "pane.scrollback" }, // tmux's
    .{ .name = "resize-pane -Z", .id = "pane.zoom" }, // tmux's
    .{ .name = "workspace.picker", .id = "workspace.switch" },
    .{ .name = "palette.toggle", .id = "palette.commands" },
};

/// One editor-leader chord: a key, and the canonical registry id it
/// speaks. Lives HERE because both sides of the seam need the type —
/// config.zig builds the table, editor.zig dispatches it — and this is
/// the only file both can import (std-only, so the editor stays
/// headless-testable).
pub const LeaderBind = struct { ch: u8, id: []const u8 };

/// The canonical id for any accepted spelling, as a STATIC string —
/// what an editor bind stores (the wire JSON it was parsed from is
/// freed) and what the id seam dispatches. The parameterized
/// `tab.select-N` has no static id and stays app-leader territory; it
/// resolves null here on purpose.
pub fn canonicalId(name: []const u8) ?[]const u8 {
    if (byId(name)) |c| return c.id;
    for (aliases) |a| {
        if (std.mem.eql(u8, name, a.name)) {
            if (byId(a.id)) |c| return c.id;
        }
    }
    return null;
}

pub fn byId(id: []const u8) ?Command {
    for (commands) |c| {
        if (std.mem.eql(u8, c.id, id)) return c;
    }
    return null;
}

/// Resolve any accepted spelling — canonical id, alias, or the
/// parameterized `tab.select-N` — to something dispatchable.
pub fn specFromName(name: []const u8) ?Spec {
    // Parameterized, so it cannot live in the table as one row. Digits
    // 1-9 are bound tmux-style by default; config can rebind them.
    if (std.mem.startsWith(u8, name, "tab.select-")) {
        const n = std.fmt.parseInt(u8, name["tab.select-".len..], 10) catch return null;
        if (n < 1 or n > 9) return null;
        return .{ .action = .tab_select, .arg = n };
    }
    if (byId(name)) |c| return .{ .action = c.action, .arg = c.arg };
    for (aliases) |a| {
        if (std.mem.eql(u8, name, a.name)) {
            if (byId(a.id)) |c| return .{ .action = c.action, .arg = c.arg };
        }
    }
    return null;
}

/// Resolve a live keybind back to its command — the which-key menu's
/// direction. `Command.keys` is a hand-written display string that a
/// rebind never updates, so a menu drawn from it would lie; the
/// truthful path is config's `Keybinds.entries` (action+arg) → this →
/// the title. First match wins, same as the table's other lookups.
pub fn byAction(action: Action, arg: u8) ?Command {
    for (commands) |c| {
        if (c.action == action and c.arg == arg) return c;
    }
    return null;
}

/// A command id as an ex-command name: "pane.split-right" →
/// "PaneSplitRight". Every non-alphanumeric run is a segment break and
/// each segment is capitalized, which lands on vim's own user-command
/// shape (leading uppercase) — so derived names cannot collide with
/// built-in `:w` / `:q` by construction.
pub fn exName(id: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var start_of_segment = true;
    for (id) |ch| {
        const alnum = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9');
        if (!alnum) {
            start_of_segment = true;
            continue;
        }
        if (n >= out.len) break;
        out[n] = if (start_of_segment) std.ascii.toUpper(ch) else ch;
        n += 1;
        start_of_segment = false;
    }
    return out[0..n];
}

/// Resolve a derived ex name (`PaneSplitRight`) back to its command.
/// The editor's `:` bridge is the caller: names are derived rather than
/// stored, so this recomputes rather than looking up a second table that
/// could disagree with the first.
pub fn byExName(name: []const u8) ?Command {
    var buf: [96]u8 = undefined;
    for (commands) |c| {
        if (std.mem.eql(u8, exName(c.id, &buf), name)) return c;
    }
    return null;
}

/// Vim's rule for user-defined commands: a lowercase name could shadow
/// `:w`, so it is not a legal ex name. Applied to config aliases too.
pub fn isExName(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] < 'A' or s[0] > 'Z') return false;
    for (s[1..]) |ch| {
        const alnum = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9');
        if (!alnum) return false;
    }
    return true;
}

// ----------------------------------------------------------------- tests

test "exName follows vim's user-command shape" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("PaneSplitRight", exName("pane.split-right", &buf));
    try std.testing.expectEqualStrings("TabNew", exName("tab.new", &buf));
    try std.testing.expectEqualStrings("PaletteCommands", exName("palette.commands", &buf));
    // Leading/trailing/doubled separators must not produce empty segments.
    try std.testing.expectEqualStrings("AB", exName(".a..b.", &buf));
    try std.testing.expectEqualStrings("", exName("...", &buf));
}

test "every derived ex name is a legal one" {
    var buf: [64]u8 = undefined;
    for (commands) |c| {
        try std.testing.expect(isExName(exName(c.id, &buf)));
    }
}

test "byExName round-trips every command, and refuses editor verbs" {
    var buf: [96]u8 = undefined;
    for (commands) |c| {
        const got = byExName(exName(c.id, &buf)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(c.id, got.id);
    }
    // The editor owns these; the bridge must never claim one. They are
    // lowercase, so vim's own rule already excludes them — this is the
    // regression test for that rule quietly changing.
    for ([_][]const u8{ "w", "q", "wq", "x", "e", "noh" }) |verb| {
        try std.testing.expect(byExName(verb) == null);
    }
}

test "byAction round-trips every command" {
    for (commands) |c| {
        const got = byAction(c.action, c.arg) orelse return error.TestUnexpectedResult;
        // Same action+arg, not necessarily same row — but the table has
        // one row per capability, so it must be the same row.
        try std.testing.expectEqualStrings(c.id, got.id);
    }
    // Parameterized tab.select has no table row; the menu handles it
    // as its own collapsed entry, and this stays null on purpose.
    try std.testing.expect(byAction(.tab_select, 3) == null);
}

test "isExName enforces the shadowing rule" {
    try std.testing.expect(isExName("PaneSplitRight"));
    try std.testing.expect(!isExName("write")); // would shadow :w
    try std.testing.expect(!isExName("Pane-Split")); // not alphanumeric
    try std.testing.expect(!isExName(""));
}

test "ids are unique and canonical" {
    for (commands, 0..) |a, i| {
        // The palette shows titles; two rows with one id would be a
        // duplicate capability rather than an alias.
        for (commands[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.id, b.id));
        }
        // Lowercase dotted: the shared config file is written this way,
        // and a stray capital would only ever resolve by accident.
        for (a.id) |ch| try std.testing.expect(ch < 'A' or ch > 'Z');
    }
}

test "aliases resolve, and never shadow a canonical id" {
    for (aliases) |a| {
        try std.testing.expect(byId(a.id) != null); // alias target exists
        try std.testing.expect(byId(a.name) == null); // alias is not itself a command
        try std.testing.expect(specFromName(a.name) != null);
    }
}

test "specFromName resolves ids, aliases and tab.select-N" {
    try std.testing.expectEqual(Action.split_right, specFromName("pane.split-right").?.action);
    try std.testing.expectEqual(Action.split_right, specFromName("app.split.vertical").?.action);
    try std.testing.expectEqual(Action.tab_new, specFromName("session.new").?.action);

    const sel = specFromName("tab.select-3").?;
    try std.testing.expectEqual(Action.tab_select, sel.action);
    try std.testing.expectEqual(@as(u8, 3), sel.arg);

    // Out of range and malformed both decline rather than clamping — a
    // config typo should do nothing, not something surprising.
    try std.testing.expect(specFromName("tab.select-0") == null);
    try std.testing.expect(specFromName("tab.select-10") == null);
    try std.testing.expect(specFromName("tab.select-x") == null);
    try std.testing.expect(specFromName("nope.nothing") == null);
}
