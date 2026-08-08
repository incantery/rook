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

// GCD semaphores, for the read pipeline's ring. Zig 0.16 retired
// std.Thread's Mutex/Condition; these are the mac-native primitive the
// app already stands on elsewhere (dispatch_async_f in macos.zig), and
// a bounded SPSC ring wants counting semaphores anyway.
extern "c" fn dispatch_semaphore_create(value: isize) ?*anyopaque;
extern "c" fn dispatch_semaphore_wait(sem: *anyopaque, timeout: u64) isize;
extern "c" fn dispatch_semaphore_signal(sem: *anyopaque) isize;
extern "c" fn dispatch_release(obj: *anyopaque) void;
const dispatch_time_forever: u64 = ~@as(u64, 0);
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

/// The state shared between the read pipeline's two stages: a fixed
/// ring of buffers plus the metadata that rotates ownership between
/// the gather thread (fills) and the parse thread (consumes). A buffer
/// belongs to exactly one stage at a time, so buffer CONTENTS need no
/// lock — only the ring metadata does. Ported from ghostty's termio
/// pipeline (#13209 and the bb0ac4c72 idle-wake fix, MIT); the
/// constants are theirs, each one measured, and none of the reasoning
/// behind them is machine-specific enough to re-derive.
const Pipeline = struct {
    /// Ring depth: how many batches the gather stage may run ahead of
    /// the parse stage before it blocks — which, via the kernel pty
    /// queue, is also what keeps flow control on the child. Ghostty
    /// measured: below 4 minor slowdowns, above 4 nothing.
    const buffer_count = 4;
    /// One batch is also the unit of work per terminal-lock hold, so
    /// this bounds both gather latency and lock hold time.
    const buffer_capacity = 64 * 1024;
    /// Gathering a full kernel queue's worth (~1KiB on macOS) means
    /// the writer is saturated and worth briefly waiting on; anything
    /// smaller is an interactive trickle that must deliver at once.
    const bridge_threshold = 1024;
    /// Nonblocking re-read retries before sleeping in poll: the
    /// writer's refill usually lands within microseconds, and a spin
    /// bridges most gaps for the cost of a ~0.5µs syscall each.
    const bridge_spin_max = 16;
    /// One bridge poll's wait for the writer's next refill.
    const bridge_poll_timeout_ms = 1;
    /// The most one batch may spend bridging before it delivers
    /// regardless — well under a display frame, so batching is
    /// invisible on screen.
    const gather_budget_s: f64 = 0.003;

    /// Ghostty guards the ring with a mutex + two condvars; Zig 0.16
    /// retired std.Thread's, so rook's port leans on the shape of the
    /// problem instead: single producer, single consumer. Each stage
    /// OWNS its ring index (head is the gather's, tail is the
    /// parser's — never shared), two GCD semaphores carry the
    /// blocking and the ordering, and one atomic counter answers the
    /// only cross-stage question the idle rule needs ("is the parser
    /// out of work?").
    ///
    /// Counts free slots; the gather waits on it when the ring is
    /// full, which is the backpressure that lets the kernel queue
    /// push back on the child.
    sem_free: ?*anyopaque = null,
    /// Counts published batches, plus one final signal for done.
    sem_ready: ?*anyopaque = null,
    /// Valid bytes per slot, set at publish time; the semaphore
    /// signal orders the write against the parser's read.
    lens: [buffer_count]usize = @splat(0),
    /// Published, unconsumed batches. The idle test: the parser
    /// dropping this to zero while `bridging` is set fires the wake.
    outstanding: std.atomic.Value(i32) = .init(0),
    /// Set while the gather stage sleeps in a bridge poll. The parser
    /// writes the idle pipe only while this is set, so an interactive
    /// terminal never pays the syscalls.
    bridging: std.atomic.Value(bool) = .init(false),
    /// The stream is over; the parser drains the ring and exits.
    done: std.atomic.Value(bool) = .init(false),
    /// The self-pipe that lets the parser interrupt a bridge poll the
    /// moment it runs out of batches — bridging is only free while
    /// the parser is busy. -1 when unavailable; polls then simply
    /// ride out their 1ms timeout.
    idle_read: ptypkg.fd_t = -1,
    idle_write: ptypkg.fd_t = -1,
    bufs: [buffer_count][buffer_capacity]u8 = undefined,

    /// False when the OS refused a semaphore — the caller falls back
    /// to the serial loop.
    fn open(self: *Pipeline) bool {
        self.sem_free = dispatch_semaphore_create(buffer_count);
        self.sem_ready = dispatch_semaphore_create(0);
        if (self.sem_free == null or self.sem_ready == null) {
            self.close();
            return false;
        }
        if (ptypkg.makePipeNb()) |fds| {
            self.idle_read = fds[0];
            self.idle_write = fds[1];
        }
        return true;
    }

    fn close(self: *Pipeline) void {
        // A dispatch semaphore released below its creation value
        // traps (a slot the gather claimed and never published leaves
        // sem_free one short). Both stages are joined by now, so top
        // the count back up — extra signals with no waiter are
        // harmless, a short release is an abort.
        if (self.sem_free) |sem| {
            for (0..buffer_count) |_| _ = dispatch_semaphore_signal(sem);
            dispatch_release(sem);
        }
        if (self.sem_ready) |sem| dispatch_release(sem);
        if (self.idle_read >= 0) {
            ptypkg.closeFd(self.idle_read);
            ptypkg.closeFd(self.idle_write);
        }
    }

    const BridgeEv = enum { data, idle, quiet };

    /// One bridge wait: the pty for the writer's refill, the idle
    /// pipe for the parser running dry. `quiet` means the full
    /// timeout passed (the burst is over) — a poll error reads the
    /// same, deliver and let the read path classify the fd.
    fn bridgePoll(self: *Pipeline, master: ptypkg.fd_t) BridgeEv {
        var fds = [2]ptypkg.Pollfd{
            .{ .fd = master, .events = ptypkg.POLLIN },
            .{ .fd = self.idle_read, .events = ptypkg.POLLIN },
        };
        const n: u32 = if (self.idle_read >= 0) 2 else 1;
        const r = ptypkg.pollMany(&fds, n, bridge_poll_timeout_ms);
        if (r <= 0) return .quiet;
        if (n == 2 and fds[1].revents & ptypkg.POLLIN != 0) {
            ptypkg.drainFd(self.idle_read);
            return .idle;
        }
        return .data;
    }
};

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
    /// Total bytes the child has ever written. A timestamp alone cannot
    /// tell a spinner from a cursor blink — both are "output just now" —
    /// but their RATES differ by an order of magnitude, and a rate needs
    /// two samples of a counter.
    out_bytes: std.atomic.Value(u64) = .init(0),

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
                // Upstream split the cap into bytes and lines; rook's
                // config knob was always bytes, so it stays bytes and
                // the line cap stays at the library's default.
                .max_scrollback_bytes = scrollback,
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

    /// ⌘W teardown. SIGHUP stays first — it is the polite spelling, the
    /// one a shell saves its history on — but it is not teardown on its
    /// own: a foreground job under job control lives in a different
    /// process group and never sees a signal to the shell's, and a job
    /// that traps SIGHUP simply keeps running. So both group ids are
    /// captured HERE, while the master is still open for tcgetpgrp (the
    /// reap path closes it), both get the hangup, and a detached thread
    /// escalates to SIGTERM and then SIGKILL for whatever survives.
    /// The thread carries id VALUES, never `self`: the display-link
    /// reap frees this Session the moment the shell exits, and the
    /// escalation has to outlive that. If the spawn fails we've still
    /// sent the SIGHUPs, which is the whole pre-escalation behaviour.
    pub fn hangup(self: *Session) void {
        const groups = ptypkg.ProcessGroups.capture(self.pty.master, self.pid);
        groups.signal(ptypkg.SIGHUP);
        if (std.Thread.spawn(.{}, ptypkg.ProcessGroups.escalate, .{groups})) |t| t.detach() else |_| {}
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

    /// The parse half of the read pipeline. The old loop here did
    /// blocking_read → lock → parse per read, which on macOS means per
    /// KILOBYTE: the kernel tty queue caps every master read at ~1KiB
    /// no matter the buffer, so every lock, wake and kick was paid 64
    /// times per 64KB — and worse, the child sat blocked on a full
    /// 1KiB queue whenever we were parsing instead of reading. Ghostty
    /// found and fixed the same 2023-vintage loop (#13209); this is
    /// their two-stage shape on rook's session: a gather thread drains
    /// the pty into a ring of large buffers while this thread parses
    /// the previous batch, so the child runs ahead and the per-batch
    /// costs are paid per 64KB instead of per 1KiB.
    fn readLoop(self: *Session) void {
        ptypkg.setQosUserInitiated();
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
            // OSC 9;4 — the ConEmu progress protocol Claude Code
            // emits. Arrived with the 08-07 bump; null until the
            // chrome has somewhere to put it (TODO.md, the roadmap's
            // progress slice — a per-pane progress state the status
            // row and the claude plugin both want).
            .progress_report = null,
        };
        // With an allocator, or OSC 52 clipboard ops are silently
        // dropped — the old initAlloc spelling, now an Options field.
        var stream: vt.TerminalStream = .init(.{ .handler = handler, .allocator = self.gpa });
        defer stream.deinit();

        // The pipeline cannot run on a blocking fd — a blocking read
        // would park the gather thread on a quiet pty. If the fd
        // refuses (it cannot, on a real master), fall back to the old
        // serial loop rather than dying: slower is not broken.
        if (!ptypkg.setNonblock(self.pty.master)) {
            self.readLoopSerial(&stream);
            return;
        }

        var pipeline: Pipeline = .{};
        if (!pipeline.open()) {
            self.readLoopSerial(&stream);
            return;
        }
        defer pipeline.close();
        const gather = std.Thread.spawn(.{}, gatherLoop, .{ self, &pipeline }) catch {
            // No thread, no pipeline (the deferred close handles it).
            // The fd is already non-blocking, so the serial fallback
            // polls instead of blocking.
            self.readLoopSerial(&stream);
            return;
        };
        defer gather.join();

        // The parser's own ring index — single consumer, never shared.
        var tail: usize = 0;
        while (true) {
            _ = dispatch_semaphore_wait(pipeline.sem_ready.?, dispatch_time_forever);
            if (pipeline.outstanding.load(.acquire) == 0) {
                // A ready-signal with nothing published is the done
                // signal (the gather sends exactly one on its way out,
                // after any final batch). The ORDER matters: done is
                // checked only with the ring empty, so a done that
                // lands while batches are still queued cannot drop
                // the tail of the stream.
                if (pipeline.done.load(.acquire)) break;
                continue;
            }
            const batch = pipeline.bufs[tail][0..pipeline.lens[tail]];
            tail = (tail + 1) % Pipeline.buffer_count;

            _ = @import("stats.zig").global.bytes_in.fetchAdd(batch.len, .monotonic);
            self.last_out_ms.store(clockMs(), .monotonic);
            _ = self.out_bytes.fetchAdd(batch.len, .monotonic);
            // Yield to a waiting renderer before re-acquiring. The
            // batch buffer is ours until the slot is released below,
            // so parsing happens with no pipeline state held.
            while (self.snapshot_wanted.load(.acquire)) _ = usleep(50);
            self.mutex.lock();
            stream.nextSlice(batch);
            self.mutex.unlock();

            // Release the slot — and if that emptied the ring while
            // the gather is sitting in a bridge poll, wake it:
            // bridging is only free while this thread is busy, and
            // every microsecond a batch is held past our going idle
            // is added straight to output latency (ghostty's
            // bb0ac4c72, the fps-fire regression).
            const was = pipeline.outstanding.fetchSub(1, .acq_rel);
            _ = dispatch_semaphore_signal(pipeline.sem_free.?);
            if (was == 1 and pipeline.bridging.load(.acquire) and pipeline.idle_write >= 0) {
                _ = ptypkg.writeByte(pipeline.idle_write, 'i');
            }

            if (self.kick) |k| k(self.kick_ctx, self);
        }
        // Child gone. No kick here: the display link ticks at 120fps and
        // collapses the pane on its next pass — kicking from this thread
        // would let collapse (and our own join) run on the dying thread.
        self.exited.store(true, .release);
    }

    /// The pre-pipeline loop, kept as the fallback for a pty that
    /// cannot go non-blocking or a machine that cannot spare a thread.
    /// Handles both fd modes: a dry non-blocking read polls and
    /// retries, a blocking read never says dry.
    fn readLoopSerial(self: *Session, stream: *vt.TerminalStream) void {
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
            _ = @import("stats.zig").global.bytes_in.fetchAdd(n, .monotonic);
            self.last_out_ms.store(clockMs(), .monotonic);
            _ = self.out_bytes.fetchAdd(n, .monotonic);
            while (self.snapshot_wanted.load(.acquire)) _ = usleep(50);
            self.mutex.lock();
            stream.nextSlice(buf[0..n]);
            self.mutex.unlock();
            if (self.kick) |k| k(self.kick_ctx, self);
        }
        self.exited.store(true, .release);
    }

    /// The gather half: drain the kernel's ~1KiB-capped pty queue into
    /// the current ring buffer, bridge the writer's microsecond refill
    /// gaps when the stream is saturated, publish, repeat. Owns all fd
    /// waiting; exits when the child goes away, which tells the parse
    /// half through `done`. Ported from ghostty #13209 + bb0ac4c72,
    /// constants and all — each one was measured there, and none of
    /// the reasoning is machine-specific enough to re-derive.
    fn gatherLoop(self: *Session, pipeline: *Pipeline) void {
        ptypkg.setQosUserInitiated();
        // However we exit, the parser has to hear the stream is over:
        // exactly one ready-signal with nothing published, after any
        // final batch.
        defer {
            pipeline.done.store(true, .release);
            _ = dispatch_semaphore_signal(pipeline.sem_ready.?);
        }

        // The gather's own ring index — single producer, never shared.
        var head: usize = 0;
        while (true) {
            // Claim the next free buffer. Blocking here means the
            // parse stage is a full ring behind — exactly when reading
            // should stop and the kernel queue should push back on
            // the child.
            _ = dispatch_semaphore_wait(pipeline.sem_free.?, dispatch_time_forever);
            const buf: *[Pipeline.buffer_capacity]u8 = &pipeline.bufs[head];

            var total: usize = 0;
            var spins: usize = 0;
            var bridge_began: ?f64 = null;
            var gone = false;

            gather: while (total < Pipeline.buffer_capacity) {
                switch (self.pty.readMasterNb(buf[total..])) {
                    .got => |n| {
                        total += n;
                        // Each refill gap gets a fresh spin budget.
                        spins = 0;
                    },
                    .gone => {
                        gone = true;
                        break :gather;
                    },
                    .dry => {
                        // Below the threshold this is an interactive
                        // trickle — a keystroke echo, a prompt — and
                        // it must deliver with no added latency. At or
                        // past it the writer filled the kernel queue:
                        // a bulk stream worth briefly waiting on.
                        if (total < Pipeline.bridge_threshold) break :gather;

                        // The refill usually lands within microseconds;
                        // a bounded burst of retries bridges most gaps
                        // without paying a sleep+wake.
                        if (spins < Pipeline.bridge_spin_max) {
                            spins += 1;
                            continue :gather;
                        }

                        // Still dry — sleep in poll for the refill,
                        // inside a total budget that keeps batching
                        // invisible on screen. The frame loop's own
                        // clock; ns-grade precision is not needed to
                        // bound a millisecond budget.
                        const now = CACurrentMediaTime();
                        if (bridge_began) |began| {
                            if (now - began >= Pipeline.gather_budget_s) break :gather;
                        } else bridge_began = now;

                        // Bridging is only free while the parser is
                        // busy. If it is already idle, deliver now —
                        // and a request/response writer (frame then
                        // cursor query) is BLOCKED on a reply to data
                        // sitting in this very buffer, so a poll here
                        // would always sleep its full timeout.
                        if (pipeline.outstanding.load(.acquire) == 0) break :gather;
                        pipeline.bridging.store(true, .release);
                        const ev = pipeline.bridgePoll(self.pty.master);
                        pipeline.bridging.store(false, .release);
                        // Woken by the parser going idle: deliver what
                        // we have; the pty's data waits for the next
                        // batch. Quiet for the whole timeout: the
                        // burst is over. Otherwise there is data (or
                        // HUP, which the next read maps to gone).
                        if (ev == .idle or ev == .quiet) break :gather;
                        continue :gather;
                    },
                }
            }

            if (total > 0) {
                pipeline.lens[head] = total;
                head = (head + 1) % Pipeline.buffer_count;
                _ = pipeline.outstanding.fetchAdd(1, .release);
                _ = dispatch_semaphore_signal(pipeline.sem_ready.?);
            } else if (!gone) {
                // Nothing gathered and the stream lives: the claimed
                // slot goes back unused, or the free count drifts down
                // by one per empty wake and the ring slowly wedges.
                _ = dispatch_semaphore_signal(pipeline.sem_free.?);
            }
            if (gone) return;

            // A full buffer means the stream is hot: claim the next
            // slot with no intervening wait. Otherwise park until the
            // pty has data again. HUP with no data pending is the
            // child gone; with data pending, drain first and let the
            // read report it.
            if (total == Pipeline.buffer_capacity) continue;
            const ev = ptypkg.pollOne(self.pty.master, ptypkg.POLLIN, -1);
            if (ev & ptypkg.POLLIN == 0 and ev & (ptypkg.POLLHUP | ptypkg.POLLERR) != 0) return;
        }
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
    /// decide what a notification means. The struct argument is
    /// upstream's spelling of what began as rook's fork patch — the
    /// bump that deleted the fork traded two slices for one struct,
    /// named through EffectArg because the Action type has no public
    /// spelling through lib_vt (same story as clipboard.Write).
    fn effectNotify(h: *Handler, n: EffectArg("desktop_notification", 1)) void {
        const self = fromHandler(h);
        self.notify_title_len = @min(n.title.len, self.notify_title.len);
        @memcpy(self.notify_title[0..self.notify_title_len], n.title[0..self.notify_title_len]);
        self.notify_body_len = @min(n.body.len, self.notify_body.len);
        @memcpy(self.notify_body[0..self.notify_body_len], n.body[0..self.notify_body_len]);
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
        const p = self.fgPath(buf) orelse return null;
        const base = std.fs.path.basename(p);
        std.mem.copyForwards(u8, buf[0..base.len], base);
        return buf[0..base.len];
    }

    /// The full executable path of the same program. The basename can be
    /// meaningless on its own — Claude Code's versioned install runs as a
    /// binary literally named `2.1.220` — and the path is what still says
    /// whose it is. Same two syscalls.
    pub fn fgPath(self: *Session, buf: []u8) ?[]const u8 {
        const pgrp = tcgetpgrp(self.pty.master);
        if (pgrp <= 0) return null;
        var path: [proc_pidpathinfo_maxsize]u8 = undefined;
        const n = proc_pidpath(pgrp, &path, path.len);
        if (n <= 0) return null;
        const p = path[0..@intCast(n)];
        if (p.len == 0 or p.len > buf.len) return null;
        @memcpy(buf[0..p.len], p);
        return buf[0..p.len];
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

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "the pipeline delivers every batch, in order, under backpressure" {
    // The ring's contract, exercised without a pty: a producer
    // publishes more batches than the ring holds (so the free-slot
    // wait must engage), a consumer verifies content and order, and
    // the done signal ends the stream exactly once.
    var pipeline: Pipeline = .{};
    try testing.expect(pipeline.open());
    defer pipeline.close();

    const rounds = Pipeline.buffer_count * 5;
    const Producer = struct {
        fn run(p: *Pipeline) void {
            var head: usize = 0;
            for (0..rounds) |i| {
                _ = dispatch_semaphore_wait(p.sem_free.?, dispatch_time_forever);
                const buf = &p.bufs[head];
                // A patterned batch whose length and bytes both encode
                // its sequence number.
                const len = 128 + i;
                @memset(buf[0..len], @intCast(i % 251));
                p.lens[head] = len;
                head = (head + 1) % Pipeline.buffer_count;
                _ = p.outstanding.fetchAdd(1, .release);
                _ = dispatch_semaphore_signal(p.sem_ready.?);
            }
            p.done.store(true, .release);
            _ = dispatch_semaphore_signal(p.sem_ready.?);
        }
    };
    const t = try std.Thread.spawn(.{}, Producer.run, .{&pipeline});
    defer t.join();

    var tail: usize = 0;
    var seen: usize = 0;
    while (true) {
        _ = dispatch_semaphore_wait(pipeline.sem_ready.?, dispatch_time_forever);
        if (pipeline.outstanding.load(.acquire) == 0) {
            if (pipeline.done.load(.acquire)) break;
            continue;
        }
        const batch = pipeline.bufs[tail][0..pipeline.lens[tail]];
        tail = (tail + 1) % Pipeline.buffer_count;
        try testing.expectEqual(@as(usize, 128 + seen), batch.len);
        for (batch) |b| try testing.expectEqual(@as(u8, @intCast(seen % 251)), b);
        seen += 1;
        _ = pipeline.outstanding.fetchSub(1, .acq_rel);
        _ = dispatch_semaphore_signal(pipeline.sem_free.?);
    }
    try testing.expectEqual(rounds, seen);
}

test "a real shell's stream survives the pipeline end to end" {
    // The smoke test the ring test cannot be: a genuine pty, megabytes
    // of bulk output saturating the gather's bridge path, then EOF —
    // the whole two-thread lifecycle including the orderly shutdown.
    const gpa = testing.allocator;
    const s = try Session.start(
        gpa,
        testing.io,
        "/bin/sh",
        null,
        // 2MB of x then a marker: bulk enough to rotate the ring many
        // times over, and the marker's arrival proves the tail of the
        // stream was not lost in the teardown race.
        "dd if=/dev/zero bs=1024 count=2048 2>/dev/null | tr '\\0' 'x'; printf DONEMARK",
        .default,
        80,
        24,
        8,
        16,
        64 * 1024,
    );
    defer s.deinit();

    // Park the parser briefly the way a renderer snapshot would: the
    // gather then runs AHEAD — ring filling, backpressure engaging,
    // the paths a keeping-up parser never visits.
    s.snapshot_wanted.store(true, .release);
    _ = usleep(200_000);
    s.snapshot_wanted.store(false, .release);

    // The command exits on its own; exited flips when the gather sees
    // EOF and the parser drains. Bounded wait, honest failure.
    var waited_ms: usize = 0;
    while (!s.exited.load(.acquire) and waited_ms < 30_000) {
        _ = usleep(10_000);
        waited_ms += 10;
    }
    try testing.expect(s.exited.load(.acquire));
    // Every byte reached the PARSER (out_bytes counts what was handed
    // to the stream, not what was read off the fd).
    try testing.expect(s.out_bytes.load(.monotonic) >= 2 * 1024 * 1024);

    // And the marker made it through to the terminal itself, asked
    // the way copy-mode's `/` asks.
    const hits = s.searchBegin("DONEMARK");
    s.searchEnd();
    try testing.expect(hits > 0);
}
