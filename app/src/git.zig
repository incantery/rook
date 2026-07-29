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
//! KNOWN GAP vs the Go side: no timeout. Go wraps these in a
//! context with reviewTimeout; 0.16 has no cancelable wait, and a
//! watchdog thread racing kill() against wait() is worse than the hang
//! it prevents. A wedged git wedges the calling thread. Left explicit
//! rather than papered over, and it wants fixing before this runs on a
//! UI thread.

const std = @import("std");

pub const Result = struct {
    /// Child stdout. Caller owns it.
    stdout: []u8,
    /// Exit status. A signalled or unknown termination reports 255,
    /// which no git command uses as a success code.
    code: u8,

    pub fn deinit(self: Result, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
    }
};

/// Run git in `dir`. Null when git could not be started at all — a
/// machine with no git, which is a different thing from git failing.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    args: []const []const u8,
    limit: usize,
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

    var buf: [16 * 1024]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buf);
    const out = reader.interface.allocRemaining(gpa, .limited(limit)) catch {
        _ = child.wait(io) catch {};
        return null;
    };

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
