//! rook config: $XDG_CONFIG_HOME/rook/config.toml (default
//! ~/.config/rook/config.toml). A deliberate TOML subset — flat
//! `key = value` lines, # comments, quoted strings, numbers. Dashes and
//! underscores in keys are interchangeable (font-size == font_size).
//! Missing file = defaults.
//!
//! ONE FILE, TWO READERS. This is rook-host's config too, and most of
//! what is in it belongs to the host: coder, workflow, workspace-allow,
//! [agent], [jira], [lsp], [cloud], [workspaces.*]. So:
//!
//!   - Only TOP-LEVEL keys are ours. A key inside any [table] is
//!     someone else's by definition — parsing `url` out of [jira] as if
//!     it were a window setting is how a shared file goes wrong.
//!   - An unrecognised key is SILENT, not a warning. We are a guest in
//!     this file and cannot tell a typo from a host key we've never
//!     heard of. The cost is that our own typos are quiet too, which is
//!     the price of one config instead of two (NEXT.md's layered
//!     config.d/ is where this eventually gets its rigour back).

const std = @import("std");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// What sits behind a translucent window. `blur` = NSVisualEffectView
/// behind-window material (10.10+, boring, reliable); `glass` /
/// `glass-clear` = NSGlassEffectView, macOS 26's Liquid Glass (falls
/// back to blur pre-Tahoe). Needs background-opacity < 1 to be seen.
pub const Blur = enum { none, blur, glass, glass_clear };

pub fn blurFromName(name: []const u8) ?Blur {
    const map = [_]struct { n: []const u8, b: Blur }{
        .{ .n = "none", .b = .none },
        .{ .n = "blur", .b = .blur },
        .{ .n = "glass", .b = .glass },
        .{ .n = "glass-clear", .b = .glass_clear },
        .{ .n = "glass_clear", .b = .glass_clear },
        // Ghostty's names, for switchers' muscle memory.
        .{ .n = "macos-glass-regular", .b = .glass },
        .{ .n = "macos-glass-clear", .b = .glass_clear },
    };
    for (map) |m| {
        if (std.mem.eql(u8, name, m.n)) return m.b;
    }
    return null;
}

/// What BEL does. `visual` is the default because the signal that
/// matters is "which pane wants me", and that is the chip dot plus a
/// dock bounce — an agent finishing work in a background space should
/// be findable, not audible. `audible` adds NSBeep for people who want
/// the terminal to sound like a terminal.
pub const Bell = enum { none, visual, audible, all };

/// What OSC 52 may do. `allow` is the default and matches every other
/// terminal worth switching from: without it, yanking in vim or tmux
/// over ssh silently does nothing, which is the single most common
/// "why is my terminal broken" report there is.
///
/// It is a knob at all because a clipboard WRITE is an unprompted one:
/// any program that can put bytes on your screen — including `cat` of a
/// file you didn't write — can replace what your next ⌘V pastes. Reads
/// are not a question here; ghostty-vt never forwards them.
pub const ClipboardWrite = enum { allow, deny };

pub fn clipboardWriteFromName(name: []const u8) ?ClipboardWrite {
    if (std.mem.eql(u8, name, "allow") or std.mem.eql(u8, name, "true")) return .allow;
    if (std.mem.eql(u8, name, "deny") or std.mem.eql(u8, name, "false")) return .deny;
    return null;
}

