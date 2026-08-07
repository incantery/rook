//! Buffer — a document (the rook-buffers model: a file is a document,
//! not a window). Rope storage + path identity + grouped undo. All
//! mutation goes through insert/deleteRange so undo never desyncs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ropepkg = @import("rope.zig");

/// What we last saw on disk, at load or at save.
///
/// Enough to notice somebody else's write. In an agent workspace that
/// is not a corner case — the whole premise of rook is that things are
/// editing your files while you look at them.
pub const DiskState = struct {
    mtime_ns: i128,
    size: u64,
    inode: u64,

    fn of(st: std.Io.File.Stat) DiskState {
        return .{
            .mtime_ns = @intCast(st.mtime.nanoseconds),
            .size = st.size,
            .inode = @intCast(st.inode),
        };
    }

    /// All three, not just mtime: a filesystem with coarse timestamps
    /// can rewrite a file inside one tick, and a replace-by-rename
    /// (which is what rook's own save does) keeps neither size nor
    /// inode stable.
    fn matches(self: DiskState, st: std.Io.File.Stat) bool {
        const other = DiskState.of(st);
        return self.mtime_ns == other.mtime_ns and
            self.size == other.size and
            self.inode == other.inode;
    }
};

pub const EditFn = *const fn (ctx: *anyopaque, start: usize, removed: usize, added: usize) void;

pub const Watcher = struct { ctx: *anyopaque, cb: EditFn };

/// How many views may watch one document. See Buffer.watchers.
pub const max_watchers = 16;

