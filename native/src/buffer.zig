//! Buffer — a document (the rook-buffers model: a file is a document,
//! not a window). Rope storage + path identity + grouped undo. All
//! mutation goes through insert/deleteRange so undo never desyncs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ropepkg = @import("rope.zig");

pub const Buffer = struct {
    rope: ropepkg.Rope,
    /// Absolute path, owned; null = scratch.
    path: ?[]u8 = null,
    modified: bool = false,

    /// Bumped by every content mutation (edits, undo, redo) — the
    /// highlighter's reparse trigger.
    version: u64 = 0,

    undo_stack: std.ArrayListUnmanaged(Edit) = .empty,
    redo_stack: std.ArrayListUnmanaged(Edit) = .empty,
    /// Edits sharing a group id undo as one `u`. Bump via newUndoGroup
    /// at command boundaries (entering insert mode, each discrete
    /// normal-mode edit); everything typed inside shares the group.
    group: u32 = 0,

    /// One reversible edit: bytes `deleted` were replaced by
    /// `inserted_len` bytes at `off`.
    const Edit = struct {
        off: usize,
        inserted_len: usize,
        deleted: []u8, // owned
        group: u32,
    };

    pub fn initEmpty(gpa: Allocator) Allocator.Error!Buffer {
        return .{ .rope = try .init(gpa, "") };
    }

    pub fn initFromFile(gpa: Allocator, io: std.Io, abs_path: []const u8) !Buffer {
        const data: []u8 = std.Io.Dir.cwd().readFileAlloc(io, abs_path, gpa, .limited(1 << 30)) catch |err| switch (err) {
            error.FileNotFound => try gpa.alloc(u8, 0), // new file: empty buffer, path set
            else => return err,
        };
        defer gpa.free(data);
        var b: Buffer = .{ .rope = try .init(gpa, data) };
        errdefer b.rope.deinit(gpa);
        b.path = try gpa.dupe(u8, abs_path);
        return b;
    }

    pub fn deinit(self: *Buffer, gpa: Allocator) void {
        self.rope.deinit(gpa);
        if (self.path) |p| gpa.free(p);
        for (self.undo_stack.items) |e| gpa.free(e.deleted);
        self.undo_stack.deinit(gpa);
        for (self.redo_stack.items) |e| gpa.free(e.deleted);
        self.redo_stack.deinit(gpa);
    }

    pub fn save(self: *Buffer, gpa: Allocator, io: std.Io) !void {
        const p = self.path orelse return error.NoPath;
        const flat = try self.rope.dupeRange(gpa, 0, self.rope.byteLen());
        defer gpa.free(flat);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = flat });
        self.modified = false;
    }

    pub fn newUndoGroup(self: *Buffer) void {
        self.group +%= 1;
    }

    pub fn insert(self: *Buffer, gpa: Allocator, off: usize, text: []const u8) Allocator.Error!void {
        if (text.len == 0) return;
        try self.applyEdit(gpa, off, off, text, true);
    }

    pub fn deleteRange(self: *Buffer, gpa: Allocator, start: usize, end: usize) Allocator.Error!void {
        if (start == end) return;
        try self.applyEdit(gpa, start, end, "", true);
    }

    fn applyEdit(self: *Buffer, gpa: Allocator, start: usize, end: usize, text: []const u8, clear_redo: bool) Allocator.Error!void {
        const deleted = try self.rope.dupeRange(gpa, start, end);
        errdefer gpa.free(deleted);
        try self.undo_stack.append(gpa, .{
            .off = start,
            .inserted_len = text.len,
            .deleted = deleted,
            .group = self.group,
        });
        try self.rope.delete(gpa, start, end);
        try self.rope.insert(gpa, start, text);
        self.modified = true;
        self.version +%= 1;
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
            });
            try self.rope.delete(gpa, e.off, e.off + e.inserted_len);
            try self.rope.insert(gpa, e.off, e.deleted);
            target = e.off;
            gpa.free(e.deleted);
            self.modified = true;
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
    try b.save(gpa, io);
    try testing.expect(!b.modified);
    b.deinit(gpa);

    var b2 = try Buffer.initFromFile(gpa, io, file_path);
    defer b2.deinit(gpa);
    const s = try contents(gpa, &b2);
    defer gpa.free(s);
    try testing.expectEqualStrings("one\ntwo\n", s);
}