/// Parse a byte size: a bare number, or one with a `kb`/`mb`/`gb`
/// suffix (case-insensitive, optional space, `k`/`m`/`g` accepted too).
///
/// Suffixes exist because this key is measured in BYTES and the useful
/// values are in the millions — `scrollback = 10485760` is a number
/// nobody can read, check, or edit with confidence.
pub fn parseSize(raw: []const u8) ?usize {
    const val = std.mem.trim(u8, raw, " \t\"");
    if (val.len == 0) return null;
    var i: usize = 0;
    while (i < val.len and val[i] >= '0' and val[i] <= '9') i += 1;
    if (i == 0) return null;
    const n = std.fmt.parseInt(usize, val[0..i], 10) catch return null;

    var unit_buf: [4]u8 = undefined;
    const rest = std.mem.trim(u8, val[i..], " \t");
    if (rest.len == 0) return n;
    if (rest.len > unit_buf.len) return null;
    const unit = std.ascii.lowerString(unit_buf[0..rest.len], rest);

    const mult: usize = if (std.mem.eql(u8, unit, "b"))
        1
    else if (std.mem.eql(u8, unit, "k") or std.mem.eql(u8, unit, "kb"))
        1024
    else if (std.mem.eql(u8, unit, "m") or std.mem.eql(u8, unit, "mb"))
        1024 * 1024
    else if (std.mem.eql(u8, unit, "g") or std.mem.eql(u8, unit, "gb"))
        1024 * 1024 * 1024
    else
        return null;
    return std.math.mul(usize, n, mult) catch null;
}

pub fn bellFromName(name: []const u8) ?Bell {
    if (std.mem.eql(u8, name, "none")) return .none;
    if (std.mem.eql(u8, name, "visual")) return .visual;
    if (std.mem.eql(u8, name, "audible")) return .audible;
    if (std.mem.eql(u8, name, "all") or std.mem.eql(u8, name, "both")) return .all;
    return null;
}

pub const Config = struct {
    font_size: f64 = 13,
    font_family: [:0]const u8 = "FiraCode Nerd Font Mono",
    /// Builtin theme name (theme.zig); unknown names warn + default.
    theme: []const u8 = "default",
    /// 1.0 = opaque. Anything lower forfeits direct-to-display
    /// scan-out (the compositor takes over: ~+5ms present lag
    /// fullscreen) — measured tradeoff, opt-in on purpose.
    background_opacity: f64 = 1.0,
    background_blur: Blur = .none,
    /// Points of breathing room between the chrome and the pane area
    /// (content otherwise runs to the very window edge). 0–32.
    window_padding: f64 = 0,
    bell: Bell = .visual,
    clipboard_write: ClipboardWrite = .allow,
    /// Scrollback per pane, in BYTES (the emulator's unit; it rounds up
    /// to a page and floors at one page's worth of the active area).
    /// Ghostty's own default, and for the same reason: rook previously
    /// took the library's EMBEDDED default of 10,000 bytes, which is a
    /// sane floor for a widget on someone else's screen and about 930
    /// rows for a terminal you live in. Launch-time only — resizing a
    /// live PageList's limit isn't something the library offers.
    scrollback: usize = 10 * 1024 * 1024,
};

/// One number over the config file — the live-reload poll compares this
/// at 1Hz (the file is tiny; reading beats fs-event plumbing). Keybinds
/// live in the same file now, so one read covers both.
pub fn digest(io: std.Io, gpa: std.mem.Allocator) u64 {
    var h = std.hash.Wyhash.init(0x400c);
    var pathbuf: [1024]u8 = undefined;
    if (cfgPath(&pathbuf)) |path| {
        if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch null) |data| {
            h.update(data);
            gpa.free(data);
        }
    }
    return h.final();
}

/// Trim a trailing `# comment` from a value.
///
/// A QUOTED value ends at its closing quote: `theme = "Nocturne" # nice`
/// has to yield `"Nocturne"`, and a # inside the quotes is data, not a
/// comment. The old code only stripped comments from unquoted values, so
/// a commented quoted line parsed as garbage and was dropped in silence
/// — which is how a keybind that was plainly in the file did nothing.
pub fn stripComment(val: []const u8) []const u8 {
    if (val.len > 0 and val[0] == '"') {
        var i: usize = 1;
        while (i < val.len) : (i += 1) {
            if (val[i] == '\\') {
                i += 1;
                continue;
            }
            if (val[i] == '"') return val[0 .. i + 1];
        }
        return val; // unterminated — leave it; unquote will decline it
    }
    if (std.mem.indexOfScalar(u8, val, '#')) |h|
        return std.mem.trim(u8, val[0..h], " \t");
    return val;
}

