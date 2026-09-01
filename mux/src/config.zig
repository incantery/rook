//! Configuration, minimal, from the same ~/.config/rook/rook.toml
//! the Go rook uses. [tmux] prefix = "`" or "C-b" (compat), and a
//! [mux] section for knobs that earned one:
//!   nav_owners = ["nvim", "fzf"]   # programs that keep Ctrl-hjkl
//!   scrollback_mb = 4
//!   accent = "#cba6f7"             # chrome color: tabs, borders, popup
//!   restore = true                 # resurrect last layout on boot (default off)
//!   sidebar = true                 # the spaces/agents side panel
//!   sidebar_width = 30             # its width in columns
//!   agents = ["claude"]            # programs the agents rail looks for
//!
//! and the [companion] table the Go half already reads — the one
//! resident rook knows by name, so it can say when and where it is
//! open:
//!   [companion]
//!   command = "vera"               # what summons it; its first word
//!   program = "vera"               # …or the program outright, when
//!                                  # the command's first word is a
//!                                  # wrapper (`program = ""` = off)
const std = @import("std");
const chrome = @import("chrome.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub fn prefixKey() u8 {
    var buf: [4096]u8 = undefined;
    const home = std.mem.span(getenv("HOME") orelse return 0x02);
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/.config/rook/rook.toml", .{home}) catch return 0x02;
    const f = std.c.fopen(path, "r") orelse return 0x02;
    defer _ = std.c.fclose(f);
    const n = std.c.fread(&buf, 1, buf.len, f);
    return parsePrefix(buf[0..n]) orelse 0x02;
}

/// Finds `prefix = "..."` and translates tmux key syntax: "C-x" is
/// ctrl, a single char is itself.
pub fn parsePrefix(toml: []const u8) ?u8 {
    var lines = std.mem.splitScalar(u8, toml, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, t, "prefix")) continue;
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        const val = std.mem.trim(u8, t[eq + 1 ..], " \t\"'");
        if (val.len == 1) return val[0];
        if (val.len == 3 and (val[0] == 'C' or val[0] == 'c') and val[1] == '-') {
            const ch = std.ascii.toLower(val[2]);
            if (ch >= 'a' and ch <= 'z') return ch - 'a' + 1;
        }
    }
    return null;
}

/// The [mux] knobs, defaults matching the hardcoded originals.
pub const Mux = struct {
    /// newline-joined program names that own Ctrl-h/j/k/l
    owners: [512]u8 = @splat(0),
    owners_len: usize = 0,
    scrollback_bytes: usize = 4 * 1024 * 1024,
    /// The one chrome accent: the active tab chip, focused borders, the
    /// popup box. A hex color or one of the eight ANSI names, which map
    /// into the same palette.
    accent: chrome.Rgb = chrome.mauve,
    /// The side panel: on unless asked otherwise, and it folds away on
    /// glass too narrow for it regardless.
    sidebar: bool = true,
    sidebar_width: u16 = 30,
    /// Resurrect the last saved layout on server boot. Off by default:
    /// a fresh `rook` opens a clean workspace, not last session's splits.
    restore: bool = false,
    /// newline-joined foreground program names that mean "an agent is
    /// running in this pane". The one opinion rook holds about what an
    /// agent *is*, and the only reason it holds it: so a session
    /// somebody started by hand still shows up on the agents rail
    /// instead of being invisible to everything but the tab bar.
    agents: [256]u8 = @splat(0),
    agents_len: usize = 0,
    /// The companion's program name: the foreground program that
    /// means "the resident is open in this pane". One name, not a
    /// list — the slot is singular by design, and rook reports every
    /// pane running it. Empty *and set* turns the slot off; unset
    /// means `default_companion`.
    companion: [64]u8 = @splat(0),
    companion_len: usize = 0,
    companion_from: enum { none, name, command, program } = .none,

    pub fn ownersSlice(self: *const Mux) []const u8 {
        return self.owners[0..self.owners_len];
    }

    pub fn agentsSlice(self: *const Mux) []const u8 {
        if (self.agents_len == 0) return default_agents;
        return self.agents[0..self.agents_len];
    }

    /// The program rook watches for as the companion. Empty means the
    /// slot is off — either named empty, or the default overridden
    /// away — and rook then knows nothing about a companion, which is
    /// a legitimate thing to configure.
    pub fn companionSlice(self: *const Mux) []const u8 {
        if (self.companion_from == .none) return default_companion;
        return self.companion[0..self.companion_len];
    }

    /// Precedence, whichever order the lines appear in: `program`
    /// (said outright), then the first word of `command` (what
    /// summons her, which is usually her binary), then `name`.
    ///
    /// `name` last on purpose. To the Go half it labels the popup, not
    /// the program — a config that reads `command = "vera chat"` and
    /// `name = "Vera"` means one thing there and would mean another
    /// here, and a shared file where one key means two things is how
    /// `lsp` once cost the host its whole config. It is taken only
    /// when nothing better names the occupant.
    fn setCompanion(self: *Mux, val: []const u8, from: @TypeOf(@as(Mux, undefined).companion_from)) void {
        if (@intFromEnum(self.companion_from) > @intFromEnum(from)) return;
        const word = std.mem.sliceTo(std.mem.trim(u8, val, " \t"), ' ');
        const base = std.fs.path.basename(word);
        if (base.len > self.companion.len) return;
        @memcpy(self.companion[0..base.len], base);
        self.companion_len = base.len;
        self.companion_from = from;
    }
};

