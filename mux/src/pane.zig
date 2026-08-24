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

/// Same recovery for a callback's Nth parameter (clipboard.Write has
/// no public spelling in lib_vt).
fn EffectArg(comptime name: []const u8, comptime i: usize) type {
    const F = @FieldType(Effects, name);
    const Fn = @typeInfo(@typeInfo(F).optional.child).pointer.child;
    return @typeInfo(Fn).@"fn".params[i].type.?;
}

const max_clipboard = 8 * 1024 * 1024;

const Timeval = extern struct { sec: i64, usec: i32 };
extern "c" fn gettimeofday(tv: *Timeval, tz: ?*anyopaque) c_int;
/// Wall-clock milliseconds. The activity stamp is read by other
/// processes through the state feed, so it has to be an epoch they
/// share — not the server's CLOCK_UPTIME_RAW.
fn epochMs() i64 {
    var tv: Timeval = .{ .sec = 0, .usec = 0 };
    _ = gettimeofday(&tv, null);
    return tv.sec * 1000 + @divTrunc(@as(i64, tv.usec), 1000);
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
    /// Wall-clock ms of the last batch this pane's pty produced, 0 if
    /// never. Stamped by the reader thread, read by the state feed:
    /// liveness that a worktree scan cannot see (an agent thinking
    /// writes no files; a long test run is not stale).
    last_output_ms: std.atomic.Value(i64) = .init(0),
    cols: u16,
    rows: u16,
    /// Server's self-pipe write end: one byte per parsed batch wakes
    /// the poll loop to snapshot and redraw.
    wake_fd: ptypkg.fd_t,
    id: u32,
    /// OSC 52 landing zone: the reader thread copies a clipboard write
    /// here (guarded by lock), the server forwards it to the glass.
    clip_buf: []u8 = &.{},
    clip_len: usize = 0,
    clip_pending: std.atomic.Value(bool) = .init(false),
    /// Stdin overflow queue (server thread only): what the pty would
    /// not take without blocking.
    in_buf: std.ArrayList(u8) = .empty,
    in_off: usize = 0,
    /// Raw-byte tee for block clients: the reader thread appends each
    /// read batch here (guarded by lock) while tee_on; the server
    /// drains and fans out. Overflow (a stalled drain) drops the
    /// buffer and forces a fresh snapshot instead.
    tee_on: std.atomic.Value(bool) = .init(false),
    tee_buf: std.ArrayList(u8) = .empty,
    tee_overflow: bool = false,

    pub fn start(
        gpa: std.mem.Allocator,
        io: std.Io,
        shell: [*:0]const u8,
        cwd: ?[*:0]const u8,
        cols: u16,
        rows: u16,
        wake_fd: ptypkg.fd_t,
        id: u32,
        cmd: ?[*:0]const u8,
        max_scrollback: usize,
    ) !*Pane {
        const self = try gpa.create(Pane);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .term = try .init(io, gpa, .{
                .cols = cols,
                .rows = rows,
                .max_scrollback_bytes = max_scrollback,
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
        // We are the mux now: scrub any outer multiplexer's identity so
        // programs in the pane (nvim plugins especially) don't think
        // they are living in tmux or herdr.
        ptypkg.unsetEnv("TMUX");
        ptypkg.unsetEnv("TMUX_PANE");
        ptypkg.unsetEnv("HERDR_PANE_ID");
        ptypkg.unsetEnv("HERDR_SESSION");
        // a command (popups) runs under the shell; panes get a login
        // shell as before
        if (cmd) |c| {
            const argv = [_][*:0]const u8{ shell, "-c", c };
            self.pid = try self.pty.spawnIn(&argv, cwd);
        } else {
            const argv = [_][*:0]const u8{ shell, "-l" };
            self.pid = try self.pty.spawnIn(&argv, cwd);
        }
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

    /// OSC 52 write: stash the text for the server to forward to the
    /// outer terminal as its own OSC 52 (pre-tmux shape). Fires on the
    /// reader thread with the lock held.
    fn effectClipboardWrite(h: *Handler, w: EffectArg("clipboard_write", 1)) EffectRet("clipboard_write") {
        const self = fromHandler(h);
        var data: []const u8 = "";
        for (w.contents) |c| {
            if (std.mem.eql(u8, c.mime, "text/plain")) {
                data = c.data;
                break;
            }
        }
        if (data.len > max_clipboard) return .invalid_data;
        if (self.clip_buf.len < data.len) {
            self.clip_buf = self.gpa.realloc(self.clip_buf, data.len) catch return .io_error;
        }
        @memcpy(self.clip_buf[0..data.len], data);
        self.clip_len = data.len;
        self.clip_pending.store(true, .release);
        return .success;
    }

    /// The server's side: take the pending clipboard text, or null.
    /// Caller frees nothing; the buffer is reused.
    pub fn takeClip(self: *Pane, out: []u8) ?[]const u8 {
        if (!self.clip_pending.swap(false, .acq_rel)) return null;
        os_unfair_lock_lock(&self.lock);
        defer os_unfair_lock_unlock(&self.lock);
        const n = @min(self.clip_len, out.len);
        @memcpy(out[0..n], self.clip_buf[0..n]);
        return out[0..n];
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
            .clipboard_write = &effectClipboardWrite,
            .title_changed = null,
            .pwd_changed = null,
            .progress_report = null,
        };
        var stream: vt.TerminalStream = .init(.{ .handler = handler, .allocator = self.gpa });
        defer stream.deinit();
        _ = ptypkg.setNonblock(self.pty.master);

        var buf: [256 * 1024]u8 = undefined;
        outer: while (true) {
            // Accumulate until the pty runs dry: the kernel hands out
            // ~1KiB per read, and locking/parsing/waking per kilobyte
            // is the churn the two-stage pipeline exists to kill. This
            // is the poor man's version: batch, then parse once.
            var total: usize = 0;
            var gone = false;
            while (total < buf.len) {
                switch (self.pty.readMasterNb(buf[total..])) {
                    .got => |n| total += n,
                    .dry => {
                        if (total > 0) break;
                        _ = ptypkg.pollOne(self.pty.master, ptypkg.POLLIN, -1);
                    },
                    .gone => {
                        gone = true;
                        break;
                    },
                }
            }
            if (total > 0) {
                self.last_output_ms.store(epochMs(), .release);
                os_unfair_lock_lock(&self.lock);
                stream.nextSlice(buf[0..total]);
                // tee the raw batch for block clients; 2MB behind
                // means the drain stalled — drop and let the server
                // resync that client with a fresh snapshot
                if (self.tee_on.load(.acquire)) {
                    if (self.tee_buf.items.len + total > 2 * 1024 * 1024) {
                        self.tee_buf.clearRetainingCapacity();
                        self.tee_overflow = true;
                    } else {
                        self.tee_buf.appendSlice(self.gpa, buf[0..total]) catch {};
                    }
                }
                os_unfair_lock_unlock(&self.lock);
                _ = ptypkg.writeByte(self.wake_fd, 'p');
            }
            if (gone) break :outer;
        }
        self.exited.store(true, .release);
        _ = ptypkg.writeByte(self.wake_fd, 'x');
    }

    /// Snapshot terminal state into rs for rendering. Server thread.
    /// Does this pane's terminal have a DEC private mode set? The
    /// server mirrors paste/focus modes of the focused pane onto the
    /// glass, same as kitty flags.
    pub fn modeSet(self: *Pane, m: vt.modes.Mode) bool {
        os_unfair_lock_lock(&self.lock);
        defer os_unfair_lock_unlock(&self.lock);
        return self.term.modes.get(m);
    }

    /// The pane's current kitty keyboard flags (0 = legacy). The
    /// server mirrors the focused pane's flags onto the glass.
    pub fn kittyFlags(self: *Pane) u8 {
        os_unfair_lock_lock(&self.lock);
        defer os_unfair_lock_unlock(&self.lock);
        return self.term.screens.active.kitty_keyboard.current().int();
    }

    pub fn snapshot(self: *Pane) !void {
        os_unfair_lock_lock(&self.lock);
        defer os_unfair_lock_unlock(&self.lock);
        try self.rs.update(self.gpa, &self.term);
    }

    /// Replace the selection with viewport-coord cells a→b (inclusive,
    /// either order). Any thread. (pre-tmux setSelection.)
    pub fn setSelection(self: *Pane, ax: u16, ay: u16, bx: u16, by: u16) void {
        os_unfair_lock_lock(&self.lock);
        defer os_unfair_lock_unlock(&self.lock);
        const s = self.term.screens.active;
        const pa = s.pages.pin(.{ .viewport = .{ .x = ax, .y = ay } }) orelse return;
        const pb = s.pages.pin(.{ .viewport = .{ .x = bx, .y = by } }) orelse return;
        s.select(.init(pa, pb, false)) catch {};
    }

    /// Extend the selection's end to a viewport cell, keeping its
    /// anchor. The anchor pin is content-tracked by the screen, so it
    /// stays put while copy mode scrolls. No selection yet: both ends
    /// land here.
    pub fn extendSelection(self: *Pane, x: u16, y: u16) void {
        os_unfair_lock_lock(&self.lock);
        defer os_unfair_lock_unlock(&self.lock);
        const s = self.term.screens.active;
        const pb = s.pages.pin(.{ .viewport = .{ .x = x, .y = y } }) orelse return;
        const anchor = if (s.selection) |sel| sel.bounds.tracked.start.* else pb;
        s.select(.init(anchor, pb, false)) catch {};
    }

    /// The pane's window title (OSC 0/2), copied out; empty when the
    /// program never set one. The Terminal stores it; we just read.
    pub fn title(self: *Pane, buf: []u8) []const u8 {
        os_unfair_lock_lock(&self.lock);
        defer os_unfair_lock_unlock(&self.lock);
        const t = std.mem.sliceTo(self.term.title.items, 0);
        const n = @min(t.len, buf.len);
        @memcpy(buf[0..n], t[0..n]);
        return buf[0..n];
    }

    /// The scrollback above the visible screen as unwrapped logical
    /// lines — a fresh client's backfill, reflowable at its width.
    /// Null when there is no history (or the pane is on the alt
    /// screen, which has none).
    pub fn historyText(self: *Pane, gpa: std.mem.Allocator) ?[]const u8 {
        os_unfair_lock_lock(&self.lock);
        defer os_unfair_lock_unlock(&self.lock);
        const s = self.term.screens.active;
        const text = s.dumpStringAllocUnwrapped(gpa, .{ .history = .{ .x = 0, .y = 0 } }) catch return null;
        if (text.len == 0) {
            gpa.free(text);
            return null;
        }
        return text;
    }

    pub const Tee = struct { bytes: []u8, overflow: bool };

    /// Drain the raw-byte tee. Caller frees bytes. Null when empty.
    pub fn takeTee(self: *Pane, gpa: std.mem.Allocator) ?Tee {
        os_unfair_lock_lock(&self.lock);
        defer os_unfair_lock_unlock(&self.lock);
        if (self.tee_buf.items.len == 0 and !self.tee_overflow) return null;
        const bytes = gpa.dupe(u8, self.tee_buf.items) catch return null;
        const ov = self.tee_overflow;
        self.tee_buf.clearRetainingCapacity();
        self.tee_overflow = false;
        return .{ .bytes = bytes, .overflow = ov };
    }

    pub fn hasSelection(self: *Pane) bool {
        os_unfair_lock_lock(&self.lock);
        defer os_unfair_lock_unlock(&self.lock);
        return self.term.screens.active.selection != null;
    }

    pub fn clearSelection(self: *Pane) void {
        os_unfair_lock_lock(&self.lock);
        defer os_unfair_lock_unlock(&self.lock);
        self.term.screens.active.clearSelection();
    }

    /// The selected text, allocated with gpa; null when nothing is
    /// selected. Caller frees.
    pub fn selectionText(self: *Pane) ?[:0]const u8 {
        os_unfair_lock_lock(&self.lock);
        defer os_unfair_lock_unlock(&self.lock);
        const s = self.term.screens.active;
        const sel = s.selection orelse return null;
        return s.selectionString(self.gpa, .{ .sel = sel }) catch null;
    }

    /// Does the program in this pane want mouse events?
    pub fn wantsMouse(self: *Pane) bool {
        os_unfair_lock_lock(&self.lock);
        defer os_unfair_lock_unlock(&self.lock);
        const m = &self.term.modes;
        return m.get(.mouse_event_normal) or m.get(.mouse_event_button) or m.get(.mouse_event_any);
    }

    /// Scroll the viewport by rows (negative = back in time).
    pub fn scroll(self: *Pane, delta: i32) void {
        os_unfair_lock_lock(&self.lock);
        defer os_unfair_lock_unlock(&self.lock);
        self.term.screens.active.scroll(.{ .delta_row = delta });
    }
    pub fn scrollTop(self: *Pane) void {
        os_unfair_lock_lock(&self.lock);
        defer os_unfair_lock_unlock(&self.lock);
        self.term.screens.active.scroll(.top);
    }
    pub fn scrollBottom(self: *Pane) void {
        os_unfair_lock_lock(&self.lock);
        defer os_unfair_lock_unlock(&self.lock);
        self.term.screens.active.scroll(.active);
    }

    /// Queue bytes for the pty. Never blocks the server: a program
    /// that stopped reading its tty (Ctrl-S, stopped job) fills the
    /// kernel buffer, and the overflow waits here until POLLOUT. A
    /// pane more than 16MB behind is not coming back; drop input.
    pub fn write(self: *Pane, bytes: []const u8) void {
        const backlog = self.in_buf.items.len - self.in_off;
        if (backlog > 16 * 1024 * 1024) return;
        self.in_buf.appendSlice(self.gpa, bytes) catch return;
        self.flushIn();
    }

    /// Drain the stdin queue as far as the pty will take it.
    pub fn flushIn(self: *Pane) void {
        while (self.in_off < self.in_buf.items.len) {
            const n = ptypkg.writeNbFd(self.pty.master, self.in_buf.items[self.in_off..]) catch {
                self.in_buf.clearRetainingCapacity();
                self.in_off = 0;
                return;
            };
            if (n == 0) return; // pty full; server polls POLLOUT
            self.in_off += n;
        }
        self.in_off = 0;
        if (self.in_buf.capacity > 256 * 1024) {
            self.in_buf.clearAndFree(self.gpa);
        } else {
            self.in_buf.clearRetainingCapacity();
        }
    }

    pub fn pendingIn(self: *Pane) bool {
        return self.in_off < self.in_buf.items.len;
    }

    pub fn resize(self: *Pane, cols: u16, rows: u16) void {
        if (cols == 0 or rows == 0) return;
        os_unfair_lock_lock(&self.lock);

        // Bottom-anchor scrollback across the reflow. ghostty keeps the
        // TOP viewport line pinned on resize; when scrolled back, a width
        // shrink rewraps lines taller and pushes the newer lines you were
        // reading off the bottom ("rendering too far back"). Instead pin
        // the newest visible line: track it, let it follow the reflow,
        // then seat it back at the bottom — tmux's feel. Only when
        // actually scrolled back; the live bottom (and the alt screen,
        // which has no scrollback) leaves the viewport .active untouched.
        const s = self.term.screens.active;
        const anchor: ?*vt.Pin = switch (s.pages.viewport) {
            .active => null,
            else => if (s.pages.pin(.{ .viewport = .{ .x = 0, .y = self.rows -| 1 } })) |bp|
                (s.pages.trackPin(bp) catch null)
            else
                null,
        };

        self.cols = cols;
        self.rows = rows;
        self.term.resize(self.gpa, .{ .cols = cols, .rows = rows }) catch {};

        if (anchor) |ap| {
            // Tracked pins are maintained across reflow (and scrollback
            // trims), so ap stays valid — same guarantee the selection
            // pins rely on.
            s.scroll(.{ .pin = ap.* }); // the anchor becomes the top row…
            if (rows > 1) s.scroll(.{ .delta_row = -(@as(isize, rows) - 1) }); // …then the bottom
            s.pages.untrackPin(ap);
        }

        const in_band = self.term.modes.get(.in_band_size_reports);
        os_unfair_lock_unlock(&self.lock);
        self.pty.setSize(.{ .ws_row = rows, .ws_col = cols }) catch {};
        // Apps that enabled mode 2048 (nvim, notably) stop trusting
        // SIGWINCH and wait for the terminal to report the new size
        // in-band. We drive term.resize directly rather than through the
        // stream Handler that would emit this, so send it ourselves —
        // otherwise closing a split leaves nvim painting the old, smaller
        // width. Pixel geometry is unknown at the mux, reported as 0.
        if (in_band) {
            var buf: [64]u8 = undefined;
            const rep = std.fmt.bufPrint(&buf, "\x1b[48;{d};{d};0;0t", .{ rows, cols }) catch return;
            self.write(rep);
        }
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
        if (self.clip_buf.len > 0) self.gpa.free(self.clip_buf);
        self.in_buf.deinit(self.gpa);
        self.tee_buf.deinit(self.gpa);
        self.pty.deinit();
        self.rs.deinit(self.gpa);
        self.term.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// The program reading this pty right now — "nvim", or the shell
    /// at its prompt. Two syscalls, no cache to go stale.
    pub fn fgName(self: *Pane, buf: []u8) ?[]const u8 {
        const pgrp = tcgetpgrp(self.pty.master);
        if (pgrp <= 0) return null;
        var path: [4096]u8 = undefined;
        const n = proc_pidpath(pgrp, &path, path.len);
        if (n <= 0) return null;
        const full = path[0..@intCast(n)];
        var base = std.fs.path.basename(full);
        // a versioned binary ("2.1.240", claude code's layout) tells
        // you nothing; the directory above it is the product name
        if (base.len > 0 and allVersionish(base)) {
            if (std.fs.path.dirname(full)) |dir| {
                const parent = std.fs.path.basename(dir);
                if (parent.len > 0 and !allVersionish(parent)) base = parent;
            }
        }
        if (base.len == 0 or base.len > buf.len) return null;
        @memcpy(buf[0..base.len], base);
        return buf[0..base.len];
    }

    /// Working directory of the foreground process group leader —
    /// where a split or new window should open. macOS libproc; the
    /// struct layout is the frozen libproc ABI.
    pub fn fgCwd(self: *Pane, buf: []u8) ?[:0]const u8 {
        const pgrp = tcgetpgrp(self.pty.master);
        if (pgrp <= 0) return null;
        var info: VnodePathInfo = undefined;
        const n = proc_pidinfo(pgrp, PROC_PIDVNODEPATHINFO, 0, &info, @sizeOf(VnodePathInfo));
        if (n <= 0) return null;
        const path = std.mem.sliceTo(&info.cdir.path, 0);
        if (path.len == 0 or path.len + 1 > buf.len) return null;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        return buf[0..path.len :0];
    }
};

fn allVersionish(s2: []const u8) bool {
    for (s2) |ch| {
        if (!(ch >= '0' and ch <= '9') and ch != '.' and ch != '-') return false;
    }
    return true;
}

extern "c" fn tcgetpgrp(fd: ptypkg.fd_t) ptypkg.pid_t;
extern "c" fn proc_pidpath(pid: ptypkg.pid_t, buf: [*]u8, len: u32) c_int;

// ---- libproc cwd lookup ----
extern "c" fn proc_pidinfo(pid: ptypkg.pid_t, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;
const PROC_PIDVNODEPATHINFO: c_int = 9;
/// struct vnode_info_path: vnode_info (vinfo_stat 136 + type/pad/fsid
/// 16) then MAXPATHLEN of path.
const VnodeInfoPath = extern struct {
    vi: [152]u8,
    path: [1024]u8,
};
const VnodePathInfo = extern struct {
    cdir: VnodeInfoPath,
    rdir: VnodeInfoPath,
};
comptime {
    std.debug.assert(@sizeOf(VnodePathInfo) == 2352);
}
