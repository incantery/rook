//! The substrate: one contract, two implementations.
//!
//! Threads, reviews and their anchors can be reached two ways, and both
//! are permanent rather than one being a stepping stone to the other:
//!
//!   .local  — the registry in THIS process. sqlite read-only, git
//!             in-process, re-anchoring against the working tree as it
//!             is right now rather than as it was when someone
//!             serialised a response.
//!   .remote — HTTP to a rook-host, in whatever language that host is
//!             written. The only option that can work from somewhere
//!             else: a phone answering an ask over the relay cannot read
//!             sqlite.
//!
//! This module exists because both arms were already here, chosen by an
//! `orelse` written out twice — once in review.zig, once in
//! threaddoc.zig — with the selection rule duplicated and parity held
//! together by a test somebody had to remember to write. That is an
//! accident that behaves like an abstraction. This makes it one.
//!
//! What it buys, concretely: callers name an operation, not a transport.
//! Nothing above this line knows whether an answer came from sqlite or
//! from a socket, and nothing knows what the host is written in — so the
//! day the host changes language, the remote arm keeps working and no
//! caller changes at all.
//!
//! WRITES ARE REMOTE ON BOTH ARMS, and that is a deliberate invariant
//! rather than an unfinished port. rook-host is the single writer: it
//! keeps a thread's blob insert and its row insert in ONE transaction so
//! that pruning snapshots cannot race a half-created thread, and rookctl
//! and claude write through it too — including when the app is not
//! running. A second writer breaks that invariant no matter what
//! language it is written in. It moves when the sole-writer question is
//! settled, not before.
//!
//! Scope is the thread/review substrate. Asks, usage, transcripts,
//! attention and the agent deck remain direct hostc clients: they have no
//! local arm and no near-term plan for one, and wrapping them here would
//! be interface for its own sake.

const std = @import("std");
const review = @import("review.zig");
const threaddoc = @import("threaddoc.zig");
const regdb = @import("regdb.zig");
const diffsource = @import("diffsource.zig");
const workspaces = @import("workspaces.zig");
const git = @import("git.zig");

pub const Arm = enum {
    local,
    remote,

    pub fn name(self: Arm) []const u8 {
        return switch (self) {
            .local => "local",
            .remote => "remote",
        };
    }
};