/// What rook looks for when nothing says otherwise. Claude Code names
/// its binary by version, so `pane.programName` is what makes this a
/// word rather than "2.1.241".
pub const default_agents = "claude";

/// The companion when the config names none. Rook ships the slot and
/// the config names the occupant — vera is the first one, and the one
/// the slot was cut for, so she is also the default.
pub const default_companion = "vera";

pub fn muxConfig() Mux {
    var out: Mux = .{};
    var buf: [8192]u8 = undefined;
    const home = std.mem.span(getenv("HOME") orelse return out);
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/.config/rook/rook.toml", .{home}) catch return out;
    const f = std.c.fopen(path, "r") orelse return out;
    defer _ = std.c.fclose(f);
    const n = std.c.fread(&buf, 1, buf.len, f);
    parseMux(buf[0..n], &out);
    return out;
}

pub fn parseMux(toml: []const u8, out: *Mux) void {
    var section: enum { other, mux, companion } = .other;
    var lines = std.mem.splitScalar(u8, toml, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        if (t[0] == '[') {
            section = if (std.mem.eql(u8, t, "[mux]"))
                .mux
            else if (std.mem.eql(u8, t, "[companion]"))
                .companion
            else
                .other;
            continue;
        }
        if (section == .other) continue;
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        const key = std.mem.trim(u8, t[0..eq], " \t");
        const val = std.mem.trim(u8, t[eq + 1 ..], " \t");
        if (section == .companion) {
            // The Go half's slot: `command` is what summons it and
            // `name` labels it. Any of the three can tell the engine
            // which program to watch for, in the order `setCompanion`
            // spells out; `key` is the front door's business and is
            // skipped here, as is anything else the table grows.
            const v = std.mem.trim(u8, val, "\"'");
            if (std.mem.eql(u8, key, "program")) {
                out.setCompanion(v, .program);
            } else if (std.mem.eql(u8, key, "command")) {
                out.setCompanion(v, .command);
            } else if (std.mem.eql(u8, key, "name")) {
                out.setCompanion(v, .name);
            }
            continue;
        }
        if (std.mem.eql(u8, key, "scrollback_mb")) {
            const mb = std.fmt.parseInt(usize, std.mem.trim(u8, val, "\"'"), 10) catch continue;
            const clamped: usize = @min(mb, 256);
            out.scrollback_bytes = clamped * 1024 * 1024;
        } else if (std.mem.eql(u8, key, "accent")) {
            const v = std.mem.trim(u8, val, "\"'");
            out.accent = chrome.Rgb.parse(v) orelse chrome.named(v) orelse out.accent;
        } else if (std.mem.eql(u8, key, "restore")) {
            const v = std.mem.trim(u8, val, "\"'");
            out.restore = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
        } else if (std.mem.eql(u8, key, "sidebar")) {
            const v = std.mem.trim(u8, val, "\"'");
            out.sidebar = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
        } else if (std.mem.eql(u8, key, "sidebar_width")) {
            const n = std.fmt.parseInt(u16, std.mem.trim(u8, val, "\"'"), 10) catch continue;
            out.sidebar_width = std.math.clamp(n, 16, 60);
        } else if (std.mem.eql(u8, key, "nav_owners")) {
            out.owners_len = parseList(val, &out.owners);
        } else if (std.mem.eql(u8, key, "agents")) {
            out.agents_len = parseList(val, &out.agents);
        }
    }
}

/// `["a", "b"]` → `a\nb` in `buf`; returns the length written. The
/// list form every [mux] list key uses.
fn parseList(val: []const u8, buf: []u8) usize {
    var len: usize = 0;
    var it = std.mem.tokenizeAny(u8, val, "[]\"', ");
    while (it.next()) |name| {
        if (len + name.len + 1 > buf.len) break;
        if (len > 0) {
            buf[len] = '\n';
            len += 1;
        }
        @memcpy(buf[len .. len + name.len], name);
        len += name.len;
    }
    return len;
}

