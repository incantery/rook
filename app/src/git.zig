//! git, read from the filesystem — never spawned.
//!
//! This file used to RUN git: `git -C <dir> <args…>` behind a watchdog
//! thread, for `diff --no-index` (the diff viewer) and `rev-parse
//! --show-toplevel` (the repo root), plus a path-confinement guard for
//! anchor paths that arrived from stored comments and from clients.
//!
//! All three callers left in the strip, and what remains needs no
//! subprocess at all: the branch is a read of `.git/HEAD` (following a
//! worktree's `gitdir:` pointer when there is one), and the repo root is
//! a walk up looking for `.git`. So rook no longer executes git, which
//! also retires the watchdog and everything it was guarding against — a
//! wedged child, a grandchild holding the stdout pipe, a kill racing a
//! reap after pid reuse.
//!
//! If something needs to run git again, take the machinery back out of
//! git history rather than writing it fresh: the ordering rule that made
//! the watchdog safe (read to EOF → signal → JOIN → wait, so the only
//! reap strictly follows the join) is easy to get wrong.

const std = @import("std");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

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

