//! The workspace registry — read from the environment graph.
//!
//! A workspace is DECLARED: a `workspace` node in environment.json (name
//! and root, usually emitted by the config program — rook-config(5)),
//! not a row registered somewhere. This used to be sqlite (rook.db,
//! owned by rook-host); the host left in the strip and nothing wrote the
//! table since, so the app was linking libsqlite3 to read a registry
//! frozen in July. A registry nobody can write is not a registry.
//!
//! What the db held that the graph deliberately does not:
//! `last_used` recency — ephemeral UI state, to return in-memory (or as
//! a dumb flat file) when a feature needs it; and `worktree_of` children
//! — git already knows a repo's worktrees, so those come back DERIVED
//! from `.git/worktrees/` rather than stored, when worktree management
//! lands. Neither justifies a database the config graph now replaces.
//!
//! Re-parsed on every load: the graph is one small cached file, `env
//! apply` rewrites it, and a palette open should see what config last
//! applied without a restart. Same pattern as plugins.zig — one file,
//! N consumers, none owning another's parse.

const std = @import("std");
const cfgpkg = @import("config.zig");
const envapply = @import("envapply.zig");

// C dirent, the same shape and for the same reason as filelist.zig:
// walking a directory is one syscall per entry, and std.Io.Dir would
// need an io handle threaded through code that only wants readdir.
const Dirent = extern struct {
    d_ino: u64,
    d_seekoff: u64,
    d_reclen: u16,
    d_namlen: u16,
    d_type: u8,
    d_name: [1024]u8,
};
extern "c" fn opendir(path: [*:0]const u8) ?*anyopaque;
extern "c" fn readdir(d: *anyopaque) ?*Dirent;
extern "c" fn closedir(d: *anyopaque) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: u16) c_int;

pub const Entry = struct {
    name: []u8,
    root: []u8,
    /// Parent workspace name for worktree children (derived from
    /// `.git/worktrees/` — see appendWorktrees), empty for top-level.
    parent: []u8,
};

pub fn free(gpa: std.mem.Allocator, list: []Entry) void {
    for (list) |e| {
        gpa.free(e.name);
        gpa.free(e.root);
        gpa.free(e.parent);
    }
    gpa.free(list);
}

/// Load the declared workspaces, in graph order — the author's order,
/// which beats a recency shuffle for muscle memory. A missing graph, an
/// unparseable graph, no workspace nodes: all the same answer, an EMPTY
/// list, never a failure — rook must run fine unconfigured.
///
/// A leading `~/` in root expands against $HOME, so a hand-written graph
/// can say what a config program would compute. A later node with the
/// same name replaces the earlier one, matching the SDKs' put rule.
pub fn load(io: std.Io, gpa: std.mem.Allocator) []Entry {
    const data = cfgpkg.envData(io, gpa) orelse return &.{};
    defer gpa.free(data);
    const declared = parse(gpa, data);
    // Entries MOVE into the grouped list; only the slice itself is freed.
    defer gpa.free(declared);

    var out: std.ArrayListUnmanaged(Entry) = .empty;
    defer out.deinit(gpa);
    for (declared) |e| {
        out.append(gpa, e) catch {
            gpa.free(e.name);
            gpa.free(e.root);
            gpa.free(e.parent);
            continue;
        };
        // Children follow their parent — the grouping the palette
        // renders as `rook/zig`, derived rather than stored.
        appendWorktrees(io, gpa, &out, e.name, e.root);
    }
    return out.toOwnedSlice(gpa) catch &.{};
}

/// The worktrees of one declared workspace, straight from git's own
/// records: `.git/worktrees/<name>/gitdir` names each linked checkout.
/// Nothing is stored, so nothing can go stale — a worktree added by
/// anyone, through rook or not, is here on the next read. Only a MAIN
/// checkout owns `.git/worktrees`; a workspace that is itself a
/// worktree has a `.git` pointer FILE and derives nothing.
fn appendWorktrees(io: std.Io, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(Entry), ws_name: []const u8, ws_root: []const u8) void {
    var pbuf: [1024]u8 = undefined;
    const wdirz = std.fmt.bufPrintZ(&pbuf, "{s}/.git/worktrees", .{ws_root}) catch return;
    const d = opendir(wdirz.ptr) orelse return;
    defer _ = closedir(d);
    while (readdir(d)) |de| {
        const name = de.d_name[0..de.d_namlen];
        if (name.len == 0 or name[0] == '.') continue;
        var gbuf: [1024]u8 = undefined;
        const gpath = std.fmt.bufPrint(&gbuf, "{s}/.git/worktrees/{s}/gitdir", .{ ws_root, name }) catch continue;
        const content = readSmall(io, gpa, gpath) orelse continue;
        defer gpa.free(content);
        const wtroot = worktreeRoot(content) orelse continue;
        // A stale record (checkout deleted, `git worktree prune` not
        // yet run) points at a directory that is not there. Skip it
        // the way prune would, rather than listing a dead workspace.
        var zbuf: [1024]u8 = undefined;
        const wz = std.fmt.bufPrintZ(&zbuf, "{s}", .{wtroot}) catch continue;
        if (access(wz.ptr, 0) != 0) continue;
        const nm = gpa.dupe(u8, name) catch continue;
        const rt = gpa.dupe(u8, wtroot) catch {
            gpa.free(nm);
            continue;
        };
        const pr = gpa.dupe(u8, ws_name) catch {
            gpa.free(nm);
            gpa.free(rt);
            continue;
        };
        out.append(gpa, .{ .name = nm, .root = rt, .parent = pr }) catch {
            gpa.free(nm);
            gpa.free(rt);
            gpa.free(pr);
        };
    }
}

