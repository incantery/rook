//! Configuration, minimal, from the same ~/.config/rook/rook.toml
//! the Go rook uses. [tmux] prefix = "`" or "C-b" (compat), and a
//! [mux] section for knobs that earned one:
//!   nav_owners = ["nvim", "fzf"]   # programs that keep Ctrl-hjkl
//!   scrollback_mb = 4
//!   accent = "#cba6f7"             # chrome color: tabs, borders, popup
//!   restore = false                # skip resurrecting the last layout on boot
//!   sidebar_mode = "hidden"        # the legacy spaces/agents side panel:
//!                                  # open, collapsed, hidden
//!   sidebar = false                # the older spelling: true = open
//!   sidebar_width = 30             # its width in columns, open
//!   agents = ["claude"]            # programs the agents rail looks for
//!                                  # (none unless named)
//!   bar = true                     # the calm bar: one row at the bottom,
//!                                  # who holds the focused pane's keys
//!                                  # left, signals right (false = off)
//!   glyphs = "unicode"             # "ascii" for a glass without the marks
//!   status_space = ["input", "-", "working", "attention", "unread", "pins"]
//!                                  # the calm bar's modules; "-" is where
//!                                  # the right-aligned ones start (also
//!                                  # agents, blocked, session)
//!   startup = "home"               # where plain `rook` lands: "home", or
//!                                  # "last-space" for the space you were in
//!
//! the [companion] table the Go half already reads — the one resident
//! rook knows by name, so it can say when and where it is open. Rook
//! names no occupant: without this table there is none.
//!   [companion]
//!   command = "vera"               # what summons it; its first word
//!   program = "vera"               # …or the program outright, when
//!                                  # the command's first word is a
//!                                  # wrapper (`program = ""` = off)
//!
//! [home] (`Home`, below), and [keys] — what each key after the prefix
//! does — which is keys.zig's, read by `keysConfig`.
const std = @import("std");
const chrome = @import("chrome.zig");
const keyspkg = @import("keys.zig");

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
    /// The legacy side panel. Hidden unless asked for: the frame is
    /// the tab bar, the work at full width, and the calm bar, and
    /// home (prefix-o) is where the spaces and the agents are
    /// looked at. A config that says `sidebar_mode = "open"` gets the
    /// rail back, folding to the collapsed dots on narrow glass and
    /// away when even that would crowd the work. `sidebar = true` is
    /// the older spelling of `.open`, and the later of the two lines
    /// in a file wins.
    side_mode: chrome.SideMode = .hidden,
    sidebar_width: u16 = 30,
    /// Resurrect the last saved layout on server boot: workspaces,
    /// windows, cwds, and every pane that told rook how to bring its
    /// program back (`rook resume`). On by default since resume exists;
    /// a boot with nothing saved opens a clean workspace either way.
    restore: bool = true,
    /// newline-joined foreground program names that mean "an agent is
    /// running in this pane", so a session somebody started by hand
    /// still shows up on the agents rail instead of being invisible to
    /// everything but the tab bar. Rook names none itself: empty means
    /// the rail sees only what a producer pushes.
    agents: [256]u8 = @splat(0),
    agents_len: usize = 0,
    /// The companion's program name: the foreground program that
    /// means "the resident is open in this pane". One name, not a
    /// list — the slot is singular by design, and rook reports every
    /// pane running it. Empty means no companion: rook ships the slot,
    /// and only the config names an occupant.
    companion: [64]u8 = @splat(0),
    companion_len: usize = 0,
    companion_from: enum { none, name, command, program } = .none,
    /// The calm bar at the bottom of the glass. On by default and
    /// kept on: appearing and disappearing would resize every hosted
    /// TUI, the one motion rook must never cause, so the choice is
    /// made once here rather than per signal.
    bar: bool = true,
    /// ASCII marks and glyphs for a glass that cannot show the
    /// Unicode ones. The inks and fills are the same, so the
    /// hierarchy survives the swap (docs/ui-design-system.md).
    ascii_glyphs: bool = false,
    /// Where a glass lands: home, unless `last-space` asks for the
    /// space the server is showing instead.
    startup_last_space: bool = false,
    /// The calm bar's modules, newline-joined names. Empty means the
    /// default composition.
    status_space: [256]u8 = @splat(0),
    status_space_len: usize = 0,

    pub fn ownersSlice(self: *const Mux) []const u8 {
        return self.owners[0..self.owners_len];
    }

    pub fn agentsSlice(self: *const Mux) []const u8 {
        return self.agents[0..self.agents_len];
    }

    /// The program rook watches for as the companion. Empty means the
    /// slot is off, and rook then knows nothing about a companion.
    pub fn companionSlice(self: *const Mux) []const u8 {
        return self.companion[0..self.companion_len];
    }

    pub fn statusSpace(self: *const Mux) []const u8 {
        return if (self.status_space_len > 0) self.status_space[0..self.status_space_len] else default_status_space;
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

/// Who holds the keys, then the signals, with one global attention
/// count and no more of a dashboard than that.
pub const default_status_space = "input\n-\nworking\nattention\nunread\npins";

/// The prefix table: rook's defaults under the file's [keys] (keys.zig).
pub fn keysConfig() keyspkg.Keys {
    var buf: [8192]u8 = undefined;
    const home = std.mem.span(getenv("HOME") orelse return keyspkg.defaults());
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/.config/rook/rook.toml", .{home}) catch return keyspkg.defaults();
    const f = std.c.fopen(path, "r") orelse return keyspkg.defaults();
    defer _ = std.c.fclose(f);
    const n = std.c.fread(&buf, 1, buf.len, f);
    return keyspkg.load(buf[0..n]);
}

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
            const on = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
            out.side_mode = if (on) .open else .hidden;
        } else if (std.mem.eql(u8, key, "sidebar_mode")) {
            const v = std.mem.trim(u8, val, "\"'");
            out.side_mode = chrome.SideMode.parse(v) orelse out.side_mode;
        } else if (std.mem.eql(u8, key, "sidebar_width")) {
            const n = std.fmt.parseInt(u16, std.mem.trim(u8, val, "\"'"), 10) catch continue;
            out.sidebar_width = std.math.clamp(n, 16, 60);
        } else if (std.mem.eql(u8, key, "nav_owners")) {
            out.owners_len = parseList(val, &out.owners);
        } else if (std.mem.eql(u8, key, "agents")) {
            out.agents_len = parseList(val, &out.agents);
        } else if (std.mem.eql(u8, key, "bar")) {
            const v = std.mem.trim(u8, val, "\"'");
            out.bar = !(std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "off"));
        } else if (std.mem.eql(u8, key, "glyphs")) {
            const v = std.mem.trim(u8, val, "\"'");
            out.ascii_glyphs = std.mem.eql(u8, v, "ascii");
        } else if (std.mem.eql(u8, key, "status_space")) {
            out.status_space_len = parseList(val, &out.status_space);
        } else if (std.mem.eql(u8, key, "startup")) {
            const v = std.mem.trim(u8, val, "\"'");
            out.startup_last_space = std.mem.eql(u8, v, "last-space") or std.mem.eql(u8, v, "last_space") or std.mem.eql(u8, v, "space");
        }
    }
}

