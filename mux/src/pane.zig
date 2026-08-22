//! One pane: a pty, a ghostty-vt Terminal fed by a reader thread, and
//! the RenderState the server snapshots frames from. This is the
//! pre-tmux Session cut to the bone: serial read loop only (the
//! two-stage pipeline comes back when a benchmark asks for it), no
//! search, no selection, no clipboard.
const std = @import("std");
const vt = @import("ghostty-vt");
const ptypkg = @import("pty.zig");

// Zig 0.16 retired std.Thread.Mutex; os_unfair_lock is the mac-native
// primitive the pre-tmux app stood on.
extern "c" fn os_unfair_lock_lock(l: *u32) void;
extern "c" fn os_unfair_lock_unlock(l: *u32) void;

const Handler = @typeInfo(@TypeOf(vt.Terminal.vtHandler)).@"fn".return_type.?;
const Effects = @FieldType(Handler, "effects");

/// Effect callback return/arg types aren't all exported from lib_vt;
/// recover them from the callback signatures (pre-tmux trick).
fn EffectRet(comptime name: []const u8) type {
    const F = @FieldType(Effects, name);
    const Fn = @typeInfo(@typeInfo(F).optional.child).pointer.child;
    return @typeInfo(Fn).@"fn".return_type.?;
}

pub const Pane = struct {
    gpa: std.mem.Allocator,
    pty: ptypkg.Pty,
    pid: ptypkg.pid_t,
    term: vt.Terminal,
    lock: u32 = 0,
    rs: vt.RenderState = .empty,
    thread: ?std.Thread = null,
    exited: std.atomic.Value(bool) = .init(false),
    cols: u16,
    rows: u16,
    /// Server's self-pipe write end: one byte per parsed batch wakes
    /// the poll loop to snapshot and redraw.
    wake_fd: ptypkg.fd_t,
    id: u32,

    pub fn start(
        gpa: std.mem.Allocator,
        io: std.Io,
        shell: [*:0]const u8,
        cwd: ?[*:0]const u8,
        cols: u16,
        rows: u16,
        wake_fd: ptypkg.fd_t,
        id: u32,
    ) !*Pane {
        const self = try gpa.create(Pane);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .term = try .init(io, gpa, .{
                .cols = cols,
                .rows = rows,
                .max_scrollback_bytes = 4 * 1024 * 1024,
            }),
            .pty = try ptypkg.Pty.open(.{ .ws_row = rows, .ws_col = cols }),
            .pid = undefined,
            .cols = cols,
            .rows = rows,
            .wake_fd = wake_fd,
            .id = id,
        };
        ptypkg.setEnv("TERM", "xterm-256color");
        ptypkg.setEnv("COLORTERM", "truecolor");
        ptypkg.setEnv("ROOK_MUX_PANE", "1");
        const argv = [_][*:0]const u8{ shell, "-l" };
        self.pid = try self.pty.spawnIn(&argv, cwd);
        self.thread = try std.Thread.spawn(.{}, readLoop, .{self});
        return self;
    }

    fn fromHandler(h: *Handler) *Pane {
        return @fieldParentPtr("term", h.terminal);
    }

    fn effectWritePty(h: *Handler, data: [:0]const u8) void {
        fromHandler(h).pty.writeMaster(data) catch {};
    }
    fn effectDeviceAttributes(_: *Handler) EffectRet("device_attributes") {
        return .{};
    }
    fn effectSize(h: *Handler) EffectRet("size") {
        const s = fromHandler(h);
        return .{ .rows = s.rows, .columns = s.cols, .cell_width = 8, .cell_height = 16 };
    }
    fn effectEnquiry(_: *Handler) []const u8 {
        return "";
    }
    fn effectXtversion(_: *Handler) []const u8 {
        return "rook-mux 0.0.0";
    }
    fn effectColorScheme(_: *Handler) EffectRet("color_scheme") {
        return .dark;
    }

    fn readLoop(self: *Pane) void {
        var handler = self.term.vtHandler();
        handler.effects = .{
            .write_pty = &effectWritePty,
            .device_attributes = &effectDeviceAttributes,
            .size = &effectSize,
            .enquiry = &effectEnquiry,
            .xtversion = &effectXtversion,
            .color_scheme = &effectColorScheme,
            .bell = null,
            .desktop_notification = null,
            .clipboard_write = null,
            .title_changed = null,
            .pwd_changed = null,
            .progress_report = null,
        };
        var stream: vt.TerminalStream = .init(.{ .handler = handler, .allocator = self.gpa });
        defer stream.deinit();
        _ = ptypkg.setNonblock(self.pty.master);

        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = switch (self.pty.readMasterNb(&buf)) {
                .got => |n| n,
                .dry => {
                    _ = ptypkg.pollOne(self.pty.master, ptypkg.POLLIN, -1);
                    continue;
                },
                .gone => break,
            };
            os_unfair_lock_lock(&self.lock);
            stream.nextSlice(buf[0..n]);
            os_unfair_lock_unlock(&self.lock);
            _ = ptypkg.writeByte(self.wake_fd, 'p');
        }
        self.exited.store(true, .release);
        _ = ptypkg.writeByte(self.wake_fd, 'x');
    }

    /// Snapshot terminal state into rs for rendering. Server thread.
    pub fn snapshot(self: *Pane) !void {
        os_unfair_lock_lock(&self.lock);
        defer os_unfair_lock_unlock(&self.lock);
        try self.rs.update(self.gpa, &self.term);
    }

    pub fn write(self: *Pane, bytes: []const u8) void {
        self.pty.writeMaster(bytes) catch {};
    }

    pub fn resize(self: *Pane, cols: u16, rows: u16) void {
        if (cols == 0 or rows == 0) return;
        os_unfair_lock_lock(&self.lock);
        self.cols = cols;
        self.rows = rows;
        self.term.resize(self.gpa, .{ .cols = cols, .rows = rows }) catch {};
        os_unfair_lock_unlock(&self.lock);
        self.pty.setSize(.{ .ws_row = rows, .ws_col = cols }) catch {};
    }

    /// Polite kill: HUP the foreground and shell process groups, with
    /// escalation on a detached thread (pre-tmux hangup, verbatim).
    pub fn hangup(self: *Pane) void {
        const groups = ptypkg.ProcessGroups.capture(self.pty.master, self.pid);
        groups.signal(ptypkg.SIGHUP);
        if (std.Thread.spawn(.{}, ptypkg.ProcessGroups.escalate, .{groups})) |t| t.detach() else |_| {}
    }

    pub fn deinit(self: *Pane) void {
        if (self.thread) |t| t.join();
        _ = ptypkg.Pty.wait(self.pid);
        self.pty.deinit();
        self.rs.deinit(self.gpa);
        self.term.deinit(self.gpa);
        self.gpa.destroy(self);
    }
};
