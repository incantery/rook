//! Apply: config is a program, and rook runs it.
//!
//! Until now the human ran the emitter by hand (`go run . --out
//! environment.json`) and rook noticed the file change and applied it
//! silently. Both halves of that were wrong. Running a build step is not a
//! human's job, and a config that applies itself the instant it parses
//! gives you no chance to see what it does first.
//!
//! # Three states, and only one file
//!
//!   SOURCE     the program you edit          <config>/main.go, config.ts
//!   CANDIDATE  what it emits                 rook runs it, into a temp file
//!   APPLIED    what rook is running          <config>/environment.json
//!
//! `environment.json` IS the applied state — it is the file rook reads, so
//! there is no separate last-applied to keep in sync and no way for the two
//! to disagree. VISION.md's third diff (drift: last-applied vs live) has
//! nothing to compare yet, because nothing mutates the graph at runtime. It
//! gets a file when it gets a meaning.
//!
//! preview = diff(APPLIED, CANDIDATE)
//! apply   = write CANDIDATE over APPLIED, and the existing reload does the
//!           rest — the same path a hand-edited graph already took
//!
//! # Why the diff is by node id
//!
//! The IR is a flat list of nodes each carrying an `id` (docs/environments/
//! IR.md), which makes the diff a set operation rather than a text one. A
//! reordered emit must read as "no changes", because key order is a
//! property of the emitter, not of the configuration — the SDKs pin theirs
//! with a byte-parity test for exactly this reason.

const std = @import("std");

// ---- running the config program ----

