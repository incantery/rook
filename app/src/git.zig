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

/// `git diff --no-index` between two in-memory texts, via scratch files.
/// Returns the raw patch. Caller owns the Result.
///
/// Two texts rather than a path and a ref, and that is the point: it
/// diffs whatever a caller HAS, so the same code answers for a working
/// tree, for a commit, and for two sides a remote host sent over. A
/// source that is not git at all still gets a git-quality patch out of
/// it.
///
/// Exit 1 means "the files differ" and is the expected outcome. Exit 0 is
/// legal too — git can consider texts equal where a byte compare did not,
/// via an autocrlf setting — and yields an empty patch, which reads as no
/// changes.
pub fn diffTexts(
    gpa: std.mem.Allocator,
    io: std.Io,
    old: []const u8,
    cur: []const u8,
    context_lines: u32,
    limit: usize,
) ?Result {
    var rnd: [8]u8 = undefined;
    io.random(&rnd); // 0.16 routes randomness through Io, not std.crypto
    var namebuf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&namebuf, "rook-diff-{x}", .{std.mem.readInt(u64, &rnd, .little)}) catch return null;

    var rootbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = tmpRoot(&rootbuf, name) orelse return null;

    const cwd = std.Io.Dir.cwd();
    var dir = cwd.createDirPathOpen(io, root, .{}) catch return null;
    defer {
        dir.close(io);
        cwd.deleteTree(io, root) catch {};
    }
    dir.writeFile(io, .{ .sub_path = "a", .data = old }) catch return null;
    dir.writeFile(io, .{ .sub_path = "b", .data = cur }) catch return null;

    var ubuf: [32]u8 = undefined;
    const uflag = std.fmt.bufPrint(&ubuf, "--unified={d}", .{context_lines}) catch return null;
    const r = run(gpa, io, root, &.{ "diff", "--no-index", uflag, "a", "b" }, limit) orelse return null;
    if (r.code != 0 and r.code != 1) {
        r.deinit(gpa);
        return null; // git itself failed
    }
    return r;
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn tmpRoot(buf: []u8, name: []const u8) ?[]const u8 {
    const base = if (getenv("TMPDIR")) |t| std.mem.trimEnd(u8, std.mem.span(t), "/") else "/tmp";
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ base, name }) catch null;
}

/// The repository's top-level directory for `dir`, or null when `dir` is
/// not in a repo.
///
/// Anchor paths are stored top-relative because that is how git reports
/// them, and a workspace root can sit BELOW the top — so joining an
/// anchor path onto the workspace root instead of onto the top silently
/// resolves the wrong file in exactly the repos where it matters.
/// Caller owns the result.
pub fn repoTop(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) ?[]u8 {
    const r = run(gpa, io, dir, &.{ "rev-parse", "--show-toplevel" }, 64 * 1024) orelse return null;
    defer r.deinit(gpa);
    if (r.code != 0) return null;
    const top = std.mem.trim(u8, r.stdout, " \t\r\n");
    if (top.len == 0) return null;
    return gpa.dupe(u8, top) catch null;
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

// ------------------------------------------------------- branch, no fork
//
// The status bar's branch segment. Read straight off the filesystem —
// deliberately NOT through run(): this polls at 2Hz for the focused
// pane's repo, so it has to be two small file reads, not a subprocess
// whose exit you wait on sixty times a minute.

/// The branch HEAD names ("main"), or the first 7 hex digits of a
/// detached sha — the width git itself abbreviates to. Copied into
/// `buf`; null when the content is neither shape (a tag ref, garbage).
pub fn parseHead(content: []const u8, buf: []u8) ?[]const u8 {
    const line = std.mem.trim(u8, content, " \t\r\n");
    const ref = "ref: refs/heads/";
    if (std.mem.startsWith(u8, line, ref)) {
        const name = line[ref.len..];
        if (name.len == 0 or name.len > buf.len) return null;
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }
    // Detached HEAD: a bare object id. A ref outside refs/heads (a
    // tag, a remote) is not a branch and reads as nothing rather than
    // as a lie.
    if (line.len >= 7 and buf.len >= 7) {
        for (line) |c| {
            const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
            if (!hex) return null;
        }
        @memcpy(buf[0..7], line[0..7]);
        return buf[0..7];
    }
    return null;
}

/// Resolve a worktree's `.git` FILE ("gitdir: <path>") to the HEAD
/// path to read. A relative gitdir resolves against the directory
/// holding the file, which is how git writes them.
pub fn worktreeHeadPath(gitfile: []const u8, at_dir: []const u8, buf: []u8) ?[]const u8 {
    const line = std.mem.trim(u8, gitfile, " \t\r\n");
    const prefix = "gitdir: ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const dir = line[prefix.len..];
    if (dir.len == 0) return null;
    if (dir[0] == '/')
        return std.fmt.bufPrint(buf, "{s}/HEAD", .{dir}) catch null;
    return std.fmt.bufPrint(buf, "{s}/{s}/HEAD", .{ at_dir, dir }) catch null;
}

/// The branch of the repo owning `path` — walking UP like git itself
/// does (a pane's cwd is usually a subdirectory), following a
/// worktree's `.git` pointer file. Null when no repo owns the path.
pub fn headBranch(io: std.Io, gpa: std.mem.Allocator, path: []const u8, buf: []u8) ?[]const u8 {
    var dir = path;
    while (dir.len > 0) {
        var pbuf: [1024]u8 = undefined;
        // .git as a DIRECTORY (the repo itself) first...
        const headpath = std.fmt.bufPrint(&pbuf, "{s}/.git/HEAD", .{dir}) catch return null;
        if (readSmall(io, gpa, headpath)) |content| {
            defer gpa.free(content);
            return parseHead(content, buf);
        }
        // ...then .git as a worktree's pointer FILE.
        const gitfile = std.fmt.bufPrint(&pbuf, "{s}/.git", .{dir}) catch return null;
        if (readSmall(io, gpa, gitfile)) |content| {
            const target = blk: {
                defer gpa.free(content);
                var hp: [1024]u8 = undefined;
                const p = worktreeHeadPath(content, dir, &hp) orelse return null;
                break :blk readSmall(io, gpa, p) orelse return null;
            };
            defer gpa.free(target);
            return parseHead(target, buf);
        }
        dir = std.fs.path.dirname(dir) orelse return null;
    }
    return null;
}

fn readSmall(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096)) catch null;
}