pub fn cfgPath(buf: []u8) ?[]const u8 {
    if (getenv("XDG_CONFIG_HOME")) |x| {
        return std.fmt.bufPrint(buf, "{s}/rook/config.toml", .{std.mem.span(x)}) catch null;
    }
    const home = getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/rook/config.toml", .{std.mem.span(home)}) catch null;
}

pub fn load(io: std.Io, gpa: std.mem.Allocator) Config {
    var cfg: Config = .{};

    var pathbuf: [1024]u8 = undefined;
    const path = cfgPath(&pathbuf) orelse return cfg;

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return cfg;
    defer gpa.free(data);

    var in_table = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        // Everything from the first [table] on belongs to someone else.
        if (line[0] == '[') {
            in_table = true;
            continue;
        }
        if (in_table) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;

        var key_raw = std.mem.trim(u8, line[0..eq], " \t");
        // TOML allows quoted keys ("background-opacity" = 0.9) — same key.
        if (key_raw.len >= 2 and key_raw[0] == '"' and key_raw[key_raw.len - 1] == '"')
            key_raw = key_raw[1 .. key_raw.len - 1];
        var keybuf: [64]u8 = undefined;
        if (key_raw.len > keybuf.len) continue;
        for (key_raw, 0..) |c, i| keybuf[i] = if (c == '-') '_' else c;
        const key = keybuf[0..key_raw.len];

        const val = stripComment(std.mem.trim(u8, line[eq + 1 ..], " \t"));

        if (std.mem.eql(u8, key, "font_size")) {
            cfg.font_size = std.fmt.parseFloat(f64, val) catch blk: {
                std.debug.print("rook config: bad font-size '{s}'\n", .{val});
                break :blk cfg.font_size;
            };
        } else if (std.mem.eql(u8, key, "font_family")) {
            const stripped = std.mem.trim(u8, val, "\"");
            if (stripped.len > 0) {
                cfg.font_family = gpa.dupeZ(u8, stripped) catch cfg.font_family;
            }
        } else if (std.mem.eql(u8, key, "background_opacity")) {
            cfg.background_opacity = std.fmt.parseFloat(f64, val) catch 1.0;
            if (cfg.background_opacity < 0.3 or cfg.background_opacity > 1.0) {
                std.debug.print("rook config: background-opacity {d} out of [0.3, 1.0], using 1.0\n", .{cfg.background_opacity});
                cfg.background_opacity = 1.0;
            }
        } else if (std.mem.eql(u8, key, "theme")) {
            const stripped = std.mem.trim(u8, val, "\"");
            if (stripped.len > 0) {
                cfg.theme = gpa.dupe(u8, stripped) catch cfg.theme;
            }
        } else if (std.mem.eql(u8, key, "window_padding") or
            std.mem.eql(u8, key, "window_padding_x") or
            std.mem.eql(u8, key, "window_padding_y"))
        {
            // The wails app spells it per-axis; rook insets uniformly.
            // Either name sets the one knob — last line wins, which for
            // the usual `x = y` pair is the same answer.
            cfg.window_padding = std.fmt.parseFloat(f64, val) catch 0;
            if (cfg.window_padding < 0 or cfg.window_padding > 32) {
                std.debug.print("rook config: window-padding {d} out of [0, 32], using 0\n", .{cfg.window_padding});
                cfg.window_padding = 0;
            }
        } else if (std.mem.eql(u8, key, "bell")) {
            const stripped = std.mem.trim(u8, val, "\"");
            cfg.bell = bellFromName(stripped) orelse blk: {
                std.debug.print("rook config: unknown bell '{s}' (none, visual, audible, all)\n", .{stripped});
                break :blk .visual;
            };
        } else if (std.mem.eql(u8, key, "scrollback") or
            std.mem.eql(u8, key, "scrollback_limit"))
        {
            // `scrollback-limit` is ghostty's spelling; same knob.
            cfg.scrollback = parseSize(val) orelse blk: {
                std.debug.print("rook config: bad scrollback '{s}' (bytes, or 10mb / 512kb)\n", .{val});
                break :blk cfg.scrollback;
            };
            // 0 means "no scrollback at all" and is a real answer. A
            // gigabyte is not; it's a typo with a unit attached.
            if (cfg.scrollback > 1024 * 1024 * 1024) {
                std.debug.print("rook config: scrollback {d} over the 1gb ceiling, using 1gb\n", .{cfg.scrollback});
                cfg.scrollback = 1024 * 1024 * 1024;
            }
        } else if (std.mem.eql(u8, key, "clipboard_write")) {
            const stripped = std.mem.trim(u8, val, "\"");
            cfg.clipboard_write = clipboardWriteFromName(stripped) orelse blk: {
                std.debug.print("rook config: unknown clipboard-write '{s}' (allow, deny)\n", .{stripped});
                break :blk .allow;
            };
        } else if (std.mem.eql(u8, key, "background_blur")) {
            const stripped = std.mem.trim(u8, val, "\"");
            cfg.background_blur = blurFromName(stripped) orelse blk: {
                std.debug.print("rook config: unknown background-blur '{s}' (none, blur, glass, glass-clear)\n", .{stripped});
                break :blk .none;
            };
        }
        // No else: unknown top-level keys are the host's. See the header.
    }

    if (cfg.font_size < 6 or cfg.font_size > 72) {
        std.debug.print("rook config: font-size {d} out of range, using 13\n", .{cfg.font_size});
        cfg.font_size = 13;
    }
    return cfg;
}

