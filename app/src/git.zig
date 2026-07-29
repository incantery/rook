//! Running git, and confining the paths we hand it.
//!
//! The Go host's gitOut, ported: `git -C <dir> <args...>`, stdout
//! captured, exit code reported rather than thrown. Callers here care
//! about the code — `git diff --no-index` exits 1 for "the files
//! differ", which is the SUCCESS case at every call site in the
//! re-anchoring path.
//!
//! stderr is discarded, and that is a decision rather than an omission.
//! The Go side formats it into an error message, but every failure in
//! the anchoring path collapses to the same answer — mark the anchor
//! outdated and render it from stored text — so the text would be built
//! and dropped. Discarding also removes the deadlock that piping two
//! streams and draining one invites: a chatty stderr fills its pipe and
//! the child blocks forever.
//!
//! Timeouts are enforced by a watchdog thread, matching the Go side's
//! context deadline. The race that makes watchdogs dangerous — killing a
//! pid the main thread has already reaped, which after pid reuse means
//! killing a stranger — is closed by ORDERING rather than by locking:
//!
//!   main:     read stdout to EOF → signal done → JOIN watchdog → wait()
//!   watchdog: poll `done`; on expiry SIGKILL the pid, then exit
//!
//! The only reap is main's wait(), and it happens strictly after the
//! join, so no kill can ever follow it. The watchdog signals rather than
//! calling Child.kill(), which would reap from a second thread and
//! mutate the Child out from under its owner.
//!
//! What the deadline does NOT cover: the signal goes to git alone, not
//! to a process group, so a grandchild that inherited the stdout pipe
//! (a pager, a credential helper) keeps it open and the read stays
//! blocked. Fixing that means putting the child in its own process group
//! at spawn, which SpawnOptions does not expose — and the alternative,
//! signalling OUR group, would take the app down with it. None of the
//! commands here run helpers, so this is a bound on the guarantee rather
//! than a live bug.

const std = @import("std");

/// What the Go host uses for the same calls (reviewTimeout). Generous:
/// this bounds a wedged git, it does not police a slow one.
pub const default_timeout_ms: u64 = 10_000;

/// How often the watchdog checks whether it is still needed. Short
/// enough that the thread is gone almost immediately after a normal
/// call — which is every call — and long enough that it costs nothing.
const watchdog_tick_ms: u64 = 25;

const Watchdog = struct {
    pid: std.posix.pid_t,
    io: std.Io,
    timeout_ms: u64,
    done: std.atomic.Value(bool) = .init(false),
    /// Set when the watchdog actually fired, so the caller can tell a
    /// killed git from one that merely failed.
    fired: std.atomic.Value(bool) = .init(false),

    fn watch(self: *Watchdog) void {
        var waited: u64 = 0;
        while (waited < self.timeout_ms) {
            if (self.done.load(.acquire)) return;
            const tick: std.Io.Clock.Duration = .{
                .raw = std.Io.Duration.fromMilliseconds(watchdog_tick_ms),
                // `awake` excludes suspend, so closing the lid for an
                // hour does not spend the deadline and shoot a healthy
                // git the moment the machine wakes.
                .clock = .awake,
            };
            tick.sleep(self.io) catch return;
            waited += watchdog_tick_ms;
        }
        if (self.done.load(.acquire)) return;
        self.fired.store(true, .release);
        // SIGKILL, not TERM: this fires only after the deadline, and a
        // git that ignored TERM would leave us waiting all over again.
        std.posix.kill(self.pid, .KILL) catch {};
    }
};

pub const Result = struct {
    /// Child stdout. Caller owns it.
    stdout: []u8,
    /// Exit status. A signalled or unknown termination reports 255,
    /// which no git command uses as a success code.
    code: u8,
    /// True when the watchdog killed it. Distinct from a nonzero code,
    /// because "git took too long" and "git said no" are different
    /// answers — the first says nothing about the repository.
    timed_out: bool = false,

    pub fn deinit(self: Result, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
    }
};

/// Run git in `dir` with the default deadline.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    args: []const []const u8,
    limit: usize,
) ?Result {
    return runTimeout(gpa, io, dir, args, limit, default_timeout_ms);
}