const PollFd = extern struct { fd: c_int, events: i16, revents: i16 };
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn fork() c_int;
extern "c" fn execvp(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn dup2(old: c_int, new: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn getdtablesize() c_int;
extern "c" fn _exit(code: c_int) noreturn;

pub const max_changes = 64;

fn Text(comptime n: usize) type {
    return struct {
        b: [n]u8 = @splat(0),
        n: usize = 0,
        pub fn set(self: *@This(), s: []const u8) void {
            self.n = @min(n, s.len);
            @memcpy(self.b[0..self.n], s[0..self.n]);
        }
        pub fn get(self: *const @This()) []const u8 {
            return self.b[0..self.n];
        }
    };
}

pub const Kind = enum { add, remove, change };

pub const Change = struct {
    kind: Kind,
    id: Text(96) = .{},
    /// What actually differs, for a `change` — "font-size: 16 → 20". Empty
    /// for adds and removes, where the id is the whole story.
    detail: Text(160) = .{},
};

/// The result of a preview.
///
/// `ok` false means the comparison could not be made at all — a candidate
/// that does not parse is NOT "no changes", and rendering it as such would
/// be the worst possible lie: it would say your edit did nothing.
pub const Diff = struct {
    changes: [max_changes]Change = @splat(.{ .kind = .add }),
    n: usize = 0,
    more: usize = 0,
    ok: bool = false,
    err: Text(160) = .{},

    pub fn slice(self: *const Diff) []const Change {
        return self.changes[0..self.n];
    }
    pub fn empty(self: *const Diff) bool {
        return self.ok and self.n == 0 and self.more == 0;
    }

    fn push(self: *Diff, kind: Kind, id: []const u8, detail: []const u8) void {
        if (self.n >= max_changes) {
            self.more += 1;
            return;
        }
        self.changes[self.n] = .{ .kind = kind };
        self.changes[self.n].id.set(id);
        self.changes[self.n].detail.set(detail);
        self.n += 1;
    }
};

/// Every node in a graph, keyed by id.
const Nodes = std.StringHashMap(std.json.Value);

fn collect(gpa: std.mem.Allocator, root: std.json.Value, out: *Nodes) !void {
    const obj = switch (root) {
        .object => |o| o,
        else => return error.NotAGraph,
    };
    const nodes = obj.get("nodes") orelse return; // a graph with no nodes is legal
    const arr = switch (nodes) {
        .array => |a| a,
        else => return error.NotAGraph,
    };
    for (arr.items) |n| {
        const no = switch (n) {
            .object => |o| o,
            else => continue,
        };
        const id = switch (no.get("id") orelse continue) {
            .string => |s| s,
            else => continue,
        };
        // Last id wins, matching the SDKs: `put` replaces by id, so a
        // program that sets font-size twice emits one node.
        try out.put(try gpa.dupe(u8, id), n);
    }
}

/// preview: what applying the candidate would change.
pub fn diff(gpa: std.mem.Allocator, applied_json: []const u8, candidate_json: []const u8) Diff {
    var d = Diff{};

    const cand = std.json.parseFromSlice(std.json.Value, gpa, candidate_json, .{}) catch {
        d.err.set("the config program emitted something that is not JSON");
        return d;
    };
    defer cand.deinit();

    // An ABSENT applied graph is not an error — it is a first apply, and
    // every node reads as an add. An unparseable one is also treated as
    // absent: rook is not running it either.
    const applied_parsed: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, gpa, applied_json, .{}) catch null;
    defer if (applied_parsed) |p| p.deinit();

    var old_nodes = Nodes.init(gpa);
    defer {
        var it = old_nodes.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        old_nodes.deinit();
    }
    var new_nodes = Nodes.init(gpa);
    defer {
        var it = new_nodes.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        new_nodes.deinit();
    }

    if (applied_parsed) |p| collect(gpa, p.value, &old_nodes) catch {};
    collect(gpa, cand.value, &new_nodes) catch {
        d.err.set("the config program emitted no `nodes` array");
        return d;
    };

    // Removals and changes, in the applied graph's order.
    var oit = old_nodes.iterator();
    while (oit.next()) |e| {
        if (new_nodes.get(e.key_ptr.*)) |now| {
            if (!eq(e.value_ptr.*, now)) {
                var buf: [160]u8 = undefined;
                d.push(.change, e.key_ptr.*, describe(&buf, e.value_ptr.*, now));
            }
        } else {
            d.push(.remove, e.key_ptr.*, "");
        }
    }
    // Additions.
    var nit = new_nodes.iterator();
    while (nit.next()) |e| {
        if (old_nodes.get(e.key_ptr.*) == null) d.push(.add, e.key_ptr.*, "");
    }

    d.ok = true;
    return d;
}

/// Which keys differ, and how — "font-size: 16 → 20".
///
/// One key's worth, because a preview line has to fit on a line. The id
/// already says which node; this says why it is listed.
fn describe(buf: []u8, old: std.json.Value, new: std.json.Value) []const u8 {
    const oo = switch (old) {
        .object => |o| o,
        else => return "",
    };
    const no = switch (new) {
        .object => |o| o,
        else => return "",
    };
    var it = no.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, "id")) continue;
        const before = oo.get(e.key_ptr.*);
        if (before != null and eq(before.?, e.value_ptr.*)) continue;
        var ob: [64]u8 = undefined;
        var nb: [64]u8 = undefined;
        return std.fmt.bufPrint(buf, "{s}: {s} → {s}", .{
            e.key_ptr.*,
            if (before) |b| scalar(&ob, b) else "(unset)",
            scalar(&nb, e.value_ptr.*),
        }) catch "";
    }
    // Only removals of keys, then.
    var oit = oo.iterator();
    while (oit.next()) |e| {
        if (no.get(e.key_ptr.*) == null)
            return std.fmt.bufPrint(buf, "{s} removed", .{e.key_ptr.*}) catch "";
    }
    return "";
}

fn scalar(buf: []u8, v: std.json.Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        .integer => |i| std.fmt.bufPrint(buf, "{d}", .{i}) catch "?",
        .float => |f| std.fmt.bufPrint(buf, "{d}", .{f}) catch "?",
        .bool => |b| if (b) "true" else "false",
        .null => "null",
        .array => "[…]",
        .object => "{…}",
        .number_string => |s| s,
    };
}

