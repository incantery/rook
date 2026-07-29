//! Re-anchoring, assembled: a stored anchor in, where it lives in today's
//! file out.
//!
//! anchor.zig holds the arithmetic and stays pure. This is the half that
//! touches the world — reads the current content, forks git for a diff,
//! and remembers the answer so a pane's poll does not re-fork for a file
//! nobody edited. The Go host's anchorNow, less the piece named below.
//!
//! Every failure lands on the same answer: outdated, with the STORED
//! range. Missing file, missing snapshot, git absent, path that escapes
//! the repo — all of it. An anchor degrades, it never errors, because
//! the alternative is a comment that disappears when its file moves.
//!
//! The base ref is a PARAMETER here, where the Go side resolves it
//! internally through reviewBaseFor. That resolution reaches the
//! workspace registry, worktree parentage, and origin's default branch,
//! and none of that belongs behind an anchoring call — the caller
//! already knows which base it is reviewing against. It stays in Go
//! until the registry itself comes across.

const std = @import("std");
const anchor = @import("anchor.zig");
const blobs = @import("blobs.zig");
const git = @import("git.zig");

pub const Hunk = anchor.Hunk;

/// Which content an anchor is anchored INTO.
///
/// The distinction is load-bearing and cost the Go side a regression:
/// a modified-side anchor compares against the working tree, but an
/// original-side anchor's snapshot came from the diff base, so it must
/// re-anchor against that SAME base. Comparing it to the working tree
/// brands a fresh anchor outdated the instant the tree diverges — which
/// on that side it always has, by definition.
pub const Side = enum { modified, original };

pub const Anchor = struct {
    // in: immutable ground truth, exactly as stored.
    path: []const u8,
    start_line: u32,
    end_line: u32,
    blob_sha: []const u8,
    side: Side = .modified,

    // out: the view, recomputed on every read and never written back.
    current_start: u32 = 0,
    current_end: u32 = 0,
    outdated: bool = false,
};

/// Cache of parsed hunks per (stored blob, current blob) pair.
///
/// One entry serves every anchor pointing at that file version, which is
/// the point: a review with forty hunks in one file forks git once, not
/// forty times. Keyed by content hashes rather than by path, so two
/// workspaces holding the same file version share the answer.
pub const Memo = struct {
    gpa: std.mem.Allocator,
    map: std.StringHashMapUnmanaged([]Hunk) = .empty,

    /// Crude cap, mirroring the Go side. Entries are a handful of ints,
    /// and clearing wholesale beats an LRU nobody will tune.
    const cap = 256;

    pub fn init(gpa: std.mem.Allocator) Memo {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Memo) void {
        self.clear();
        self.map.deinit(self.gpa);
    }

    fn clear(self: *Memo) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.map.clearRetainingCapacity();
    }

    fn get(self: *Memo, key: []const u8) ?[]Hunk {
        return self.map.get(key);
    }

    /// Takes ownership of `hunks` on success; frees it on failure, so the
    /// caller never has to know which happened.
    fn put(self: *Memo, key: []const u8, hunks: []Hunk) void {
        if (self.map.count() >= cap) self.clear();
        const owned_key = self.gpa.dupe(u8, key) catch {
            self.gpa.free(hunks);
            return;
        };
        self.map.put(self.gpa, owned_key, hunks) catch {
            self.gpa.free(owned_key);
            self.gpa.free(hunks);
        };
    }
};

pub const Context = struct {
    /// Repository top level. Anchor paths are top-relative, as git
    /// reports them.
    top: []const u8,
    /// What an original-side anchor re-anchors against — "HEAD", or the
    /// merge-base sha. Ignored for modified-side anchors.
    base_ref: []const u8 = "HEAD",
    blobs: *blobs.Store,
    memo: *Memo,
};

/// Largest file we will re-anchor into. Beyond this the answer is
/// outdated rather than a multi-hundred-megabyte read on a poll; the
/// capture side already declines to snapshot files this big, so in
/// practice such an anchor has no blob_sha and never reaches here.
const max_file = 16 * 1024 * 1024;