/// Run git in `dir`. Null when git could not be started at all — a
/// machine with no git, which is a different thing from git failing.
pub fn runTimeout(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    args: []const []const u8,
    limit: usize,
    timeout_ms: u64,
) ?Result {
    var argv = std.ArrayListUnmanaged([]const u8).initCapacity(gpa, args.len + 3) catch return null;
    defer argv.deinit(gpa);
    argv.appendAssumeCapacity("git");
    argv.appendAssumeCapacity("-C");
    argv.appendAssumeCapacity(dir);
    argv.appendSliceAssumeCapacity(args);

    // opts.argv aliases argv.items, so rewriting argv.items[0] below
    // retargets the retry without rebuilding anything.
    // `-C dir` is the ONLY thing that moves git, and setting .cwd as well
    // would apply the move twice — git then chdir's to `dir` relative to
    // `dir` and dies with 128. The Go side has the same shape for the
    // same reason.
    const opts: std.process.SpawnOptions = .{
        .argv = argv.items,
        .stdout = .pipe,
        .stderr = .ignore,
        .stdin = .ignore,
    };
    var child = std.process.spawn(io, opts) catch blk: {
        // launchd hands the daemon a minimal PATH with no git on it, so
        // fall back the way the Go side does before giving up.
        argv.items[0] = "/usr/bin/git";
        break :blk std.process.spawn(io, opts) catch return null;
    };

    // The watchdog only makes sense once we have a pid to signal; a
    // spawn with no id is already over.
    var dog: Watchdog = .{ .pid = child.id orelse 0, .io = io, .timeout_ms = timeout_ms };
    const thread: ?std.Thread = if (dog.pid > 0)
        std.Thread.spawn(.{}, Watchdog.watch, .{&dog}) catch null
    else
        null;

    // Retiring is spelled out on every path rather than deferred, and
    // that is deliberate: a defer would ALSO run on the paths that
    // already joined, and joining a thread twice is undefined. It has to
    // happen before wait() on both, because wait() is the reap and no
    // kill may follow it.
    const retire = struct {
        fn call(d: *Watchdog, t: ?std.Thread) void {
            if (t) |th| {
                d.done.store(true, .release);
                th.join();
            }
        }
    }.call;

    var buf: [16 * 1024]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buf);
    const out = reader.interface.allocRemaining(gpa, .limited(limit)) catch {
        retire(&dog, thread);
        _ = child.wait(io) catch {};
        return null;
    };

    retire(&dog, thread);
    const term = child.wait(io) catch {
        gpa.free(out);
        return null;
    };
    return .{
        .stdout = out,
        .code = switch (term) {
            .exited => |c| c,
            else => 255,
        },
        .timed_out = dog.fired.load(.acquire),
    };
}

/// Join a repo-relative path onto `top`, refusing anything that escapes.
///
/// Ported from the Go host's confinePath. The guard matters because these
/// paths arrive from stored anchors and from clients — an anchor whose
/// path is "../../.ssh/id_rsa" must not become a file read, and the
/// answer has to be refusal rather than clamping, because a clamped path
/// silently anchors a comment to the wrong file.
///
/// Writes into `buf` and returns the slice. Null on refusal.
pub fn confine(buf: []u8, top: []const u8, rel: []const u8) ?[]const u8 {
    if (rel.len == 0) return null;
    if (rel[0] == '/') return null; // absolute
    // Reject traversal by component rather than by substring: "a..b" is a
    // perfectly ordinary name, and "..%2f" is not our decoding problem.
    var it = std.mem.splitScalar(u8, rel, '/');
    var depth: isize = 0;
    while (it.next()) |c| {
        if (c.len == 0 or std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) {
            depth -= 1;
            if (depth < 0) return null; // escapes top
            continue;
        }
        depth += 1;
    }
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ top, rel }) catch null;
}

// ---------------------------------------------------------------------

const testing = std.testing;

