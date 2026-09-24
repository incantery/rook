//! Configuration, as the engine is handed it. The Go front door owns
//! rook.toml: `rook config json` parses it with a real TOML parser,
//! refuses what is wrong with it, and prints one JSON document — the
//! engine's half, already checked (internal/config/engine.go). The
//! engine runs that at boot (`load`), and a running engine is handed a
//! fresh one over the socket by `rook reload` (`c2s.config`). There is
//! no second parser here to drift from the first.
//!
//! What the document carries — `prefix`, `[mux]`, the companion's
//! program, `[keys]`, `[home]` — is read into the structs below, over
//! the engine's own defaults. The knobs themselves are documented in
//! README.md and mux/README.md.
const std = @import("std");
const chrome = @import("chrome.zig");
const keyspkg = @import("keys.zig");
const ptypkg = @import("pty.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn pipe(fds: *[2]ptypkg.fd_t) c_int;
extern "c" fn dup2(old: ptypkg.fd_t, new: ptypkg.fd_t) c_int;
extern "c" fn execvp(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn read(fd: ptypkg.fd_t, buf: [*]u8, n: usize) isize;
extern "c" fn close(fd: ptypkg.fd_t) c_int;
extern "c" fn waitpid(pid: ptypkg.pid_t, status: ?*c_int, options: c_int) ptypkg.pid_t;
extern "c" fn _NSGetExecutablePath(buf: [*]u8, size: *u32) c_int;

/// The [mux] knobs, over their defaults.
pub const Mux = struct {
    /// newline-joined program names that own Ctrl-h/j/k/l
    owners: [512]u8 = @splat(0),
    owners_len: usize = 0,
    scrollback_bytes: usize = 4 * 1024 * 1024,
    /// The one chrome accent: the active tab chip, focused borders, the
    /// popup box. A hex color or one of the eight ANSI names, which map
    /// into the same palette.
    accent: chrome.Rgb = chrome.mauve,
    /// The legacy side panel, hidden unless asked for. `sidebar = true`
    /// is the older spelling of `.open`; `sidebar_mode` wins over it.
    side_mode: chrome.SideMode = .hidden,
    sidebar_width: u16 = 30,
    /// Resurrect the last saved layout on server boot: workspaces,
    /// windows, cwds, and every pane that told rook how to bring its
    /// program back (`rook resume`).
    restore: bool = true,
    /// newline-joined foreground program names that mean "an agent is
    /// running in this pane", so a session somebody started by hand
    /// still shows up on the agents rail. Rook names none itself.
    agents: [256]u8 = @splat(0),
    agents_len: usize = 0,
    /// The companion's program name: the foreground program that means
    /// "the resident is open in this pane". Empty means no companion.
    companion: [64]u8 = @splat(0),
    companion_len: usize = 0,
    /// The calm bar at the bottom of the glass.
    bar: bool = true,
    /// ASCII marks and glyphs for a glass that cannot show the
    /// Unicode ones (docs/ui-design-system.md).
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
};

/// Who holds the keys, then the signals, with one global attention
/// count and no more of a dashboard than that.
pub const default_status_space = "input\n-\nworking\nattention\nunread\npins";

/// Home: the one workspace outside the list of spaces, a key away
/// from any of them (docs/home.md). Rook seeds it from here when it
/// is gone to and it is not there; with nothing configured it is one
/// shell in `~`, a scratch pad.
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

/// Everything the engine is configured with.
pub const Config = struct {
    /// C-b when unset, as tmux has it.
    prefix: u8 = 0x02,
    mux: Mux = .{},
    /// empty here; `defaults` fills it (the table is built at run time)
    keys: keyspkg.Keys = .{},
    home: Home = .{},

    /// The engine's defaults, which a document is read over.
    pub fn defaults() Config {
        return .{ .keys = keyspkg.defaults() };
    }
};

/// The document as `rook config json` writes it. Every field is
/// optional: what is left out is the default.
const Doc = struct {
    v: u32 = 0,
    prefix: []const u8 = "",
    mux: struct {
        nav_owners: []const []const u8 = &.{},
        scrollback_mb: ?u32 = null,
        accent: []const u8 = "",
        restore: ?bool = null,
        sidebar_mode: []const u8 = "",
        sidebar: ?bool = null,
        sidebar_width: ?u16 = null,
        agents: []const []const u8 = &.{},
        bar: ?bool = null,
        glyphs: []const u8 = "",
        status_space: []const []const u8 = &.{},
        startup: []const u8 = "",
    } = .{},
    companion: []const u8 = "",
    keys: ?std.json.ArrayHashMap([]const u8) = null,
    home: struct {
        on_empty: []const u8 = "",
        color: []const u8 = "",
        dir: []const u8 = "",
        windows: []const struct {
            name: []const u8 = "",
            dir: []const u8 = "",
            panes: []const struct {
                command: []const u8 = "",
                dir: []const u8 = "",
                split: []const u8 = "",
            } = &.{},
        } = &.{},
    } = .{},
};

/// The newest document shape this engine reads; an older front door's
/// document still reads, a newer one is refused rather than half-read.
pub const doc_version = 1;

/// A compiled document → the config, over the defaults.
pub fn fromJson(gpa: std.mem.Allocator, bytes: []const u8) !Config {
    const parsed = try std.json.parseFromSlice(Doc, gpa, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const d = parsed.value;
    if (d.v > doc_version) return error.NewerConfig;
    var out = Config.defaults();
    if (keyspkg.parseKey(d.prefix)) |k| out.prefix = k;

    const m = &out.mux;
    m.owners_len = joinInto(d.mux.nav_owners, &m.owners);
    if (d.mux.scrollback_mb) |mb| m.scrollback_bytes = @as(usize, @min(mb, 256)) * 1024 * 1024;
    if (d.mux.accent.len > 0) m.accent = chrome.Rgb.parse(d.mux.accent) orelse chrome.named(d.mux.accent) orelse m.accent;
    if (d.mux.sidebar) |on| m.side_mode = if (on) .open else .hidden;
    if (d.mux.sidebar_mode.len > 0) m.side_mode = chrome.SideMode.parse(d.mux.sidebar_mode) orelse m.side_mode;
    if (d.mux.sidebar_width) |w| m.sidebar_width = std.math.clamp(w, 16, 60);
    if (d.mux.restore) |r| m.restore = r;
    m.agents_len = joinInto(d.mux.agents, &m.agents);
    if (d.mux.bar) |b| m.bar = b;
    m.ascii_glyphs = std.mem.eql(u8, d.mux.glyphs, "ascii");
    m.status_space_len = joinInto(d.mux.status_space, &m.status_space);
    const st = d.mux.startup;
    m.startup_last_space = std.mem.eql(u8, st, "last-space") or std.mem.eql(u8, st, "last_space") or std.mem.eql(u8, st, "space");
    const comp = d.companion[0..@min(d.companion.len, m.companion.len)];
    @memcpy(m.companion[0..comp.len], comp);
    m.companion_len = comp.len;

    if (d.keys) |ks| {
        var it = ks.map.iterator();
        while (it.next()) |e| {
            const key = keyspkg.parseKey(e.key_ptr.*) orelse continue;
            out.keys.set(key, e.value_ptr.*);
        }
    }

    const h = &out.home;
    h.stay = std.mem.eql(u8, d.home.on_empty, "stay");
    if (d.home.color.len > 0) h.color = chrome.Rgb.parse(d.home.color) orelse chrome.named(d.home.color);
    h.dir = h.keep(d.home.dir);
    for (d.home.windows) |w| {
        if (h.windows_n == Home.max_windows) break;
        var hw: Home.Window = .{ .name = h.keep(w.name), .dir = h.keep(w.dir) };
        for (w.panes) |p| {
            if (hw.panes_n == Home.max_panes) break;
            hw.panes[hw.panes_n] = .{ .cmd = h.keep(p.command), .dir = h.keep(p.dir), .down = std.mem.eql(u8, p.split, "down") };
            hw.panes_n += 1;
        }
        h.windows[h.windows_n] = hw;
        h.windows_n += 1;
    }
    return out;
}

/// Names → `a\nb` in `buf`; the length written.
fn joinInto(names: []const []const u8, buf: []u8) usize {
    var len: usize = 0;
    for (names) |n| {
        if (len + n.len + 1 > buf.len) break;
        if (len > 0) {
            buf[len] = '\n';
            len += 1;
        }
        @memcpy(buf[len..][0..n.len], n);
        len += n.len;
    }
    return len;
}

/// The config at boot: the front door's compiled document, or the
/// defaults and the reason there is none, for the calm bar to say.
pub const Loaded = struct { config: Config, err: []const u8 = "" };

pub fn load(gpa: std.mem.Allocator) Loaded {
    const bytes = fetch(gpa) catch |e| return .{ .config = Config.defaults(), .err = switch (e) {
        error.NoFrontDoor => "config: rook not found; defaults",
        error.Refused => "config: rook.toml refused (rook config check); defaults",
    } };
    defer gpa.free(bytes);
    const c = fromJson(gpa, bytes) catch return .{ .config = Config.defaults(), .err = "config: unreadable (rook config json); defaults" };
    return .{ .config = c };
}

/// Run `rook config json` and keep its stdout. The front door is
/// `$ROOK_FRONT_DOOR` when the launcher said where it is, else the
/// `bin/rook` of the install this engine is part of (it lives in
/// `libexec/rook/`), else whatever `rook` is on PATH. Called before
/// any pane thread exists, so forking here is plain.
pub fn fetch(gpa: std.mem.Allocator) ![]u8 {
    var cands: [3]?[*:0]const u8 = .{ null, null, null };
    if (getenv("ROOK_FRONT_DOOR")) |p| cands[0] = p;
    var exe_buf: [1024]u8 = undefined;
    var sib_buf: [1100]u8 = undefined;
    var exe_len: u32 = exe_buf.len;
    if (_NSGetExecutablePath(&exe_buf, &exe_len) == 0) {
        const exe = std.mem.sliceTo(&exe_buf, 0);
        const dir = std.fs.path.dirname(exe) orelse "";
        if (std.fmt.bufPrintZ(&sib_buf, "{s}/../../bin/rook", .{dir})) |z| cands[1] = z.ptr else |_| {}
    }
    cands[2] = "rook";
    var refused = false;
    for (cands, 0..) |cand, i| {
        const c = cand orelse continue;
        const r = runJson(gpa, c, i == 2) catch |e| {
            if (e == error.Refused) refused = true;
            continue;
        };
        return r;
    }
    return if (refused) error.Refused else error.NoFrontDoor;
}

/// One candidate: `<rook> config json`, stdout captured. Exit 127 is
/// "no such program", anything else nonzero is the file refused.
fn runJson(gpa: std.mem.Allocator, path: [*:0]const u8, search: bool) ![]u8 {
    var p: [2]ptypkg.fd_t = undefined;
    if (pipe(&p) != 0) return error.PipeFailed;
    const pid = ptypkg.fork_();
    if (pid < 0) {
        _ = close(p[0]);
        _ = close(p[1]);
        return error.ForkFailed;
    }
    if (pid == 0) {
        _ = dup2(p[1], 1);
        _ = close(p[0]);
        _ = close(p[1]);
        const argv = [_:null]?[*:0]const u8{ path, "config", "json", null };
        _ = if (search) execvp(path, &argv) else execv(path, &argv);
        _exit(127);
    }
    _ = close(p[1]);
    defer _ = close(p[0]);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = read(p[0], &buf, buf.len);
        if (n <= 0) break;
        try out.appendSlice(gpa, buf[0..@intCast(n)]);
        if (out.items.len > 1 << 20) break;
    }
    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);
    const code = (status >> 8) & 0xff;
    if (code == 127) return error.NotFound;
    if (status != 0) return error.Refused;
    return out.toOwnedSlice(gpa);
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

test "an empty document is the defaults" {
    const c = try fromJson(std.testing.allocator, "{}");
    try std.testing.expectEqual(@as(u8, 0x02), c.prefix);
    try std.testing.expect(c.mux.bar and c.mux.restore and !c.mux.ascii_glyphs);
    try std.testing.expectEqual(chrome.mauve, c.mux.accent);
    try std.testing.expectEqualStrings("", c.mux.companionSlice());
    try std.testing.expectEqualStrings("", c.mux.agentsSlice());
    try std.testing.expectEqualStrings(default_status_space, c.mux.statusSpace());
    try std.testing.expectEqual(keyspkg.Verb.split_right, c.keys.get('v').verb);
    try std.testing.expectEqual(@as(usize, 0), c.home.windows_n);
}

test "a compiled document, read" {
    const doc =
        \\{"v":1,"prefix":"`","mux":{"nav_owners":["nvim","fzf"],"scrollback_mb":8,"accent":"cyan",
        \\"sidebar":true,"sidebar_mode":"collapsed","agents":["claude","codex"],"bar":false,"glyphs":"ascii",
        \\"status_space":["input","-","pins"],"startup":"last-space","restore":false,"future":1},
        \\"companion":"vera","keys":{"g":"popup 72x86@124x48 grim","x":"","C-o":"home"},
        \\"home":{"on_empty":"stay","color":"#112233","dir":"~/work","windows":[
        \\{"name":"me","panes":[{"command":"docket"},{"command":""}]},
        \\{"name":"notes","dir":"~/notes","panes":[{"command":"nvim"},{"dir":"archive","split":"down"}]}]}}
    ;
    const c = try fromJson(std.testing.allocator, doc);
    const eq = std.testing.expectEqualStrings;
    try std.testing.expectEqual(@as(u8, '`'), c.prefix);
    try eq("nvim\nfzf", c.mux.ownersSlice());
    try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), c.mux.scrollback_bytes);
    try std.testing.expectEqual(chrome.teal, c.mux.accent);
    try std.testing.expectEqual(chrome.SideMode.collapsed, c.mux.side_mode); // mode over the old spelling
    try eq("claude\ncodex", c.mux.agentsSlice());
    try std.testing.expect(!c.mux.bar and c.mux.ascii_glyphs and c.mux.startup_last_space and !c.mux.restore);
    try eq("input\n-\npins", c.mux.statusSpace());
    try eq("vera", c.mux.companionSlice());
    try std.testing.expectEqual(keyspkg.Verb.popup, c.keys.get('g').verb);
    try eq("\x1f72x86@124x48\x1fgrim", c.keys.arg(c.keys.get('g')));
    try std.testing.expectEqual(keyspkg.Verb.none, c.keys.get('x').verb);
    try std.testing.expectEqual(keyspkg.Verb.home, c.keys.get(0x0f).verb);
    try std.testing.expectEqual(keyspkg.Verb.split_right, c.keys.get('v').verb); // defaults stay under
    const h = c.home;
    try std.testing.expect(h.stay);
    try std.testing.expectEqual(chrome.Rgb{ .r = 0x11, .g = 0x22, .b = 0x33 }, h.color.?);
    try eq("~/work", h.str(h.dir));
    try std.testing.expectEqual(@as(usize, 2), h.windows_n);
    try eq("me", h.str(h.windows[0].name));
    try eq("docket", h.str(h.windows[0].panes[0].cmd));
    try std.testing.expectEqual(@as(usize, 2), h.windows[0].panes_n);
    try eq("~/notes", h.str(h.windows[1].dir));
    try eq("archive", h.str(h.windows[1].panes[1].dir));
    try std.testing.expect(h.windows[1].panes[1].down and !h.windows[1].panes[0].down);
}

test "a document from a newer front door is refused, not half-read" {
    try std.testing.expectError(error.NewerConfig, fromJson(std.testing.allocator, "{\"v\":99}"));
}
