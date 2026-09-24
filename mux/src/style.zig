//! The stylesheet: how the chrome looks, per workspace, by rule
//! (docs/style.md). Rook's own rules come first, then the config's
//! `[style]`, then each `[[style.match]]` whose conditions all hold,
//! in order — a later rule wins, property by property. Nothing here
//! draws; `look` turns the winning properties into a `ui.Theme` and
//! the words the bars say, and the painters read those.
//!
//! What a rule can ask about is the workspace on the glass, as facts
//! rook can see for itself: whether it is home, its name, the focused
//! pane's directory, program, repository and branch. The repository is
//! read from `.git` directly — the origin remote, as host/owner/name —
//! so a matcher is a file read, never a `git` process.
const std = @import("std");
const chromepkg = @import("chrome.zig");
const ui = @import("ui.zig");

const Rgb = chromepkg.Rgb;

/// One set of looks. Null is "as the rule before left it".
pub const Props = struct {
    accent: ?[]const u8 = null,
    bar: ?[]const u8 = null,
    raised: ?[]const u8 = null,
    selection: ?[]const u8 = null,
    text: ?[]const u8 = null,
    subtext: ?[]const u8 = null,
    muted: ?[]const u8 = null,
    border: ?[]const u8 = null,
    border_focused: ?[]const u8 = null,
    attention: ?[]const u8 = null,
    working: ?[]const u8 = null,
    unread: ?[]const u8 = null,
    success: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    chip_bg: ?[]const u8 = null,
    chip_fg: ?[]const u8 = null,
    tint: ?[]const u8 = null,
    tint_amount: ?u8 = null,
    chip: ?[]const u8 = null,
    tabs: ?[]const u8 = null,
    separator: ?[]const u8 = null,
    fill: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    label: ?[]const u8 = null,
    bar_label: ?[]const u8 = null,

    /// `over` on top of `self`: each property `over` says wins.
    pub fn merge(self: *Props, over: Props) void {
        inline for (std.meta.fields(Props)) |f| {
            if (@field(over, f.name)) |v| @field(self, f.name) = v;
        }
    }
};

pub const When = struct {
    home: ?bool = null,
    workspace: []const u8 = "",
    dir: []const u8 = "",
    repo: []const u8 = "",
    branch: []const u8 = "",
    program: []const u8 = "",
};

pub const Rule = struct { when: When = .{}, style: Props = .{} };

/// Rook's own rules, ahead of the config's. Home is the one place rook
/// has a look of its own: its colour on the chip, the chrome pulled
/// toward it, and its name said at both edges (docs/home.md). A rule in
/// the file says otherwise by saying it later.
pub const builtin = [_]Rule{
    .{ .when = .{ .home = true }, .style = .{
        .tint = "accent",
        .chip_bg = "accent",
        .chip_fg = "#11111b",
        .icon = "⌂",
        .label = "{icon} home",
        .bar_label = "{icon} home",
    } },
};

const Doc = struct {
    style: struct {
        base: Props = .{},
        rules: []const Rule = &.{},
    } = .{},
};

/// The config's stylesheet, owning its strings until the next reload
/// replaces it.
pub const Sheet = struct {
    parsed: ?std.json.Parsed(Doc) = null,

    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Sheet {
        return .{ .parsed = try std.json.parseFromSlice(Doc, gpa, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) };
    }

    pub fn deinit(self: *Sheet) void {
        if (self.parsed) |*p| p.deinit();
        self.parsed = null;
    }

    pub fn base(self: *const Sheet) Props {
        return if (self.parsed) |p| p.value.style.base else .{};
    }

    pub fn rules(self: *const Sheet) []const Rule {
        return if (self.parsed) |p| p.value.style.rules else &.{};
    }
};

/// What a rule can ask about, for the workspace on the glass.
pub const Facts = struct {
    home: bool = false,
    workspace: []const u8 = "",
    dir: []const u8 = "",
    repo: []const u8 = "",
    branch: []const u8 = "",
    program: []const u8 = "",
    /// $HOME, for `~` in a `dir` matcher
    home_dir: []const u8 = "",
};