/// Home: the one workspace outside the list of spaces, a key away
/// from any of them (docs/home.md). Rook seeds it from here when it
/// is gone to and it is not there; with nothing configured it is one
/// shell in `~`, a scratch pad.
///
///   [home]
///   on_empty = "return"      # its last pane closed: back to the space
///                            # you came from, and home starts over next
///                            # time; "stay" seeds it again in place
///   dir = "~"                # where its panes start, unless they say
///   color = "cyan"           # its accent, and its chrome's tint (a hex
///                            # colour or an ANSI name; the accent unset)
///   [[home.window]]
///   name = "me"
///   dir = "~/work"
///   panes = ["grim", "docket"]        # each a pane, side by side
///   [[home.window]]
///   name = "notes"
///   [[home.window.pane]]
///   command = "nvim scratch.md"
///   dir = "~/notes"
///   [[home.window.pane]]
///   split = "down"                    # a shell, under it
pub const Home = struct {
    pub const max_windows = 8;
    pub const max_panes = 8;
    /// A string in `buf`: `Home` is returned by value, so it holds no
    /// slices into itself.
    pub const Str = struct { off: u16 = 0, len: u16 = 0 };
    pub const Pane = struct { cmd: Str = .{}, dir: Str = .{}, down: bool = false };
    pub const Window = struct {
        name: Str = .{},
        dir: Str = .{},
        panes: [max_panes]Pane = @splat(.{}),
        panes_n: usize = 0,
    };

    stay: bool = false,
    /// Home's colour: its accent, and what its chrome is tinted
    /// toward. Null is the config's accent.
    color: ?chrome.Rgb = null,
    dir: Str = .{},
    windows: [max_windows]Window = @splat(.{}),
    windows_n: usize = 0,
    buf: [4096]u8 = undefined,
    buf_len: usize = 0,

    pub fn str(self: *const Home, s: Str) []const u8 {
        return self.buf[s.off..][0..s.len];
    }

    fn keep(self: *Home, v: []const u8) Str {
        if (self.buf_len + v.len > self.buf.len) return .{};
        @memcpy(self.buf[self.buf_len..][0..v.len], v);
        const out: Str = .{ .off = @intCast(self.buf_len), .len = @intCast(v.len) };
        self.buf_len += v.len;
        return out;
    }
};