test "run reports git's exit code, and 1 is not a failure" {
    // The semantic this module exists to preserve: `git diff --no-index`
    // exits 1 for "the files differ", which is the SUCCESS case for
    // re-anchoring. A runner that treated nonzero as failure would
    // report every changed file as having no hunks — every anchor would
    // silently stop moving.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dirbuf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "l1\nl2\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b", .data = "l1\nCHANGED\n" });

    const differ = run(testing.allocator, testing.io, dir, &.{ "diff", "--no-index", "--unified=0", "a", "b" }, 1 << 20) orelse {
        return error.SkipZigTest; // no git on this machine
    };
    defer differ.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 1), differ.code);
    try testing.expect(std.mem.indexOf(u8, differ.stdout, "@@ -2 +2 @@") != null);

    // Identical files: exit 0, no hunks.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c", .data = "l1\nl2\n" });
    const same = run(testing.allocator, testing.io, dir, &.{ "diff", "--no-index", "--unified=0", "a", "c" }, 1 << 20).?;
    defer same.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), same.code);
    try testing.expectEqualStrings("", same.stdout);
}

test "the watchdog kills a child that outlives its deadline" {
    // Driven against /bin/sleep rather than through run(), because no
    // git invocation reliably hangs with stdin on /dev/null — and a
    // test that only asserts "if it timed out, then…" asserts nothing.
    // This exercises the mechanism that matters: the kill fires, and the
    // join-before-reap ordering holds.
    var child = std.process.spawn(testing.io, .{
        .argv = &.{ "/bin/sleep", "30" },
        .stdout = .pipe,
        .stderr = .ignore,
        .stdin = .ignore,
    }) catch return error.SkipZigTest;

    var dog: Watchdog = .{ .pid = child.id.?, .io = testing.io, .timeout_ms = 200 };
    const thread = try std.Thread.spawn(.{}, Watchdog.watch, .{&dog});

    // The read returns because the kill closes the pipe — which is what
    // unwedges a hung call in production too.
    var buf: [256]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(testing.io, &buf);
    const out = try reader.interface.allocRemaining(testing.allocator, .limited(4096));
    defer testing.allocator.free(out);

    dog.done.store(true, .release);
    thread.join();
    const term = try child.wait(testing.io);

    try testing.expect(dog.fired.load(.acquire));
    // Signalled, not exited — sleep(1) would have exited 0 after 30s.
    try testing.expect(term != .exited);
}

test "a normal call retires the watchdog without firing it" {
    const r = runTimeout(testing.allocator, testing.io, ".", &.{"--version"}, 4096, 10_000) orelse return error.SkipZigTest;
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(!r.timed_out);
}

test "run captures stdout" {
    const r = run(testing.allocator, testing.io, ".", &.{"--version"}, 4096) orelse return error.SkipZigTest;
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.startsWith(u8, r.stdout, "git version"));
}

test "confine keeps paths inside the repo" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("/repo/a/b.txt", confine(&buf, "/repo", "a/b.txt").?);
    try testing.expectEqualStrings("/repo/f.txt", confine(&buf, "/repo", "f.txt").?);
    // Descending then coming back up stays inside, so it is allowed —
    // this is the case a naive "contains .." check gets wrong.
    try testing.expectEqualStrings("/repo/a/../b.txt", confine(&buf, "/repo", "a/../b.txt").?);
    // ...and so is a name that merely contains dots.
    try testing.expectEqualStrings("/repo/a..b", confine(&buf, "/repo", "a..b").?);
}

test "confine refuses what escapes" {
    var buf: [512]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), confine(&buf, "/repo", ""));
    try testing.expectEqual(@as(?[]const u8, null), confine(&buf, "/repo", "/etc/passwd"));
    try testing.expectEqual(@as(?[]const u8, null), confine(&buf, "/repo", ".."));
    try testing.expectEqual(@as(?[]const u8, null), confine(&buf, "/repo", "../secret"));
    try testing.expectEqual(@as(?[]const u8, null), confine(&buf, "/repo", "a/../../secret"));
    // Refusal, not clamping: a clamped path anchors a comment to the
    // wrong file rather than to no file.
    try testing.expectEqual(@as(?[]const u8, null), confine(&buf, "/repo", "a/b/../../../x"));
}