// ---- keybinds ----
//
// Same file. Leader chords, tmux-shaped: top-level `leader = "x"`, then
// a [keybinds] table of `"<leader>v" = "pane.split-right"` lines — the
// shape rook-host's config already uses. (`[app]` is the old rook
// keybinds.toml shape, still accepted so a pre-rename file keeps
// working.) Double-tap the leader to type it literally.
//
// Bindings name COMMANDS, and registry.zig is the list of them. A name
// rook does not implement yet is skipped in silence rather than warned
// about: the wails keymap has ~30 names to our registry's smaller set,
// and a config file listing them is correct rather than wrong — the
// commands arrive with their features. [editor] and its subtables
// belong to the editor scope and are parsed past.

// The names, the actions, and the aliases all live in registry.zig now:
// keybinds, the palette, and ctl must agree on what a command IS, and
// two tables drift. config depends on registry (never the reverse) so
// both stay leaf modules with their own test roots.
pub const registry = @import("registry.zig");
pub const Action = registry.Action;
pub const ActionSpec = registry.Spec;

const actionFromName = registry.specFromName;

pub const Bind = struct { ch: u8, action: Action, arg: u8 = 0 };

pub const Keybinds = struct {
    leader: ?u8 = null,
    entries: [32]Bind = undefined,
    n: usize = 0,

    pub fn lookup(self: *const Keybinds, ch: u8) ?Bind {
        for (self.entries[0..self.n]) |e| {
            if (e.ch == ch) return e;
        }
        return null;
    }

    /// Bind or rebind: a chord char holds one action (config lines
    /// replace defaults).
    fn bind(self: *Keybinds, ch: u8, spec: ActionSpec) void {
        for (self.entries[0..self.n]) |*e| {
            if (e.ch == ch) {
                e.* = .{ .ch = ch, .action = spec.action, .arg = spec.arg };
                return;
            }
        }
        if (self.n < self.entries.len) {
            self.entries[self.n] = .{ .ch = ch, .action = spec.action, .arg = spec.arg };
            self.n += 1;
        }
    }
};

/// Unquote a TOML basic string if quoted, resolving \" and \\.
/// Returns a slice into `buf`.
fn unquote(s: []const u8, buf: []u8) []const u8 {
    if (s.len < 2 or s[0] != '"' or s[s.len - 1] != '"') return s;
    const inner = s[1 .. s.len - 1];
    var n: usize = 0;
    var i: usize = 0;
    while (i < inner.len and n < buf.len) : (i += 1) {
        if (inner[i] == '\\' and i + 1 < inner.len) {
            i += 1;
            buf[n] = switch (inner[i]) {
                'n' => '\n',
                't' => '\t',
                else => inner[i], // \" \\ and anything else: literal
            };
        } else buf[n] = inner[i];
        n += 1;
    }
    return buf[0..n];
}