/// Deep equality over parsed JSON.
///
/// Object comparison is order-INDEPENDENT on purpose: key order is a
/// property of whoever serialised it, not of the configuration, and a
/// preview that reported changes because a field moved would be a preview
/// nobody reads.
fn eq(a: std.json.Value, b: std.json.Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .integer => |x| switch (b) {
            .integer => |y| x == y,
            .float => |y| @as(f64, @floatFromInt(x)) == y,
            else => false,
        },
        .float => |x| switch (b) {
            .float => |y| x == y,
            .integer => |y| x == @as(f64, @floatFromInt(y)),
            else => false,
        },
        .number_string => |x| b == .number_string and std.mem.eql(u8, x, b.number_string),
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| blk: {
            if (b != .array or b.array.items.len != x.items.len) break :blk false;
            for (x.items, b.array.items) |ai, bi| {
                if (!eq(ai, bi)) break :blk false;
            }
            break :blk true;
        },
        .object => |x| blk: {
            if (b != .object or b.object.count() != x.count()) break :blk false;
            var it = x.iterator();
            while (it.next()) |e| {
                const other = b.object.get(e.key_ptr.*) orelse break :blk false;
                if (!eq(e.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

const g_empty = "{\"rookEnvironment\":1,\"nodes\":[]}";

test "a first apply is all additions" {
    const cand =
        \\{"rookEnvironment":1,"nodes":[
        \\{"id":"option:app:font-size","kind":"option","key":"font-size","value":20},
        \\{"id":"leader:app","kind":"leader","key":"`"}]}
    ;
    var d = diff(testing.allocator, "", cand);
    try testing.expect(d.ok);
    try testing.expectEqual(@as(usize, 2), d.n);
    try testing.expectEqual(Kind.add, d.slice()[0].kind);
}

test "an identical graph has no changes, whatever the key order" {
    // The emitters pin key order with a byte-parity test, but a
    // hand-edited graph or a future emitter need not. Key order is a
    // property of the serialiser, not of the configuration — a preview
    // that flagged a moved field is a preview nobody reads.
    const a =
        \\{"rookEnvironment":1,"nodes":[{"id":"o1","kind":"option","key":"font-size","value":20}]}
    ;
    const b =
        \\{"rookEnvironment":1,"nodes":[{"value":20,"key":"font-size","kind":"option","id":"o1"}]}
    ;
    var d = diff(testing.allocator, a, b);
    try testing.expect(d.ok);
    try testing.expect(d.empty());
}

test "node ORDER is not a change either" {
    const a =
        \\{"rookEnvironment":1,"nodes":[{"id":"a","v":1},{"id":"b","v":2}]}
    ;
    const b =
        \\{"rookEnvironment":1,"nodes":[{"id":"b","v":2},{"id":"a","v":1}]}
    ;
    var d = diff(testing.allocator, a, b);
    try testing.expect(d.empty());
}

test "a changed value says which key and both sides" {
    const a =
        \\{"rookEnvironment":1,"nodes":[{"id":"o1","kind":"option","key":"font-size","value":16}]}
    ;
    const b =
        \\{"rookEnvironment":1,"nodes":[{"id":"o1","kind":"option","key":"font-size","value":20}]}
    ;
    var d = diff(testing.allocator, a, b);
    try testing.expectEqual(@as(usize, 1), d.n);
    try testing.expectEqual(Kind.change, d.slice()[0].kind);
    // The whole point of a preview is that you can read it.
    try testing.expectEqualStrings("value: 16 → 20", d.slice()[0].detail.get());
}

test "adds, removes and changes in one pass" {
    const a =
        \\{"rookEnvironment":1,"nodes":[{"id":"keep","v":1},{"id":"gone","v":1},{"id":"edit","v":1}]}
    ;
    const b =
        \\{"rookEnvironment":1,"nodes":[{"id":"keep","v":1},{"id":"edit","v":2},{"id":"new","v":1}]}
    ;
    var d = diff(testing.allocator, a, b);
    try testing.expectEqual(@as(usize, 3), d.n);
    var adds: usize = 0;
    var removes: usize = 0;
    var changes: usize = 0;
    for (d.slice()) |c| switch (c.kind) {
        .add => adds += 1,
        .remove => removes += 1,
        .change => changes += 1,
    };
    try testing.expectEqual(@as(usize, 1), adds);
    try testing.expectEqual(@as(usize, 1), removes);
    try testing.expectEqual(@as(usize, 1), changes);
}

test "a candidate that does not parse is NOT 'no changes'" {
    // The worst possible lie a preview could tell: your edit did nothing.
    // A broken program must read as broken, and apply must refuse.
    var d = diff(testing.allocator, g_empty, "{ this is not json");
    try testing.expect(!d.ok);
    try testing.expect(!d.empty());
    try testing.expect(d.err.get().len > 0);
}

test "a missing applied graph is a first apply, not an error" {
    var d = diff(testing.allocator, "", g_empty);
    try testing.expect(d.ok);
    try testing.expect(d.empty());
}

test "an unreadable applied graph still previews" {
    // rook is not running it either, so everything the candidate has is an
    // addition. Refusing to preview would leave you with no way to see what
    // would fix it.
    const cand =
        \\{"rookEnvironment":1,"nodes":[{"id":"o1","v":1}]}
    ;
    var d = diff(testing.allocator, "{ broken", cand);
    try testing.expect(d.ok);
    try testing.expectEqual(@as(usize, 1), d.n);
    try testing.expectEqual(Kind.add, d.slice()[0].kind);
}

test "more changes than fit are counted, not dropped silently" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendSlice(testing.allocator, "{\"nodes\":[");
    for (0..max_changes + 10) |i| {
        if (i > 0) try buf.append(testing.allocator, ',');
        var b: [64]u8 = undefined;
        try buf.appendSlice(testing.allocator, try std.fmt.bufPrint(&b, "{{\"id\":\"n{d}\"}}", .{i}));
    }
    try buf.appendSlice(testing.allocator, "]}");

    const d = diff(testing.allocator, g_empty, buf.items);
    try testing.expect(d.ok);
    try testing.expectEqual(@as(usize, max_changes), d.n);
    try testing.expectEqual(@as(usize, 10), d.more);
}

// ---- the source: the program the human edits ----

pub const Lang = enum { go, ts };

pub const Source = struct {
    lang: Lang,
    /// The file whose mtime/content decides whether a re-run is needed.
    file: [512]u8 = @splat(0),
    file_len: usize = 0,

    pub fn path(self: *const Source) []const u8 {
        return self.file[0..self.file_len];
    }
};

/// What config program lives in `dir`, if any.
///
/// Convention, not configuration: a config directory that needs config to
/// find its config has lost the plot. Go wins a tie only because it is the
/// SDK rook itself ships; a directory containing both is a directory whose
/// owner should delete one.
pub fn findSource(io: std.Io, dir: []const u8) ?Source {
    const candidates = [_]struct { lang: Lang, name: []const u8 }{
        .{ .lang = .go, .name = "main.go" },
        .{ .lang = .ts, .name = "config.ts" },
        .{ .lang = .ts, .name = "config.mts" },
    };
    for (candidates) |c| {
        var s = Source{ .lang = c.lang };
        const p = std.fmt.bufPrint(&s.file, "{s}/{s}", .{ dir, c.name }) catch continue;
        s.file_len = p.len;
        std.Io.Dir.cwd().access(io, p, .{}) catch continue;
        return s;
    }
    return null;
}

pub const Run = struct {
    ok: bool = false,
    /// stdout+stderr, capped. A config program that fails to compile has
    /// something to say and the human needs to read it — "apply failed" on
    /// its own would send them looking in the wrong place.
    log: [4096]u8 = @splat(0),
    log_len: usize = 0,

    pub fn logStr(self: *const Run) []const u8 {
        return self.log[0..self.log_len];
    }
};

/// Run the config program, writing its graph to `out_path`.
///
/// Its OWN stdout is captured rather than piped into the graph: both SDKs
/// take `--out`, and a program that also printed a debug line would
/// otherwise emit a file that does not parse — a failure mode that would
/// look like a rook bug rather than a stray println.
pub fn run(dir: []const u8, src: Source, out_path: []const u8) Run {
    var r = Run{};

    var argv_buf: [6][:0]const u8 = undefined;
    var dirz: [512]u8 = undefined;
    var outz: [512]u8 = undefined;
    if (dir.len >= dirz.len or out_path.len >= outz.len) {
        setLog(&r, "paths too long");
        return r;
    }
    @memcpy(dirz[0..dir.len], dir);
    dirz[dir.len] = 0;
    @memcpy(outz[0..out_path.len], out_path);
    outz[out_path.len] = 0;
    const out_z: [:0]const u8 = outz[0..out_path.len :0];

    const argv: []const [:0]const u8 = switch (src.lang) {
        .go => blk: {
            argv_buf[0] = "go";
            argv_buf[1] = "run";
            argv_buf[2] = ".";
            argv_buf[3] = "--out";
            argv_buf[4] = out_z;
            break :blk argv_buf[0..5];
        },
        // npx rather than a bare tsx: a config directory should not need a
        // global install, and `npx` resolves a local one first.
        .ts => blk: {
            const base = std.fs.path.basename(src.path());
            var namez: [128]u8 = undefined;
            if (base.len >= namez.len) {
                setLog(&r, "config file name too long");
                break :blk argv_buf[0..0];
            }
            @memcpy(namez[0..base.len], base);
            namez[base.len] = 0;
            argv_buf[0] = "npx";
            argv_buf[1] = "tsx";
            argv_buf[2] = namez[0..base.len :0];
            argv_buf[3] = "--out";
            argv_buf[4] = out_z;
            break :blk argv_buf[0..5];
        },
    };
    if (argv.len == 0) return r;
    return runArgv(dir, argv);
}

/// pipe, fork, exec, read, wait. Shared by the emitter and by `go mod
/// tidy`, which want the same thing: an exit status and whatever the tool
/// had to say about it.
fn runArgv(dir: []const u8, argv: []const [:0]const u8) Run {
    var r = Run{};
    var dirz: [512]u8 = undefined;
    if (dir.len >= dirz.len) {
        setLog(&r, "path too long");
        return r;
    }
    @memcpy(dirz[0..dir.len], dir);
    dirz[dir.len] = 0;

    var fds: [2]c_int = undefined;
    if (pipe(&fds) != 0) {
        setLog(&r, "pipe failed");
        return r;
    }

    var cargv: [7:null]?[*:0]const u8 = @splat(null);
    for (argv, 0..) |a, i| cargv[i] = a.ptr;

    const child = fork();
    if (child < 0) {
        _ = close(fds[0]);
        _ = close(fds[1]);
        setLog(&r, "fork failed");
        return r;
    }
    if (child == 0) {
        // Run FROM the config directory, so `go run .` and a relative
        // config.ts both mean what they look like.
        _ = chdir(@ptrCast(&dirz));
        _ = dup2(fds[1], 1);
        _ = dup2(fds[1], 2);
        var fd: c_int = 3;
        const maxfd = getdtablesize();
        while (fd < maxfd) : (fd += 1) _ = close(fd);
        _ = execvp(cargv[0].?, &cargv);
        // 127 is the shell's "command not found", and that is exactly what
        // this is: no Go toolchain, or no node.
        _exit(127);
    }

    _ = close(fds[1]);
    while (r.log_len < r.log.len) {
        const n = read(fds[0], @as([*]u8, &r.log) + r.log_len, r.log.len - r.log_len);
        if (n <= 0) break;
        r.log_len += @intCast(n);
    }
    _ = close(fds[0]);

    var status: c_int = 0;
    _ = waitpid(child, &status, 0);
    const code: u8 = @truncate(@as(u32, @bitCast(status)) >> 8);
    if (code == 127 and r.log_len == 0) {
        setLog(&r, "not on PATH — that toolchain is not installed");
        return r;
    }
    r.ok = code == 0;
    return r;
}

fn setLog(r: *Run, msg: []const u8) void {
    r.log_len = @min(r.log.len, msg.len);
    @memcpy(r.log[0..r.log_len], msg[0..r.log_len]);
}

/// `go mod tidy`, so the first apply is not what discovers the SDK is
/// missing. Best-effort: no toolchain means the starter is still written
/// and the failure surfaces at apply, where it is already explained.
pub fn tidy(dir: []const u8) void {
    var argv_buf: [4][:0]const u8 = undefined;
    argv_buf[0] = "go";
    argv_buf[1] = "mod";
    argv_buf[2] = "tidy";
    _ = runArgv(dir, argv_buf[0..3]);
}

/// A hash of the config program, for the poll loop. Zero when there is no
/// source — a directory with only a hand-written environment.json is a
/// legitimate setup, and it has nothing to re-run.
pub fn sourceDigest(io: std.Io, gpa: std.mem.Allocator, dir: []const u8) u64 {
    const src = findSource(io, dir) orelse return 0;
    var h = std.hash.Wyhash.init(0xa9911);
    if (std.Io.Dir.cwd().readFileAlloc(io, src.path(), gpa, .limited(1 << 20)) catch null) |data| {
        h.update(data);
        gpa.free(data);
    }
    return h.final();
}

/// Has the config program been edited since the graph rook is running was
/// written?
///
/// The startup question, and it needs its own answer. Comparing the source
/// against rook's LAST SEEN digest cannot work at launch — there is no last
/// seen — and treating the first sight as "no change" means an edit made
/// while rook was closed is silently never mentioned. mtime costs nothing
/// when nothing moved, which is the common case.
pub fn sourceNewerThanGraph(io: std.Io, dir: []const u8, graph_path: []const u8) bool {
    const src = findSource(io, dir) orelse return false;
    const cwd = std.Io.Dir.cwd();
    const s = cwd.statFile(io, src.path(), .{}) catch return false;
    // No graph at all: the program has never been applied, so everything
    // it says is pending.
    const g = cwd.statFile(io, graph_path, .{}) catch return true;
    return s.mtime.nanoseconds > g.mtime.nanoseconds;
}

test "findSource prefers a real file and reports the language" {
    var tio: std.Io.Threaded = .init(testing.allocator, .{});
    defer tio.deinit();
    const io = tio.io();

    var buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "/tmp/rook-envapply-test-{d}", .{std.Thread.getCurrentId()});
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    defer cwd.deleteTree(io, dir) catch {};

    // Nothing there: a directory with only a hand-written graph is legal.
    try testing.expect(findSource(io, dir) == null);

    var tsb: [320]u8 = undefined;
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&tsb, "{s}/config.ts", .{dir}), .data = "x" });
    try testing.expectEqual(Lang.ts, findSource(io, dir).?.lang);

    // Go wins the tie: it is the SDK rook ships.
    var gob: [320]u8 = undefined;
    try cwd.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&gob, "{s}/main.go", .{dir}), .data = "x" });
    try testing.expectEqual(Lang.go, findSource(io, dir).?.lang);
}