pub const Buffer = struct {
    rope: ropepkg.Rope,
    /// Absolute path, owned; null = scratch.
    path: ?[]u8 = null,
    /// The file as we last saw it, or null when we have no claim on it
    /// (a scratch buffer, or a path that did not exist when we opened
    /// it). Null means `save` will not refuse — fail open, like the
    /// rest of rook's host-facing code.
    disk: ?DiskState = null,

    /// Bumped by every content mutation (edits, undo, redo) — the
    /// highlighter's reparse trigger. Monotonic, so it says "something
    /// happened", never "we are back where we were".
    version: u64 = 0,
    /// What changed, tagged with the version each edit produced — see
    /// TreeEdit and editsSince. A capped FIFO that nobody drains: a
    /// document shown in two panes has two parsers, and "edits since
    /// YOUR last parse" is a different slice for each. The drain-once
    /// API this replaces let whichever pane parsed first eat the edits
    /// the other one needed, and the loser reparsed against a stale
    /// tree — highlighting that is not wrong loudly, just wrong.
    edits: std.ArrayListUnmanaged(TreeEdit) = .empty,
    /// The newest version whose edit has been evicted from the log. A
    /// parser whose tree is older than this cannot be told what
    /// changed; its answer is a full parse.
    edits_floor: u64 = 0,
    /// While pinned, newUndoGroup does nothing. An ex command that
    /// edits many lines is ONE change to undo however many primitives
    /// it reaches for, and the primitives are the ones that open
    /// groups.
    group_pinned: bool = false,
    /// Told about every edit — offset, bytes removed, bytes added — so
    /// anything holding a POSITION in this document can move it. One
    /// seam on purpose: a position that only some edits update is worse
    /// than one that never updates, because it is right often enough to
    /// be trusted.
    ///
    /// A LIST, not one slot. A document open in two panes has two sets
    /// of marks to move, and the single-listener seam this replaces was
    /// written when a buffer could only ever have one view. Sixteen is
    /// far past any sane number of panes onto one file; a seventeenth
    /// view simply does not get its marks shifted, which is the least
    /// harmful way to run out.
    watchers: [max_watchers]?Watcher = @splat(null),

    /// The version last pushed to a language server. It lives on the
    /// DOCUMENT rather than on a view because the server has one copy:
    /// two panes showing one file must not each sync it, and the one
    /// that syncs must not depend on which pane you typed in.
    lsp_version: u64 = std.math.maxInt(u64),

    /// The version a formatting request was made against. The reply's
    /// offsets are measured against THAT text, so applying them to any
    /// other version garbles the file. Comparing against lsp_version
    /// instead would not do: a keystroke plus one debounced didChange
    /// during the round trip makes version == lsp_version again while
    /// the reply still describes the old text. On the DOCUMENT for the
    /// same reason lsp_version is — the reply may land on a different
    /// pane than the one that asked.
    fmt_req_version: u64 = std.math.maxInt(u64),

    /// Edits are numbered, and the number rides along through undo and
    /// redo. The number on top of the undo stack therefore identifies
    /// the buffer's CONTENT STATE rather than how much has happened to
    /// it — which is what lets `u` all the way back to the last write
    /// report the file as unmodified again.
    seq_next: u64 = 1,
    /// The state last written. 0 is the empty stack: how a buffer
    /// starts, and where a full undo of everything lands.
    saved_seq: u64 = 0,

    undo_stack: std.ArrayListUnmanaged(Edit) = .empty,
    redo_stack: std.ArrayListUnmanaged(Edit) = .empty,
    /// Edits sharing a group id undo as one `u`. Bump via newUndoGroup
    /// at command boundaries (entering insert mode, each discrete
    /// normal-mode edit); everything typed inside shares the group.
    group: u32 = 0,

    /// This buffer's content is a VIEW of something else, so editing it
    /// could only ever produce a lie. A diff document is the first case:
    /// its text is computed from two sides, its gutter numbers belong to
    /// a file the buffer does not contain, and half its rows are lines
    /// that were deleted.
    ///
    /// Enforced here rather than at the keymap, and that is the point.
    /// The editor mutates through forty-nine call sites and every one of
    /// them lands on applyEdit; a guard on the keys would have to
    /// enumerate every command that edits, and the one it missed would
    /// corrupt the document silently.
    readonly: bool = false,

    /// Set when an edit was declined, cleared by whoever reports it. The
    /// buffer cannot show a message and the editor cannot see every
    /// refusal, so the flag is the seam between them — otherwise a
    /// read-only buffer swallows keystrokes and looks broken rather than
    /// protected.
    refused: bool = false,

    /// One reversible edit: bytes `deleted` were replaced by
    /// `inserted_len` bytes at `off`.
    const Edit = struct {
        off: usize,
        inserted_len: usize,
        deleted: []u8, // owned
        group: u32,
        /// Identity of the state this edit PRODUCED. Preserved when the
        /// edit moves between the two stacks, so a state you return to
        /// is recognisably the same state.
        seq: u64,
    };

    /// Is the buffer different from what was last written?
    ///
    /// Derived, not stored. A stored flag can only ever be set — no
    /// amount of undo un-sets it — so a buffer undone all the way back
    /// to the last save still claimed to be dirty, `:q` still refused,
    /// and you learned to reach for `:q!` reflexively. A reflex is a
    /// bad thing to teach someone whose next guard is `:w!`.
    pub fn isModified(self: *const Buffer) bool {
        return self.stateSeq() != self.saved_seq;
    }

    /// Declare the current state written. For `save`, and for the
    /// projected buffers that save through the app instead of to a file.
    pub fn markSaved(self: *Buffer) void {
        self.saved_seq = self.stateSeq();
    }

    fn stateSeq(self: *const Buffer) u64 {
        const top = self.undo_stack.getLastOrNull() orelse return 0;
        return top.seq;
    }

    /// Where the file stands relative to what we loaded or last wrote.
    ///
    /// `gone` is its own state and not a kind of `changed`, because the
    /// two demand opposite reactions: a changed file can be reloaded,
    /// but reloading a deleted one replaces the pane's contents with an
    /// empty buffer and nulls the disk claim — after which a `:w`
    /// resurrects, without so much as a warning, a file somebody
    /// deliberately removed. That was a shipped bug, not a hypothesis.
    pub const OnDisk = enum { same, changed, gone };

    /// One stat, cheap enough to ask on a timer. `same` whenever we
    /// hold no claim (a scratch or projected buffer, or a path that did
    /// not exist when it was opened) — the same fail-open rule `save`
    /// uses, so the two can never disagree about whose file this is.
    pub fn onDisk(self: *const Buffer, io: std.Io) OnDisk {
        const known = self.disk orelse return .same;
        const p = self.path orelse return .same;
        const st = std.Io.Dir.cwd().statFile(io, p, .{}) catch |err| {
            // Any stat failure OTHER than absence is indistinguishable
            // from change, and treated as one.
            return if (err == error.FileNotFound) .gone else .changed;
        };
        return if (known.matches(st)) .same else .changed;
    }

    /// Start telling `ctx` about edits. Idempotent: a view that
    /// re-attaches to a document it already watches must not be told
    /// twice, or every mark it holds moves double.
    pub fn watch(self: *Buffer, ctx: *anyopaque, cb: EditFn) void {
        for (&self.watchers) |*w| {
            if (w.*) |have| {
                if (have.ctx == ctx) return;
            }
        }
        for (&self.watchers) |*w| {
            if (w.* == null) {
                w.* = .{ .ctx = ctx, .cb = cb };
                return;
            }
        }
    }

    pub fn unwatch(self: *Buffer, ctx: *anyopaque) void {
        for (&self.watchers) |*w| {
            if (w.*) |have| {
                if (have.ctx == ctx) w.* = null;
            }
        }
    }

    /// Every watcher, in slot order. Order is not a contract — a
    /// watcher that cared which other watcher went first would be
    /// depending on how panes happened to be opened.
    fn notifyEdit(self: *Buffer, start: usize, removed: usize, added: usize) void {
        for (self.watchers) |w| {
            if (w) |have| have.cb(have.ctx, start, removed, added);
        }
    }

    /// Become `fresh`, in place, keeping this document's identity.
    ///
    /// For reload: the document may be on screen in several panes, and
    /// swapping the POINTER would leave the others holding a buffer
    /// nothing writes to any more. Watchers, and the undo history, are
    /// deliberately not carried over — the text they described is gone.
    /// A wholesale replacement: every recorded edit is meaningless
    /// against the new text, so the next parse starts over.
    pub fn replaceContents(self: *Buffer, gpa: Allocator, fresh: Buffer) void {
        const keep = self.watchers;
        var old = self.*;
        old.watchers = @splat(null);
        self.* = fresh;
        self.watchers = keep;
        // A version that only ever grows: a view comparing versions to
        // decide whether to re-clamp must not be fooled by a reload
        // resetting the count.
        self.version = old.version + 1;
        // Every recorded edit described the text that just left. Any
        // parser holding a tree of ANY older version — including one in
        // a pane that is not the one reloading — must start over.
        self.edits_floor = self.version;
        old.deinit(gpa);
    }

    pub fn initEmpty(gpa: Allocator) Allocator.Error!Buffer {
        return .{ .rope = try .init(gpa, "") };
    }

    pub fn initFromFile(gpa: Allocator, io: std.Io, abs_path: []const u8) !Buffer {
        // Stat BEFORE the read, and the order is the whole point. A
        // write landing between the two calls is either recorded as
        // newer than the bytes we hold (stat last — `save` then
        // overwrites it without a word) or older (stat first — `save`
        // refuses over content that was in fact current). Only the
        // second failure is survivable; it costs a `:w!`.
        const before: ?DiskState = if (std.Io.Dir.cwd().statFile(io, abs_path, .{})) |st| .of(st) else |_| null;
        const data: []u8 = std.Io.Dir.cwd().readFileAlloc(io, abs_path, gpa, .limited(1 << 30)) catch |err| switch (err) {
            error.FileNotFound => try gpa.alloc(u8, 0), // new file: empty buffer, path set
            else => return err,
        };
        defer gpa.free(data);
        var b: Buffer = .{ .rope = try .init(gpa, data) };
        errdefer b.rope.deinit(gpa);
        b.path = try gpa.dupe(u8, abs_path);
        b.disk = before;
        return b;
    }

    pub fn deinit(self: *Buffer, gpa: Allocator) void {
        self.rope.deinit(gpa);
        if (self.path) |p| gpa.free(p);
        for (self.undo_stack.items) |e| gpa.free(e.deleted);
        self.undo_stack.deinit(gpa);
        for (self.redo_stack.items) |e| gpa.free(e.deleted);
        self.redo_stack.deinit(gpa);
        self.edits.deinit(gpa);
    }

    pub const SaveError = error{
        NoPath,
        /// The file moved under us since we opened or last wrote it.
        /// `force` is the caller's `:w!`.
        ChangedOnDisk,
    } || Allocator.Error || std.Io.Dir.CreateFileAtomicError ||
        std.Io.File.Atomic.ReplaceError || std.Io.Writer.Error;

    /// Write the buffer to its path.
    ///
    /// Three properties, each of which was absent and each of which can
    /// cost somebody a file:
    ///
    /// ATOMIC. The old implementation was `writeFile`, which truncates
    /// in place. A crash, a full disk or a cancelled write halfway
    /// through leaves HALF a file where the source used to be, and the
    /// original is gone. This creates a sibling temp file and renames
    /// over the target, so the path is either the old bytes or the new
    /// ones and never a prefix of either.
    ///
    /// PERMISSIONS SURVIVE. Rename-over installs a NEW inode, so the
    /// mode has to be carried across by hand — otherwise `:w` on a
    /// shell script hands it back non-executable. (Truncate-in-place
    /// got this for free, which is why it was never noticed.)
    ///
    /// SYMLINKS ARE WRITTEN THROUGH, not replaced. Renaming over a link
    /// silently turns it into a regular file, which is how a dotfile
    /// linked into a repo stops tracking the repo.
    pub fn save(self: *Buffer, gpa: Allocator, io: std.Io, force: bool) SaveError!void {
        const p = self.path orelse return error.NoPath;
        const cwd = std.Io.Dir.cwd();

        // Resolve first: everything below acts on the real file, not on
        // the name that points at it.
        var real_buf: [1024]u8 = undefined;
        const target: []const u8 = if (cwd.realPathFile(io, p, &real_buf)) |n| real_buf[0..n] else |_| p;

        const now: ?std.Io.File.Stat = cwd.statFile(io, target, .{}) catch null;
        if (!force) {
            if (self.disk) |known| {
                // Gone counts as changed: the file we claimed no longer
                // exists, so writing would resurrect it with our copy of
                // content somebody deliberately removed.
                const same = if (now) |st| known.matches(st) else false;
                if (!same) return error.ChangedOnDisk;
            }
        }

        const flat = try self.rope.dupeRange(gpa, 0, self.rope.byteLen());
        defer gpa.free(flat);

        var af = try cwd.createFileAtomic(io, target, .{
            .permissions = if (now) |st| st.permissions else .default_file,
            .replace = true,
        });
        // deinit removes the temp file if we never got to `replace`, so
        // a failure leaves the target untouched rather than littering.
        defer af.deinit(io);
        var wbuf: [64 * 1024]u8 = undefined;
        var w = af.file.writer(io, &wbuf);
        try w.interface.writeAll(flat);
        try w.interface.flush();
        try af.replace(io);

        self.markSaved();
        self.disk = if (cwd.statFile(io, target, .{})) |st| .of(st) else |_| null;
    }

    /// `full` means "the log cannot say what changed" — edits that old
    /// have been evicted, or the document was replaced wholesale — and
    /// whoever asked has to reparse from scratch.
    pub const Pending = struct { edits: []const TreeEdit, full: bool };

    /// Every edit after version `v`, oldest first — the slice a parser
    /// whose tree describes version `v` needs to catch up. Sliced, not
    /// drained: each consumer asks with its own version and the log
    /// stays put, which is what lets two panes on one document each
    /// keep an honest tree.
    pub fn editsSince(self: *const Buffer, v: u64) Pending {
        if (v < self.edits_floor) return .{ .edits = &.{}, .full = true };
        const items = self.edits.items;
        var i = items.len;
        while (i > 0 and items[i - 1].version > v) i -= 1;
        return .{ .edits = items[i..], .full = false };
    }

    fn recordEdit(self: *Buffer, gpa: Allocator, start: usize, old_end: usize, new_end: usize, before: PointPair) void {
        if (self.edits.items.len >= max_edits) {
            // FIFO: the oldest edit leaves, and with it the ability to
            // serve any parser still behind it. The floor records what
            // was lost so editsSince can refuse honestly.
            const evicted = self.edits.orderedRemove(0);
            self.edits_floor = evicted.version;
        }
        const ne_row = self.rope.lineOfOffset(new_end);
        self.edits.append(gpa, .{
            .start = @intCast(start),
            .old_end = @intCast(old_end),
            .new_end = @intCast(new_end),
            .start_row = @intCast(before.start_row),
            .start_col = @intCast(before.start_col),
            .old_end_row = @intCast(before.end_row),
            .old_end_col = @intCast(before.end_col),
            .new_end_row = @intCast(ne_row),
            .new_end_col = @intCast(new_end - self.rope.lineStart(ne_row)),
            // The version this edit PRODUCES — the caller bumps right
            // after recording.
            .version = self.version +% 1,
        }) catch {
            // A change that could not be recorded: nobody behind this
            // point can be served any more.
            self.edits.clearRetainingCapacity();
            self.edits_floor = self.version +% 1;
        };
    }

    const PointPair = struct { start_row: usize, start_col: usize, end_row: usize, end_col: usize };

    pub fn newUndoGroup(self: *Buffer) void {
        if (self.group_pinned) return;
        self.group +%= 1;
    }

/// One edit, in the shape tree-sitter's `ts_tree_edit` wants.
///
/// Named TreeEdit and not Edit because the undo stack's own Edit was
/// here first and means something different: that one is reversible
/// history, this one is a hint to a parser.
///
/// Recorded here because this is the only place that knows both the
/// BEFORE and the AFTER of a change — the byte offsets and the
/// row/column points either side of it. Reconstructing that downstream
/// would mean diffing two copies of the document, which is the cost the
/// whole exercise is trying to avoid.
pub const TreeEdit = struct {
    start: u32,
    old_end: u32,
    new_end: u32,
    start_row: u32,
    start_col: u32,
    old_end_row: u32,
    old_end_col: u32,
    new_end_row: u32,
    new_end_col: u32,
    /// The buffer version this edit produced — what editsSince slices
    /// the log by.
    version: u64 = 0,
};

/// Edits the log keeps. Small: parsers ask every frame so they are
/// rarely more than one behind, and anything that overruns this in one
/// gap is a change big enough that a full parse is the honest answer
/// anyway.
pub const max_edits = 64;

    pub fn insert(self: *Buffer, gpa: Allocator, off: usize, text: []const u8) Allocator.Error!void {
        if (text.len == 0) return;
        try self.applyEdit(gpa, off, off, text, true);
    }

    pub fn deleteRange(self: *Buffer, gpa: Allocator, start: usize, end: usize) Allocator.Error!void {
        if (start == end) return;
        try self.applyEdit(gpa, start, end, "", true);
    }

    fn applyEdit(self: *Buffer, gpa: Allocator, start: usize, end: usize, text: []const u8, clear_redo: bool) Allocator.Error!void {
        if (self.readonly) {
            self.refused = true;
            return;
        }
        const deleted = try self.rope.dupeRange(gpa, start, end);
        errdefer gpa.free(deleted);
        try self.undo_stack.append(gpa, .{
            .off = start,
            .inserted_len = text.len,
            .deleted = deleted,
            .group = self.group,
            .seq = self.seq_next,
        });
        self.seq_next += 1;
        // The points BEFORE the rope moves: tree-sitter's edit wants
        // where the change started and where it used to end, in the old
        // document's coordinates.
        const before: PointPair = blk: {
            const sr = self.rope.lineOfOffset(start);
            const er = self.rope.lineOfOffset(end);
            break :blk .{
                .start_row = sr,
                .start_col = start - self.rope.lineStart(sr),
                .end_row = er,
                .end_col = end - self.rope.lineStart(er),
            };
        };
        try self.rope.delete(gpa, start, end);
        try self.rope.insert(gpa, start, text);
        self.recordEdit(gpa, start, end, start + text.len, before);
        self.version +%= 1;
        self.notifyEdit(start, end - start, text.len);
        if (clear_redo) {
            for (self.redo_stack.items) |e| gpa.free(e.deleted);
            self.redo_stack.clearRetainingCapacity();
        }
    }

    /// Undo the newest group. Returns the offset of the last reverted
    /// edit (cursor target), or null if nothing to undo.
    pub fn undo(self: *Buffer, gpa: Allocator) Allocator.Error!?usize {
        return self.rewind(gpa, &self.undo_stack, &self.redo_stack);
    }

    pub fn redo(self: *Buffer, gpa: Allocator) Allocator.Error!?usize {
        return self.rewind(gpa, &self.redo_stack, &self.undo_stack);
    }

    fn rewind(
        self: *Buffer,
        gpa: Allocator,
        from: *std.ArrayListUnmanaged(Edit),
        to: *std.ArrayListUnmanaged(Edit),
    ) Allocator.Error!?usize {
        const last = from.getLastOrNull() orelse return null;
        const g = last.group;
        var target: usize = last.off;
        while (from.getLastOrNull()) |e| {
            if (e.group != g) break;
            _ = from.pop();
            // Invert: remove what was inserted, restore what was deleted.
            const inv_deleted = try self.rope.dupeRange(gpa, e.off, e.off + e.inserted_len);
            errdefer gpa.free(inv_deleted);
            try to.append(gpa, .{
                .off = e.off,
                .inserted_len = e.deleted.len,
                .deleted = inv_deleted,
                .group = g,
                // Carried, not re-issued: an edit that comes back to
                // the undo stack restores the state it first produced.
                .seq = e.seq,
            });
            // The points BEFORE the rope moves, exactly as applyEdit
            // takes them. An undo is an edit as far as a parser is
            // concerned — skipping the record here meant a tree kept
            // incrementally was silently wrong from the first `u`.
            const before: PointPair = blk: {
                const sr = self.rope.lineOfOffset(e.off);
                const er = self.rope.lineOfOffset(e.off + e.inserted_len);
                break :blk .{
                    .start_row = sr,
                    .start_col = e.off - self.rope.lineStart(sr),
                    .end_row = er,
                    .end_col = e.off + e.inserted_len - self.rope.lineStart(er),
                };
            };
            try self.rope.delete(gpa, e.off, e.off + e.inserted_len);
            try self.rope.insert(gpa, e.off, e.deleted);
            self.recordEdit(gpa, e.off, e.off + e.inserted_len, e.off + e.deleted.len, before);
            self.notifyEdit(e.off, e.inserted_len, e.deleted.len);
            target = e.off;
            gpa.free(e.deleted);
            self.version +%= 1;
        }
        return target;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn contents(gpa: Allocator, b: *Buffer) ![]u8 {
    return b.rope.dupeRange(gpa, 0, b.rope.byteLen());
}

test "buffer edit and grouped undo/redo" {
    const gpa = testing.allocator;
    var b = try Buffer.initEmpty(gpa);
    defer b.deinit(gpa);

    b.newUndoGroup();
    try b.insert(gpa, 0, "hello world");
    b.newUndoGroup();
    try b.deleteRange(gpa, 5, 11);
    try b.insert(gpa, 5, "!");

    var s = try contents(gpa, &b);
    try testing.expectEqualStrings("hello!", s);
    gpa.free(s);

    // One undo reverts BOTH edits of the second group.
    _ = try b.undo(gpa);
    s = try contents(gpa, &b);
    try testing.expectEqualStrings("hello world", s);
    gpa.free(s);

    _ = try b.undo(gpa);
    s = try contents(gpa, &b);
    try testing.expectEqualStrings("", s);
    gpa.free(s);

    try testing.expectEqual(@as(?usize, null), try b.undo(gpa));

    _ = try b.redo(gpa);
    _ = try b.redo(gpa);
    s = try contents(gpa, &b);
    try testing.expectEqualStrings("hello!", s);
    gpa.free(s);

    // New edit clears redo.
    b.newUndoGroup();
    try b.insert(gpa, 0, "x");
    try testing.expectEqual(@as(?usize, null), try b.redo(gpa));
}

test "buffer save/load round trip" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathbuf: [128]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&pathbuf, ".zig-cache/tmp/{s}/t.txt", .{tmp.sub_path});

    var b = try Buffer.initFromFile(gpa, io, file_path); // missing → empty
    try testing.expectEqual(@as(usize, 0), b.rope.byteLen());
    try b.insert(gpa, 0, "one\ntwo\n");
    try b.save(gpa, io, false);
    try testing.expect(!b.isModified());
    b.deinit(gpa);

    var b2 = try Buffer.initFromFile(gpa, io, file_path);
    defer b2.deinit(gpa);
    const s = try contents(gpa, &b2);
    defer gpa.free(s);
    try testing.expectEqualStrings("one\ntwo\n", s);
}