/// Does a rule's `when` hold for these facts? Every condition said must.
pub fn matches(w: When, f: Facts) bool {
    if (w.home) |h| if (h != f.home) return false;
    if (w.workspace.len > 0 and !glob(w.workspace, f.workspace)) return false;
    if (w.repo.len > 0 and !glob(w.repo, f.repo)) return false;
    if (w.branch.len > 0 and !glob(w.branch, f.branch)) return false;
    if (w.program.len > 0 and !glob(w.program, f.program)) return false;
    if (w.dir.len > 0) {
        var buf: [1024]u8 = undefined;
        const pat = if (std.mem.startsWith(u8, w.dir, "~") and f.home_dir.len > 0)
            (std.fmt.bufPrint(&buf, "{s}{s}", .{ f.home_dir, w.dir[1..] }) catch w.dir)
        else
            w.dir;
        if (!glob(pat, f.dir)) return false;
    }
    return true;
}

/// `*` any run (across `/` too), `?` one byte, everything else itself.
pub fn glob(pat: []const u8, s: []const u8) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (i < s.len) {
        if (p < pat.len and (pat[p] == '?' or pat[p] == s[i])) {
            p += 1;
            i += 1;
        } else if (p < pat.len and pat[p] == '*') {
            star = p;
            mark = i;
            p += 1;
        } else if (star) |st| {
            p = st + 1;
            mark += 1;
            i = mark;
        } else return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

/// Where a rule came from, for the explanation.
pub const Source = enum { rook, config };

pub const max_rules = 64;

/// The cascade's outcome: the winning properties, and which rules said
/// anything (rook's own first, then the config's), for `rook style`.
pub const n_props = std.meta.fields(Props).len;

/// Where a winning property came from: a rule's place in the cascade
/// (rook's own first, then the config's), the config's [style], or
/// nowhere.
pub const From = union(enum) { none, base, rule: u16 };

pub const Resolved = struct {
    props: Props = .{},
    matched: [max_rules]bool = @splat(false),
    n_rules: usize = 0,
    from: [n_props]From = @splat(.none),

    fn take(self: *Resolved, over: Props, src: From) void {
        inline for (std.meta.fields(Props), 0..) |fld, i| {
            if (@field(over, fld.name)) |v| {
                @field(self.props, fld.name) = v;
                self.from[i] = src;
            }
        }
    }
};

pub fn resolve(sheet: *const Sheet, f: Facts) Resolved {
    var r: Resolved = .{};
    for (builtin) |rule| {
        if (matches(rule.when, f)) {
            r.take(rule.style, .{ .rule = @intCast(r.n_rules) });
            r.matched[r.n_rules] = true;
        }
        r.n_rules += 1;
    }
    r.take(sheet.base(), .base);
    for (sheet.rules()) |rule| {
        if (r.n_rules == max_rules) break;
        if (matches(rule.when, f)) {
            r.take(rule.style, .{ .rule = @intCast(r.n_rules) });
            r.matched[r.n_rules] = true;
        }
        r.n_rules += 1;
    }
    return r;
}

// ---- from properties to a theme

pub const Cap = ui.Cap;

/// A colour value: a hex colour (#rgb or #rrggbb), an ANSI name, or a
/// role of the theme as it stands.
fn colour(v: []const u8, t: *const ui.Theme) ?Rgb {
    if (v.len == 4 and v[0] == '#') {
        var six: [7]u8 = .{ '#', v[1], v[1], v[2], v[2], v[3], v[3] };
        return Rgb.parse(&six);
    }
    if (Rgb.parse(v)) |c| return c;
    const name = if (std.mem.startsWith(u8, v, "bright-")) v["bright-".len..] else v;
    if (chromepkg.named(name)) |c| return c;
    return role(t, v);
}

fn role(t: *const ui.Theme, name: []const u8) ?Rgb {
    const table = .{
        .{ "accent", "accent" },         .{ "bar", "chrome" },            .{ "raised", "raised" },
        .{ "selection", "selection" },   .{ "text", "primary" },          .{ "subtext", "secondary" },
        .{ "muted", "muted" },           .{ "border", "border" },         .{ "border_focused", "border_focused" },
        .{ "attention", "attention" },   .{ "working", "working" },       .{ "unread", "unread" },
        .{ "success", "success" },       .{ "error", "err" },
    };
    inline for (table) |e| {
        if (std.mem.eql(u8, name, e[0])) return @field(t, e[1]);
    }
    return null;
}

/// The winning properties over a base theme. Colours said outright
/// land first (the accent before anything that names it); then the
/// tint pulls every chrome ground and edge the rules left alone; then
/// the chip's colours, which default to a raised chip in the text ink.
pub fn theme(p: Props, base_theme: ui.Theme) ui.Theme {
    var t = base_theme;
    const set = struct {
        fn f(th: *ui.Theme, v: ?[]const u8, comptime field: []const u8) bool {
            const s = v orelse return false;
            if (colour(s, th)) |c| {
                @field(th, field) = c;
                return true;
            }
            return false;
        }
    }.f;
    if (set(&t, p.accent, "accent")) {
        if (p.border_focused == null) t.border_focused = t.accent;
    }
    const bar = set(&t, p.bar, "chrome");
    const raised = set(&t, p.raised, "raised");
    const selection = set(&t, p.selection, "selection");
    _ = set(&t, p.text, "primary");
    _ = set(&t, p.subtext, "secondary");
    _ = set(&t, p.muted, "muted");
    const border = set(&t, p.border, "border");
    _ = set(&t, p.border_focused, "border_focused");
    _ = set(&t, p.attention, "attention");
    _ = set(&t, p.working, "working");
    _ = set(&t, p.unread, "unread");
    _ = set(&t, p.success, "success");
    _ = set(&t, p.@"error", "err");
    if (p.tint) |tv| {
        if (colour(tv, &t)) |c| {
            const amt: u16 = p.tint_amount orelse 26;
            const pull = struct {
                fn f(x: Rgb, to: Rgb, a: u16) Rgb {
                    return ui.toward(x, to, @min(a, 100));
                }
            }.f;
            if (!bar) t.chrome = pull(t.chrome, c, amt);
            if (!raised) t.raised = pull(t.raised, c, amt + 6);
            if (!selection) t.selection = pull(t.selection, c, amt + 6);
            t.border_subtle = pull(t.border_subtle, c, amt + 4);
            if (!border) t.border = pull(t.border, c, amt + 14);
        }
    }
    t.chip_bg = t.raised;
    t.chip_fg = t.primary;
    _ = set(&t, p.chip_bg, "chip_bg");
    _ = set(&t, p.chip_fg, "chip_fg");
    if (t.glyphs == .unicode) {
        if (p.chip) |c| t.chip_cap = Cap.parse(c);
        if (p.tabs) |c| t.tab_cap = Cap.parse(c);
    } else {
        // the caps are Nerd Font glyphs; an ASCII glass draws brackets
        if (p.chip) |c| t.chip_cap = if (Cap.parse(c) == .plain) .plain else .bracket;
        if (p.tabs) |c| t.tab_cap = if (Cap.parse(c) == .plain) .plain else .bracket;
    }
    if (p.separator) |s| t.separator = s;
    if (p.fill) |s| t.fill = if (s.len == 0) " " else s;
    return t;
}

/// A template over the facts: {name} {repo} {branch} {dir} {icon}, and
/// the same in capitals for the word upper-cased. `{repo}` is the
/// repository's last part; `{dir}` the directory's.
pub fn render(buf: []u8, tmpl: []const u8, f: Facts, icon: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var i: usize = 0;
    while (i < tmpl.len) {
        if (tmpl[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, tmpl, i, '}')) |end| {
                const tok = tmpl[i + 1 .. end];
                var lower: [16]u8 = undefined;
                if (tok.len <= lower.len) {
                    const low = std.ascii.lowerString(&lower, tok);
                    const upper = tok.len > 0 and std.ascii.isUpper(tok[0]);
                    const val: ?[]const u8 = if (std.mem.eql(u8, low, "name"))
                        f.workspace
                    else if (std.mem.eql(u8, low, "repo"))
                        std.fs.path.basename(f.repo)
                    else if (std.mem.eql(u8, low, "branch"))
                        f.branch
                    else if (std.mem.eql(u8, low, "dir"))
                        std.fs.path.basename(f.dir)
                    else if (std.mem.eql(u8, low, "icon"))
                        icon
                    else
                        null;
                    if (val) |v| {
                        if (upper) {
                            for (v) |ch| w.writeByte(std.ascii.toUpper(ch)) catch break;
                        } else w.writeAll(v) catch {};
                        i = end + 1;
                        continue;
                    }
                }
            }
        }
        w.writeByte(tmpl[i]) catch break;
        i += 1;
    }
    return w.buffered();
}