// ---- setup: the first-run prompt ----

/// The TypeScript SDK, carried in the binary.
///
/// `@incantery/rook` is not on npm, and a starter that imports a package
/// that does not exist is a starter that fails on the first line. Writing
/// the file out instead is also better than the npm version would be: it is
/// offline, and it cannot drift from the rook that wrote it.
pub const ts_sdk = @embedFile("ts_sdk");

pub const go_mod =
    \\module rookconfig
    \\
    \\go 1.23
    \\
;

pub const go_main =
    \\// Your rook configuration.
    \\//
    \\// This is a PROGRAM, not a settings file: it runs, and what it emits is
    \\// what rook materializes. Edit it, and rook will notice, run it, and show
    \\// you what would change before anything happens.
    \\package main
    \\
    \\import "github.com/incantery/rook/sdk/rook"
    \\
    \\func main() {
    \\    e := rook.New()
    \\
    \\    e.FontSize(14)
    \\
    \\    e.Run()
    \\}
    \\
;

pub const ts_main =
    \\// Your rook configuration.
    \\//
    \\// This is a PROGRAM, not a settings file: it runs, and what it emits is
    \\// what rook materializes. Edit it, and rook will notice, run it, and show
    \\// you what would change before anything happens.
    \\import { env } from "./rook.ts";
    \\
    \\const e = env();
    \\
    \\e.fontSize(14);
    \\
    \\e.run();
    \\
;