fn readSmall(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096)) catch null;
}

/// gitdir file content -> the worktree's root. The file holds the path
/// of the checkout's `.git` pointer file; its directory is the root.
fn worktreeRoot(content: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, content, " \t\r\n");
    if (!std.mem.endsWith(u8, t, "/.git")) return null;
    const r = t[0 .. t.len - "/.git".len];
    return if (r.len == 0) null else r;
}

/// The graph-bytes half of load(), split out so it can be tested without
/// the process-global config directory.
fn parse(gpa: std.mem.Allocator, data: []const u8) []Entry {
    var out: std.ArrayListUnmanaged(Entry) = .empty;
    defer out.deinit(gpa);

    const Wire = struct {
        nodes: []struct {
            kind: []const u8 = "",
            name: []const u8 = "",
            root: []const u8 = "",
        } = &.{},
    };
    const parsed = std.json.parseFromSlice(Wire, gpa, data, .{ .ignore_unknown_fields = true }) catch return &.{};
    defer parsed.deinit();

    for (parsed.value.nodes) |n| {
        if (!std.mem.eql(u8, n.kind, "workspace")) continue;
        if (n.name.len == 0 or n.root.len == 0) continue;
        const root = expandTilde(gpa, n.root) orelse continue;
        const e: Entry = .{
            .name = gpa.dupe(u8, n.name) catch {
                gpa.free(root);
                continue;
            },
            .root = root,
            .parent = gpa.dupe(u8, "") catch {
                gpa.free(root);
                continue;
            },
        };
        // Same name twice: the later declaration wins, in the earlier
        // position — the graph's own replace-by-id rule, kept here for
        // hand-written files the SDKs never saw.
        var replaced = false;
        for (out.items) |*old| {
            if (std.mem.eql(u8, old.name, e.name)) {
                gpa.free(old.name);
                gpa.free(old.root);
                gpa.free(old.parent);
                old.* = e;
                replaced = true;
                break;
            }
        }
        if (!replaced) out.append(gpa, e) catch {
            gpa.free(e.name);
            gpa.free(e.root);
            gpa.free(e.parent);
        };
    }
    return out.toOwnedSlice(gpa) catch &.{};
}

/// `~/x` → `$HOME/x` (and bare `~` → `$HOME`). Anything else is copied
/// as-is. Caller owns the result.
fn expandTilde(gpa: std.mem.Allocator, root: []const u8) ?[]u8 {
    if (root.len > 0 and root[0] == '~' and (root.len == 1 or root[1] == '/')) {
        if (std.c.getenv("HOME")) |home| {
            const h = std.mem.span(home);
            return std.mem.concat(gpa, u8, &.{ h, root[1..] }) catch null;
        }
    }
    return gpa.dupe(u8, root) catch null;
}

// ------------------------------------------------------------ worktrees
//
// The write half of what appendWorktrees reads. Both verbs run git as a
// subprocess and surface ITS words on failure — the guards with teeth
// (`worktree remove` refuses a dirty checkout) are git's own, and
// paraphrasing them would only lose information. rook adds the one
// check git does not make at remove time: commits on the branch that
// the workspace's HEAD cannot reach. Losing the only checkout of an
// unmerged branch is the mistake this verb exists to refuse.

/// A branch name that is also safe as one path segment. Stricter than
/// git-check-ref-format on purpose: the name becomes a directory under
/// the data dir, and nobody ever wept over not naming a worktree "a/b".
fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 100) return false;
    if (name[0] == '-' or name[0] == '.') return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// Where rook-created worktrees live: `$XDG_DATA_HOME/rook/worktrees/