/// Map `a`'s stored range onto the file as it is right now, filling in
/// current_start / current_end / outdated.
pub fn resolve(gpa: std.mem.Allocator, io: std.Io, ctx: Context, a: *Anchor) void {
    a.current_start = a.start_line;
    a.current_end = a.end_line;

    var pathbuf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = git.confine(&pathbuf, ctx.top, a.path) orelse {
        a.outdated = true;
        return;
    };

    const cur = currentContent(gpa, io, ctx, a, abs) orelse {
        a.outdated = true; // deleted, unreadable, or base content gone
        return;
    };
    defer gpa.free(cur);

    const cur_sha = anchor.blobSha(cur);
    if (std.mem.eql(u8, &cur_sha, a.blob_sha)) return; // unchanged: one hash, no git

    var keybuf: [96]u8 = undefined;
    const key = std.fmt.bufPrint(&keybuf, "{s}:{s}", .{ a.blob_sha, &cur_sha }) catch {
        a.outdated = true;
        return;
    };

    const hunks = ctx.memo.get(key) orelse blk: {
        const old = ctx.blobs.get(gpa, a.blob_sha) orelse {
            a.outdated = true; // snapshot pruned or never captured — fail open
            return;
        };
        defer gpa.free(old);
        const fresh = diffHunks(gpa, io, old, cur) orelse {
            a.outdated = true;
            return;
        };
        ctx.memo.put(key, fresh);
        // put() may have dropped it (allocation failure, or the cap
        // cleared the table) — read back, and fall back to the value we
        // computed only if it survived.
        break :blk ctx.memo.get(key) orelse {
            const m = anchor.mapRange(fresh, a.start_line, a.end_line);
            apply(a, m);
            return;
        };
    };

    apply(a, anchor.mapRange(hunks, a.start_line, a.end_line));
}

fn apply(a: *Anchor, m: anchor.Mapped) void {
    a.outdated = m.outdated;
    // An outdated anchor keeps its STORED range — that is what it renders
    // from, alongside its stored text.
    a.current_start = if (m.outdated) a.start_line else m.start;
    a.current_end = if (m.outdated) a.end_line else m.end;
}

/// What the anchor's side says "current" means. Caller owns the result.
fn currentContent(gpa: std.mem.Allocator, io: std.Io, ctx: Context, a: *const Anchor, abs: []const u8) ?[]u8 {
    switch (a.side) {
        .original => {
            var specbuf: [std.fs.max_path_bytes + 64]u8 = undefined;
            const spec = std.fmt.bufPrint(&specbuf, "{s}:{s}", .{ ctx.base_ref, a.path }) catch return null;
            const r = git.run(gpa, io, ctx.top, &.{ "show", spec }, max_file) orelse return null;
            if (r.code != 0) {
                r.deinit(gpa);
                return null; // base content gone
            }
            return r.stdout;
        },
        .modified => return std.Io.Dir.cwd().readFileAlloc(io, abs, gpa, .limited(max_file)) catch null,
    }
}

/// `git diff --no-index --unified=0` between two contents, via scratch
/// files. Caller owns the result.
///
/// Exit 1 means "the files differ" and is the expected outcome — we only
/// get here because the hashes already disagree. Exit 0 is legal too
/// (git can consider them equal where a byte compare did not, e.g. via
/// an autocrlf setting) and yields no hunks, which maps to no movement.
fn diffHunks(gpa: std.mem.Allocator, io: std.Io, old: []const u8, cur: []const u8) ?[]Hunk {
    var rnd: [8]u8 = undefined;
    io.random(&rnd); // 0.16 routes randomness through Io, not std.crypto
    var namebuf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&namebuf, "rook-reanchor-{x}", .{std.mem.readInt(u64, &rnd, .little)}) catch return null;

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

    const r = git.run(gpa, io, root, &.{ "diff", "--no-index", "--unified=0", "a", "b" }, max_file) orelse return null;
    defer r.deinit(gpa);
    if (r.code != 0 and r.code != 1) return null; // git itself failed

    var list: std.ArrayListUnmanaged(Hunk) = .empty;
    defer list.deinit(gpa);
    var it = anchor.hunks(r.stdout);
    while (it.next()) |h| list.append(gpa, h) catch return null;
    return list.toOwnedSlice(gpa) catch null;
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn tmpRoot(buf: []u8, name: []const u8) ?[]const u8 {
    const base = if (getenv("TMPDIR")) |t| std.mem.trimEnd(u8, std.mem.span(t), "/") else "/tmp";
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ base, name }) catch null;
}

// ---------------------------------------------------------------------
// Tests — the port of reanchor_test.go's TestAnchorNow, step for step.
// These drive real git and a real sqlite fixture, because the parts
// worth testing here are exactly the ones a fake would paper over: what
// git calls a hunk, and whether a missing row reads as pruned.
// ---------------------------------------------------------------------