pub fn homeConfig() Home {
    var out: Home = .{};
    var buf: [8192]u8 = undefined;
    const home = std.mem.span(getenv("HOME") orelse return out);
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/.config/rook/rook.toml", .{home}) catch return out;
    const f = std.c.fopen(path, "r") orelse return out;
    defer _ = std.c.fclose(f);
    const n = std.c.fread(&buf, 1, buf.len, f);
    parseHome(buf[0..n], &out);
    return out;
}

pub fn parseHome(toml: []const u8, out: *Home) void {
    var section: enum { other, home, window, pane } = .other;
    var lines = std.mem.splitScalar(u8, toml, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or t[0] == '#') continue;
        if (t[0] == '[') {
            if (std.mem.eql(u8, t, "[home]")) {
                section = .home;
            } else if (std.mem.eql(u8, t, "[[home.window]]")) {
                section = .other;
                if (out.windows_n < Home.max_windows) {
                    out.windows[out.windows_n] = .{};
                    out.windows_n += 1;
                    section = .window;
                }
            } else if (std.mem.eql(u8, t, "[[home.window.pane]]")) {
                section = .other;
                if (out.windows_n > 0) {
                    const w = &out.windows[out.windows_n - 1];
                    if (w.panes_n < Home.max_panes) {
                        w.panes[w.panes_n] = .{};
                        w.panes_n += 1;
                        section = .pane;
                    }
                }
            } else section = .other;
            continue;
        }
        if (section == .other) continue;
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        const key = std.mem.trim(u8, t[0..eq], " \t");
        const raw = std.mem.trim(u8, t[eq + 1 ..], " \t");
        switch (section) {
            .home => {
                const v = quoted(raw) orelse continue;
                if (std.mem.eql(u8, key, "on_empty")) {
                    out.stay = std.mem.eql(u8, v, "stay");
                } else if (std.mem.eql(u8, key, "dir")) {
                    out.dir = out.keep(v);
                } else if (std.mem.eql(u8, key, "color")) {
                    out.color = chrome.Rgb.parse(v) orelse chrome.named(v);
                }
            },
            .window => {
                const w = &out.windows[out.windows_n - 1];
                if (std.mem.eql(u8, key, "name")) {
                    w.name = out.keep(quoted(raw) orelse continue);
                } else if (std.mem.eql(u8, key, "dir")) {
                    w.dir = out.keep(quoted(raw) orelse continue);
                } else if (std.mem.eql(u8, key, "panes")) {
                    // a list of commands, each quoted: commands have
                    // spaces, so this is not parseList's split on them
                    var rest = raw;
                    while (std.mem.indexOfAny(u8, rest, "\"'")) |q| {
                        const close = std.mem.indexOfScalarPos(u8, rest, q + 1, rest[q]) orelse break;
                        if (w.panes_n < Home.max_panes) {
                            w.panes[w.panes_n] = .{ .cmd = out.keep(rest[q + 1 .. close]) };
                            w.panes_n += 1;
                        }
                        rest = rest[close + 1 ..];
                    }
                }
            },
            .pane => {
                const w = &out.windows[out.windows_n - 1];
                const p = &w.panes[w.panes_n - 1];
                const v = quoted(raw) orelse continue;
                if (std.mem.eql(u8, key, "command")) {
                    p.cmd = out.keep(v);
                } else if (std.mem.eql(u8, key, "dir")) {
                    p.dir = out.keep(v);
                } else if (std.mem.eql(u8, key, "split")) {
                    p.down = std.mem.eql(u8, v, "down");
                }
            },
            .other => {},
        }
    }
}