// ---- git, read from the files

pub const Git = struct {
    repo: [256]u8 = undefined,
    repo_len: usize = 0,
    branch: [128]u8 = undefined,
    branch_len: usize = 0,

    pub fn repoSlice(self: *const Git) []const u8 {
        return self.repo[0..self.repo_len];
    }
    pub fn branchSlice(self: *const Git) []const u8 {
        return self.branch[0..self.branch_len];
    }
};

/// The repository `dir` is in, if any: walk up to a `.git` (a
/// directory, or a worktree's file pointing at one), read HEAD for the
/// branch and the common config for the origin remote.
pub fn gitOf(dir: []const u8) Git {
    var g: Git = .{};
    var here = dir;
    var pbuf: [1100]u8 = undefined;
    var gitdir_buf: [1100]u8 = undefined;
    while (here.len > 0) {
        const dotgit = std.fmt.bufPrint(&pbuf, "{s}/.git", .{here}) catch return g;
        var fbuf: [1024]u8 = undefined;
        var gitdir: []const u8 = "";
        if (isDir(dotgit)) {
            gitdir = std.fmt.bufPrint(&gitdir_buf, "{s}", .{dotgit}) catch return g;
        } else if (readSmall(dotgit, &fbuf)) |txt| {
            // a worktree: `gitdir: <path>`
            const t = std.mem.trim(u8, txt, " \t\r\n");
            if (std.mem.startsWith(u8, t, "gitdir:")) {
                const p = std.mem.trim(u8, t["gitdir:".len..], " \t");
                gitdir = if (p.len > 0 and p[0] == '/')
                    (std.fmt.bufPrint(&gitdir_buf, "{s}", .{p}) catch return g)
                else
                    (std.fmt.bufPrint(&gitdir_buf, "{s}/{s}", .{ here, p }) catch return g);
            }
        }
        if (gitdir.len > 0) {
            readGit(&g, gitdir);
            return g;
        }
        if (std.mem.eql(u8, here, "/")) break;
        here = std.fs.path.dirname(here) orelse break;
    }
    return g;
}