pub const Substrate = struct {
    arm: Arm,
    gpa: std.mem.Allocator,
    io: std.Io,

    /// Pick an arm. Local when the registry can be opened, remote
    /// otherwise — a machine where the db is somewhere this build does
    /// not expect, or a client that is not on the same machine at all.
    ///
    /// Called per poll rather than once at startup, and cheaply (one
    /// sqlite open): a registry can appear after first launch, and an arm
    /// chosen once at boot would strand the app on the wrong one until
    /// restart.
    pub fn select(gpa: std.mem.Allocator, io: std.Io) Substrate {
        const db = regdb.open();
        if (db) |h| {
            regdb.close(h);
            return .{ .arm = .local, .gpa = gpa, .io = io };
        }
        return .{ .arm = .remote, .gpa = gpa, .io = io };
    }

    /// Force an arm. For tests, and for a `--remote` switch if one is
    /// ever wanted.
    pub fn init(arm: Arm, gpa: std.mem.Allocator, io: std.Io) Substrate {
        return .{ .arm = arm, .gpa = gpa, .io = io };
    }

    // ------------------------------------------------------------ reads

    /// The review panel.
    ///
    /// The local arm can still decline — the db was opened by select()
    /// and could be gone or unreadable a moment later — so remote stays
    /// the floor here rather than only in select(). Blanking the panel
    /// because of a race would be worse than a slightly stale answer.
    pub fn reviewSnapshot(self: Substrate, workspace: []const u8) review.Snapshot {
        if (workspace.len == 0) return .{};
        if (self.arm == .local) {
            if (review.read(self.gpa, self.io, workspace)) |snap| return snap;
        }
        return review.fetchHost(self.gpa, self.io, workspace);
    }

    /// The thread sidebar.
    pub fn threadList(self: Substrate, workspace: []const u8) threaddoc.Snapshot {
        if (workspace.len == 0) return .{};
        if (self.arm == .local) {
            if (threaddoc.readList(self.gpa, self.io, workspace)) |snap| return snap;
        }
        return threaddoc.listHost(self.gpa, self.io, workspace);
    }

    /// Which files a diff source considers changed.
    ///
    /// `base` is the source: "" lets it be decided (a worktree reviews
    /// its whole task, everything else its uncommitted work), "head" and
    /// "branch" ask for one. Callers pass it through and read the
    /// resolved `.base` back out of the answer, because branch mode fails
    /// open to head and only the answer knows whether it did.
    ///
    /// Unlike reviews and threads, the local arm here needs no registry
    /// rows — only a repo. The registry is consulted for one thing, WHERE
    /// the repo is, and a diff source that is handed a top can answer with
    /// no rook state at all. That is what makes it the piece a plugin
    /// could supply.
    pub fn changes(self: Substrate, workspace: []const u8, base: []const u8) diffsource.Changes {
        if (workspace.len == 0) return .{ .arena = .init(self.gpa) };
        if (self.arm == .local) {
            if (self.locate(workspace)) |loc| {
                defer loc.deinit(self.gpa);
                return diffsource.changes(self.gpa, self.io, loc.top, loc.request(base));
            }
        }
        return diffsource.changesHost(self.gpa, self.io, workspace, base);
    }

    /// Both texts of one file, from the same source.
    pub fn diffSides(self: Substrate, workspace: []const u8, path: []const u8, base: []const u8) diffsource.Sides {
        if (workspace.len == 0 or path.len == 0) return .{ .arena = .init(self.gpa) };
        if (self.arm == .local) {
            if (self.locate(workspace)) |loc| {
                defer loc.deinit(self.gpa);
                return diffsource.sides(self.gpa, self.io, loc.top, path, loc.request(base));
            }
        }
        return diffsource.sidesHost(self.gpa, self.io, workspace, path, base);
    }

    /// Where a workspace's repo is, and whether it is a worktree of
    /// another — the only two facts the local diff arm needs from the
    /// registry.
    const Located = struct {
        top: []u8,
        /// The SOURCE workspace's root, empty when this is not a
        /// worktree. Non-empty is also what makes branch the default.
        parent_root: []u8,

        fn request(self: Located, base: []const u8) diffsource.Request {
            return .{ .param = base, .parent_root = self.parent_root };
        }

        fn deinit(self: Located, gpa: std.mem.Allocator) void {
            gpa.free(self.top);
            gpa.free(self.parent_root);
        }
    };

    /// Null when the registry has never heard of this workspace, or its
    /// root is not in a repo — both of which mean the local arm has
    /// nothing to say and the remote one should be asked instead.
    ///
    /// The repo TOP, not the workspace root: a workspace can sit in a
    /// subdirectory of its repo, and git reports paths relative to the
    /// top. Joining a changed path onto the root would resolve the wrong
    /// file in exactly the repos where the distinction exists.
    fn locate(self: Substrate, workspace: []const u8) ?Located {
        const root = workspaces.rootOf(self.gpa, workspace) orelse return null;
        defer self.gpa.free(root);
        const top = git.repoTop(self.gpa, self.io, root) orelse return null;

        var parent_root: []u8 = &.{};
        if (workspaces.parentOf(self.gpa, workspace)) |parent| {
            defer self.gpa.free(parent);
            if (workspaces.rootOf(self.gpa, parent)) |pr| parent_root = pr;
        }
        return .{ .top = top, .parent_root = parent_root };
    }

    /// A thread as an editable document. Remote on BOTH arms.
    ///
    /// Not an unfinished port either. The document is not a view of the
    /// rows — it is half of the save contract: a save posts the whole
    /// document back and the host diffs it against its OWN fresh render,
    /// answering 409 with that render. Rendering locally would mean the
    /// prefix we compute comes from our renderer while the check comes
    /// from the host's, so any byte of difference — comment order, a
    /// separator, a timestamp format — becomes a 409 no retry can clear.
    /// It moves when the writer moves.
    pub fn threadDoc(self: Substrate, id: i64) ?threaddoc.Doc {
        return threaddoc.fetchDoc(self.gpa, self.io, id);
    }

    // ----------------------------------------------------------- writes
    //
    // Remote on both arms. See the invariant at the top of the file: the
    // host is the single writer, and a second one breaks the transaction
    // that keeps a prune from racing a half-created thread regardless of
    // what language it is written in.

    pub fn setReviewState(self: Substrate, id: i64, state: []const u8) bool {
        return review.setState(self.gpa, self.io, id, state);
    }

    pub fn saveThreadDoc(self: Substrate, id: i64, content: []const u8) threaddoc.SaveResult {
        return threaddoc.saveDoc(self.gpa, self.io, id, content);
    }

    pub fn threadVerb(self: Substrate, id: i64, name: []const u8) bool {
        return threaddoc.verb(self.gpa, self.io, id, name);
    }
};