test "parseMux" {
    var m: Mux = .{};
    parseMux("[mux]\nscrollback_mb = 8\naccent = \"cyan\"\nnav_owners = [\"nvim\", \"fzf\"]\n", &m);
    try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), m.scrollback_bytes);
    try std.testing.expectEqual(chrome.teal, m.accent);
    try std.testing.expectEqualStrings("nvim\nfzf", m.ownersSlice());
    var d: Mux = .{};
    parseMux("[tmux]\nprefix = \"`\"\naccent = \"red\"\n", &d);
    try std.testing.expectEqual(chrome.mauve, d.accent); // wrong section: ignored
    parseMux("[mux]\naccent = \"bright-blue\"\n", &d);
    try std.testing.expectEqual(chrome.blue, d.accent);
    parseMux("[mux]\naccent = \"#f9e2af\"\n", &d);
    try std.testing.expectEqual(chrome.yellow, d.accent);
    var sb: Mux = .{};
    try std.testing.expectEqual(true, sb.sidebar);
    try std.testing.expectEqual(@as(u16, 30), sb.sidebar_width);
    parseMux("[mux]\nsidebar = false\nsidebar_width = 999\n", &sb);
    try std.testing.expectEqual(false, sb.sidebar);
    try std.testing.expectEqual(@as(u16, 60), sb.sidebar_width); // clamped
    var r: Mux = .{};
    try std.testing.expectEqual(false, r.restore); // default off
    parseMux("[mux]\nrestore = true\n", &r);
    try std.testing.expectEqual(true, r.restore);
    parseMux("[mux]\nrestore = false\n", &r);
    try std.testing.expectEqual(false, r.restore);
    var a: Mux = .{};
    try std.testing.expectEqualStrings("claude", a.agentsSlice()); // the default
    parseMux("[mux]\nagents = [\"claude\", \"codex\"]\n", &a);
    try std.testing.expectEqualStrings("claude\ncodex", a.agentsSlice());
}

test "the companion slot, named or summoned" {
    const eq = std.testing.expectEqualStrings;
    // nothing configured: the slot still exists, with its first occupant
    var d: Mux = .{};
    try eq("vera", d.companionSlice());
    // the command's first word is the program to watch for
    var c: Mux = .{};
    parseMux("[companion]\ncommand = \"vera chat\"\nkey = \"g\"\n", &c);
    try eq("vera", c.companionSlice());
    // a path is still a program name
    var p: Mux = .{};
    parseMux("[companion]\ncommand = \"/opt/homebrew/bin/aider --dark\"\n", &p);
    try eq("aider", p.companionSlice());
    // `program` wins over the command, whichever order they come in
    var n: Mux = .{};
    parseMux("[companion]\ncommand = \"vera chat\"\nprogram = \"vera-dev\"\n", &n);
    try eq("vera-dev", n.companionSlice());
    var n2: Mux = .{};
    parseMux("[companion]\nprogram = \"vera-dev\"\ncommand = \"vera chat\"\n", &n2);
    try eq("vera-dev", n2.companionSlice());
    // …and `name` loses to the command: over there it labels the
    // popup, and a label is not a program name
    var l: Mux = .{};
    parseMux("[companion]\ncommand = \"vera chat\"\nname = \"Vera\"\n", &l);
    try eq("vera", l.companionSlice());
    // with nothing better, the label is what names the occupant
    var only: Mux = .{};
    parseMux("[companion]\nname = \"vera\"\nkey = \"g\"\n", &only);
    try eq("vera", only.companionSlice());
    // named empty: no companion at all, which is a thing to configure
    var off: Mux = .{};
    parseMux("[companion]\nprogram = \"\"\n", &off);
    try eq("", off.companionSlice());
    // a table that says nothing about the occupant still gets one
    var bare: Mux = .{};
    parseMux("[companion]\nkey = \"g\"\n", &bare);
    try eq("vera", bare.companionSlice());
    // the table only counts under its own header
    var elsewhere: Mux = .{};
    parseMux("[mux]\nname = \"nope\"\n[worktree]\ncommand = \"nope\"\n", &elsewhere);
    try eq("vera", elsewhere.companionSlice());
}

test "parsePrefix" {
    try std.testing.expectEqual(@as(?u8, 0x60), parsePrefix("[tmux]\nprefix = \"`\"\n"));
    try std.testing.expectEqual(@as(?u8, 0x02), parsePrefix("prefix = \"C-b\""));
    try std.testing.expectEqual(@as(?u8, 0x01), parsePrefix("prefix = 'C-a'"));
    try std.testing.expectEqual(@as(?u8, null), parsePrefix("[tmux]\nplugins = []\n"));
}