/// A chord key: one char, or a named key (TAB, SPACE, ESC).
fn chordChar(s: []const u8) ?u8 {
    if (s.len == 1) return s[0];
    if (std.mem.eql(u8, s, "TAB")) return '\t';
    if (std.mem.eql(u8, s, "SPACE")) return ' ';
    if (std.mem.eql(u8, s, "ESC")) return 0x1b;
    return null;
}

/// Find the first top-level '=' (outside quotes) — keys like
/// "<leader>\"" contain quote-escaped content.
fn topLevelEq(line: []const u8) ?usize {
    var in_quote = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_quote and c == '\\') {
            i += 1;
            continue;
        }
        if (c == '"') in_quote = !in_quote;
        if (!in_quote and c == '=') return i;
    }
    return null;
}

pub fn loadKeybinds(io: std.Io, gpa: std.mem.Allocator) Keybinds {
    var kb: Keybinds = .{};
    // tmux's defaults: <leader>1–9 jump to tabs, <leader>[ enters copy
    // mode. Config lines rebind.
    for (1..10) |d| kb.bind(@intCast('0' + d), .{ .action = .tab_select, .arg = @intCast(d) });
    kb.bind('[', .{ .action = .copy_mode });
    // tmux: prefix-s = choose-session. Spaces are sessions, so the
    // workspace palette lives on s ('w' stays free for a future
    // choose-window/tab picker, also tmux's).
    kb.bind('s', .{ .action = .workspace_switch });
    // tmux: prefix-z = resize-pane -Z. Same key, same muscle memory.
    kb.bind('z', .{ .action = .pane_zoom });
    // The attention inbox — the wails app's <leader>a, kept.
    kb.bind('a', .{ .action = .panel_attention });
    // …and back to a question you stepped away from.
    kb.bind('q', .{ .action = .panel_ask });

    var pathbuf: [1024]u8 = undefined;
    const path = cfgPath(&pathbuf) orelse return kb;

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return kb;
    defer gpa.free(data);

    // `none` is the top level, where `leader` lives (the editor's own
    // leader sits under [editor] and must not be mistaken for it).
    var section: enum { none, app, other } = .none;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            section = if (std.mem.eql(u8, line, "[keybinds]") or std.mem.eql(u8, line, "[app]"))
                .app
            else
                .other;
            continue;
        }
        if (section == .other) continue;

        const eq = topLevelEq(line) orelse continue;
        var keybuf: [64]u8 = undefined;
        var valbuf: [64]u8 = undefined;
        const key = unquote(std.mem.trim(u8, line[0..eq], " \t"), &keybuf);
        const val = stripComment(std.mem.trim(u8, line[eq + 1 ..], " \t"));
        const value = unquote(val, &valbuf);

        if (std.mem.eql(u8, key, "leader")) {
            kb.leader = chordChar(value) orelse blk: {
                std.debug.print("rook keybinds: leader must be one key, got '{s}'\n", .{value});
                break :blk null;
            };
        } else if (section == .app and std.mem.startsWith(u8, key, "<leader>")) {
            // An unsupported chord shape or an action we haven't built
            // yet: skip it. See the header — this file names commands
            // rook does not have, and that is not an error.
            const ch = chordChar(key["<leader>".len..]) orelse continue;
            const spec = actionFromName(value) orelse continue;
            kb.bind(ch, spec);
        }
    }

    if (kb.n > 0 and kb.leader == null)
        std.debug.print("rook keybinds: chords defined but no leader set — they are unreachable\n", .{});
    return kb;
}

// ---- tests ----
//
// The pure parsing rules get their own test root (build.zig), for the
// same reason paste.zig does: everything here fails SILENTLY by design
// — we are a guest in a shared file — so a broken rule shows up as a
// keybind that just doesn't work, with nothing on stderr to explain it.