test "undoing back to the save point clears modified" {
    // The bug this replaces: `modified` was a flag, and a flag can only
    // ever be set. `u` all the way back to what you saved still refused
    // `:q`, which teaches the `:q!` reflex — a bad habit to build in
    // someone whose next guard is `:w!`.
    const gpa = testing.allocator;
    var b = try Buffer.initEmpty(gpa);
    defer b.deinit(gpa);

    try testing.expect(!b.isModified()); // fresh
    b.newUndoGroup();
    try b.insert(gpa, 0, "hello");
    try testing.expect(b.isModified());

    b.markSaved();
    try testing.expect(!b.isModified());

    b.newUndoGroup();
    try b.insert(gpa, 5, " world");
    try testing.expect(b.isModified());

    _ = try b.undo(gpa);
    try testing.expect(!b.isModified()); // back AT the save point

    _ = try b.redo(gpa);
    try testing.expect(b.isModified()); // and away from it again
}

test "undoing PAST the save point is still modified" {
    // Symmetry the flag could never express: the file on disk holds
    // "hello", and an empty buffer differs from it just as much as a
    // longer one does.
    const gpa = testing.allocator;
    var b = try Buffer.initEmpty(gpa);
    defer b.deinit(gpa);

    b.newUndoGroup();
    try b.insert(gpa, 0, "hello");
    b.markSaved();

    _ = try b.undo(gpa);
    try testing.expect(b.isModified());
}