/// `"x"` or `'x'` → `x`; a trailing `# comment` after the value is fine.
fn quoted(raw: []const u8) ?[]const u8 {
    if (raw.len < 2 or (raw[0] != '"' and raw[0] != '\'')) return null;
    const close = std.mem.indexOfScalarPos(u8, raw, 1, raw[0]) orelse return null;
    return raw[1..close];
}

/// A home directory as the config spells it: `~` and `~/x` are under
/// $HOME, and so is a relative path — home is not anywhere else.
pub fn expandDir(dir: []const u8, buf: []u8) ?[:0]const u8 {
    const h = std.mem.span(getenv("HOME") orelse return null);
    if (dir.len == 0 or std.mem.eql(u8, dir, "~")) return std.fmt.bufPrintZ(buf, "{s}", .{h}) catch null;
    if (std.mem.startsWith(u8, dir, "~/")) return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ h, dir[2..] }) catch null;
    if (dir[0] == '/') return std.fmt.bufPrintZ(buf, "{s}", .{dir}) catch null;
    return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ h, dir }) catch null;
}

test "home: nothing configured is a scratch pad" {
    var h: Home = .{};
    parseHome("[tmux]\nprefix = \"`\"\n", &h);
    try std.testing.expectEqual(@as(usize, 0), h.windows_n);
    try std.testing.expect(!h.stay);
}