test "stripComment: quoted value keeps its quotes, loses the comment" {
    const t = std.testing;
    try t.expectEqualStrings("\"tab.new\"", stripComment("\"tab.new\"  # carried over"));
    try t.expectEqualStrings("\"Nocturne\"", stripComment("\"Nocturne\""));
    // A # inside quotes is data.
    try t.expectEqualStrings("\"#ff00ff\"", stripComment("\"#ff00ff\" # a color"));
    // An escaped quote does not end the string.
    try t.expectEqualStrings("\"a\\\"b\"", stripComment("\"a\\\"b\" # x"));
}

test "stripComment: unquoted value" {
    const t = std.testing;
    try t.expectEqualStrings("0.9", stripComment("0.9 # eyeball it"));
    try t.expectEqualStrings("18", stripComment("18"));
    try t.expectEqualStrings("", stripComment("# only a comment"));
}

test "keybind values survive a trailing comment" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    const v = unquote(stripComment("\"tab.new\"  # carried over from rookz"), &buf);
    try t.expectEqualStrings("tab.new", v);
    try t.expect(actionFromName(v).?.action == .tab_new);
}

test "actionFromName takes the registry's names and rookz's aliases" {
    const t = std.testing;
    try t.expect(actionFromName("session.new").?.action == .tab_new);
    try t.expect(actionFromName("app.split.vertical").?.action == .split_right);
    try t.expect(actionFromName("tab.select-3").?.arg == 3);
    // A registry command rook has not built yet: skipped, not an error.
    try t.expect(actionFromName("workspace.manager") == null);
}

test "parseSize takes bytes, units, and neither silently" {
    const t = std.testing;
    try t.expectEqual(@as(?usize, 1024), parseSize("1024"));
    try t.expectEqual(@as(?usize, 10 * 1024 * 1024), parseSize("10mb"));
    // Case, spacing and the short spellings are all the same value —
    // this is a number a person types, not a wire format.
    try t.expectEqual(@as(?usize, 10 * 1024 * 1024), parseSize("10MB"));
    try t.expectEqual(@as(?usize, 10 * 1024 * 1024), parseSize("10 mb"));
    try t.expectEqual(@as(?usize, 10 * 1024 * 1024), parseSize("10m"));
    try t.expectEqual(@as(?usize, 512 * 1024), parseSize("512kb"));
    try t.expectEqual(@as(?usize, 2 * 1024 * 1024 * 1024), parseSize("2gb"));
    // 0 is a real answer: no scrollback at all.
    try t.expectEqual(@as(?usize, 0), parseSize("0"));
    // TOML quotes are the config's, not the value's.
    try t.expectEqual(@as(?usize, 10 * 1024 * 1024), parseSize("\"10mb\""));
    // Rejected, so the caller warns instead of taking a wrong number.
    try t.expect(parseSize("") == null);
    try t.expect(parseSize("mb") == null);
    try t.expect(parseSize("10tb") == null);
    try t.expect(parseSize("ten") == null);
    // Overflow must not wrap into a small, plausible-looking limit.
    try t.expect(parseSize("99999999999999999999gb") == null);
}

test "clipboard-write takes both the enum names and the booleans" {
    const t = std.testing;
    try t.expectEqual(ClipboardWrite.allow, clipboardWriteFromName("allow").?);
    try t.expectEqual(ClipboardWrite.deny, clipboardWriteFromName("deny").?);
    // TOML users reach for a bare bool for a yes/no knob; both spellings
    // mean the same thing, and only a real typo warns.
    try t.expectEqual(ClipboardWrite.allow, clipboardWriteFromName("true").?);
    try t.expectEqual(ClipboardWrite.deny, clipboardWriteFromName("false").?);
    try t.expect(clipboardWriteFromName("ask") == null);
}

test "topLevelEq ignores '=' inside a quoted key" {
    const t = std.testing;
    try t.expectEqual(@as(?usize, 7), topLevelEq("leader = \"`\""));
    // The key is "<leader>\"" — the escaped quote must not end it.
    const line = "\"<leader>\\\"\" = \"app.split.horizontal\"";
    const eq = topLevelEq(line).?;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("<leader>\"", unquote(std.mem.trim(u8, line[0..eq], " \t"), &buf));
}