// ---------------------------------------------------------------------

const testing = std.testing;
const testdb = @import("testdb.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

test "select finds the local arm when the registry opens" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dirbuf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(testing.io, "rook");
    var dbbuf: [std.fs.max_path_bytes]u8 = undefined;
    const db = try std.fmt.bufPrintZ(&dbbuf, "{s}/rook/rook.db", .{dir});
    try testdb.run(db, testdb.schema);

    _ = setenv("XDG_DATA_HOME", dir, 1);
    const sub = Substrate.select(testing.allocator, testing.io);
    try testing.expectEqual(Arm.local, sub.arm);
}

test "select falls to the remote arm with no registry" {
    // Not an error state: it is every client that is not on this
    // machine, plus any machine where the db is somewhere else.
    _ = setenv("XDG_DATA_HOME", "/nonexistent/rook-test", 1);
    const sub = Substrate.select(testing.allocator, testing.io);
    try testing.expectEqual(Arm.remote, sub.arm);
}

test "an empty workspace is empty on both arms, and asks nobody" {
    // The guard that used to sit in each caller. Worth keeping here
    // because a blank workspace name would otherwise become a request
    // for "/workspaces//threads".
    _ = setenv("XDG_DATA_HOME", "/nonexistent/rook-test", 1);
    inline for (.{ Arm.local, Arm.remote }) |arm| {
        const sub = Substrate.init(arm, testing.allocator, testing.io);
        try testing.expect(!sub.reviewSnapshot("").live);
        try testing.expect(!sub.threadList("").live);
    }
}

test "the local arm answers reviews and threads from the registry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dirbuf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(testing.io, "rook");
    var dbbuf: [std.fs.max_path_bytes]u8 = undefined;
    const db = try std.fmt.bufPrintZ(&dbbuf, "{s}/rook/rook.db", .{dir});
    try testdb.run(db, testdb.schema);
    try testdb.run(db,
        \\INSERT INTO rook_tasks (id, parent_id, workspace, work_type, state, title, anchor_kind, detail, created_at, updated_at)
        \\ VALUES (1, 0, 'src', 'review', 'reviewing', 'r', 'ref', '{"label":"unstaged","verb":"commit"}', 't', 't');
        \\INSERT INTO rook_tasks (id, parent_id, workspace, work_type, state, title, anchor_kind, detail, created_at, updated_at)
        \\ VALUES (2, 1, 'src', 'review', 'rejected', 'wants fix', 'none', '', 't', 't');
        \\INSERT INTO threads (id, workspace, path, start_line, end_line, blob_sha, anchor_text, state, created_at, updated_at)
        \\ VALUES (1, 'src', 'a.zig', 4, 4, 's', 'anchored', 'open', 't', 't');
    );
    _ = setenv("XDG_DATA_HOME", dir, 1);

    const sub = Substrate.select(testing.allocator, testing.io);
    try testing.expectEqual(Arm.local, sub.arm);

    const r = sub.reviewSnapshot("src");
    try testing.expect(r.live and r.any);
    try testing.expectEqualStrings("unstaged", r.label.get());
    try testing.expect(!r.ready); // one rejected child blocks
    try testing.expectEqual(@as(i64, 1), r.blocking);

    const t = sub.threadList("src");
    try testing.expect(t.live);
    try testing.expectEqual(@as(usize, 1), t.slice().len);
    try testing.expectEqualStrings("a.zig", t.slice()[0].path.get());
}

