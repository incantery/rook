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
extern "c" fn usleep(us: u32) c_int;

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

    /// os_unfair_lock has no fairness: under a firehose the reader
    /// re-acquires back-to-back and starves the render thread for
    /// hundreds of ms (measured). The renderer raises this flag before
    /// locking; the reader yields between chunks while it's up.
    snapshot_wanted: std.atomic.Value(bool) = .init(false),

    /// Input kick: called after each parsed chunk (outside the lock) so
    /// the app can render an echo immediately instead of waiting for the
    /// next display-link tick. The callee gates on pending input to keep
    /// firehose output coalesced (the wake-per-KB lesson).
    kick: ?*const fn (*anyopaque, *Session) void = null,
    kick_ctx: *anyopaque = undefined,

    /// Set by the reader thread when the child side goes away (shell
    /// exited). The app collapses the pane on its next frame.
    exited: std.atomic.Value(bool) = .init(false),

    // Geometry for XTWINOPS size reports; updated by resize().
    cols: u16,
    rows: u16,
    cell_w_px: u32,
    cell_h_px: u32,

    /// Take the session lock for a render snapshot, with priority over
    /// the reader's parse loop.
    /// Scroll the viewport into history (negative) or toward the
    /// active area (positive). No-op on screens without scrollback
    /// (the alt screen). Any thread.
    pub fn scrollViewport(self: *Session, delta: isize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.term.screens.active.scroll(.{ .delta_row = delta });
    }

    pub fn scrollTo(self: *Session, where: enum { top, active }) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (where) {
            .top => self.term.screens.active.scroll(.top),
            .active => self.term.screens.active.scroll(.active),
        }
    }

    pub const MouseMode = enum { none, x10, normal, button, any };

    /// What mouse tracking the foreground app asked for (DECSET
    /// 9/1000/1002/1003) and whether it wants SGR encoding (1006).
    pub fn mouseMode(self: *Session) struct { mode: MouseMode, sgr: bool } {
        self.mutex.lock();
        defer self.mutex.unlock();
        const m = &self.term.modes;
        const mode: MouseMode = if (m.get(.mouse_event_any))
            .any
        else if (m.get(.mouse_event_button))
            .button
        else if (m.get(.mouse_event_normal))
            .normal
        else if (m.get(.mouse_event_x10))
            .x10
        else
            .none;
        return .{ .mode = mode, .sgr = m.get(.mouse_format_sgr) };
    }

    /// Has the foreground app asked for bracketed paste (DECSET 2004)?
    /// Same shape as mouseMode: emulator truth, no heuristic.
    pub fn bracketedPaste(self: *Session) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.term.modes.get(.bracketed_paste);
    }

    /// Replace the selection with viewport-coord cells a→b (inclusive
    /// cells; either order). Any thread.
    pub fn setSelection(self: *Session, ax: u16, ay: u16, bx: u16, by: u16) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const s = self.term.screens.active;
        const pa = s.pages.pin(.{ .viewport = .{ .x = ax, .y = ay } }) orelse return;
        const pb = s.pages.pin(.{ .viewport = .{ .x = bx, .y = by } }) orelse return;
        s.select(.init(pa, pb, false)) catch {};
    }

    pub fn clearSelection(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.term.screens.active.clearSelection();
    }

    /// The selected text (unwrapped), or null. Caller frees.
    pub fn selectionText(self: *Session, alloc: std.mem.Allocator) ?[:0]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const s = self.term.screens.active;
        const sel = s.selection orelse return null;
        return s.selectionString(alloc, .{ .sel = sel }) catch null;
    }

    pub fn lockForSnapshot(self: *Session) void {
        self.snapshot_wanted.store(true, .release);
        self.mutex.lock();
    }

    pub fn unlockForSnapshot(self: *Session) void {
        self.mutex.unlock();
        self.snapshot_wanted.store(false, .release);
    }

    pub fn start(gpa: std.mem.Allocator, io: anytype, shell: [*:0]const u8, cwd: ?[*:0]const u8, colors: vt.Terminal.Colors, cols: u16, rows: u16, cell_w_px: u32, cell_h_px: u32) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .term = try .init(io, gpa, .{ .cols = cols, .rows = rows, .colors = colors }),
            .pty = try ptypkg.Pty.open(.{ .ws_row = rows, .ws_col = cols }),
            .pid = undefined,
            .cols = cols,
            .rows = rows,
            .cell_w_px = cell_w_px,
            .cell_h_px = cell_h_px,
        };

        ptypkg.setEnv("TERM", "xterm-256color");
        ptypkg.setEnv("COLORTERM", "truecolor");
        // Login shell (-l): a Dock-launched app has a skeleton env, and
        // .zprofile is where PATH/homebrew/starship come from — the
        // convention every terminal app follows.
        const argv = [_][*:0]const u8{ shell, "-l" };
        self.pid = try self.pty.spawnIn(&argv, cwd);

        self.thread = try std.Thread.spawn(.{}, readLoop, .{self});
        return self;
    }

    /// Tear down after exited flips true. Joins the reader thread (which
    /// is past its loop by then), reaps the child, closes the pty, frees
    /// the terminal. NEVER call from the reader thread itself — collapse
    /// runs on the display-link tick, which also makes joining safe.
    pub fn deinit(self: *Session) void {
        if (self.thread) |t| t.join();
        _ = ptypkg.Pty.wait(self.pid);
        self.pty.deinit();
        self.term.deinit(self.gpa);
        self.gpa.destroy(self);
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
            _ = @import("stats.zig").global.bytes_in.fetchAdd(n, .monotonic);
            // Yield to a waiting renderer before re-acquiring.
            while (self.snapshot_wanted.load(.acquire)) _ = usleep(50);
            self.mutex.lock();
            stream.nextSlice(buf[0..n]);
            self.mutex.unlock();
            if (self.kick) |k| k(self.kick_ctx, self);
        }
        // Child gone. No kick here: the display link ticks at 120fps and
        // collapses the pane on its next pass — kicking from this thread
        // would let collapse (and our own join) run on the dying thread.
        self.exited.store(true, .release);
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