fn readGit(g: *Git, gitdir: []const u8) void {
    var pbuf: [1200]u8 = undefined;
    var fbuf: [4096]u8 = undefined;
    // HEAD is the worktree's own
    if (std.fmt.bufPrint(&pbuf, "{s}/HEAD", .{gitdir})) |hp| {
        if (readSmall(hp, &fbuf)) |head| {
            const h = std.mem.trim(u8, head, " \t\r\n");
            const b = if (std.mem.startsWith(u8, h, "ref: refs/heads/")) h["ref: refs/heads/".len..] else h[0..@min(h.len, 7)];
            g.branch_len = @min(b.len, g.branch.len);
            @memcpy(g.branch[0..g.branch_len], b[0..g.branch_len]);
        }
    } else |_| {}
    // the config is the common dir's: a worktree's `commondir` says where
    var common_buf: [1100]u8 = undefined;
    var common: []const u8 = gitdir;
    if (std.fmt.bufPrint(&pbuf, "{s}/commondir", .{gitdir})) |cp| {
        var cbuf: [1024]u8 = undefined;
        if (readSmall(cp, &cbuf)) |c| {
            const rel = std.mem.trim(u8, c, " \t\r\n");
            common = if (rel.len > 0 and rel[0] == '/')
                (std.fmt.bufPrint(&common_buf, "{s}", .{rel}) catch gitdir)
            else
                (std.fmt.bufPrint(&common_buf, "{s}/{s}", .{ gitdir, rel }) catch gitdir);
        }
    } else |_| {}
    const cfgp = std.fmt.bufPrint(&pbuf, "{s}/config", .{common}) catch return;
    const cfg = readSmall(cfgp, &fbuf) orelse return;
    const url = originUrl(cfg) orelse return;
    var nb: [256]u8 = undefined;
    const norm = normalizeRemote(url, &nb);
    g.repo_len = @min(norm.len, g.repo.len);
    @memcpy(g.repo[0..g.repo_len], norm[0..g.repo_len]);
}

/// `url` under `[remote "origin"]` in a git config.
pub fn originUrl(cfg: []const u8) ?[]const u8 {
    var in_origin = false;
    var lines = std.mem.splitScalar(u8, cfg, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len > 0 and t[0] == '[') {
            in_origin = std.mem.eql(u8, t, "[remote \"origin\"]");
            continue;
        }
        if (!in_origin) continue;
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, t[0..eq], " \t"), "url")) return std.mem.trim(u8, t[eq + 1 ..], " \t");
    }
    return null;
}