/// The nearest ancestor of `path` that is a repository root — the
/// directory whose `.git` is a directory (readable HEAD) or a
/// worktree's pointer file. Same filesystem-only probe as headBranch,
/// for the same reason: callers ask on the key path. Copied into
/// `buf`; null when nothing above `path` is a repo.
pub fn repoRootFs(io: std.Io, gpa: std.mem.Allocator, path: []const u8, buf: []u8) ?[]const u8 {
    var dir = path;
    while (dir.len > 0) {
        var pbuf: [1024]u8 = undefined;
        const headpath = std.fmt.bufPrint(&pbuf, "{s}/.git/HEAD", .{dir}) catch return null;
        if (readSmall(io, gpa, headpath)) |c| {
            gpa.free(c);
            if (dir.len > buf.len) return null;
            @memcpy(buf[0..dir.len], dir);
            return buf[0..dir.len];
        }
        const gitfile = std.fmt.bufPrint(&pbuf, "{s}/.git", .{dir}) catch return null;
        if (readSmall(io, gpa, gitfile)) |c| {
            gpa.free(c);
            if (dir.len > buf.len) return null;
            @memcpy(buf[0..dir.len], dir);
            return buf[0..dir.len];
        }
        dir = std.fs.path.dirname(dir) orelse return null;
    }
    return null;
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

test "a branch ref parses to its name" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("main", parseHead("ref: refs/heads/main\n", &buf).?);
    try testing.expectEqualStrings("feat/clickable-statusline", parseHead("ref: refs/heads/feat/clickable-statusline", &buf).?);
}

test "a detached head abbreviates to 7, like git does" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("fb7e182", parseHead("fb7e182f00aa11bb22cc33dd44ee55ff66aa77bb\n", &buf).?);
}

test "what is not a branch reads as nothing, not as a lie" {
    var buf: [64]u8 = undefined;
    // A tag ref is not a branch.
    try testing.expect(parseHead("ref: refs/tags/v1.0", &buf) == null);
    try testing.expect(parseHead("", &buf) == null);
    try testing.expect(parseHead("garbage", &buf) == null);
    // Too short to be an object id.
    try testing.expect(parseHead("abc123", &buf) == null);
}

test "a worktree gitdir resolves absolute and relative" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "/repo/.git/worktrees/wt/HEAD",
        worktreeHeadPath("gitdir: /repo/.git/worktrees/wt\n", "/anywhere", &buf).?,
    );
    try testing.expectEqualStrings(
        "/wt/../repo/.git/worktrees/wt/HEAD",
        worktreeHeadPath("gitdir: ../repo/.git/worktrees/wt", "/wt", &buf).?,
    );
    try testing.expect(worktreeHeadPath("not a pointer", "/wt", &buf) == null);
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
