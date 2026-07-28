//! A live terminal session: pty + ghostty-vt Terminal + reader thread.
//! The mutex guards the terminal; the render thread takes it briefly to
//! snapshot via RenderState.update, the reader thread takes it to parse.
//!
//! The stream is NOT the read-only vtStream(): we wire the Effects
//! callbacks so queries get answered — DA1/DA2, DSR, XTWINOPS size,
//! XTVERSION, ENQ. Without these, programs that query-and-wait (nvim
//! does on exit) stall on their response timeout.

const std = @import("std");
const vt = @import("ghostty-vt");
const ptypkg = @import("pty.zig");

const Handler = @typeInfo(@TypeOf(vt.Terminal.vtHandler)).@"fn".return_type.?;
const Effects = Handler.Effects;

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

/// The return type of an Effects callback, by field name — the types
/// (Attributes, Size, ColorScheme) aren't all exported from lib_vt, so
/// they're recovered from the callback signatures instead.
fn EffectRet(comptime name: []const u8) type {
    const F = @FieldType(Effects, name);
    const Fn = @typeInfo(@typeInfo(F).optional.child).pointer.child;
    return @typeInfo(Fn).@"fn".return_type.?;
}

pub const Session = struct {
    gpa: std.mem.Allocator,
    term: vt.Terminal,
    pty: ptypkg.Pty,
    pid: ptypkg.pid_t,
    mutex: Lock = .{},
    thread: ?std.Thread = null,

    // Geometry for XTWINOPS size reports; updated by resize().
    cols: u16,
    rows: u16,
    cell_w_px: u32,
    cell_h_px: u32,

    pub fn start(gpa: std.mem.Allocator, io: anytype, shell: [*:0]const u8, cols: u16, rows: u16, cell_w_px: u32, cell_h_px: u32) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .term = try .init(io, gpa, .{ .cols = cols, .rows = rows }),
            .pty = try ptypkg.Pty.open(.{ .ws_row = rows, .ws_col = cols }),
            .pid = undefined,
            .cols = cols,
            .rows = rows,
            .cell_w_px = cell_w_px,
            .cell_h_px = cell_h_px,
        };

        ptypkg.setEnv("TERM", "xterm-256color");
        ptypkg.setEnv("COLORTERM", "truecolor");
        const argv = [_][*:0]const u8{shell};
        self.pid = try self.pty.spawn(&argv);

        self.thread = try std.Thread.spawn(.{}, readLoop, .{self});
        return self;
    }

    fn readLoop(self: *Session) void {
        var handler = self.term.vtHandler();
        handler.effects = .{
            .write_pty = &effectWritePty,
            .device_attributes = &effectDeviceAttributes,
            .size = &effectSize,
            .enquiry = &effectEnquiry,
            .xtversion = &effectXtversion,
            .color_scheme = &effectColorScheme,
            .bell = null,
            .clipboard_write = null,
            .title_changed = null,
            .pwd_changed = null,
        };
        var stream: vt.TerminalStream = .initAlloc(self.gpa, handler);
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

    fn fromHandler(h: *Handler) *Session {
        return @fieldParentPtr("term", h.terminal);
    }

    fn effectWritePty(h: *Handler, data: [:0]const u8) void {
        // Fires inside stream.nextSlice on the reader thread; the pty
        // write path takes no lock, so no deadlock with the held mutex.
        fromHandler(h).pty.writeMaster(data) catch {};
    }

    fn effectDeviceAttributes(_: *Handler) EffectRet("device_attributes") {
        return .{};
    }

    fn effectSize(h: *Handler) EffectRet("size") {
        const s = fromHandler(h);
        return .{
            .rows = s.rows,
            .columns = s.cols,
            .cell_width = s.cell_w_px,
            .cell_height = s.cell_h_px,
        };
    }

    fn effectEnquiry(_: *Handler) []const u8 {
        return "";
    }

    fn effectXtversion(_: *Handler) []const u8 {
        return "rookz 0.0.1";
    }

    fn effectColorScheme(_: *Handler) EffectRet("color_scheme") {
        return .dark;
    }

    pub fn write(self: *Session, bytes: []const u8) void {
        self.pty.writeMaster(bytes) catch {};
    }

    /// Resize the emulator (reflow included) and tell the child via
    /// TIOCSWINSZ. Any-thread safe.
    pub fn resize(self: *Session, cols: u16, rows: u16, cell_w: u32, cell_h: u32) void {
        self.mutex.lock();
        self.cols = cols;
        self.rows = rows;
        self.cell_w_px = cell_w;
        self.cell_h_px = cell_h;
        self.term.resize(self.gpa, .{
            .cols = cols,
            .rows = rows,
            .cell_size_px = .{ .width = cell_w, .height = cell_h },
        }) catch |err| {
            std.debug.print("rookz: terminal resize failed: {}\n", .{err});
        };
        self.mutex.unlock();
        self.pty.setSize(.{ .ws_row = rows, .ws_col = cols }) catch {};
    }
};