/// A remote as host/owner/name: `git@github.com:a/b.git`,
/// `https://github.com/a/b`, `ssh://git@host:22/a/b.git` all read
/// `github.com/a/b`.
pub fn normalizeRemote(url: []const u8, buf: []u8) []const u8 {
    var u = url;
    if (std.mem.indexOf(u8, u, "://")) |i| u = u[i + 3 ..];
    if (std.mem.indexOfScalar(u8, u, '@')) |i| u = u[i + 1 ..];
    if (std.mem.endsWith(u8, u, "/")) u = u[0 .. u.len - 1];
    if (std.mem.endsWith(u8, u, ".git")) u = u[0 .. u.len - 4];
    var w: std.Io.Writer = .fixed(buf);
    // host:path (scp form) or host:port/path
    if (std.mem.indexOfScalar(u8, u, ':')) |c| {
        const host = u[0..c];
        var rest = u[c + 1 ..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |sl| {
            if (std.fmt.parseInt(u16, rest[0..sl], 10)) |_| rest = rest[sl + 1 ..] else |_| {}
        }
        w.print("{s}/{s}", .{ host, rest }) catch {};
    } else w.writeAll(u) catch {};
    return w.buffered();
}

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn stat(path: [*:0]const u8, buf: *std.c.Stat) c_int;

fn isDir(path: []const u8) bool {
    var zb: [1100]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zb, "{s}", .{path}) catch return false;
    var st: std.c.Stat = undefined;
    if (stat(z, &st) != 0) return false;
    return (st.mode & std.c.S.IFMT) == std.c.S.IFDIR;
}

fn readSmall(path: []const u8, buf: []u8) ?[]const u8 {
    var zb: [1200]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zb, "{s}", .{path}) catch return null;
    const fd = open(z, 0);
    if (fd < 0) return null;
    defer _ = close(fd);
    const n = read(fd, buf.ptr, buf.len);
    if (n <= 0) return null;
    return buf[0..@intCast(n)];
}

test "glob" {
    try std.testing.expect(glob("github.com/grafana/*", "github.com/grafana/grafana"));
    try std.testing.expect(!glob("github.com/grafana/*", "github.com/incantery/rook"));
    try std.testing.expect(glob("*", ""));
    try std.testing.expect(glob("feat/?", "feat/x"));
    try std.testing.expect(glob("*/rook", "/Users/x/go/src/github.com/incantery/rook"));
    try std.testing.expect(!glob("rook", "rookd"));
    try std.testing.expect(glob("*review*", "pr-review-42"));
}

test "remotes normalize to host/owner/name" {
    var b: [256]u8 = undefined;
    try std.testing.expectEqualStrings("github.com/incantery/rook", normalizeRemote("git@github.com:incantery/rook.git", &b));
    try std.testing.expectEqualStrings("github.com/incantery/rook", normalizeRemote("https://github.com/incantery/rook", &b));
    try std.testing.expectEqualStrings("gitlab.example.com/a/b", normalizeRemote("ssh://git@gitlab.example.com:22/a/b.git", &b));
    try std.testing.expectEqualStrings("github.com/a/b", normalizeRemote("https://user@github.com/a/b.git/", &b));
}

test "origin url from a git config" {
    const cfg =
        \\[core]
        \\    bare = false
        \\[remote "upstream"]
        \\    url = git@github.com:other/x.git
        \\[remote "origin"]
        \\    url = git@github.com:incantery/rook.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
    ;
    try std.testing.expectEqualStrings("git@github.com:incantery/rook.git", originUrl(cfg).?);
}

