//! rookz config: $XDG_CONFIG_HOME/rookz/config.toml (default
//! ~/.config/rookz/config.toml). A deliberate TOML subset — flat
//! `key = value` lines, # comments, quoted strings, numbers; [sections]
//! are skipped, not errors. Dashes and underscores in keys are
//! interchangeable (font-size == font_size). Missing file = defaults.

const std = @import("std");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub const Config = struct {
    font_size: f64 = 13,
    font_family: [:0]const u8 = "FiraCode Nerd Font Mono",
    /// Builtin theme name (theme.zig); unknown names warn + default.
    theme: []const u8 = "default",
    /// 1.0 = opaque. Anything lower forfeits direct-to-display
    /// scan-out (the compositor takes over: ~+5ms present lag
    /// fullscreen) — measured tradeoff, opt-in on purpose.
    background_opacity: f64 = 1.0,
};

/// One number over both config files — the live-reload poll compares
/// this at 1Hz (files are tiny; reading beats fs-event plumbing).
pub fn digest(io: std.Io, gpa: std.mem.Allocator) u64 {
    var h = std.hash.Wyhash.init(0x400c);
    var pathbuf: [1024]u8 = undefined;
    inline for (.{ "config.toml", "keybinds.toml" }) |name| {
        if (cfgPath(&pathbuf, name)) |path| {
            if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch null) |data| {
                h.update(data);
                gpa.free(data);
            }
        }
        h.update(&.{0});
    }
    return h.final();
}

fn cfgPath(buf: []u8, comptime name: []const u8) ?[]const u8 {
    if (getenv("XDG_CONFIG_HOME")) |x| {
        return std.fmt.bufPrint(buf, "{s}/rookz/" ++ name, .{std.mem.span(x)}) catch null;
    }
    const home = getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/rookz/" ++ name, .{std.mem.span(home)}) catch null;
}

pub fn load(io: std.Io, gpa: std.mem.Allocator) Config {
    var cfg: Config = .{};

    var pathbuf: [1024]u8 = undefined;
    const path = blk: {
        if (getenv("XDG_CONFIG_HOME")) |x| {
            break :blk std.fmt.bufPrint(&pathbuf, "{s}/rookz/config.toml", .{std.mem.span(x)}) catch return cfg;
        }
        const home = getenv("HOME") orelse return cfg;
        break :blk std.fmt.bufPrint(&pathbuf, "{s}/.config/rookz/config.toml", .{std.mem.span(home)}) catch return cfg;
    };

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return cfg;
    defer gpa.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;

        var key_raw = std.mem.trim(u8, line[0..eq], " \t");
        // TOML allows quoted keys ("background-opacity" = 0.9) — same key.
        if (key_raw.len >= 2 and key_raw[0] == '"' and key_raw[key_raw.len - 1] == '"')
            key_raw = key_raw[1 .. key_raw.len - 1];
        var keybuf: [64]u8 = undefined;
        if (key_raw.len > keybuf.len) continue;
        for (key_raw, 0..) |c, i| keybuf[i] = if (c == '-') '_' else c;
        const key = keybuf[0..key_raw.len];

        var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        // Strip a trailing comment on unquoted values.
        if (val.len == 0 or val[0] != '"') {
            if (std.mem.indexOfScalar(u8, val, '#')) |hash| {
                val = std.mem.trim(u8, val[0..hash], " \t");
            }
        }

        if (std.mem.eql(u8, key, "font_size")) {
            cfg.font_size = std.fmt.parseFloat(f64, val) catch blk: {
                std.debug.print("rookz config: bad font-size '{s}'\n", .{val});
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
                std.debug.print("rookz config: background-opacity {d} out of [0.3, 1.0], using 1.0\n", .{cfg.background_opacity});
                cfg.background_opacity = 1.0;
            }
        } else if (std.mem.eql(u8, key, "theme")) {
            const stripped = std.mem.trim(u8, val, "\"");
            if (stripped.len > 0) {
                cfg.theme = gpa.dupe(u8, stripped) catch cfg.theme;
            }
        } else {
            std.debug.print("rookz config: unknown key '{s}' (known: font-size, font-family, theme, background-opacity)\n", .{key_raw});
        }
    }

    if (cfg.font_size < 6 or cfg.font_size > 72) {
        std.debug.print("rookz config: font-size {d} out of range, using 13\n", .{cfg.font_size});
        cfg.font_size = 13;
    }
    return cfg;
}

// ---- keybinds.toml ----
//
// Leader chords, tmux-shaped: `leader = "x"` in [app], then
// `"<leader>v" = "pane.split-right"` lines. Double-tap the leader to
// type it literally; an unknown chord key is swallowed. Canonical
// action names are the wails keymap's (pane.split-right, pane.
// split-down, pane.focus-*, tab.new/next/prev); a few aliases from
// Seth's first file are accepted. [editor] is parsed past, not into —
// there is no editor yet.