test "the local diff arm answers from the repo the registry points at" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dirbuf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(testing.io, "rook");
    try tmp.dir.createDirPath(testing.io, "repo");
    var dbbuf: [std.fs.max_path_bytes]u8 = undefined;
    const db = try std.fmt.bufPrintZ(&dbbuf, "{s}/rook/rook.db", .{dir});
    try testdb.run(db, testdb.schema);

    var repobuf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = try std.fmt.bufPrint(&repobuf, "{s}/repo", .{dir});
    // A real repo with a real commit, because the point of the local arm
    // is that it reads the working tree rather than a serialised copy of
    // it — and because branch mode below needs a main to fork from.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/committed.txt", .data = "base\n" });
    inline for (.{
        &[_][]const u8{ "init", "-q", "-b", "main" },
        &[_][]const u8{ "add", "-A" },
        &[_][]const u8{ "-c", "user.email=t@example.com", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "base" },
    }) |argv| {
        const r = git.run(testing.allocator, testing.io, repo, argv, 1 << 20) orelse return error.SkipZigTest;
        defer r.deinit(testing.allocator);
    }
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/f.txt", .data = "one\n" });

    // Two workspaces over the same repo: a top-level one, and one marked
    // as a worktree OF it. Same tree, different default source — which is
    // the whole reason locate() reads worktree_of at all.
    var sql: [2048]u8 = undefined;
    try testdb.run(db, try std.fmt.bufPrintZ(&sql,
        \\INSERT INTO workspaces (name, root, created_at, last_used) VALUES ('src', '{s}', 't', 't');
        \\INSERT INTO workspaces (name, root, worktree_of, created_at, last_used) VALUES ('wt', '{s}', 'src', 't', 't');
    , .{ repo, repo }));
    _ = setenv("XDG_DATA_HOME", dir, 1);

    const sub = Substrate.select(testing.allocator, testing.io);
    try testing.expectEqual(Arm.local, sub.arm);

    var c = sub.changes("src", "");
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.files.len);
    try testing.expectEqualStrings("f.txt", c.files[0].path);
    // No worktree_of, so the source decided head.
    try testing.expectEqual(diffsource.Mode.head, c.base.mode);

    var s = sub.diffSides("src", "f.txt", "");
    defer s.deinit();
    try testing.expectEqualStrings("one\n", s.modified);
    // The committed file has both sides; f.txt is new, so its original is
    // empty and that is a state rather than a failure.
    var old = sub.diffSides("src", "committed.txt", "");
    defer old.deinit();
    try testing.expectEqualStrings("base\n", old.original);

    // The worktree row defaults to BRANCH mode, resolved against main.
    // This is what binds workspaces.parentOf: without it, parent_root
    // stays empty and this reads head like the row above.
    var wt = sub.changes("wt", "");
    defer wt.deinit();
    try testing.expectEqual(diffsource.Mode.branch, wt.base.mode);
    try testing.expectEqualStrings("main", wt.base.name);
    try testing.expectEqualStrings("", wt.base.fallback);

    // ...and an explicit param overrides the default either way, which is
    // the header toggle.
    var forced = sub.changes("wt", "head");
    defer forced.deinit();
    try testing.expectEqual(diffsource.Mode.head, forced.base.mode);

    // A workspace the registry has never heard of cannot be located, so
    // the local arm declines and the remote one answers — with no host,
    // that is an empty list rather than a crash or a wrong repo.
    var unknown = sub.changes("nope", "");
    defer unknown.deinit();
    try testing.expectEqual(@as(usize, 0), unknown.files.len);
}

test "a workspace below its repo top still resolves top-relative paths" {
    // The claim locate() makes in its own doc comment, which the test
    // above cannot check because there the workspace root and the repo top
    // are the same directory — so substituting one for the other changed
    // nothing and the comment was asserting on trust.
    //
    // git reports porcelain paths relative to the TOP however deep you
    // run it, so the changes list looks right either way. Where it breaks
    // is reading the file: a top-relative path joined onto the workspace
    // root points at a file that is not there, and the side comes back
    // empty — a diff that renders as "this file is gone".
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dirbuf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(testing.io, "rook");
    try tmp.dir.createDirPath(testing.io, "repo/sub");
    var dbbuf: [std.fs.max_path_bytes]u8 = undefined;
    const db = try std.fmt.bufPrintZ(&dbbuf, "{s}/rook/rook.db", .{dir});
    try testdb.run(db, testdb.schema);

    var repobuf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = try std.fmt.bufPrint(&repobuf, "{s}/repo", .{dir});
    const r = git.run(testing.allocator, testing.io, repo, &.{ "init", "-q", "-b", "main" }, 1 << 20) orelse return error.SkipZigTest;
    r.deinit(testing.allocator);
    // Changed at the TOP, while the workspace lives one level down.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/f.txt", .data = "top level\n" });

    var sql: [2048]u8 = undefined;
    try testdb.run(db, try std.fmt.bufPrintZ(&sql, "INSERT INTO workspaces (name, root, created_at, last_used) VALUES ('deep', '{s}/sub', 't', 't');", .{repo}));
    _ = setenv("XDG_DATA_HOME", dir, 1);

    const sub = Substrate.init(.local, testing.allocator, testing.io);
    var c = sub.changes("deep", "");
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.files.len);
    try testing.expectEqualStrings("f.txt", c.files[0].path);

    var s = sub.diffSides("deep", c.files[0].path, "");
    defer s.deinit();
    try testing.expectEqualStrings("top level\n", s.modified);
}

