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

/// Who is reading this pty right now — see fgName. tcgetpgrp works on
/// the MASTER side on macOS (verified against a real vim under a forked
/// pty), which matters because the master is the only end rook holds.
extern "c" fn tcgetpgrp(fd: ptypkg.fd_t) ptypkg.pid_t;
extern "c" fn CACurrentMediaTime() f64;

/// The app's one clock, in the milliseconds the activity stamps use.
pub fn clockMs() i64 {
    return @intFromFloat(CACurrentMediaTime() * 1000.0);
}
/// <libproc.h>, in libSystem. Gives the full executable path, so the
/// name survives without p_comm's 16-byte truncation.
extern "c" fn proc_pidpath(pid: ptypkg.pid_t, buf: [*]u8, len: u32) c_int;
const proc_pidpathinfo_maxsize = 4 * 1024;

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

/// Same recovery, for a callback's Nth parameter. clipboard.Write is the
/// one that needs it: lib_vt.zig re-exports most of terminal/main.zig
/// but not `clipboard`, so the type you must name to implement
/// `clipboard_write` has no public spelling. Worth reporting upstream.
fn EffectArg(comptime name: []const u8, comptime i: usize) type {
    const F = @FieldType(Effects, name);
    const Fn = @typeInfo(@typeInfo(F).optional.child).pointer.child;
    return @typeInfo(Fn).@"fn".params[i].type.?;
}