test "home: windows, their panes, and where they start" {
    var h: Home = .{};
    parseHome(
        \\[home]
        \\on_empty = "stay"
        \\color = "cyan"
        \\dir = "~/work"
        \\[[home.window]]
        \\name = "me"
        \\panes = ["grim", "docket --all"]  # side by side
        \\[[home.window]]
        \\name = "notes"
        \\dir = "~/notes"
        \\[[home.window.pane]]
        \\command = "nvim scratch.md"
        \\[[home.window.pane]]
        \\dir = "archive"
        \\split = "down"
        \\[keys]
        \\name = "not a window"
    , &h);
    const eq = std.testing.expectEqualStrings;
    try std.testing.expect(h.stay);
    try std.testing.expectEqual(@as(?chrome.Rgb, chrome.teal), h.color);
    try eq("~/work", h.str(h.dir));
    try std.testing.expectEqual(@as(usize, 2), h.windows_n);
    const me = h.windows[0];
    try eq("me", h.str(me.name));
    try std.testing.expectEqual(@as(usize, 2), me.panes_n);
    try eq("grim", h.str(me.panes[0].cmd));
    try eq("docket --all", h.str(me.panes[1].cmd));
    const notes = h.windows[1];
    try eq("notes", h.str(notes.name));
    try eq("~/notes", h.str(notes.dir));
    try std.testing.expectEqual(@as(usize, 2), notes.panes_n);
    try eq("nvim scratch.md", h.str(notes.panes[0].cmd));
    try eq("", h.str(notes.panes[1].cmd));
    try eq("archive", h.str(notes.panes[1].dir));
    try std.testing.expect(notes.panes[1].down and !notes.panes[0].down);
    // a pane table before any window has nowhere to go
    var stray: Home = .{};
    parseHome("[[home.window.pane]]\ncommand = \"x\"\n", &stray);
    try std.testing.expectEqual(@as(usize, 0), stray.windows_n);
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
    try std.testing.expectEqual(chrome.SideMode.hidden, sb.side_mode); // off unless asked
    try std.testing.expectEqual(@as(u16, 30), sb.sidebar_width);
    parseMux("[mux]\nsidebar = true\n", &sb);
    try std.testing.expectEqual(chrome.SideMode.open, sb.side_mode);
    parseMux("[mux]\nsidebar = false\nsidebar_width = 999\n", &sb);
    try std.testing.expectEqual(chrome.SideMode.hidden, sb.side_mode); // the old spelling
    try std.testing.expectEqual(@as(u16, 60), sb.sidebar_width); // clamped
    parseMux("[mux]\nsidebar_mode = \"collapsed\"\n", &sb);
    try std.testing.expectEqual(chrome.SideMode.collapsed, sb.side_mode);
    parseMux("[mux]\nsidebar_mode = \"folded\"\n", &sb);
    try std.testing.expectEqual(chrome.SideMode.collapsed, sb.side_mode); // a name it does not know changes nothing
    var r: Mux = .{};
    try std.testing.expectEqual(true, r.restore); // default on
    parseMux("[mux]\nrestore = true\n", &r);
    try std.testing.expectEqual(true, r.restore);
    parseMux("[mux]\nrestore = false\n", &r);
    try std.testing.expectEqual(false, r.restore);
    var a: Mux = .{};
    try std.testing.expectEqualStrings("", a.agentsSlice()); // rook names no agent
    parseMux("[mux]\nagents = [\"claude\", \"codex\"]\n", &a);
    try std.testing.expectEqualStrings("claude\ncodex", a.agentsSlice());
    var b: Mux = .{};
    try std.testing.expect(b.bar); // the calm bar is on unless turned off
    parseMux("[mux]\nbar = false\n", &b);
    try std.testing.expect(!b.bar);
    parseMux("[mux]\nbar = true\n", &b);
    try std.testing.expect(b.bar);
    try std.testing.expect(!b.ascii_glyphs);
    parseMux("[mux]\nglyphs = \"ascii\"\n", &b);
    try std.testing.expect(b.ascii_glyphs);
    // plain `rook` lands at home unless the config asks for the space
    var s: Mux = .{};
    try std.testing.expect(!s.startup_last_space);
    parseMux("[mux]\nstartup = \"last-space\"\n", &s);
    try std.testing.expect(s.startup_last_space);
    parseMux("[mux]\nstartup = \"global\"\n", &s);
    try std.testing.expect(!s.startup_last_space);
}

test "the status bar's modules are the default until a config names them" {
    var d: Mux = .{};
    try std.testing.expectEqualStrings(default_status_space, d.statusSpace());
    parseMux("[mux]\nstatus_space = [\"input\"]\n", &d);
    try std.testing.expectEqualStrings("input", d.statusSpace());
}

test "the companion slot, named or summoned" {
    const eq = std.testing.expectEqualStrings;
    // nothing configured: the slot is empty — rook names no occupant
    var d: Mux = .{};
    try eq("", d.companionSlice());
    // the command's first word is the program to watch for
    var c: Mux = .{};
    parseMux("[companion]\ncommand = \"vera chat\"\n", &c);
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
    parseMux("[companion]\nname = \"vera\"\n", &only);
    try eq("vera", only.companionSlice());
    // program named empty over a command: no companion at all
    var off: Mux = .{};
    parseMux("[companion]\ncommand = \"vera chat\"\nprogram = \"\"\n", &off);
    try eq("", off.companionSlice());
    // the table only counts under its own header
    var elsewhere: Mux = .{};
    parseMux("[mux]\nname = \"nope\"\n[worktree]\ncommand = \"nope\"\n", &elsewhere);
    try eq("", elsewhere.companionSlice());
}

test "parsePrefix" {
    try std.testing.expectEqual(@as(?u8, 0x60), parsePrefix("[tmux]\nprefix = \"`\"\n"));
    try std.testing.expectEqual(@as(?u8, 0x02), parsePrefix("prefix = \"C-b\""));
    try std.testing.expectEqual(@as(?u8, 0x01), parsePrefix("prefix = 'C-a'"));
    try std.testing.expectEqual(@as(?u8, null), parsePrefix("[tmux]\nplugins = []\n"));
}