test "a new edit after undo cannot reach the save point again" {
    // Redo is discarded, so the saved state is unreachable and the
    // buffer must keep saying so rather than matching by accident.
    const gpa = testing.allocator;
    var b = try Buffer.initEmpty(gpa);
    defer b.deinit(gpa);

    b.newUndoGroup();
    try b.insert(gpa, 0, "one");
    b.newUndoGroup();
    try b.insert(gpa, 3, "two");
    b.markSaved(); // saved "onetwo"

    _ = try b.undo(gpa); // back to "one"
    b.newUndoGroup();
    try b.insert(gpa, 3, "three"); // clears redo; "onetwo" is gone
    try testing.expect(b.isModified());
    _ = try b.undo(gpa);
    try testing.expect(b.isModified());
}

test "a whole insert-mode group is one step away from saved" {
    // Everything typed between two newUndoGroup calls shares a group,
    // so one `u` returns to the save point — not one `u` per keystroke.
    const gpa = testing.allocator;
    var b = try Buffer.initEmpty(gpa);
    defer b.deinit(gpa);

    b.newUndoGroup();
    try b.insert(gpa, 0, "saved\n");
    b.markSaved();

    b.newUndoGroup(); // enterInsert
    for ("typing") |c| try b.insert(gpa, b.rope.byteLen(), &[_]u8{c});
    try testing.expect(b.isModified());

    _ = try b.undo(gpa);
    try testing.expect(!b.isModified());
}