const testing = std.testing;
const testdb = @import("testdb.zig");
const regdb = @import("regdb.zig");

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []const u8, // repo dir, relative to cwd
    dbpath: [:0]const u8,
    rootbuf: [std.fs.max_path_bytes]u8 = undefined,
    dbbuf: [std.fs.max_path_bytes]u8 = undefined,

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn writeFile(self: *Fixture, name: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
    }

    /// Put a snapshot in anchor_blobs and return its sha. Bound as a
    /// blob rather than interpolated, so content with quotes or NULs is
    /// stored the way a real capture would store it.
    fn snapshot(self: *Fixture, content: []const u8) ![40]u8 {
        const sha = anchor.blobSha(content);
        try testdb.run(self.dbpath, testdb.schema);
        const db = try testdb.open(self.dbpath);
        defer _ = regdb.sqlite3_close(db);
        var stmt: ?*anyopaque = null;
        try testing.expectEqual(regdb.OK, regdb.sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO anchor_blobs (sha, content) VALUES (?, ?)", -1, &stmt, null));
        defer _ = regdb.sqlite3_finalize(stmt);
        _ = regdb.sqlite3_bind_text(stmt, 1, &sha, 40, regdb.STATIC);
        _ = testdb.sqlite3_bind_blob(stmt, 2, content.ptr, @intCast(content.len), regdb.STATIC);
        _ = regdb.sqlite3_step(stmt);
        return sha;
    }
};

fn fixture() !*Fixture {
    const f = try testing.allocator.create(Fixture);
    f.* = .{ .tmp = testing.tmpDir(.{}), .root = undefined, .dbpath = undefined };
    f.root = try std.fmt.bufPrint(&f.rootbuf, ".zig-cache/tmp/{s}", .{f.tmp.sub_path});
    f.dbpath = try std.fmt.bufPrintZ(&f.dbbuf, "{s}/rook.db", .{f.root});
    return f;
}

fn destroy(f: *Fixture) void {
    f.deinit();
    testing.allocator.destroy(f);
}

test "an unchanged file keeps its range, and never forks git" {
    const f = try fixture();
    defer destroy(f);
    try f.writeFile("f.txt", "l1\nl2\nl3\nl4\nl5\n");
    const sha = try f.snapshot("l1\nl2\nl3\nl4\nl5\n");

    var store = blobs.Store.openPath(f.dbpath);
    defer store.close();
    var memo = Memo.init(testing.allocator);
    defer memo.deinit();
    const ctx: Context = .{ .top = f.root, .blobs = &store, .memo = &memo };

    var a: Anchor = .{ .path = "f.txt", .start_line = 3, .end_line = 4, .blob_sha = &sha };
    resolve(testing.allocator, testing.io, ctx, &a);
    try testing.expectEqual(@as(u32, 3), a.current_start);
    try testing.expectEqual(@as(u32, 4), a.current_end);
    try testing.expect(!a.outdated);
    // The fast path is the whole point: same hash, so nothing was memoed
    // because no diff was ever run.
    try testing.expectEqual(@as(usize, 0), memo.map.count());
}

test "edits above shift the range down" {
    const f = try fixture();
    defer destroy(f);
    const sha = try f.snapshot("l1\nl2\nl3\nl4\nl5\n");
    try f.writeFile("f.txt", "a\nb\nl1\nl2\nl3\nl4\nl5\n");

    var store = blobs.Store.openPath(f.dbpath);
    defer store.close();
    var memo = Memo.init(testing.allocator);
    defer memo.deinit();
    const ctx: Context = .{ .top = f.root, .blobs = &store, .memo = &memo };

    var a: Anchor = .{ .path = "f.txt", .start_line = 3, .end_line = 4, .blob_sha = &sha };
    resolve(testing.allocator, testing.io, ctx, &a);
    try testing.expectEqual(@as(u32, 5), a.current_start);
    try testing.expectEqual(@as(u32, 6), a.current_end);
    try testing.expect(!a.outdated);

    // Second anchor into the same file version: served from the memo,
    // which is what stops a forty-hunk review forking git forty times.
    try testing.expectEqual(@as(usize, 1), memo.map.count());
    var b: Anchor = .{ .path = "f.txt", .start_line = 1, .end_line = 1, .blob_sha = &sha };
    resolve(testing.allocator, testing.io, ctx, &b);
    try testing.expectEqual(@as(u32, 3), b.current_start);
    try testing.expectEqual(@as(usize, 1), memo.map.count());
}

