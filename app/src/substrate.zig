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
            if (threaddoc.readList(self.gpa, workspace)) |snap| return snap;
        }
        return threaddoc.listHost(self.gpa, self.io, workspace);
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