/// Every save test needs the same three lines.
fn tmpPath(buf: []u8, sub: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/{s}", .{ sub, name });
}

test "save preserves the file's permissions" {
    // Rename-over installs a NEW inode, so the mode does not come along
    // by itself. `:w` on a shell script must not hand it back
    // non-executable.
    const gpa = testing.allocator;
    const io = testing.io;
    const cwd = std.Io.Dir.cwd();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathbuf: [128]u8 = undefined;
    const p = try tmpPath(&pathbuf, &tmp.sub_path, "script.sh");

    try cwd.writeFile(io, .{ .sub_path = p, .data = "#!/bin/sh\n" });
    try cwd.setFilePermissions(io, p, .fromMode(0o755), .{});

    var b = try Buffer.initFromFile(gpa, io, p);
    defer b.deinit(gpa);
    try b.insert(gpa, b.rope.byteLen(), "echo hi\n");
    try b.save(gpa, io, false);

    const st = try cwd.statFile(io, p, .{});
    try testing.expectEqual(@as(u32, 0o755), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
}

test "save writes THROUGH a symlink instead of replacing it" {
    // A dotfile linked into a repo stops tracking the repo the moment a
    // save turns the link into a regular file.
    const gpa = testing.allocator;
    const io = testing.io;
    const cwd = std.Io.Dir.cwd();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [128]u8 = undefined;
    var link_buf: [128]u8 = undefined;
    const real = try tmpPath(&real_buf, &tmp.sub_path, "real.txt");
    const link = try tmpPath(&link_buf, &tmp.sub_path, "link.txt");

    try cwd.writeFile(io, .{ .sub_path = real, .data = "before\n" });
    try tmp.dir.symLink(io, "real.txt", "link.txt", .{});

    var b = try Buffer.initFromFile(gpa, io, link);
    defer b.deinit(gpa);
    try b.deleteRange(gpa, 0, b.rope.byteLen());
    try b.insert(gpa, 0, "after\n");
    try b.save(gpa, io, false);

    // The link is still a link...
    const lst = try cwd.statFile(io, link, .{ .follow_symlinks = false });
    try testing.expectEqual(std.Io.File.Kind.sym_link, lst.kind);
    // ...and the write landed on its target.
    var read_buf: [64]u8 = undefined;
    const got = try cwd.readFile(io, real, &read_buf);
    try testing.expectEqualStrings("after\n", got);
}

test "save refuses to clobber a file that changed underneath it" {
    // The agent-workspace case: something else edited the file while it
    // was open. Saving over it without a word is the one outcome that
    // destroys work nobody can get back.
    const gpa = testing.allocator;
    const io = testing.io;
    const cwd = std.Io.Dir.cwd();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathbuf: [128]u8 = undefined;
    const p = try tmpPath(&pathbuf, &tmp.sub_path, "shared.txt");

    try cwd.writeFile(io, .{ .sub_path = p, .data = "mine\n" });
    var b = try Buffer.initFromFile(gpa, io, p);
    defer b.deinit(gpa);
    try b.insert(gpa, 0, "edited ");

    try cwd.writeFile(io, .{ .sub_path = p, .data = "theirs, and longer\n" });
    try testing.expectError(error.ChangedOnDisk, b.save(gpa, io, false));

    // Refusing means refusing: their bytes are untouched.
    var read_buf: [64]u8 = undefined;
    try testing.expectEqualStrings("theirs, and longer\n", try cwd.readFile(io, p, &read_buf));

    // `:w!` is the way through, and it re-establishes the claim so the
    // NEXT save is not refused for a conflict already resolved.
    try b.save(gpa, io, true);
    try testing.expectEqualStrings("edited mine\n", try cwd.readFile(io, p, &read_buf));
    try b.insert(gpa, 0, "again ");
    try b.save(gpa, io, false);
}

test "a file deleted underneath us counts as changed" {
    // Writing would resurrect content somebody deliberately removed.
    const gpa = testing.allocator;
    const io = testing.io;
    const cwd = std.Io.Dir.cwd();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathbuf: [128]u8 = undefined;
    const p = try tmpPath(&pathbuf, &tmp.sub_path, "doomed.txt");

    try cwd.writeFile(io, .{ .sub_path = p, .data = "here\n" });
    var b = try Buffer.initFromFile(gpa, io, p);
    defer b.deinit(gpa);
    try b.insert(gpa, 0, "x");
    try cwd.deleteFile(io, p);
    try testing.expectError(error.ChangedOnDisk, b.save(gpa, io, false));
    try b.save(gpa, io, true);
}

test "a deleted file reads as gone, never as changed" {
    // The poll must be able to tell the two apart: `changed` is
    // reloadable, `gone` must NOT be — reloading what is not there
    // empties the pane and drops the disk claim, after which `:w`
    // quietly resurrects a file somebody deliberately removed.
    const gpa = testing.allocator;
    const io = testing.io;
    const cwd = std.Io.Dir.cwd();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathbuf: [128]u8 = undefined;
    const p = try tmpPath(&pathbuf, &tmp.sub_path, "vanishing.txt");

    try cwd.writeFile(io, .{ .sub_path = p, .data = "here\n" });
    var b = try Buffer.initFromFile(gpa, io, p);
    defer b.deinit(gpa);
    try testing.expectEqual(Buffer.OnDisk.same, b.onDisk(io));

    try cwd.deleteFile(io, p);
    try testing.expectEqual(Buffer.OnDisk.gone, b.onDisk(io));
    // Unmodified or not, the write still guards: recreating the file
    // must be `:w!`, a choice.
    try testing.expectError(error.ChangedOnDisk, b.save(gpa, io, false));

    // The file coming back (a branch switched home) is a new identity:
    // that IS `changed`, and the poll may reload it.
    try cwd.writeFile(io, .{ .sub_path = p, .data = "back\n" });
    try testing.expectEqual(Buffer.OnDisk.changed, b.onDisk(io));
}

test "a file that did not exist when we opened it is not claimed" {
    // No claim, no refusal: `:e newfile` then `:w` must just work.
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var pathbuf: [128]u8 = undefined;
    const p = try tmpPath(&pathbuf, &tmp.sub_path, "brand-new.txt");

    var b = try Buffer.initFromFile(gpa, io, p);
    defer b.deinit(gpa);
    try testing.expectEqual(@as(?DiskState, null), b.disk);
    try b.insert(gpa, 0, "hello\n");
    try b.save(gpa, io, false);
    try testing.expect(b.disk != null);
}

test "recorded tree edits describe exactly what changed" {
    // The bookkeeping tree-sitter's incremental parse stands on. If
    // these offsets or points are wrong the parser reuses subtrees that
    // no longer belong where it puts them, and the result is not a
    // crash — it is highlighting that is subtly, permanently wrong.
    const gpa = testing.allocator;
    var b = try Buffer.initEmpty(gpa);
    defer b.deinit(gpa);
    var v = b.version; // the parse-cursor a consumer would hold

    try b.insert(gpa, 0, "const a = 1;\nconst b = 2;\n");
    {
        const rec = b.editsSince(v);
        try testing.expect(!rec.full);
        try testing.expectEqual(@as(usize, 1), rec.edits.len);
        const e = rec.edits[0];
        try testing.expectEqual(@as(u32, 0), e.start);
        try testing.expectEqual(@as(u32, 0), e.old_end); // an insert removes nothing
        try testing.expectEqual(@as(u32, 26), e.new_end);
        try testing.expectEqual(@as(u32, 0), e.start_row);
        try testing.expectEqual(@as(u32, 0), e.old_end_row);
        // Two newlines went in, so the end point moved down two rows and
        // back to column zero. Getting this wrong is the classic way to
        // corrupt an incremental parse.
        try testing.expectEqual(@as(u32, 2), e.new_end_row);
        try testing.expectEqual(@as(u32, 0), e.new_end_col);
    }
    v = b.version;

    // A delete spanning a line break: the OLD end is two rows on, the
    // new end is where the cut lands.
    try b.deleteRange(gpa, 10, 20);
    {
        const rec = b.editsSince(v);
        try testing.expectEqual(@as(usize, 1), rec.edits.len);
        const e = rec.edits[0];
        try testing.expectEqual(@as(u32, 10), e.start);
        try testing.expectEqual(@as(u32, 20), e.old_end);
        try testing.expectEqual(@as(u32, 10), e.new_end);
        try testing.expectEqual(@as(u32, 0), e.start_row);
        try testing.expectEqual(@as(u32, 10), e.start_col);
        try testing.expectEqual(@as(u32, 1), e.old_end_row);
        try testing.expectEqual(@as(u32, 7), e.old_end_col);
        try testing.expectEqual(@as(u32, 0), e.new_end_row);
        try testing.expectEqual(@as(u32, 10), e.new_end_col);
    }
    v = b.version;

    // Applying the recorded edits to the old text must produce the new
    // text. This is the property the parser actually depends on, and it
    // is checkable without a grammar anywhere in sight.
    const before = try b.rope.dupeRange(gpa, 0, b.rope.byteLen());
    defer gpa.free(before);
    try b.insert(gpa, 5, "XY");
    const rec = b.editsSince(v);
    const e = rec.edits[0];
    const after = try b.rope.dupeRange(gpa, 0, b.rope.byteLen());
    defer gpa.free(after);
    try testing.expectEqualStrings(before[0..e.start], after[0..e.start]);
    try testing.expectEqualStrings(before[e.old_end..], after[e.new_end..]);
}

test "too many edits at once fall back to a full parse" {
    const gpa = testing.allocator;
    var b = try Buffer.initEmpty(gpa);
    defer b.deinit(gpa);
    const v = b.version;
    // A macro, a :g, a rename landing across a file. Past the cap the
    // honest answer is to reparse from scratch rather than to keep a
    // partial list that describes some of what happened.
    for (0..Buffer.max_edits + 5) |_| try b.insert(gpa, 0, "x");
    const rec = b.editsSince(v);
    try testing.expect(rec.full);
    try testing.expectEqual(@as(usize, 0), rec.edits.len);
    // A parser that kept up through the burst is still served: the log
    // holds the newest max_edits, and only whoever fell behind the
    // eviction floor is sent back to a full parse.
    const caught_up = b.editsSince(b.version -| 3);
    try testing.expect(!caught_up.full);
    try testing.expectEqual(@as(usize, 3), caught_up.edits.len);
}

test "replacing the document invalidates the edit record" {
    const gpa = testing.allocator;
    var b = try Buffer.initEmpty(gpa);
    defer b.deinit(gpa);
    const v0 = b.version;
    try b.insert(gpa, 0, "hello");
    try testing.expect(!b.editsSince(v0).full);
    const parsed_at = b.version;
    // A reload: every recorded offset refers to a document that is gone
    // — including for a parser that was fully caught up.
    const fresh = try Buffer.initEmpty(gpa);
    b.replaceContents(gpa, fresh);
    try testing.expect(b.editsSince(v0).full);
    try testing.expect(b.editsSince(parsed_at).full);
}

test "two parsers each get their own slice of the edit log" {
    // The two-panes-one-file bug: the old drain-once API let pane A's
    // parse eat the edits pane B needed, and pane B then fed
    // tree-sitter a stale tree as if it were current. Each consumer
    // must be able to ask for exactly its delta, in either order,
    // without taking anything from the other.
    const gpa = testing.allocator;
    var b = try Buffer.initEmpty(gpa);
    defer b.deinit(gpa);

    try b.insert(gpa, 0, "one\n");
    const pane_a = b.version; // A parses here
    try b.insert(gpa, 4, "two\n");
    const pane_b = b.version; // B parses here
    try b.insert(gpa, 8, "three\n");

    const ra = b.editsSince(pane_a);
    try testing.expect(!ra.full);
    try testing.expectEqual(@as(usize, 2), ra.edits.len);

    const rb = b.editsSince(pane_b);
    try testing.expect(!rb.full);
    try testing.expectEqual(@as(usize, 1), rb.edits.len);

    // Asking is not draining: the same questions answer the same way.
    try testing.expectEqual(@as(usize, 2), b.editsSince(pane_a).edits.len);
    try testing.expectEqual(@as(usize, 1), b.editsSince(pane_b).edits.len);
}

test "undo and redo are edits as far as a parser is concerned" {
    const gpa = testing.allocator;
    var b = try Buffer.initEmpty(gpa);
    defer b.deinit(gpa);

    b.newUndoGroup();
    try b.insert(gpa, 0, "hello world");
    const v = b.version;

    _ = try b.undo(gpa);
    {
        // The undo must be in the log — a version bump with no
        // recorded edit is exactly the stale-tree corruption the log
        // exists to prevent.
        const rec = b.editsSince(v);
        try testing.expect(!rec.full);
        try testing.expectEqual(@as(usize, 1), rec.edits.len);
        const e = rec.edits[0];
        try testing.expectEqual(@as(u32, 0), e.start);
        try testing.expectEqual(@as(u32, 11), e.old_end); // the insert leaves
        try testing.expectEqual(@as(u32, 0), e.new_end);
    }

    _ = try b.redo(gpa);
    {
        const rec = b.editsSince(v);
        try testing.expectEqual(@as(usize, 2), rec.edits.len);
        const e = rec.edits[1];
        try testing.expectEqual(@as(u32, 0), e.start);
        try testing.expectEqual(@as(u32, 0), e.old_end);
        try testing.expectEqual(@as(u32, 11), e.new_end); // and comes back
    }
}