test "an edit to the anchored lines outdates, keeping the stored range" {
    const f = try fixture();
    defer destroy(f);
    const sha = try f.snapshot("l1\nl2\nl3\nl4\nl5\n");
    try f.writeFile("f.txt", "l1\nl2\nCHANGED\nl4\nl5\n");

    var store = blobs.Store.openPath(f.dbpath);
    defer store.close();
    var memo = Memo.init(testing.allocator);
    defer memo.deinit();
    const ctx: Context = .{ .top = f.root, .blobs = &store, .memo = &memo };

    var a: Anchor = .{ .path = "f.txt", .start_line = 3, .end_line = 4, .blob_sha = &sha };
    resolve(testing.allocator, testing.io, ctx, &a);
    try testing.expect(a.outdated);
    try testing.expectEqual(@as(u32, 3), a.current_start);
    try testing.expectEqual(@as(u32, 4), a.current_end);
}

test "every failure lands on outdated with the stored range" {
    const f = try fixture();
    defer destroy(f);
    const sha = try f.snapshot("l1\nl2\nl3\nl4\nl5\n");

    var store = blobs.Store.openPath(f.dbpath);
    defer store.close();
    var memo = Memo.init(testing.allocator);
    defer memo.deinit();
    const ctx: Context = .{ .top = f.root, .blobs = &store, .memo = &memo };

    // Deleted (never written) file.
    var gone: Anchor = .{ .path = "f.txt", .start_line = 3, .end_line = 4, .blob_sha = &sha };
    resolve(testing.allocator, testing.io, ctx, &gone);
    try testing.expect(gone.outdated);
    try testing.expectEqual(@as(u32, 3), gone.current_start);

    // Snapshot pruned: the file is there and has changed, but the
    // content to diff against is gone.
    try f.writeFile("g.txt", "totally different\n");
    var pruned: Anchor = .{ .path = "g.txt", .start_line = 1, .end_line = 1, .blob_sha = "nope" };
    resolve(testing.allocator, testing.io, ctx, &pruned);
    try testing.expect(pruned.outdated);
    try testing.expectEqual(@as(u32, 1), pruned.current_start);

    // A path that escapes the repo is refused before it becomes a read.
    var escaping: Anchor = .{ .path = "../../../etc/passwd", .start_line = 1, .end_line = 1, .blob_sha = &sha };
    resolve(testing.allocator, testing.io, ctx, &escaping);
    try testing.expect(escaping.outdated);
}

test "an original-side anchor re-anchors against the base, not the tree" {
    // The regression the Go side carries a comment about. a.txt is
    // committed as "hello\n" and the working tree has since diverged;
    // an original-side anchor must compare against HEAD, because on that
    // side the tree has diverged BY DEFINITION and comparing to it would
    // brand every fresh anchor outdated immediately.
    const f = try fixture();
    defer destroy(f);
    try f.writeFile("a.txt", "hello\n");
    const sha = try f.snapshot("hello\n");

    const init = git.run(testing.allocator, testing.io, f.root, &.{ "init", "-q" }, 1 << 16) orelse
        return error.SkipZigTest; // no git on this machine
    defer init.deinit(testing.allocator);
    inline for (.{
        &[_][]const u8{ "add", "a.txt" },
        &[_][]const u8{ "-c", "user.email=t@example.com", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "x" },
    }) |argv| {
        const r = git.run(testing.allocator, testing.io, f.root, argv, 1 << 16).?;
        defer r.deinit(testing.allocator);
        try testing.expectEqual(@as(u8, 0), r.code);
    }
    try f.writeFile("a.txt", "edited\n"); // tree diverges from the base

    var store = blobs.Store.openPath(f.dbpath);
    defer store.close();
    var memo = Memo.init(testing.allocator);
    defer memo.deinit();
    const ctx: Context = .{ .top = f.root, .base_ref = "HEAD", .blobs = &store, .memo = &memo };

    var orig: Anchor = .{ .path = "a.txt", .start_line = 1, .end_line = 1, .blob_sha = &sha, .side = .original };
    resolve(testing.allocator, testing.io, ctx, &orig);
    try testing.expect(!orig.outdated);
    try testing.expectEqual(@as(u32, 1), orig.current_start);

    // The same anchor on the MODIFIED side sees the diverged tree and is
    // outdated — the two sides genuinely disagree, which is why the
    // field exists.
    var mod: Anchor = .{ .path = "a.txt", .start_line = 1, .end_line = 1, .blob_sha = &sha, .side = .modified };
    resolve(testing.allocator, testing.io, ctx, &mod);
    try testing.expect(mod.outdated);
}