/// <workspace>/<name>`. Nested by workspace — the old flat layout let
/// two repos' `zig` worktrees collide. A checkout is derived state, not
/// configuration, so it belongs in the data dir, not beside the repo.
fn worktreePath(buf: []u8, ws: []const u8, name: []const u8) ?[]const u8 {
    if (std.c.getenv("XDG_DATA_HOME")) |x|
        return std.fmt.bufPrint(buf, "{s}/rook/worktrees/{s}/{s}", .{ std.mem.span(x), ws, name }) catch null;
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/share/rook/worktrees/{s}/{s}", .{ std.mem.span(home), ws, name }) catch null;
}

fn makePath(dir: []const u8) void {
    var buf: [1024]u8 = undefined;
    if (dir.len >= buf.len) return;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or buf[i] == '/') {
            const save = buf[i];
            buf[i] = 0;
            _ = mkdir(@ptrCast(&buf), 0o755);
            buf[i] = save;
        }
    }
}

/// The root of a DECLARED (top-level) workspace by name, or null.
fn declaredRoot(io: std.Io, gpa: std.mem.Allocator, ws: []const u8) ?[]u8 {
    const list = load(io, gpa);
    defer free(gpa, list);
    for (list) |e| {
        if (e.parent.len == 0 and std.mem.eql(u8, e.name, ws))
            return gpa.dupe(u8, e.root) catch null;
    }
    return null;
}

fn say(out: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(out, fmt ++ "\n", args) catch "err reply too long\n";
}

/// `worktree add <workspace> <name>`: a checkout of branch <name> under
/// the data dir, creating the branch if it is new. Replies `ok <path>`
/// — the caller (usually an agent) wants somewhere to cd.
pub fn worktreeAdd(io: std.Io, gpa: std.mem.Allocator, ws: []const u8, name: []const u8, out: []u8) []const u8 {
    if (!validName(name)) return say(out, "err worktree name: letters, digits, . _ - (not leading)", .{});
    const root = declaredRoot(io, gpa, ws) orelse
        return say(out, "err no declared workspace '{s}' (see `workspaces`)", .{ws});
    defer gpa.free(root);

    var dbuf: [1024]u8 = undefined;
    const dest = worktreePath(&dbuf, ws, name) orelse return say(out, "err no data dir", .{});
    const cut = std.mem.lastIndexOfScalar(u8, dest, '/') orelse return say(out, "err bad path", .{});
    makePath(dest[0..cut]);

    var destz_buf: [1024]u8 = undefined;
    const destz = std.fmt.bufPrintZ(&destz_buf, "{s}", .{dest}) catch return say(out, "err path too long", .{});
    var namez_buf: [128]u8 = undefined;
    const namez = std.fmt.bufPrintZ(&namez_buf, "{s}", .{name}) catch return say(out, "err name too long", .{});

    const r = envapply.runArgv(root, &.{ "git", "worktree", "add", destz, "-b", namez });
    if (r.ok) return say(out, "ok {s}", .{dest});
    // `-b` refuses an existing branch; attaching to it is what the
    // caller meant, so try exactly that before reporting anything.
    if (std.mem.indexOf(u8, r.logStr(), "already exists") != null) {
        const r2 = envapply.runArgv(root, &.{ "git", "worktree", "add", destz, namez });
        if (r2.ok) return say(out, "ok {s}", .{dest});
        return say(out, "err {s}", .{std.mem.trim(u8, r2.logStr(), " \t\r\n")});
    }
    return say(out, "err {s}", .{std.mem.trim(u8, r.logStr(), " \t\r\n")});
}

