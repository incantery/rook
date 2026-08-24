//! The wire: 1-byte type, 4-byte LE length, payload. Both directions.
//! Deliberately dumb for the MVP; the structured multi-client cell
//! protocol replaces this, not extends it.
const std = @import("std");
const ptypkg = @import("pty.zig");

pub const c2s = enum(u8) { attach = 1, stdin = 2, resize = 3, detach = 4, stats = 5, shutdown = 6, nav = 7, popup = 8, session = 9, blocks = 10, attach_block = 11, block_cmd = 12, state = 13, capture = 14, side = 15 };
pub const s2c = enum(u8) { draw = 1, exit = 2, stats_text = 3, blocks_text = 4, block_created = 5, state_json = 6, ack = 7, text = 8 };

pub fn write(fd: ptypkg.fd_t, kind: u8, payload: []const u8) !void {
    var hdr: [5]u8 = undefined;
    hdr[0] = kind;
    std.mem.writeInt(u32, hdr[1..5], @intCast(payload.len), .little);
    if (!ptypkg.writeAllFd(fd, &hdr)) return error.WriteFailed;
    if (!ptypkg.writeAllFd(fd, payload)) return error.WriteFailed;
}

/// Incremental frame reader over a nonblocking fd.
pub const Reader = struct {
    buf: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,
    pending_consume: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Reader {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *Reader) void {
        self.buf.deinit(self.gpa);
    }

    /// Pull available bytes off the (nonblocking) fd. False on EOF.
    pub fn fill(self: *Reader, fd: ptypkg.fd_t) bool {
        var tmp: [64 * 1024]u8 = undefined;
        while (true) {
            const n = ptypkg.readNb(fd, &tmp);
            if (n < 0) return true; // dry
            if (n == 0) return false; // EOF
            const got: usize = @intCast(n);
            self.buf.appendSlice(self.gpa, tmp[0..got]) catch return false;
            if (got < tmp.len) return true;
        }
    }

    pub const Msg = struct { kind: u8, payload: []const u8 };

    /// Next complete frame, or null. Payload is valid until the next
    /// call to next/fill.
    pub fn next(self: *Reader) ?Msg {
        if (self.buf.items.len < 5) return null;
        const len = std.mem.readInt(u32, self.buf.items[1..5], .little);
        const total = 5 + @as(usize, len);
        if (self.buf.items.len < total) return null;
        const kind = self.buf.items[0];
        const payload = self.buf.items[5..total];
        // compact after the caller reads it: shift on next call
        self.pending_consume = total;
        return .{ .kind = kind, .payload = payload };
    }

    /// Consume the frame returned by the last next().
    pub fn consume(self: *Reader) void {
        if (self.pending_consume == 0) return;
        const rest = self.buf.items.len - self.pending_consume;
        std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[self.pending_consume..]);
        self.buf.shrinkRetainingCapacity(rest);
        self.pending_consume = 0;
    }
};

pub const Geometry = struct {
    cols: u16,
    rows: u16,
    pub fn encode(self: Geometry) [4]u8 {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u16, b[0..2], self.cols, .little);
        std.mem.writeInt(u16, b[2..4], self.rows, .little);
        return b;
    }
    pub fn decode(b: []const u8) ?Geometry {
        if (b.len < 4) return null;
        return .{
            .cols = std.mem.readInt(u16, b[0..2], .little),
            .rows = std.mem.readInt(u16, b[2..4], .little),
        };
    }
};