test "the cascade: rook's rules, the base, then matches in order" {
    const doc =
        \\{"style":{"base":{"chip":"round","accent":"#89b4fa"},"rules":[
        \\{"when":{"repo":"github.com/grafana/*"},"style":{"accent":"#ff8833","label":"{REPO}"}},
        \\{"when":{"home":true},"style":{"label":"{icon} HOME"}},
        \\{"when":{"workspace":"nope"},"style":{"chip":"slant"}}]}}
    ;
    var sheet = try Sheet.parse(std.testing.allocator, doc);
    defer sheet.deinit();
    const grafana: Facts = .{ .workspace = "g", .repo = "github.com/grafana/grafana" };
    const r = resolve(&sheet, grafana);
    try std.testing.expectEqualStrings("#ff8833", r.props.accent.?);
    try std.testing.expectEqualStrings("round", r.props.chip.?);
    try std.testing.expect(r.props.tint == null); // not home
    try std.testing.expect(!r.matched[0] and r.matched[1] and !r.matched[2] and !r.matched[3]);
    // the accent was the base's, then rule 1's (the first of the file's)
    const accent_i = comptime std.meta.fieldIndex(Props, "accent").?;
    try std.testing.expectEqual(From{ .rule = 1 }, r.from[accent_i]);
    const chip_i = comptime std.meta.fieldIndex(Props, "chip").?;
    try std.testing.expectEqual(From.base, r.from[chip_i]);
    var lb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("GRAFANA", render(&lb, r.props.label.?, grafana, ""));

    const home: Facts = .{ .home = true, .workspace = "home" };
    const h = resolve(&sheet, home);
    try std.testing.expectEqualStrings("accent", h.props.tint.?); // rook's own
    try std.testing.expectEqualStrings("{icon} HOME", h.props.label.?); // the file's, later
    try std.testing.expectEqualStrings("⌂ HOME", render(&lb, h.props.label.?, home, h.props.icon.?));
    const t = theme(h.props, ui.Theme.init(chromepkg.mauve, .unicode));
    try std.testing.expectEqual(Rgb{ .r = 0x89, .g = 0xb4, .b = 0xfa }, t.accent);
    try std.testing.expectEqual(t.accent, t.chip_bg); // chip_bg = "accent", after the accent
    try std.testing.expect(!std.meta.eql(t.chrome, ui.Theme.init(chromepkg.mauve, .unicode).chrome)); // tinted
    try std.testing.expectEqual(Cap.round, t.chip_cap);
}

test "a colour said outright is not tinted over" {
    const base = ui.Theme.init(chromepkg.mauve, .unicode);
    const t = theme(.{ .bar = "#000000", .tint = "red" }, base);
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, t.chrome);
    try std.testing.expect(!std.meta.eql(t.raised, base.raised));
}

extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn getpid() c_int;

fn testMkdirs(root: []const u8, rel: []const u8) !void {
    var b: [1200]u8 = undefined;
    var i: usize = 0;
    while (i <= rel.len) : (i += 1) {
        if (i == rel.len or rel[i] == '/') {
            const z = try std.fmt.bufPrintZ(&b, "{s}/{s}", .{ root, rel[0..i] });
            _ = mkdir(z, 0o755);
        }
    }
}

fn testWrite(root: []const u8, rel: []const u8, data: []const u8) !void {
    var b: [1200]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&b, "{s}/{s}", .{ root, rel });
    const fd = open(z, 0x0001 | 0x0200 | 0x0400, @as(c_uint, 0o644)); // O_WRONLY|O_CREAT|O_TRUNC
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);
    _ = write(fd, data.ptr, data.len);
}

test "git facts from a checkout, a worktree, and none" {
    var rb: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&rb, "/tmp/rook-style-test-{d}", .{getpid()});
    var zb: [260]u8 = undefined;
    _ = mkdir(try std.fmt.bufPrintZ(&zb, "{s}", .{root}), 0o755);
    try testMkdirs(root, "repo/.git/worktrees/wt");
    try testMkdirs(root, "repo/src/deep");
    try testWrite(root, "repo/.git/HEAD", "ref: refs/heads/main\n");
    try testWrite(root, "repo/.git/config", "[remote \"origin\"]\n    url = git@github.com:incantery/rook.git\n");
    try testWrite(root, "repo/.git/worktrees/wt/HEAD", "ref: refs/heads/feature/x\n");
    try testWrite(root, "repo/.git/worktrees/wt/commondir", "../..\n");
    try testMkdirs(root, "wt");
    var gb: [1200]u8 = undefined;
    try testWrite(root, "wt/.git", try std.fmt.bufPrint(&gb, "gitdir: {s}/repo/.git/worktrees/wt\n", .{root}));

    var db: [1200]u8 = undefined;
    const g = gitOf(try std.fmt.bufPrint(&db, "{s}/repo/src/deep", .{root}));
    try std.testing.expectEqualStrings("github.com/incantery/rook", g.repoSlice());
    try std.testing.expectEqualStrings("main", g.branchSlice());
    const w = gitOf(try std.fmt.bufPrint(&db, "{s}/wt", .{root}));
    try std.testing.expectEqualStrings("github.com/incantery/rook", w.repoSlice());
    try std.testing.expectEqualStrings("feature/x", w.branchSlice());
    // no repository above it at all
    try std.testing.expectEqualStrings("", gitOf("/").repoSlice());
}
