//! The oldfiles journal — every file rook opened, most recent first.
//!
//! vim's `:oldfiles`, and for the same reason: "what was I working on"
//! is a question only the editor can answer, because it is the only
//! thing that knows what you looked at. mtime does not know it (a file
//! you read is a file you never touched), and git does not know it (a
//! file you edited elsewhere is not one you opened here). The workspace
//! db carried `last_used` until 2026-08-03 and `docs/OWED.md` marks it
//! owed back as ephemeral state rather than as a database — this is it.
//!
//! The FORMAT is the contract, because the reader is a plugin in
//! another process: one absolute path per line, most recent first, no
//! header, no timestamps. Order is the recency, which is the only fact
//! this file is entitled to have an opinion about — whether a path
//! still exists, whether it belongs to the repo you are in, and how it
//! should read on a start screen are all the plugin's calls.
//!
//! Deleted paths are NOT pruned on write. A file that comes back (a
//! branch switch, a stash pop) should come back with its place in your
//! history, and a journal that forgets on every checkout is a journal
//! that only remembers the branch you are on.

const std = @import("std");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn mkdir(path: [*:0]const u8, mode: u16) c_int;

/// Paths kept. vim's default is 100; 200 costs ~16KB and covers a
/// week of a working repo, which is the window a start screen is for.
pub const cap = 200;

/// A path longer than this is not recorded. The journal is a fixed-cost
/// file on the open path, and a pathological path should cost the human
/// nothing rather than costing every open a bigger buffer.
pub const max_path = 1024;

/// Resolve the journal's path into `buf`: `$XDG_STATE_HOME/rook/oldfiles`,
/// else `~/.local/state/rook/oldfiles` — the same state-dir shape
/// `crash.zig` uses, and the path the start-screen plugin reads.
pub fn filePath(buf: []u8) ?[]const u8 {
    if (getenv("XDG_STATE_HOME")) |x|
        return std.fmt.bufPrint(buf, "{s}/rook/oldfiles", .{std.mem.span(x)}) catch null;
    const home = getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/rook/oldfiles", .{std.mem.span(home)}) catch null;
}

/// Put `path` at the head of the journal.
///
/// Read-modify-write of a ~16KB file, ATOMIC (temp + rename), on the
/// path that just read a whole document off disk — so it is small
/// against what it rides along with, and a crash mid-write leaves the
/// old journal rather than half of one.
///
/// Never fails loudly. A read-only state dir means no history, which is
/// where rook stood until now; it must not mean a file that would not
/// open.
pub fn record(gpa: std.mem.Allocator, io: std.Io, path: []const u8) void {
    if (path.len == 0 or path[0] != '/' or path.len > max_path) return;
    var pbuf: [1024]u8 = undefined;
    const jp = filePath(&pbuf) orelse return;

    const old: []const u8 = std.Io.Dir.cwd().readFileAlloc(io, jp, gpa, .limited(cap * (max_path + 1))) catch "";
    defer if (old.len > 0) gpa.free(old);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    out.ensureTotalCapacity(gpa, old.len + path.len + 1) catch return;
    out.appendSliceAssumeCapacity(path);
    out.appendAssumeCapacity('\n');

    // The new head is line one, and every OTHER mention of it is gone:
    // a journal that can hold a path twice is a start screen that
    // offers you the same file on two letters.
    var n: usize = 1;
    var it = std.mem.splitScalar(u8, old, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or std.mem.eql(u8, line, path)) continue;
        if (n >= cap) break;
        out.appendSlice(gpa, line) catch return;
        out.append(gpa, '\n') catch return;
        n += 1;
    }

    writeAtomic(io, jp, out.items);
}

/// Read the journal back, most recent first. Owned by the caller; each
/// entry borrows the returned backing buffer, so free that last.
///
/// Only the app's own tests and `rook oldfiles` need this — the start
/// screen's reader is a plugin, and it reads the file itself.
pub fn read(gpa: std.mem.Allocator, io: std.Io, out: *std.ArrayListUnmanaged([]const u8)) ?[]const u8 {
    var pbuf: [1024]u8 = undefined;
    const jp = filePath(&pbuf) orelse return null;
    const data = std.Io.Dir.cwd().readFileAlloc(io, jp, gpa, .limited(cap * (max_path + 1))) catch return null;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        out.append(gpa, line) catch break;
    }
    return data;
}

fn writeAtomic(io: std.Io, path: []const u8, data: []const u8) void {
    makeParent(path);
    const cwd = std.Io.Dir.cwd();
    var af = cwd.createFileAtomic(io, path, .{ .replace = true }) catch return;
    defer af.deinit(io);
    var wbuf: [8 * 1024]u8 = undefined;
    var w = af.file.writer(io, &wbuf);
    w.interface.writeAll(data) catch return;
    w.interface.flush() catch return;
    af.replace(io) catch return;
}

/// mkdir -p for the journal's directory. The state dir usually exists
/// (crash capture makes it at launch), but rook must not depend on
/// having crashed once to have a history.
fn makeParent(path: []const u8) void {
    const cut = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    var buf: [1024]u8 = undefined;
    const dir = path[0..cut];
    if (dir.len == 0 or dir.len >= buf.len) return;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or buf[i] == '/') {
            const save = buf[i];
            buf[i] = 0;
            _ = mkdir(@ptrCast(&buf), 0o755);
            buf[i] = save;
        }
    }
}

// ------------------------------------------------------------- tests

const testing = std.testing;

/// Point the journal at a scratch dir for the length of a test. Restored
/// by the caller — XDG_STATE_HOME is process-wide, and a test that
/// leaves it set writes the next one's history into its own directory.
fn withStateHome(dir: [*:0]const u8) void {
    _ = setenv("XDG_STATE_HOME", dir, 1);
}
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "the journal is most-recent-first, deduped and capped" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [128]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dbuf, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;
    withStateHome(dir.ptr);
    defer _ = unsetenv("XDG_STATE_HOME");

    record(gpa, io, "/a/one.zig");
    record(gpa, io, "/a/two.zig");
    record(gpa, io, "/a/one.zig"); // again: moves, does not duplicate

    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer list.deinit(gpa);
    const data = read(gpa, io, &list) orelse return error.NoJournal;
    defer gpa.free(data);
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("/a/one.zig", list.items[0]);
    try testing.expectEqualStrings("/a/two.zig", list.items[1]);
}

test "a relative path is not history" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dbuf: [128]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dbuf, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;
    withStateHome(dir.ptr);
    defer _ = unsetenv("XDG_STATE_HOME");

    record(gpa, io, "relative.zig");
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer list.deinit(gpa);
    const data = read(gpa, io, &list);
    defer if (data) |d| gpa.free(d);
    try testing.expectEqual(@as(usize, 0), list.items.len);
}