test "an empty workspace or path asks nobody for a diff" {
    _ = setenv("XDG_DATA_HOME", "/nonexistent/rook-test", 1);
    inline for (.{ Arm.local, Arm.remote }) |arm| {
        const sub = Substrate.init(arm, testing.allocator, testing.io);
        var c = sub.changes("", "");
        defer c.deinit();
        try testing.expectEqual(@as(usize, 0), c.files.len);
        // A blank path would otherwise become "?path=", which the host
        // answers about the workspace root.
        var s = sub.diffSides("src", "", "");
        defer s.deinit();
        try testing.expectEqualStrings("", s.modified);
    }
}

test "the remote arm reaches no registry, whatever is on disk" {
    // The property that makes the arms meaningfully separate: pointing
    // XDG at a perfectly good registry must not tempt a remote caller
    // into reading it. With no host to talk to, the answer is
    // not-live — never the local data.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dirbuf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(testing.io, "rook");
    var dbbuf: [std.fs.max_path_bytes]u8 = undefined;
    const db = try std.fmt.bufPrintZ(&dbbuf, "{s}/rook/rook.db", .{dir});
    try testdb.run(db, testdb.schema);
    try testdb.run(db,
        \\INSERT INTO threads (id, workspace, path, start_line, end_line, blob_sha, anchor_text, state, created_at, updated_at)
        \\ VALUES (1, 'src', 'a.zig', 4, 4, 's', 'anchored', 'open', 't', 't');
    );
    _ = setenv("XDG_DATA_HOME", dir, 1);
    // Point host.json somewhere empty so the remote arm has no host to
    // reach. BOTH variables, in hostc's own precedence order: it checks
    // XDG_STATE_HOME first, so setting only HOME would leave this test
    // talking to whatever real daemon the developer has running — and
    // the real registry has a workspace called "src" too, which is
    // exactly how this would pass for the wrong reason on one machine
    // and fail on another.
    _ = setenv("XDG_STATE_HOME", "/nonexistent/rook-test-state", 1);
    _ = setenv("HOME", "/nonexistent/rook-test-home", 1);

    const sub = Substrate.init(.remote, testing.allocator, testing.io);
    const t = sub.threadList("src");
    try testing.expect(!t.live);
    try testing.expectEqual(@as(usize, 0), t.slice().len);
}

test "the remote diff arm reads no repo, whatever the registry points at" {
    // The same separation property as the row above, for the arm where it
    // is easiest to lose: a diff source needs only a directory, so a
    // remote caller that fell through to git would silently start
    // answering about whatever repo happened to be on THIS machine.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dirbuf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    try tmp.dir.createDirPath(testing.io, "rook");
    try tmp.dir.createDirPath(testing.io, "repo");
    var dbbuf: [std.fs.max_path_bytes]u8 = undefined;
    const db = try std.fmt.bufPrintZ(&dbbuf, "{s}/rook/rook.db", .{dir});
    try testdb.run(db, testdb.schema);

    var repobuf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = try std.fmt.bufPrint(&repobuf, "{s}/repo", .{dir});
    const init = git.run(testing.allocator, testing.io, repo, &.{ "init", "-q", "-b", "main" }, 1 << 20) orelse return error.SkipZigTest;
    init.deinit(testing.allocator);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "repo/f.txt", .data = "one\n" });

    var sql: [1024]u8 = undefined;
    try testdb.run(db, try std.fmt.bufPrintZ(&sql, "INSERT INTO workspaces (name, root, created_at, last_used) VALUES ('src', '{s}', 't', 't');", .{repo}));
    _ = setenv("XDG_DATA_HOME", dir, 1);
    // hostc's own precedence order — XDG_STATE_HOME first, so setting
    // only HOME would leave this talking to a real running daemon.
    _ = setenv("XDG_STATE_HOME", "/nonexistent/rook-test-state", 1);
    _ = setenv("HOME", "/nonexistent/rook-test-home", 1);

    // Prove the local arm CAN see the repo, so the remote arm's silence
    // below is about the arm and not about a broken fixture.
    const local = Substrate.init(.local, testing.allocator, testing.io);
    var seen = local.changes("src", "");
    defer seen.deinit();
    try testing.expectEqual(@as(usize, 1), seen.files.len);

    const sub = Substrate.init(.remote, testing.allocator, testing.io);
    var c = sub.changes("src", "");
    defer c.deinit();
    try testing.expectEqual(@as(usize, 0), c.files.len);
    var s = sub.diffSides("src", "f.txt", "");
    defer s.deinit();
    try testing.expectEqualStrings("", s.modified);
}