/// Ceiling on a single OSC 52 payload we'll hold. The OSC parser's own
/// capture buffer for 52 is ALLOCATING and unbounded, so this is the
/// only cap in the path — and ours is the copy that outlives the
/// sequence, waiting for the main thread to drain it.
const max_clipboard = 8 * 1024 * 1024;

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

    /// A desktop notification was requested (OSC 9 / OSC 777). Title
    /// and body are copied here because the effect's slices are borrowed
    /// for the call only. Guarded by `mutex`, like the terminal itself —
    /// the reader writes them mid-parse and the app reads them later.
    notify_pending: bool = false,
    notify_title: [96]u8 = undefined,
    notify_title_len: usize = 0,
    notify_body: [256]u8 = undefined,
    notify_body_len: usize = 0,

    /// OSC 52: the program asked to set the system clipboard. Heap, not
    /// a fixed buffer, because a yank is whatever size the yank is —
    /// truncating someone's copied text at an arbitrary cap would hand
    /// them a corrupt paste, which is worse than refusing outright.
    /// The buffer is guarded by `mutex`; the reader fills it, the app
    /// drains it. The FLAG is atomic and outside the lock so the drain
    /// can run every frame instead of on the 2Hz HUD tick — a yank
    /// followed straight away by ⌘V is rare but real, and the cost of
    /// closing that window is one relaxed load per pane per frame
    /// rather than a mutex acquisition.
    clip_pending: std.atomic.Value(bool) = .init(false),
    clip_buf: []u8 = &.{},
    clip_len: usize = 0,

    /// Scrollback search over the active screen. It lives here rather
    /// than on the pane because every operation on it reads screen
    /// state under this mutex — and because a closing pane then frees
    /// it along with everything else it owns.
    search: ?vt.search.Screen = null,
    /// The screen the search was built against. `screens.active` moves
    /// when a program enters the alt screen, and results from the
    /// primary shown over the alternate would be nonsense — so we
    /// notice the swap and drop the search rather than lie.
    search_of: ?*vt.Screen = null,

    /// Whether OSC 52 writes are honoured (config `clipboard-write`).
    /// Read on the reader thread; the app rewrites it on live reload,
    /// and a torn read of a two-valued enum can only pick one of the
    /// two answers, so it needs no lock of its own.
    clip_allow: bool = true,

    /// BEL arrived. Set on the reader thread (inside the parse, with the
    /// mutex held), drained by the app on the main thread — the bell has
    /// to reach AppKit, and the reader is the wrong thread to touch it
    /// from. A flag rather than a count: ten bells in a burst are one
    /// "something wants you", and that is the whole signal.
    bell: std.atomic.Value(bool) = .init(false),

    /// Substrate observability (`ctl activity`, plugin op
    /// `panes.activity`): when the child last WROTE — a TUI redrawing its
    /// spinner is proof of life even while it logs nothing — and when the
    /// human last TYPED here, physical keyboard only. The two directions
    /// go through two different code paths, which is what makes them two
    /// different facts rather than a heuristic. Milliseconds on the app
    /// clock; 0 = never; atomic because the reader thread stamps one, the
    /// main thread the other, and any thread reads both.
    last_out_ms: std.atomic.Value(i64) = .init(0),
    last_in_ms: std.atomic.Value(i64) = .init(0),

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

    // ---- scrollback search ----
    //
    // ghostty-vt does the searching; all rook adds is a lifetime and a
    // viewport move. `searchAll` is the BLOCKING spelling — the library
    // also offers tick/feed so a background thread can search a huge
    // scrollback incrementally, which is what ghostty itself does. We
    // take the blocking one because it runs on the ctl/main thread with
    // the mutex held, and a stall there is a frozen window: worth
    // revisiting the moment someone feels it on a big buffer.

    /// Start a search for `needle`, returning the number of matches.
    /// Replaces any search in flight. Any thread.
    pub fn searchBegin(self: *Session, needle: []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.searchEndLocked();
        if (needle.len == 0) return 0;
        const s = self.term.screens.active;
        self.search = vt.search.Screen.init(self.gpa, s, needle) catch return 0;
        self.search_of = s;
        self.search.?.searchAll() catch {};
        const n = self.search.?.matchesLen();
        if (n == 0) self.searchEndLocked();
        return n;
    }

    /// Move to the next (older) or previous (newer) match: select it and
    /// bring it into view. `rows` is the pane height, used to place the
    /// hit rather than glue it to the top edge. Any thread.
    pub fn searchSelect(self: *Session, next: bool, rows: u16) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const s = self.term.screens.active;
        // Alt screen swap under us: the results describe a screen you
        // are no longer looking at.
        if (self.search_of != s) {
            self.searchEndLocked();
            return false;
        }
        const sr = if (self.search) |*p| p else return false;
        if (!(sr.select(if (next) .next else .prev) catch return false)) return false;
        const hl = sr.selectedMatch() orelse return false;
        const u = hl.untracked();
        s.select(.init(u.start, u.end, false)) catch {};
        // Place the hit HALF A SCREEN DOWN rather than at the top edge.
        // Done as an absolute row (which the library clamps at both
        // ends) and not as scroll-to-pin-then-up: a match already near
        // the bottom would scroll clean off the viewport that way.
        if (s.pages.pointFromPin(.screen, u.start)) |pt| {
            s.scroll(.{ .row = pt.screen.y -| @as(u32, @max(1, rows / 2)) });
        } else s.scroll(.{ .pin = u.start });
        return true;
    }

    /// Which match is selected (1-based) and how many there are.
    pub fn searchWhere(self: *Session) struct { idx: usize, n: usize } {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sr = if (self.search) |*p| p else return .{ .idx = 0, .n = 0 };
        const sel = sr.selected orelse return .{ .idx = 0, .n = sr.matchesLen() };
        return .{ .idx = sel.idx + 1, .n = sr.matchesLen() };
    }

    pub fn searchEnd(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.searchEndLocked();
    }

    fn searchEndLocked(self: *Session) void {
        if (self.search) |*sr| sr.deinit();
        self.search = null;
        self.search_of = null;
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

    /// `scrollback` is in BYTES, the emulator's own unit — it rounds up
    /// to a page and floors at one page's worth of the active area, so
    /// small values don't mean small in any exact sense.
    /// `cmd`, when given, is what the shell runs instead of going
    /// interactive — the pane lives as long as the command does. It goes
    /// through the shell rather than being exec'd directly because the
    /// caller supplies a command LINE (quoting, pipes, `&&`), and because
    /// -l still sources the profile that puts things on PATH.
    pub fn start(gpa: std.mem.Allocator, io: anytype, shell: [*:0]const u8, cwd: ?[*:0]const u8, cmd: ?[*:0]const u8, colors: vt.Terminal.Colors, cols: u16, rows: u16, cell_w_px: u32, cell_h_px: u32, scrollback: usize) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .term = try .init(io, gpa, .{
                .cols = cols,
                .rows = rows,
                .colors = colors,
                .max_scrollback = scrollback,
            }),
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
        if (cmd) |c| {
            const argv = [_][*:0]const u8{ shell, "-l", "-c", c };
            self.pid = try self.pty.spawnIn(&argv, cwd);
        } else {
            const argv = [_][*:0]const u8{ shell, "-l" };
            self.pid = try self.pty.spawnIn(&argv, cwd);
        }

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
        if (self.clip_buf.len > 0) self.gpa.free(self.clip_buf);
        // Before the terminal: the search untracks pins IN the screen.
        self.searchEndLocked();
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
            .bell = &effectBell,
            .desktop_notification = &effectNotify,
            .clipboard_write = &effectClipboardWrite,
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
            self.last_out_ms.store(clockMs(), .monotonic);
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

    /// BEL. Fires on the reader thread with the mutex held, so it does
    /// exactly one thing: raise a flag. Everything the bell actually
    /// MEANS — a dock bounce, a chip dot, a beep — is AppKit's, and
    /// belongs on the main thread.
    fn effectBell(h: *Handler) void {
        fromHandler(h).bell.store(true, .release);
    }

    /// OSC 9 / OSC 777. Same thread and same rule as the bell: copy what
    /// we need (the slices die with the call) and let the main thread
    /// decide what a notification means.
    fn effectNotify(h: *Handler, title: []const u8, body: []const u8) void {
        const self = fromHandler(h);
        self.notify_title_len = @min(title.len, self.notify_title.len);
        @memcpy(self.notify_title[0..self.notify_title_len], title[0..self.notify_title_len]);
        self.notify_body_len = @min(body.len, self.notify_body.len);
        @memcpy(self.notify_body[0..self.notify_body_len], body[0..self.notify_body_len]);
        self.notify_pending = true;
    }

    /// OSC 52. The library hands this over already base64-decoded and
    /// with the destination normalised, and it never forwards clipboard
    /// READ requests at all — so nothing on this path can leak the
    /// user's clipboard back to the program. Only writes get here.
    ///
    /// Every destination collapses to the one pasteboard: macOS has no
    /// primary selection, and `*` and `+` are already the same register
    /// in vim on this platform. Honouring `p` as something separate
    /// would invent a clipboard the OS doesn't have.
    fn effectClipboardWrite(
        h: *Handler,
        w: EffectArg("clipboard_write", 1),
    ) EffectRet("clipboard_write") {
        const self = fromHandler(h);
        if (!self.clip_allow) return .denied;

        // No contents = clear. Otherwise take the text representation;
        // the library only ever produces text/plain today, but it hands
        // us a list, so read it as one rather than assuming contents[0].
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
        // XTVERSION (CSI > 0 q) — what `echo $TERM_PROGRAM_VERSION`-style
        // probes and ghostty's own feature detection read.
        return "rook " ++ @import("build_options").version;
    }

    fn effectColorScheme(_: *Handler) EffectRet("color_scheme") {
        return .dark;
    }

    pub fn write(self: *Session, bytes: []const u8) void {
        self.pty.writeMaster(bytes) catch {};
    }

    /// The name of the program currently reading this pty — `nvim`, or
    /// `bash` when the shell is at its prompt. Null when there is no
    /// foreground group or the lookup fails; the caller decides what
    /// silence means, and for the ⌃HJKL check it means "not one of
    /// yours", so an unanswerable question costs a key nothing.
    ///
    /// Cheap enough to ask on the keystroke: two syscalls, no
    /// allocation, no cache to go stale. That last part is the point.
    /// The webview app answered this from a 3s `fg` poll and got it
    /// wrong for three seconds after every `vim`; the Zig app then
    /// answered it from the alternate screen, which was exact but
    /// asked the wrong question — plenty of full-screen programs have
    /// no splits to protect.
    ///
    /// Note the pgid, not the pid: the foreground process GROUP leader
    /// is the program the tty is talking to. A pipeline reports its
    /// first command, which is the right answer for this question.
    pub fn fgName(self: *Session, buf: []u8) ?[]const u8 {
        const pgrp = tcgetpgrp(self.pty.master);
        if (pgrp <= 0) return null;
        var path: [proc_pidpathinfo_maxsize]u8 = undefined;
        const n = proc_pidpath(pgrp, &path, path.len);
        if (n <= 0) return null;
        const base = std.fs.path.basename(path[0..@intCast(n)]);
        if (base.len == 0 or base.len > buf.len) return null;
        @memcpy(buf[0..base.len], base);
        return buf[0..base.len];
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
            std.debug.print("rook: terminal resize failed: {}\n", .{err});
        };
        self.mutex.unlock();
        self.pty.setSize(.{ .ws_row = rows, .ws_col = cols }) catch {};
    }
};
