//! A live terminal session: pty + ghostty-vt Terminal + reader thread.
//! The mutex guards the terminal; the render thread takes it briefly to
//! snapshot via RenderState.update, the reader thread takes it to parse.

const std = @import("std");
const vt = @import("ghostty-vt");
const ptypkg = @import("pty.zig");

extern "c" fn os_unfair_lock_lock(l: *u32) void;
extern "c" fn os_unfair_lock_unlock(l: *u32) void;

/// Tiny mutex over macOS os_unfair_lock: zero-init, callable from any
/// thread (display link, reader), no Io handle required.
pub const Lock = struct {
    raw: u32 = 0,
    pub fn lock(self: *Lock) void {
        os_unfair_lock_lock(&self.raw);
    }
    pub fn unlock(self: *Lock) void {
        os_unfair_lock_unlock(&self.raw);
    }
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    term: vt.Terminal,
    pty: ptypkg.Pty,
    pid: ptypkg.pid_t,
    mutex: Lock = .{},
    thread: ?std.Thread = null,

    pub fn start(gpa: std.mem.Allocator, io: anytype, shell: [*:0]const u8, cols: u16, rows: u16) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .term = try .init(io, gpa, .{ .cols = cols, .rows = rows }),
            .pty = try ptypkg.Pty.open(.{ .ws_row = rows, .ws_col = cols }),
            .pid = undefined,
        };

        ptypkg.setEnv("TERM", "xterm-256color");
        ptypkg.setEnv("COLORTERM", "truecolor");
        const argv = [_][*:0]const u8{shell};
        self.pid = try self.pty.spawn(&argv);

        self.thread = try std.Thread.spawn(.{}, readLoop, .{self});
        return self;
    }

    fn readLoop(self: *Session) void {
        var stream = self.term.vtStream();
        defer stream.deinit();

        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = self.pty.readMaster(&buf);
            if (n == 0) break;
            self.mutex.lock();
            stream.nextSlice(buf[0..n]);
            self.mutex.unlock();
        }
    }

    pub fn write(self: *Session, bytes: []const u8) void {
        self.pty.writeMaster(bytes) catch {};
    }
};