pub const Action = enum {
    split_right,
    split_down,
    focus_left,
    focus_right,
    focus_up,
    focus_down,
    tab_new,
    tab_next,
    tab_prev,
    /// Jump to tab `arg` (1-based). Digits 1–9 are bound by default,
    /// tmux-style; config can rebind them.
    tab_select,
    /// tmux copy mode: keys scroll the focused terminal's viewport.
    /// <leader>[ by default.
    copy_mode,
};

pub const ActionSpec = struct { action: Action, arg: u8 = 0 };

fn actionFromName(name: []const u8) ?ActionSpec {
    if (std.mem.startsWith(u8, name, "tab.select-")) {
        const n = std.fmt.parseInt(u8, name["tab.select-".len..], 10) catch return null;
        if (n < 1 or n > 9) return null;
        return .{ .action = .tab_select, .arg = n };
    }
    const map = [_]struct { n: []const u8, a: Action }{
        .{ .n = "pane.split-right", .a = .split_right },
        .{ .n = "app.split.vertical", .a = .split_right }, // vim :vsplit sense
        .{ .n = "pane.split-down", .a = .split_down },
        .{ .n = "app.split.horizontal", .a = .split_down },
        .{ .n = "pane.focus-left", .a = .focus_left },
        .{ .n = "pane.focus-right", .a = .focus_right },
        .{ .n = "pane.focus-up", .a = .focus_up },
        .{ .n = "pane.focus-down", .a = .focus_down },
        .{ .n = "tab.new", .a = .tab_new },
        .{ .n = "session.new", .a = .tab_new }, // the wails keymap's name for it
        .{ .n = "tab.next", .a = .tab_next },
        .{ .n = "tab.prev", .a = .tab_prev },
        .{ .n = "copy-mode", .a = .copy_mode }, // tmux's name
        .{ .n = "pane.scrollback", .a = .copy_mode },
    };
    for (map) |m| {
        if (std.mem.eql(u8, name, m.n)) return .{ .action = m.a };
    }
    return null;
}

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

    var pathbuf: [1024]u8 = undefined;
    const path = blk: {
        if (getenv("XDG_CONFIG_HOME")) |x| {
            break :blk std.fmt.bufPrint(&pathbuf, "{s}/rookz/keybinds.toml", .{std.mem.span(x)}) catch return kb;
        }
        const home = getenv("HOME") orelse return kb;
        break :blk std.fmt.bufPrint(&pathbuf, "{s}/.config/rookz/keybinds.toml", .{std.mem.span(home)}) catch return kb;
    };

    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return kb;
    defer gpa.free(data);

    var section: enum { none, app, other } = .none;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            if (std.mem.eql(u8, line, "[app]")) {
                section = .app;
            } else {
                section = .other;
                if (std.mem.eql(u8, line, "[editor]"))
                    std.debug.print("rookz keybinds: [editor] noted — no editor yet, skipped\n", .{});
            }
            continue;
        }
        if (section != .app) continue;

        const eq = topLevelEq(line) orelse continue;
        var keybuf: [64]u8 = undefined;
        var valbuf: [64]u8 = undefined;
        const key = unquote(std.mem.trim(u8, line[0..eq], " \t"), &keybuf);
        var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (val.len > 0 and val[0] != '"') {
            if (std.mem.indexOfScalar(u8, val, '#')) |hash| val = std.mem.trim(u8, val[0..hash], " \t");
        }
        const value = unquote(val, &valbuf);

        if (std.mem.eql(u8, key, "leader")) {
            kb.leader = chordChar(value) orelse blk: {
                std.debug.print("rookz keybinds: leader must be one key, got '{s}'\n", .{value});
                break :blk null;
            };
        } else if (std.mem.startsWith(u8, key, "<leader>")) {
            const ch = chordChar(key["<leader>".len..]) orelse {
                std.debug.print("rookz keybinds: unsupported chord key '{s}'\n", .{key});
                continue;
            };
            const spec = actionFromName(value) orelse {
                std.debug.print("rookz keybinds: unknown action '{s}' for '{s}'\n", .{ value, key });
                continue;
            };
            kb.bind(ch, spec);
        } else {
            std.debug.print("rookz keybinds: only <leader> chords supported yet, ignoring '{s}'\n", .{key});
        }
    }

    if (kb.n > 0 and kb.leader == null)
        std.debug.print("rookz keybinds: chords defined but no leader set — they are unreachable\n", .{});
    return kb;
}