/// `worktree remove <workspace> <name>`: refuse unmerged commits (ours),
/// refuse a dirty checkout (git's), then remove the worktree and delete
/// the branch. A branch git will not delete is reported, not forced.
pub fn worktreeRemove(io: std.Io, gpa: std.mem.Allocator, ws: []const u8, name: []const u8, out: []u8) []const u8 {
    if (!validName(name)) return say(out, "err worktree name: letters, digits, . _ - (not leading)", .{});
    const root = declaredRoot(io, gpa, ws) orelse
        return say(out, "err no declared workspace '{s}' (see `workspaces`)", .{ws});
    defer gpa.free(root);

    // The checkout's real path, from git's record — works on worktrees
    // rook never created, wherever they live.
    var gbuf: [1024]u8 = undefined;
    const gpath = std.fmt.bufPrint(&gbuf, "{s}/.git/worktrees/{s}/gitdir", .{ root, name }) catch
        return say(out, "err path too long", .{});
    const content = readSmall(io, gpa, gpath) orelse
        return say(out, "err no worktree '{s}' of '{s}' (see `workspaces`)", .{ name, ws });
    var wt_buf: [1024]u8 = undefined;
    const wtroot = blk: {
        defer gpa.free(content);
        const r = worktreeRoot(content) orelse return say(out, "err unreadable worktree record", .{});
        if (r.len >= wt_buf.len) return say(out, "err path too long", .{});
        @memcpy(wt_buf[0..r.len], r);
        break :blk wt_buf[0..r.len];
    };

    var namez_buf: [128]u8 = undefined;
    const namez = std.fmt.bufPrintZ(&namez_buf, "{s}", .{name}) catch return say(out, "err name too long", .{});
    var rangez_buf: [160]u8 = undefined;
    const rangez = std.fmt.bufPrintZ(&rangez_buf, "HEAD..{s}", .{name}) catch return say(out, "err name too long", .{});

    // Ours: commits HEAD cannot reach die with the branch. A detached
    // worktree has no branch to count, and git guards the rest.
    const rl = envapply.runArgv(root, &.{ "git", "rev-list", "--count", rangez });
    if (rl.ok) {
        const n = std.mem.trim(u8, rl.logStr(), " \t\r\n");
        if (!std.mem.eql(u8, n, "0"))
            return say(out, "err {s} unmerged commit(s) on '{s}' — merge them first", .{ n, name });
    }

    var wtz_buf: [1024]u8 = undefined;
    const wtz = std.fmt.bufPrintZ(&wtz_buf, "{s}", .{wtroot}) catch return say(out, "err path too long", .{});
    const rm = envapply.runArgv(root, &.{ "git", "worktree", "remove", wtz });
    if (!rm.ok) return say(out, "err {s}", .{std.mem.trim(u8, rm.logStr(), " \t\r\n")});

    const bd = envapply.runArgv(root, &.{ "git", "branch", "-d", namez });
    if (!bd.ok) return say(out, "ok removed (branch '{s}' kept)", .{name});
    return say(out, "ok removed", .{});
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "parse: workspace nodes only, in order, later name wins" {
    const gpa = testing.allocator;

    const list = parse(gpa,
        \\{"rookEnvironment":1,"nodes":[
        \\{"id":"opt","kind":"option","scope":"app","key":"theme","value":"nocturne"},
        \\{"id":"workspace:rook","kind":"workspace","scope":"app","name":"rook","root":"~/src/rook"},
        \\{"id":"workspace:dora","kind":"workspace","scope":"app","name":"dora","root":"/w/dora"},
        \\{"id":"workspace:rook2","kind":"workspace","scope":"app","name":"rook","root":"/moved/rook"},
        \\{"id":"bad","kind":"workspace","scope":"app","name":"","root":"/x"}
        \\]}
    );
    defer free(gpa, list);

    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("rook", list[0].name);
    try testing.expectEqualStrings("/moved/rook", list[0].root); // later wins, earlier position
    try testing.expectEqualStrings("dora", list[1].name);
    try testing.expectEqualStrings("/w/dora", list[1].root);
}

test "parse: garbage and absence are an empty list, not a failure" {
    const gpa = testing.allocator;
    const a = parse(gpa, "not json at all");
    defer free(gpa, a);
    try testing.expectEqual(@as(usize, 0), a.len);
    const b = parse(gpa, "{\"rookEnvironment\":1,\"nodes\":[]}");
    defer free(gpa, b);
    try testing.expectEqual(@as(usize, 0), b.len);
}

test "worktreeRoot strips the gitfile suffix" {
    try testing.expectEqualStrings("/w/rook-wt/feat", worktreeRoot("/w/rook-wt/feat/.git\n").?);
    try testing.expect(worktreeRoot("/not/a/gitdir\n") == null);
    try testing.expect(worktreeRoot("/.git") == null);
    try testing.expect(worktreeRoot("") == null);
}

test "validName is one safe path segment" {
    try testing.expect(validName("feat-1"));
    try testing.expect(validName("v0.41_rc"));
    try testing.expect(!validName(""));
    try testing.expect(!validName("a/b"));
    try testing.expect(!validName("-flag"));
    try testing.expect(!validName(".hidden"));
    try testing.expect(!validName("has space"));
}

test "expandTilde" {
    const gpa = testing.allocator;
    const home = std.mem.span(std.c.getenv("HOME").?);

    const a = expandTilde(gpa, "~/src/rook").?;
    defer gpa.free(a);
    try testing.expect(std.mem.startsWith(u8, a, home));
    try testing.expect(std.mem.endsWith(u8, a, "/src/rook"));

    // `~user` is NOT expansion — only `~/` and bare `~` are.
    const b = expandTilde(gpa, "~other/x").?;
    defer gpa.free(b);
    try testing.expectEqualStrings("~other/x", b);

    const c = expandTilde(gpa, "/abs/path").?;
    defer gpa.free(c);
    try testing.expectEqualStrings("/abs/path", c);
}
