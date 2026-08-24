//! The rook-mux server: windows of panes, clients, one poll loop.
//! Reader threads parse pty output into each pane's Terminal and poke
//! the self-pipe; this loop snapshots dirty panes and ships frames —
//! dirty rows only, unless something structural (attach, resize,
//! layout, focus, window switch) forces a full repaint.
const std = @import("std");
const vt = @import("ghostty-vt");
const ptypkg = @import("pty.zig");
const panepkg = @import("pane.zig");
const layoutpkg = @import("layout.zig");
const renderpkg = @import("render.zig");
const proto = @import("proto.zig");
const config = @import("config.zig");

// CLOCK_UPTIME_RAW = 8 on macOS; libc-only monotonic clock.
extern "c" fn clock_gettime_nsec_np(clock_id: c_int) u64;
fn nowUs() i64 {
    return @intCast(clock_gettime_nsec_np(8) / 1_000);
}
fn nowMs() i64 {
    return @intCast(clock_gettime_nsec_np(8) / 1_000_000);
}

/// Minimum gap between frames: coalesce a burst (telescope popup,
/// build spew) into ~120fps of frames instead of one per pty read.
const frame_gap_ms: i64 = 8;

const Client = struct {
    fd: ptypkg.fd_t,
    reader: proto.Reader,
    cols: u16 = 80,
    rows: u16 = 24,
    attached: bool = false,
    prefix: bool = false,
    /// Outbound frames the socket would not take without blocking; the
    /// loop drains it on POLLOUT. A stalled glass must never stall the
    /// server (tmux relearned this one the hard way).
    out: std.ArrayList(u8) = .empty,
    out_off: usize = 0,
    dead: bool = false,
    /// Attached to a single block instead of the composed TUI: raw
    /// pty bytes flow down, stdin routes straight to the pane.
    block: ?u32 = null,
    /// Asked for the block table once: gets pushes when it changes.
    wants_blocks: bool = false,
    /// Holds this block's geometry: its resizes win, the TUI layout
    /// stops resizing the pane, everyone else crops.
    lease: bool = false,
};

/// A client more than 32MB behind is not consuming; cut it loose.
const max_client_backlog = 32 * 1024 * 1024;

/// One window: its own split tree, focus, and zoom state. Panes live
/// on the server; the window only holds ids.
const Window = struct {
    layout: layoutpkg.Layout,
    focused: u32 = 0,
    zoomed: bool = false,
};

/// A named workspace: its own windows and current-window index. All
/// attached clients view the server's current session — the one-glass
/// model; per-client views arrive with the structured cell protocol.
const Session = struct {
    name: [32]u8 = @splat(0),
    name_len: usize = 0,
    windows: std.ArrayList(*Window) = .empty,
    cur: usize = 0,
    /// Panes docked to the left rail of this workspace: visible in
    /// every window, stacked vertically, one shared width.
    pins: std.ArrayList(u32) = .empty,
    rail_frac: f32 = 0.4,
    /// Focus lives either on a pinned pane (here) or on the current
    /// window's focused leaf.
    focus_pin: ?u32 = null,
    /// Where focus was before the last move — prefix-; goes back.
    last_focus: ?u32 = null,

    fn label(self: *const Session) []const u8 {
        return self.name[0..self.name_len];
    }
    fn setName(self: *Session, n: []const u8) void {
        self.name_len = @min(n.len, self.name.len);
        @memcpy(self.name[0..self.name_len], n[0..self.name_len]);
    }
};

/// input→frame latency samples, ring of 512.
const Lat = struct {
    samples: [512]i64 = @splat(0),
    n: usize = 0,
    total: u64 = 0,
    mark: i64 = 0, // 0 = no input awaiting a frame

    fn note(self: *Lat) void {
        if (self.mark == 0) self.mark = nowUs();
    }
    fn frame(self: *Lat) void {
        if (self.mark == 0) return;
        self.samples[self.n % self.samples.len] = nowUs() - self.mark;
        self.n += 1;
        self.total += 1;
        self.mark = 0;
    }
    fn pct(self: *Lat, p: f64) i64 {
        const count = @min(self.n, self.samples.len);
        if (count == 0) return 0;
        var sorted: [512]i64 = undefined;
        @memcpy(sorted[0..count], self.samples[0..count]);
        std.mem.sort(i64, sorted[0..count], {}, std.sort.asc(i64));
        const idx: usize = @intFromFloat(@as(f64, @floatFromInt(count - 1)) * p);
        return sorted[idx];
    }
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    listener: ptypkg.fd_t,
    sock_path: []const u8,
    prefix_key: u8,
    conf: config.Mux = .{},
    panes: std.ArrayList(*panepkg.Pane) = .empty,
    sessions: std.ArrayList(*Session) = .empty,
    cur_sess: usize = 0,
    /// Pins that follow you across workspaces (prefix-G on a pin).
    global_pins: std.ArrayList(u32) = .empty,
    /// Column of the rail/window seam in the current layout, if any.
    dock_x: ?u16 = null,
    next_id: u32 = 1,
    clients: std.ArrayList(*Client) = .empty,
    wake_r: ptypkg.fd_t,
    wake_w: ptypkg.fd_t,
    frame: renderpkg.Frame,
    placed: std.ArrayList(layoutpkg.Placed) = .empty,
    shell: [:0]const u8,
    cwd: ?[:0]const u8,
    /// Something structural changed; the next frame repaints all.
    full: bool = true,
    pending: bool = false,
    shutdown: bool = false,
    /// Copy mode (prefix-[): a mux-owned cursor walks the focused
    /// pane and its scrollback; v anchors a selection, y yanks it to
    /// the clipboard. Plain keys navigate until q/Esc.
    scrolling: bool = false,
    scur: struct { x: u16, y: u16 } = .{ .x = 0, .y = 0 },
    selecting: bool = false,
    /// Where the composed cursor last landed on the glass. A bare
    /// cursor move (backspace over trailing blanks emits a lone \b, so
    /// no cell changes) must still ship a frame, or the cursor freezes
    /// until the next content change. Row-dirty alone misses this.
    last_cursor: ?struct { id: u32, x: u16, y: u16, vis: bool } = null,
    /// After a resize the app repaints on SIGWINCH over the next few
    /// ms; that repaint can land in a frame gap or dirty no new cells,
    /// leaving the glass showing the pre-repaint reflow until the next
    /// keypress. A deferred full repaint flushes the settled result.
    /// 0 = none; else the ms deadline to force `full`.
    refresh_at: i64 = 0,
    lat: Lat = .{},
    frames_sent: u64 = 0,
    bytes_sent: u64 = 0,
    started_ms: i64 = 0,
    drag: ?Drag = null,
    /// Kitty keyboard flags currently set on the glass; mirrors the
    /// focused pane so apps that pushed the protocol get real kitty
    /// input, and everything else gets legacy bytes.
    glass_kitty: u8 = 0,
    glass_paste: bool = false,
    glass_focus: bool = false,
    glass_title: [128]u8 = @splat(0),
    glass_title_len: usize = 0,
    /// A floating pane over the current window: all input goes to it,
    /// it closes when its process exits. One at a time.
    popup: ?u32 = null,
    /// Resurrect file: sessions/windows/cwds, saved on structural
    /// change (debounced), restored on server boot. Scrollback is not
    /// saved — that's the event log's job, later.
    state_path: [1024]u8 = @splat(0),
    state_tmp: [1024]u8 = @splat(0),
    state_dirty: bool = false,
    state_saved_ms: i64 = 0,
    /// Last block table sent to subscribers; pushes happen on change.
    blocks_last: std.ArrayList(u8) = .empty,
    blocks_check_ms: i64 = 0,

    pub fn run(gpa: std.mem.Allocator, io: std.Io, sock_path: []const u8, shell: [:0]const u8, cwd: ?[:0]const u8) !void {
        // A socket file with a live server behind it means we must not
        // start; one nobody answers is a stale leftover (crash,
        // reboot) — clear it instead of failing to bind.
        const probe = ptypkg.unixConnect(sock_path);
        if (probe >= 0) {
            ptypkg.closeFd(probe);
            std.debug.print("rook-mux: a server already runs on {s}\n", .{sock_path});
            return error.AlreadyRunning;
        }
        ptypkg.unlinkPath(sock_path);

        const listener = ptypkg.unixListen(sock_path);
        if (listener < 0) {
            std.debug.print("rook-mux: cannot listen on {s} (unix socket paths max ~100 bytes)\n", .{sock_path});
            return error.ListenFailed;
        }
        defer ptypkg.closeFd(listener);

        const pipefds = ptypkg.makePipeNb() orelse return error.PipeFailed;

        // Panes inherit the socket path so `rook-mux nav` (the nvim
        // plugin's edge handoff) talks to the right server.
        const sock_z = try gpa.dupeZ(u8, sock_path);
        defer gpa.free(sock_z);
        ptypkg.setEnv("ROOK_MUX_SOCK", sock_z.ptr);

        var self: Server = .{
            .gpa = gpa,
            .io = io,
            .listener = listener,
            .sock_path = sock_path,
            .prefix_key = config.prefixKey(),
            .conf = config.muxConfig(),
            .wake_r = pipefds[0],
            .wake_w = pipefds[1],
            .frame = renderpkg.Frame.init(gpa),
            .shell = shell,
            .cwd = cwd,
            .started_ms = nowMs(),
        };
        defer self.deinitAll();

        // state file lives beside the socket
        if (std.fmt.bufPrintZ(self.state_path[0 .. self.state_path.len - 1], "{s}.state", .{sock_path})) |_| {
            _ = std.fmt.bufPrintZ(self.state_tmp[0 .. self.state_tmp.len - 1], "{s}.state.tmp", .{sock_path}) catch {};
        } else |_| {}

        self.frame.accent = self.conf.accent;
        // Resurrect only when asked ([mux] restore = true); otherwise a
        // fresh boot opens a clean workspace instead of last session's
        // splits. The state file is still saved, so opting in restores.
        const restored = self.conf.restore and try self.restoreState();
        if (!restored) _ = try self.newSession("main", null);
        try self.loop();
    }

    fn deinitAll(self: *Server) void {
        for (self.clients.items) |c| {
            ptypkg.closeFd(c.fd);
            c.reader.deinit();
            c.out.deinit(self.gpa);
            self.gpa.destroy(c);
        }
        self.clients.deinit(self.gpa);
        for (self.panes.items) |p| p.hangup();
        for (self.panes.items) |p| p.deinit();
        self.panes.deinit(self.gpa);
        for (self.sessions.items) |sn| {
            for (sn.windows.items) |w| {
                w.layout.deinit();
                self.gpa.destroy(w);
            }
            sn.windows.deinit(self.gpa);
            sn.pins.deinit(self.gpa);
            self.gpa.destroy(sn);
        }
        self.sessions.deinit(self.gpa);
        self.global_pins.deinit(self.gpa);
        self.frame.deinit();
        self.placed.deinit(self.gpa);
        self.blocks_last.deinit(self.gpa);
        ptypkg.unlinkPath(self.sock_path);
    }

    // ---- windows and panes ----

    fn sess(self: *Server) *Session {
        return self.sessions.items[self.cur_sess];
    }

    fn window(self: *Server) *Window {
        const sn = self.sess();
        return sn.windows.items[sn.cur];
    }

    /// Create a session named `name` (deduped — an existing name is a
    /// switch) and make it current. `cwd` seeds the first window; null
    /// falls back to the server default.
    fn newSession(self: *Server, name: []const u8, cwd: ?[*:0]const u8) !*Session {
        for (self.sessions.items, 0..) |sn, i| {
            if (std.mem.eql(u8, sn.label(), name)) {
                self.switchSession(i);
                return sn;
            }
        }
        const sn = try self.gpa.create(Session);
        sn.* = .{};
        sn.setName(name);
        try self.sessions.append(self.gpa, sn);
        const old_focused: ?u32 = if (self.sessions.items.len > 1) self.window().focused else null;
        self.cur_sess = self.sessions.items.len - 1;
        try self.newWindow(cwd);
        if (old_focused) |o| self.focusEvents(o, self.window().focused);
        return sn;
    }

    /// Close the named session: hang up every pane in it; reap does
    /// the accounting and the view falls back if it was current.
    fn closeSession(self: *Server, name: []const u8) void {
        for (self.sessions.items) |sn| {
            if (!std.mem.eql(u8, sn.label(), name)) continue;
            for (sn.windows.items) |w| {
                for (self.panes.items) |p| {
                    if (w.layout.contains(p.id)) p.hangup();
                }
            }
            return;
        }
    }

    fn switchSession(self: *Server, i: usize) void {
        if (i == self.cur_sess or i >= self.sessions.items.len) return;
        const old_focused = self.focusedId();
        self.cur_sess = i;
        self.scrolling = false;
        self.selecting = false;
        // a workspace pin that no longer exists can't hold focus
        if (self.sess().focus_pin) |fp| {
            if (self.pane(fp) == null) self.sess().focus_pin = null;
        }
        self.focusEvents(old_focused, self.focusedId());
        self.relayout() catch {};
    }

    fn switchSessionNamed(self: *Server, name: []const u8) void {
        for (self.sessions.items, 0..) |sn, i| {
            if (std.mem.eql(u8, sn.label(), name)) {
                self.switchSession(i);
                return;
            }
        }
    }

    fn newWindow(self: *Server, cwd_override: ?[*:0]const u8) !void {
        const sn = self.sess();
        // an explicit cwd wins; otherwise inherit from what the user
        // is looking at now
        var cwd_buf: [1024]u8 = undefined;
        const cwd = cwd_override orelse (if (sn.windows.items.len > 0) self.focusedCwd(&cwd_buf) else null);
        const prev_focused: ?u32 = if (sn.windows.items.len > 0) self.window().focused else null;
        const w = try self.gpa.create(Window);
        w.* = .{ .layout = layoutpkg.Layout.init(self.gpa) };
        try sn.windows.append(self.gpa, w);
        sn.cur = sn.windows.items.len - 1;
        const p = try self.startPane(cwd);
        try w.layout.seed(p.id);
        w.focused = p.id;
        if (prev_focused) |old_id| self.focusEvents(old_id, p.id);
        try self.relayout();
    }

    fn startPane(self: *Server, cwd: ?[*:0]const u8) !*panepkg.Pane {
        const g = self.geometry();
        const dir: ?[*:0]const u8 = cwd orelse if (self.cwd) |c| c.ptr else null;
        const p = try panepkg.Pane.start(self.gpa, self.io, self.shell.ptr, dir, g.cols, g.rows -| 1, self.wake_w, self.next_id, null, self.conf.scrollback_bytes);
        try self.panes.append(self.gpa, p);
        self.next_id += 1;
        return p;
    }

    /// The popup's outer box, centered: 60% of the screen, clamped.
    fn popupRect(self: *Server) layoutpkg.Rect {
        const g = self.geometry();
        const rows = g.rows -| 1;
        const w: u16 = @max(@min(g.cols, 30), g.cols * 6 / 10);
        const h: u16 = @max(@min(rows, 8), rows * 6 / 10);
        return .{ .x = (g.cols -| w) / 2, .y = (rows -| h) / 2, .w = w, .h = h };
    }

    fn openPopup(self: *Server, cmd: []const u8) !void {
        if (self.popup) |id| {
            // one at a time: a second request replaces the first
            if (self.pane(id)) |p| p.hangup();
        }
        var cwd_buf: [1024]u8 = undefined;
        const cwd = self.focusedCwd(&cwd_buf);
        const r = self.popupRect();
        const cmd_z = try self.gpa.dupeZ(u8, cmd);
        defer self.gpa.free(cmd_z);
        const p = try panepkg.Pane.start(self.gpa, self.io, self.shell.ptr, cwd orelse (if (self.cwd) |c| c.ptr else null), r.w -| 2, r.h -| 2, self.wake_w, self.next_id, cmd_z.ptr, self.conf.scrollback_bytes);
        try self.panes.append(self.gpa, p);
        self.next_id += 1;
        self.popup = p.id;
        self.scrolling = false;
        self.full = true;
        self.pending = true;
    }

    fn popupPane(self: *Server) ?*panepkg.Pane {
        const id = self.popup orelse return null;
        return self.pane(id);
    }

    fn leasedBy(self: *Server, pane_id: u32) ?*Client {
        for (self.clients.items) |c| {
            if (c.block == pane_id and c.lease and !c.dead) return c;
        }
        return null;
    }

    /// Where the focused pane's foreground process lives — new panes
    /// open there, tmux -c '#{pane_current_path}' without the config.
    fn focusedCwd(self: *Server, buf: []u8) ?[*:0]const u8 {
        const p = self.focusedPane() orelse return null;
        const c = p.fgCwd(buf) orelse return null;
        return c.ptr;
    }

    fn splitPane(self: *Server, side_by_side: bool) !void {
        var cwd_buf: [1024]u8 = undefined;
        const cwd = self.focusedCwd(&cwd_buf);
        const w = self.window();
        w.zoomed = false;
        const p = try self.startPane(cwd);
        try w.layout.split(w.focused, p.id, side_by_side);
        self.setFocus(p.id);
        try self.relayout();
    }

    fn pane(self: *Server, id: u32) ?*panepkg.Pane {
        for (self.panes.items) |p| {
            if (p.id == id) return p;
        }
        return null;
    }

    /// The pane input goes to: a focused rail pane, else the current
    /// window's focused leaf.
    fn focusedId(self: *Server) u32 {
        const sn = self.sess();
        return sn.focus_pin orelse self.window().focused;
    }

    fn focusedPane(self: *Server) ?*panepkg.Pane {
        return self.pane(self.focusedId());
    }

    fn isPin(self: *Server, id: u32) bool {
        for (self.global_pins.items) |g| if (g == id) return true;
        for (self.sess().pins.items) |g| if (g == id) return true;
        return false;
    }

    /// Move focus to a pane — rail or window leaf — remembering where
    /// it came from, telling both panes, and repainting.
    fn setFocus(self: *Server, id: u32) void {
        const sn = self.sess();
        const old = self.focusedId();
        if (old == id) return;
        self.focusEvents(old, id);
        sn.last_focus = old;
        if (self.isPin(id)) {
            sn.focus_pin = id;
        } else {
            sn.focus_pin = null;
            self.window().focused = id;
        }
        self.full = true;
        self.pending = true;
    }

    fn geometry(self: *Server) proto.Geometry {
        var g: proto.Geometry = .{ .cols = 80, .rows = 24 };
        for (self.clients.items) |c| {
            if (c.attached) g = .{ .cols = c.cols, .rows = c.rows };
        }
        return g;
    }

    /// Recompute the current window's rects; push sizes into its panes.
    /// A zoomed window is one rect: the focused pane, full region.
    fn relayout(self: *Server) !void {
        const g = self.geometry();
        const region: layoutpkg.Rect = .{ .x = 0, .y = 0, .w = g.cols, .h = g.rows -| 1 };
        self.placed.clearRetainingCapacity();
        const w = self.window();
        const sn = self.sess();
        self.dock_x = null;
        if (w.zoomed) {
            try self.placed.append(self.gpa, .{ .pane = self.focusedId(), .rect = region });
        } else {
            // the rail: global pins then this workspace's, stacked
            // down the left edge; hidden when the glass is too narrow
            // to give the window a real column
            const n_rails = self.global_pins.items.len + sn.pins.items.len;
            var win_region = region;
            if (n_rails > 0 and region.w >= 60) {
                var rail_w: u16 = @intFromFloat(@as(f32, @floatFromInt(region.w)) * sn.rail_frac);
                rail_w = @max(20, @min(rail_w, region.w -| 40));
                const nr: u16 = @intCast(n_rails);
                const each: u16 = (region.h -| (nr - 1)) / nr;
                var y: u16 = region.y;
                var i: u16 = 0;
                for (self.global_pins.items) |id| {
                    const h = if (i == nr - 1) region.h -| (y - region.y) else each;
                    try self.placed.append(self.gpa, .{ .pane = id, .rect = .{ .x = 0, .y = y, .w = rail_w, .h = h } });
                    y += h + 1;
                    i += 1;
                }
                for (sn.pins.items) |id| {
                    const h = if (i == nr - 1) region.h -| (y - region.y) else each;
                    try self.placed.append(self.gpa, .{ .pane = id, .rect = .{ .x = 0, .y = y, .w = rail_w, .h = h } });
                    y += h + 1;
                    i += 1;
                }
                self.dock_x = rail_w;
                win_region = .{ .x = rail_w + 1, .y = region.y, .w = region.w -| (rail_w + 1), .h = region.h };
            }
            try w.layout.place(win_region, &self.placed);
        }
        for (self.placed.items) |pl| {
            if (self.leasedBy(pl.pane) != null) continue; // a block client owns this geometry; the TUI crops
            if (self.pane(pl.pane)) |p| {
                if (p.cols != pl.rect.w or p.rows != pl.rect.h) p.resize(pl.rect.w, pl.rect.h);
            }
        }
        if (self.popupPane()) |p| {
            const r = self.popupRect();
            if (p.cols != r.w -| 2 or p.rows != r.h -| 2) p.resize(r.w -| 2, r.h -| 2);
        }
        self.full = true;
        self.pending = true;
        self.state_dirty = true;
        self.blocks_check_ms = 0; // push the new table promptly
        // and a follow-up clean repaint once the apps' SIGWINCH redraws
        // have landed, so a resize never leaves the glass half-updated
        self.refresh_at = nowMs() + 120;
    }

    // ---- the loop ----

    fn loop(self: *Server) !void {
        var fds: std.ArrayList(ptypkg.Pollfd) = .empty;
        defer fds.deinit(self.gpa);
        var last_frame: i64 = 0;
        while (true) {
            fds.clearRetainingCapacity();
            try fds.append(self.gpa, .{ .fd = self.wake_r, .events = ptypkg.POLLIN });
            try fds.append(self.gpa, .{ .fd = self.listener, .events = ptypkg.POLLIN });
            for (self.clients.items) |c| {
                const ev: i16 = if (c.out_off < c.out.items.len) ptypkg.POLLIN | ptypkg.POLLOUT else ptypkg.POLLIN;
                try fds.append(self.gpa, .{ .fd = c.fd, .events = ev });
            }
            // panes with queued stdin: watch their ptys for room
            const pane_fds_at = fds.items.len;
            for (self.panes.items) |pn| {
                if (pn.pendingIn()) try fds.append(self.gpa, .{ .fd = pn.pty.master, .events = ptypkg.POLLOUT });
            }
            var timeout: c_int = if (self.pending)
                @intCast(@max(0, frame_gap_ms - (nowMs() - last_frame)))
            else
                1000;
            // wake in time to fire a pending post-resize refresh
            if (self.refresh_at != 0) {
                const dt = self.refresh_at - nowMs();
                timeout = @intCast(std.math.clamp(dt, 0, timeout));
            }
            const n = ptypkg.pollMany(fds.items.ptr, @intCast(fds.items.len), timeout);
            if (n < 0) continue;

            if (fds.items[0].revents & ptypkg.POLLIN != 0) {
                var drain: [4096]u8 = undefined;
                while (ptypkg.readNb(self.wake_r, &drain) > 0) {}
                self.pending = true;
            }

            if (fds.items[1].revents & ptypkg.POLLIN != 0) self.accept();

            for (fds.items[2..pane_fds_at]) |pfd| {
                if (pfd.revents == 0) continue;
                const idx = self.clientIndex(pfd.fd) orelse continue;
                const c = self.clients.items[idx];
                if (pfd.revents & ptypkg.POLLOUT != 0) self.flushClient(c);
                // Serve before dropping: a one-shot client (nav) writes
                // and closes, so POLLIN and POLLHUP arrive together and
                // its bytes must still be drained.
                const alive = if (pfd.revents & ptypkg.POLLIN != 0) self.serveClient(c) else true;
                if (!alive or c.dead or pfd.revents & (ptypkg.POLLHUP | ptypkg.POLLERR) != 0) {
                    self.dropClient(idx);
                }
            }

            // drain pane stdin queues that got room
            for (fds.items[pane_fds_at..]) |pfd| {
                if (pfd.revents & ptypkg.POLLOUT == 0) continue;
                for (self.panes.items) |pn| {
                    if (pn.pty.master == pfd.fd) {
                        pn.flushIn();
                        break;
                    }
                }
            }

            // sweep clients marked dead outside the poll dispatch
            // (backlog cap, failed writes from redraw/shipClip)
            var ci: usize = self.clients.items.len;
            while (ci > 0) {
                ci -= 1;
                if (self.clients.items[ci].dead) self.dropClient(ci);
            }

            try self.reap();
            self.forwardTees();
            if (self.sessions.items.len == 0 or self.shutdown) return;

            // a resize's SIGWINCH repaint has had time to arrive: force
            // one clean full frame so the settled result is always shown
            if (self.refresh_at != 0 and nowMs() >= self.refresh_at) {
                self.refresh_at = 0;
                self.full = true;
                self.pending = true;
            }

            if (self.pending and nowMs() - last_frame >= frame_gap_ms) {
                try self.redraw();
                last_frame = nowMs();
                self.pending = false;
            }

            if (nowMs() - self.blocks_check_ms > 2000) {
                self.pushBlocks();
                self.blocks_check_ms = nowMs();
            }

            // structural changes save after 1s; cwds drift without
            // structural events, so refresh every 30s regardless
            const since_save = nowMs() - self.state_saved_ms;
            if ((self.state_dirty and since_save > 1000) or since_save > 30_000) {
                self.saveState();
                self.state_dirty = false;
                self.state_saved_ms = nowMs();
            }
        }
    }

    fn accept(self: *Server) void {
        while (true) {
            const fd = ptypkg.unixAccept(self.listener);
            if (fd < 0) return;
            _ = ptypkg.setNonblockFd(fd);
            const c = self.gpa.create(Client) catch {
                ptypkg.closeFd(fd);
                return;
            };
            c.* = .{ .fd = fd, .reader = proto.Reader.init(self.gpa) };
            self.clients.append(self.gpa, c) catch {
                ptypkg.closeFd(fd);
                self.gpa.destroy(c);
                return;
            };
        }
    }

    fn clientIndex(self: *Server, fd: ptypkg.fd_t) ?usize {
        for (self.clients.items, 0..) |c, i| {
            if (c.fd == fd) return i;
        }
        return null;
    }

    fn dropClient(self: *Server, i: usize) void {
        const c = self.clients.items[i];
        const had_lease = c.lease and c.block != null;
        ptypkg.closeFd(c.fd);
        c.reader.deinit();
        c.out.deinit(self.gpa);
        self.gpa.destroy(c);
        _ = self.clients.swapRemove(i);
        self.updateTees();
        // a departing lease holder hands geometry back to the TUI
        if (had_lease) self.relayout() catch {};
    }

    /// Frame a message onto the client's outbound queue and push what
    /// the socket will take. Never blocks; POLLOUT drains the rest.
    fn sendTo(self: *Server, c: *Client, kind: u8, payload: []const u8) void {
        if (c.dead) return;
        if (c.out.items.len - c.out_off > max_client_backlog) {
            c.dead = true;
            return;
        }
        var hdr: [5]u8 = undefined;
        hdr[0] = kind;
        std.mem.writeInt(u32, hdr[1..5], @intCast(payload.len), .little);
        c.out.appendSlice(self.gpa, &hdr) catch {
            c.dead = true;
            return;
        };
        c.out.appendSlice(self.gpa, payload) catch {
            c.dead = true;
            return;
        };
        self.flushClient(c);
    }

    fn flushClient(self: *Server, c: *Client) void {
        while (c.out_off < c.out.items.len) {
            const n = ptypkg.writeNbFd(c.fd, c.out.items[c.out_off..]) catch {
                c.dead = true;
                return;
            };
            if (n == 0) return; // kernel buffer full
            c.out_off += n;
        }
        c.out_off = 0;
        // a burst can balloon this queue; don't keep the high-water
        // mark as permanent RSS
        if (c.out.capacity > 1024 * 1024) {
            c.out.clearAndFree(self.gpa);
        } else {
            c.out.clearRetainingCapacity();
        }
    }

    /// Returns false when the client is gone. Buffered messages are
    /// processed even at EOF — a one-shot client's last words count.
    fn serveClient(self: *Server, c: *Client) bool {
        const alive = c.reader.fill(c.fd);
        while (c.reader.next()) |msg| {
            defer c.reader.consume();
            switch (msg.kind) {
                @intFromEnum(proto.c2s.attach), @intFromEnum(proto.c2s.resize) => {
                    if (c.block) |bid| {
                        // resize from a block client: only the lease
                        // holder moves the pty
                        if (c.lease) {
                            if (proto.Geometry.decode(msg.payload)) |g| {
                                if (self.pane(bid)) |p| {
                                    p.resize(g.cols, g.rows);
                                    self.full = true;
                                    self.pending = true;
                                }
                            }
                        }
                        continue;
                    }
                    if (proto.Geometry.decode(msg.payload)) |g| {
                        c.cols = g.cols;
                        c.rows = g.rows;
                        c.attached = true;
                        if (self.glass_kitty != 0) {
                            var kb: [16]u8 = undefined;
                            if (std.fmt.bufPrint(&kb, "\x1b[={d};1u", .{self.glass_kitty})) |seq| {
                                self.sendTo(c, @intFromEnum(proto.s2c.draw), seq);
                            } else |_| {}
                        }
                        self.relayout() catch {};
                    }
                },
                @intFromEnum(proto.c2s.stdin) => {
                    if (c.block) |bid| {
                        // block clients speak straight to the pane: no
                        // prefix, no mouse routing, no viewport snap
                        if (self.pane(bid)) |p| p.write(msg.payload);
                    } else self.input(c, msg.payload);
                },
                @intFromEnum(proto.c2s.blocks) => self.sendBlocks(c),
                @intFromEnum(proto.c2s.block_cmd) => self.blockCmd(c, msg.payload),
                @intFromEnum(proto.c2s.attach_block) => self.attachBlock(c, msg.payload),
                @intFromEnum(proto.c2s.session) => {
                    if (msg.payload.len >= 1) {
                        const op = msg.payload[0];
                        const name = msg.payload[1..];
                        switch (op) {
                            'l' => {
                                var lb: [1024]u8 = undefined;
                                var lw: std.ArrayList(u8) = .initBuffer(&lb);
                                for (self.sessions.items) |sn| {
                                    lw.appendSliceBounded(sn.label()) catch break;
                                    lw.appendSliceBounded("\n") catch break;
                                }
                                self.sendTo(c, @intFromEnum(proto.s2c.stats_text), lw.items);
                            },
                            's' => if (name.len > 0) self.switchSessionNamed(name),
                            'n' => if (name.len > 0) {
                                // payload: name[\tcwd]
                                var nm = name;
                                var cwd: ?[*:0]const u8 = null;
                                var cwd_buf: [1024]u8 = undefined;
                                if (std.mem.indexOfScalar(u8, name, '\t')) |tab| {
                                    nm = name[0..tab];
                                    const dir = name[tab + 1 ..];
                                    if (dir.len > 0 and dir.len < cwd_buf.len) {
                                        @memcpy(cwd_buf[0..dir.len], dir);
                                        cwd_buf[dir.len] = 0;
                                        cwd = @ptrCast(&cwd_buf);
                                    }
                                }
                                if (nm.len > 0) _ = self.newSession(nm, cwd) catch {};
                            },
                            'k' => if (name.len > 0) self.closeSession(name),
                            else => {},
                        }
                        self.pending = true;
                    }
                },
                @intFromEnum(proto.c2s.popup) => {
                    if (msg.payload.len > 0) self.openPopup(msg.payload) catch {};
                },
                @intFromEnum(proto.c2s.nav) => {
                    // vim hit a window edge and hands us the move; an
                    // explicit verb, so never forwarded anywhere.
                    if (msg.payload.len == 1) _ = self.navigate(msg.payload[0]);
                },
                @intFromEnum(proto.c2s.detach) => return false,
                @intFromEnum(proto.c2s.stats) => self.sendStats(c),
                @intFromEnum(proto.c2s.shutdown) => {
                    // polite server exit: snapshot state while the
                    // panes still breathe, HUP everything, leave
                    self.saveState();
                    for (self.panes.items) |p| p.hangup();
                    self.shutdown = true;
                },
                else => {},
            }
        }
        return alive;
    }

    /// One line per pane: id, session:window, fg program, cwd. The
    /// web client's block list, and `rook-mux blocks`. Asking once
    /// subscribes the client to pushes when the table changes.
    fn sendBlocks(self: *Server, c: *Client) void {
        c.wants_blocks = true;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        self.buildBlocks(&out);
        self.sendTo(c, @intFromEnum(proto.s2c.blocks_text), out.items);
    }

    fn buildBlocks(self: *Server, out: *std.ArrayList(u8)) void {
        for (self.global_pins.items) |id| self.blockLine(out, id, "global", "pin");
        for (self.sessions.items) |sn| {
            for (sn.pins.items) |id| self.blockLine(out, id, sn.label(), "pin");
        }
        for (self.sessions.items) |sn| {
            for (sn.windows.items, 0..) |w, wi| {
                for (self.panes.items) |p| {
                    if (!w.layout.contains(p.id)) continue;
                    var nb: [64]u8 = undefined;
                    var cb: [1024]u8 = undefined;
                    const fg = p.fgName(&nb) orelse "shell";
                    const cwd: []const u8 = if (p.fgCwd(&cb)) |cc| cc else "";
                    var line: [1200]u8 = undefined;
                    const l = std.fmt.bufPrint(&line, "{d}\t{s}:{d}\t{s}\t{d}x{d}\t{s}\n", .{ p.id, sn.label(), wi + 1, fg, p.cols, p.rows, cwd }) catch continue;
                    out.appendSlice(self.gpa, l) catch return;
                }
            }
        }
    }

    fn blockLine(self: *Server, out: *std.ArrayList(u8), id: u32, place: []const u8, slot: []const u8) void {
        const p = self.pane(id) orelse return;
        var nb: [64]u8 = undefined;
        var cb: [1024]u8 = undefined;
        const fg = p.fgName(&nb) orelse "shell";
        const cwd: []const u8 = if (p.fgCwd(&cb)) |cc| cc else "";
        var line: [1200]u8 = undefined;
        const l = std.fmt.bufPrint(&line, "{d}\t{s}:{s}\t{s}\t{d}x{d}\t{s}\n", .{ p.id, place, slot, fg, p.cols, p.rows, cwd }) catch return;
        out.appendSlice(self.gpa, l) catch {};
    }

    /// Push the block table to subscribers when it changed. Checked
    /// every couple of seconds (fg/cwd drift) and immediately after
    /// structural changes.
    fn pushBlocks(self: *Server) void {
        var any = false;
        for (self.clients.items) |c| {
            if (c.wants_blocks and !c.dead) any = true;
        }
        if (!any) return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        self.buildBlocks(&out);
        if (std.mem.eql(u8, out.items, self.blocks_last.items)) return;
        self.blocks_last.clearRetainingCapacity();
        self.blocks_last.appendSlice(self.gpa, out.items) catch {};
        for (self.clients.items) |c| {
            if (c.wants_blocks and !c.dead) self.sendTo(c, @intFromEnum(proto.s2c.blocks_text), out.items);
        }
    }

    /// Attach this client to one block: [id u32][cols u16][rows u16]
    /// [flags u8: 1 = take the resize lease]. Replies with a full
    /// snapshot, then the raw tee follows.
    fn attachBlock(self: *Server, c: *Client, payload: []const u8) void {
        if (payload.len < 9) return;
        const id = std.mem.readInt(u32, payload[0..4], .little);
        const cols = std.mem.readInt(u16, payload[4..6], .little);
        const rows = std.mem.readInt(u16, payload[6..8], .little);
        const flags = payload[8];
        const p = self.pane(id) orelse {
            self.sendTo(c, @intFromEnum(proto.s2c.exit), "no such block");
            return;
        };
        c.block = id;
        c.attached = false; // never receives composed frames
        if (flags & 1 != 0) {
            for (self.clients.items) |other| {
                if (other.block == id) other.lease = false;
            }
            c.lease = true;
            if (cols > 0 and rows > 0) p.resize(cols, rows);
            self.full = true;
        }
        self.updateTees();
        if (flags & 2 != 0) self.sendBackfill(c, p);
        self.sendSnapshot(c, p);
        self.pending = true;
    }

    /// Scrollback backfill: unwrapped history lines, written before
    /// the snapshot so they land in the client's scrollback (the
    /// snapshot's clear only wipes the viewport). Capped to the last
    /// 256KB on a line boundary.
    fn sendBackfill(self: *Server, c: *Client, p: *panepkg.Pane) void {
        const text = p.historyText(self.gpa) orelse return;
        defer self.gpa.free(@constCast(text));
        var body = text;
        if (body.len > 256 * 1024) {
            body = body[body.len - 256 * 1024 ..];
            if (std.mem.indexOfScalar(u8, body, '\n')) |nl| body = body[nl + 1 ..];
        }
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        out.appendSlice(self.gpa, "\x1b[0m") catch return;
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |line| {
            out.appendSlice(self.gpa, line) catch return;
            out.appendSlice(self.gpa, "\r\n") catch return;
        }
        self.sendTo(c, @intFromEnum(proto.s2c.draw), out.items);
    }

    /// Keep each pane's tee flag equal to "someone is watching".
    fn updateTees(self: *Server) void {
        for (self.panes.items) |p| {
            var on = false;
            for (self.clients.items) |c| {
                if (c.block == p.id and !c.dead) on = true;
            }
            p.tee_on.store(on, .release);
        }
    }

    const BlockLoc = struct { sn: *Session, w: *Window };

    fn findBlock(self: *Server, pane_id: u32) ?BlockLoc {
        for (self.sessions.items) |sn| {
            for (sn.windows.items) |w| {
                if (w.layout.contains(pane_id)) return .{ .sn = sn, .w = w };
            }
        }
        return null;
    }

    /// Typed actions for block clients — the browser's prefix keys.
    /// [op]: 'c' new window in the block's session, 'v'/'-' split the
    /// block's window, 'x' kill the block. Creations reply with the
    /// new block id so the client can hop straight onto it. The
    /// desktop view is never yanked: windows appear in the tab bar,
    /// splits show up if that window is on screen, focus stays put.
    fn blockCmd(self: *Server, c: *Client, payload: []const u8) void {
        if (payload.len < 1) return;
        const bid = c.block orelse return;
        const loc = self.findBlock(bid) orelse return;
        var cwd_buf: [1024]u8 = undefined;
        var cwd: ?[*:0]const u8 = null;
        if (self.pane(bid)) |bp| {
            if (bp.fgCwd(&cwd_buf)) |cc| cwd = cc.ptr;
        }
        switch (payload[0]) {
            'c' => {
                const w = self.gpa.create(Window) catch return;
                w.* = .{ .layout = layoutpkg.Layout.init(self.gpa) };
                loc.sn.windows.append(self.gpa, w) catch {
                    self.gpa.destroy(w);
                    return;
                };
                const p = self.startPane(cwd) catch return;
                w.layout.seed(p.id) catch {};
                w.focused = p.id;
                self.replyCreated(c, p.id);
            },
            'v', '-' => {
                const p = self.startPane(cwd) catch return;
                loc.w.layout.split(bid, p.id, payload[0] == 'v') catch return;
                loc.w.zoomed = false;
                if (loc.w == self.window()) self.relayout() catch {};
                self.replyCreated(c, p.id);
            },
            'x' => if (self.pane(bid)) |p| p.hangup(),
            else => return,
        }
        self.state_dirty = true;
        self.blocks_check_ms = 0; // push the new table promptly
        self.pending = true;
    }

    fn replyCreated(self: *Server, c: *Client, id: u32) void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, id, .little);
        self.sendTo(c, @intFromEnum(proto.s2c.block_created), &b);
    }

    fn sendSnapshot(self: *Server, c: *Client, p: *panepkg.Pane) void {
        p.snapshot() catch return;
        var f = renderpkg.Frame.init(self.gpa);
        defer f.deinit();
        const bytes = f.blockSnapshot(p);
        self.sendTo(c, @intFromEnum(proto.s2c.draw), bytes);
        // blockSnapshot consumed dirty flags the TUI still needs
        self.full = true;
        self.pending = true;
    }

    /// Fan the raw tees out to block clients; an overflow becomes a
    /// fresh snapshot instead of a gap.
    fn forwardTees(self: *Server) void {
        for (self.panes.items) |p| {
            if (!p.tee_on.load(.acquire)) continue;
            const tee = p.takeTee(self.gpa) orelse continue;
            defer self.gpa.free(tee.bytes);
            for (self.clients.items) |c| {
                if (c.block != p.id or c.dead) continue;
                if (tee.overflow) {
                    self.sendSnapshot(c, p);
                } else {
                    self.sendTo(c, @intFromEnum(proto.s2c.draw), tee.bytes);
                }
            }
        }
    }

    fn sendStats(self: *Server, c: *Client) void {
        var buf: [512]u8 = undefined;
        var nwin: usize = 0;
        for (self.sessions.items) |sn| nwin += sn.windows.items.len;
        const text = std.fmt.bufPrint(&buf, "rook-mux up {d}s · {d} session{s} · {d} window{s} · {d} pane{s} · {d} client{s}\nframes {d} · {d:.1} MB shipped\ninput→frame p50 {d}µs · p99 {d}µs · samples {d}\n", .{
            @divTrunc(nowMs() - self.started_ms, 1000),
            self.sessions.items.len,
            plural(self.sessions.items.len),
            nwin,
            plural(nwin),
            self.panes.items.len,
            plural(self.panes.items.len),
            self.clients.items.len,
            plural(self.clients.items.len),
            self.frames_sent,
            @as(f64, @floatFromInt(self.bytes_sent)) / (1024.0 * 1024.0),
            self.lat.pct(0.5),
            self.lat.pct(0.99),
            self.lat.total,
        }) catch "stats: format error";
        self.sendTo(c, @intFromEnum(proto.s2c.stats_text), text);
    }

    /// Route stdin: prefix commands here, scroll-mode keys in scroll
    /// mode, mouse events by position, everything else to the focused
    /// pane.
    fn input(self: *Server, c: *Client, bytes: []const u8) void {
        self.lat.note();
        var rest = bytes;
        while (rest.len > 0) {
            if (c.prefix) {
                c.prefix = false;
                self.command(c, rest[0]);
                rest = rest[1..];
                continue;
            }
            // SGR mouse: ESC [ < btn ; x ; y (M|m)
            if (rest.len >= 3 and rest[0] == 0x1b and rest[1] == '[' and rest[2] == '<') {
                if (parseMouse(rest)) |ev| {
                    self.mouse(ev);
                    rest = rest[ev.len..];
                    continue;
                }
            }
            if (self.scrolling) {
                self.scrollKey(rest[0]);
                rest = rest[1..];
                continue;
            }
            if (rest[0] == self.prefix_key) {
                c.prefix = true;
                rest = rest[1..];
                continue;
            }
            // A lone Ctrl-h/j/k/l is pane navigation, vim-tmux-navigator
            // style: it moves focus (crossing the pin-rail seam too,
            // since the rail is in `placed`), and falls through to the
            // pane when there is nowhere to go — so C-l still clears a
            // rightmost shell, C-j still accepts a line with no pane
            // below. vim and friends own the keys (nav_owners): the
            // plugin hands edge moves back via `rook-mux nav`. Real
            // backspace is 0x7f, unaffected; only a literal Ctrl-H
            // (0x08) is spent on navigation when a left neighbor exists.
            if (bytes.len == 1 and self.popup == null) {
                if (ctrlNavDir(rest[0])) |dir| {
                    if (!self.fgOwnsCtrlNav() and self.navigate(dir)) {
                        rest = rest[1..];
                        continue;
                    }
                }
            }
            // forward up to the next special byte
            var end: usize = rest.len;
            for (rest, 0..) |b, i| {
                if (b == self.prefix_key or b == 0x1b) {
                    if (b == 0x1b and i == 0) {
                        // a lone ESC (or non-mouse CSI): forward it
                        continue;
                    }
                    end = if (b == 0x1b) blk: {
                        // only stop for a potential mouse sequence
                        if (i + 2 < rest.len and rest[i + 1] == '[' and rest[i + 2] == '<') break :blk i;
                        continue;
                    } else i;
                    break;
                }
            }
            self.toFocused(rest[0..end]);
            rest = rest[end..];
        }
    }

    const Mouse = struct { btn: u32, x: u16, y: u16, release: bool, len: usize };

    /// In-flight drag selection: pane id and anchor cell.
    const Drag = struct { pane: u32, ax: u16, ay: u16, moved: bool };

    fn parseMouse(bytes: []const u8) ?Mouse {
        // ESC [ < btn ; x ; y M|m
        var i: usize = 3;
        var nums = [3]u32{ 0, 0, 0 };
        var ni: usize = 0;
        while (i < bytes.len) : (i += 1) {
            const b = bytes[i];
            if (b >= '0' and b <= '9') {
                nums[ni] = nums[ni] * 10 + (b - '0');
            } else if (b == ';') {
                ni += 1;
                if (ni > 2) return null;
            } else if (b == 'M' or b == 'm') {
                if (ni != 2) return null;
                return .{
                    .btn = nums[0],
                    .x = @intCast(@max(1, nums[1])),
                    .y = @intCast(@max(1, nums[2])),
                    .release = b == 'm',
                    .len = i + 1,
                };
            } else return null;
        }
        return null; // incomplete: caller falls through, bytes flushed to pane
    }

    /// A mouse event: click focuses the pane under it; wheel scrolls
    /// the pane (or the event is forwarded, pane-relative, when the
    /// program asked for mouse).
    fn mouse(self: *Server, ev: Mouse) void {
        // find the pane under the pointer (0-based cell coords)
        const cx = ev.x - 1;
        const cy = ev.y - 1;
        if (self.popup != null) {
            const r = self.popupRect();
            const p = self.popupPane() orelse return;
            if (cx > r.x and cx < r.x + r.w -| 1 and cy > r.y and cy < r.y + r.h -| 1) {
                if (p.wantsMouse()) {
                    var mb: [32]u8 = undefined;
                    const ms = std.fmt.bufPrint(&mb, "\x1b[<{d};{d};{d}{c}", .{
                        ev.btn,
                        cx - r.x,
                        cy - r.y,
                        @as(u8, if (ev.release) 'm' else 'M'),
                    }) catch return;
                    p.write(ms);
                } else if (ev.btn == 64) {
                    p.scroll(-3);
                    self.pending = true;
                } else if (ev.btn == 65) {
                    p.scroll(3);
                    self.pending = true;
                }
            }
            return;
        }
        var hit: ?layoutpkg.Placed = null;
        for (self.placed.items) |pl| {
            if (cx >= pl.rect.x and cx < pl.rect.x + pl.rect.w and cy >= pl.rect.y and cy < pl.rect.y + pl.rect.h) hit = pl;
        }
        const pl = hit orelse return;
        const is_press_click = ev.btn < 3 and !ev.release;
        if (is_press_click and pl.pane != self.focusedId()) self.setFocus(pl.pane);
        const p = self.pane(pl.pane) orelse return;
        if (!p.wantsMouse()) {
            // Mux-side text selection, tmux-style: press anchors, drag
            // extends, release copies to the glass (OSC 52) and keeps
            // the highlight.
            const px = cx - pl.rect.x;
            const py = cy - pl.rect.y;
            if (ev.btn == 0 and !ev.release) {
                p.clearSelection();
                self.drag = .{ .pane = pl.pane, .ax = px, .ay = py, .moved = false };
                self.full = true;
                self.pending = true;
                return;
            }
            if (ev.btn == 32) { // motion with left button held
                if (self.drag) |*d| {
                    if (d.pane == pl.pane) {
                        p.setSelection(d.ax, d.ay, px, py);
                        d.moved = true;
                        self.full = true;
                        self.pending = true;
                    }
                }
                return;
            }
            if (ev.btn == 0 and ev.release) {
                if (self.drag) |d| {
                    self.drag = null;
                    if (d.moved) {
                        if (p.selectionText()) |text| {
                            defer self.gpa.free(text);
                            self.shipClip(text);
                        }
                        return;
                    }
                }
                // plain click: nothing more to do (focus already moved)
                return;
            }
        }
        if (p.wantsMouse()) {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{
                ev.btn,
                cx - pl.rect.x + 1,
                cy - pl.rect.y + 1,
                @as(u8, if (ev.release) 'm' else 'M'),
            }) catch return;
            p.write(s);
            return;
        }
        // wheel on a mouse-less pane scrolls its viewport
        if (ev.btn == 64) {
            p.scroll(-3);
            self.full = true;
            self.pending = true;
        } else if (ev.btn == 65) {
            p.scroll(3);
            self.full = true;
            self.pending = true;
        }
    }

    fn toFocused(self: *Server, bytes: []const u8) void {
        if (self.popupPane()) |p| {
            p.write(bytes);
            return;
        }
        if (self.focusedPane()) |p| {
            // typing returns the view to now — a wheel-scrolled pane
            // must not eat keystrokes into an old screen silently
            p.scrollBottom();
            p.write(bytes);
        }
    }

    fn clearDrag(self: *Server) void {
        if (self.drag) |d| {
            if (self.pane(d.pane)) |p| p.clearSelection();
            self.drag = null;
        }
    }

    fn command(self: *Server, c: *Client, key: u8) void {
        if (self.popup != null) {
            switch (key) {
                'x' => if (self.popupPane()) |p| p.hangup(),
                'd' => {
                    self.sendTo(c, @intFromEnum(proto.s2c.exit), "");
                    c.attached = false;
                },
                else => {
                    if (key == self.prefix_key) self.toFocused(&[_]u8{key});
                },
            }
            self.pending = true;
            return;
        }
        switch (key) {
            'v', '|' => self.splitPane(true) catch {},
            '-' => self.splitPane(false) catch {},
            'h', 'j', 'k', 'l' => _ = self.navigate(key),
            'c' => self.newWindow(null) catch {},
            'n' => self.selectWindow((self.sess().cur + 1) % self.sess().windows.items.len),
            'p' => self.selectWindow((self.sess().cur + self.sess().windows.items.len - 1) % self.sess().windows.items.len),
            '1'...'9' => {
                const i: usize = key - '1';
                if (i < self.sess().windows.items.len) self.selectWindow(i);
            },
            's' => self.openPopup("rook-mux ls | fzf --reverse --header='workspace' | xargs -r rook-mux switch") catch {},
            'w' => self.openPopup("rook worktree") catch {},
            'P' => self.togglePin(),
            'G' => self.toggleGlobalPin(),
            ';' => {
                if (self.sess().last_focus) |last| {
                    if (self.pane(last) != null) self.setFocus(last);
                }
            },
            'H' => self.adjustSplit(.horizontal, -0.05),
            'L' => self.adjustSplit(.horizontal, 0.05),
            'K' => self.adjustSplit(.vertical, -0.05),
            'J' => self.adjustSplit(.vertical, 0.05),
            'z' => {
                self.window().zoomed = !self.window().zoomed;
                self.relayout() catch {};
            },
            '[' => self.scrollStart(),
            'o' => self.openPopup("exec $SHELL -l") catch {},
            'x' => if (self.focusedPane()) |p| p.hangup(),
            'd' => {
                self.sendTo(c, @intFromEnum(proto.s2c.exit), "");
                c.attached = false;
            },
            else => {
                // the prefix key itself: double-tap types it literally
                if (key == self.prefix_key) self.toFocused(&[_]u8{key});
            },
        }
        self.pending = true;
    }

    // ---- scroll mode ----

    fn scrollStart(self: *Server) void {
        const p = self.focusedPane() orelse return;
        self.scrolling = true;
        self.selecting = false;
        self.scur = .{ .x = 0, .y = p.rows -| 1 };
        if (p.rs.cursor.visible) {
            if (p.rs.cursor.viewport) |v| self.scur = .{ .x = v.x, .y = v.y };
        }
        self.full = true;
    }

    fn scrollKey(self: *Server, key: u8) void {
        const p = self.focusedPane() orelse {
            self.scrolling = false;
            return;
        };
        const page: i32 = @intCast(@max(1, p.rows / 2));
        const max_y = p.rows -| 1;
        const max_x = p.cols -| 1;
        var moved = false;
        switch (key) {
            'h' => {
                self.scur.x -|= 1;
                moved = true;
            },
            'l' => {
                if (self.scur.x < max_x) self.scur.x += 1;
                moved = true;
            },
            'k' => {
                if (self.scur.y > 0) self.scur.y -= 1 else p.scroll(-1);
                moved = true;
            },
            'j' => {
                if (self.scur.y < max_y) self.scur.y += 1 else p.scroll(1);
                moved = true;
            },
            '0' => {
                self.scur.x = 0;
                moved = true;
            },
            '$' => {
                self.scur.x = max_x;
                moved = true;
            },
            'u' => {
                p.scroll(-page);
                moved = true;
            },
            'd' => {
                p.scroll(page);
                moved = true;
            },
            'g' => {
                p.scrollTop();
                self.scur.y = 0;
                moved = true;
            },
            'G' => {
                p.scrollBottom();
                self.scur.y = max_y;
                moved = true;
            },
            'v' => {
                self.selecting = !self.selecting;
                if (self.selecting) {
                    p.setSelection(self.scur.x, self.scur.y, self.scur.x, self.scur.y);
                } else {
                    p.clearSelection();
                }
            },
            'y' => {
                if (p.selectionText()) |text| {
                    defer self.gpa.free(text);
                    self.shipClip(text);
                }
                p.clearSelection();
                self.selecting = false;
                p.scrollBottom();
                self.scrolling = false;
            },
            'q', 0x1b => {
                p.clearSelection();
                self.selecting = false;
                p.scrollBottom();
                self.scrolling = false;
            },
            else => {},
        }
        if (moved and self.selecting) p.extendSelection(self.scur.x, self.scur.y);
        self.full = true;
        self.pending = true;
    }

    fn adjustSplit(self: *Server, axis: layoutpkg.Axis, delta: f32) void {
        const w = self.window();
        if (w.zoomed) return;
        const sn = self.sess();
        if (sn.focus_pin != null) {
            // focused on the rail: H/L change its width
            if (axis == .horizontal) sn.rail_frac = std.math.clamp(sn.rail_frac + delta, 0.15, 0.7);
        } else {
            layoutpkg.adjust(&w.layout, w.focused, axis, delta);
        }
        self.relayout() catch {};
    }

    fn selectWindow(self: *Server, i: usize) void {
        const sn = self.sess();
        if (i == sn.cur) return;
        const old_focused = self.focusedId();
        sn.cur = i;
        self.scrolling = false;
        self.selecting = false;
        self.focusEvents(old_focused, self.focusedId());
        self.relayout() catch {};
    }

    /// 'h'/'j'/'k'/'l' → directional focus move. Returns true when
    /// focus actually moved (false at an edge, or zoomed).
    fn navigate(self: *Server, dir: u8) bool {
        if (self.window().zoomed) return false;
        const dx: i32 = switch (dir) {
            'h' => -1,
            'l' => 1,
            else => 0,
        };
        const dy: i32 = switch (dir) {
            'k' => -1,
            'j' => 1,
            'h', 'l' => 0,
            else => return false,
        };
        const from = self.focusedId();
        if (layoutpkg.navigate(self.placed.items, from, dx, dy)) |id| {
            if (id != from) {
                self.setFocus(id);
                return true;
            }
        }
        return false;
    }

    /// Tell panes that asked for focus reporting (?1004) when mux
    /// focus moves between them — nvim's FocusGained/autoread food.
    fn focusEvents(self: *Server, old_id: u32, new_id: u32) void {
        if (old_id == new_id) return;
        if (self.pane(old_id)) |p| {
            if (p.modeSet(.focus_event)) p.write("\x1b[O");
        }
        if (self.pane(new_id)) |p| {
            if (p.modeSet(.focus_event)) p.write("\x1b[I");
        }
    }

    /// prefix-P: dock the focused pane to the workspace rail, or put a
    /// docked one back into the current window as a split. A window's
    /// last pane can't be pinned (the window would vanish).
    fn togglePin(self: *Server) void {
        const sn = self.sess();
        const w = self.window();
        const id = self.focusedId();
        if (self.isPin(id)) {
            // unpin: back into the current window beside its focus
            removeId(&self.global_pins, id);
            removeId(&sn.pins, id);
            w.layout.split(w.focused, id, true) catch return;
            sn.focus_pin = null;
            w.focused = id;
        } else {
            if (w.layout.isSingle()) return; // a window's last pane stays
            _ = w.layout.remove(id);
            if (w.focused == id) w.focused = w.layout.firstLeaf() orelse 0;
            sn.pins.append(self.gpa, id) catch return;
            sn.focus_pin = id;
        }
        w.zoomed = false;
        self.relayout() catch {};
    }

    /// prefix-G on a rail pane: toggle between workspace-scoped and
    /// global (follows you across workspaces).
    fn toggleGlobalPin(self: *Server) void {
        const sn = self.sess();
        const id = sn.focus_pin orelse return;
        if (containsId(self.global_pins.items, id)) {
            removeId(&self.global_pins, id);
            sn.pins.append(self.gpa, id) catch return;
        } else {
            removeId(&sn.pins, id);
            self.global_pins.append(self.gpa, id) catch return;
        }
        self.relayout() catch {};
    }

    /// Programs that own Ctrl-h/j/k/l themselves: vim navigates its own
    /// windows first (its plugin calls `rook-mux nav` at an edge), fzf
    /// lives on C-j/C-k.
    fn fgOwnsCtrlNav(self: *Server) bool {
        const p = self.focusedPane() orelse return false;
        var buf: [64]u8 = undefined;
        const name = p.fgName(&buf) orelse return false;
        if (self.conf.owners_len > 0) {
            var it = std.mem.splitScalar(u8, self.conf.ownersSlice(), '\n');
            while (it.next()) |o| {
                if (std.mem.eql(u8, name, o)) return true;
            }
            return false;
        }
        const owners = [_][]const u8{ "nvim", "vim", "vi", "view", "gvim", "vimdiff", "nvimdiff", "fzf" };
        for (owners) |o| {
            if (std.mem.eql(u8, name, o)) return true;
        }
        return false;
    }

    fn reap(self: *Server) !void {
        var i: usize = 0;
        var removed = false;
        while (i < self.panes.items.len) {
            const p = self.panes.items[i];
            if (!p.exited.load(.acquire)) {
                i += 1;
                continue;
            }
            if (self.popup == p.id) {
                self.popup = null;
                self.full = true;
                p.deinit();
                _ = self.panes.swapRemove(i);
                removed = true;
                continue;
            }
            // a pinned pane: drop it from its rail
            removeId(&self.global_pins, p.id);
            for (self.sessions.items) |sn| {
                removeId(&sn.pins, p.id);
                if (sn.focus_pin == p.id) sn.focus_pin = null;
                if (sn.last_focus == p.id) sn.last_focus = null;
            }
            // remove from whichever session's window holds it
            outer: for (self.sessions.items, 0..) |sn, si| {
                var wi: usize = 0;
                while (wi < sn.windows.items.len) : (wi += 1) {
                    const w = sn.windows.items[wi];
                    if (!w.layout.contains(p.id)) continue;
                    const still = w.layout.remove(p.id);
                    if (!still) {
                        w.layout.deinit();
                        self.gpa.destroy(w);
                        _ = sn.windows.orderedRemove(wi);
                        if (sn.cur >= sn.windows.items.len and sn.cur > 0) sn.cur -= 1;
                        if (sn.windows.items.len == 0) {
                            sn.windows.deinit(self.gpa);
                            self.gpa.destroy(sn);
                            _ = self.sessions.orderedRemove(si);
                            if (self.cur_sess >= self.sessions.items.len and self.cur_sess > 0) self.cur_sess -= 1;
                        }
                    } else {
                        w.zoomed = false;
                        if (w.focused == p.id) w.focused = w.layout.firstLeaf() orelse 0;
                    }
                    break :outer;
                }
            }
            // block clients riding this pane get a clean goodbye
            for (self.clients.items) |bc| {
                if (bc.block == p.id) {
                    self.sendTo(bc, @intFromEnum(proto.s2c.exit), "");
                    bc.block = null;
                    bc.lease = false;
                }
            }
            p.deinit();
            _ = self.panes.swapRemove(i);
            removed = true;
        }
        if (removed) self.updateTees();
        if (removed and self.sessions.items.len > 0) try self.relayout();
    }

    fn redraw(self: *Server) !void {
        if (self.popup != null) self.full = true; // popups sit over dirty math
        var any_dirty = self.full;
        for (self.placed.items) |pl| {
            const p = self.pane(pl.pane) orelse continue;
            p.snapshot() catch continue;
            if (p.rs.dirty != .false) any_dirty = true;
            p.rs.dirty = .false;
        }
        if (self.popupPane()) |p| {
            p.snapshot() catch {};
            p.rs.dirty = .false;
        }
        // A bare cursor move dirties no cell (zsh emits a lone \b when
        // backspacing over trailing blanks; a trailing space can land
        // the same way), so row-dirty misses it and the cursor freezes
        // on the glass until the next content change. Ship when the
        // focused cursor moved, too.
        var cur_now: @TypeOf(self.last_cursor) = null;
        if (self.pane(self.focusedId())) |p| {
            const vis = p.rs.cursor.visible;
            if (p.rs.cursor.viewport) |v| {
                cur_now = .{ .id = self.focusedId(), .x = v.x, .y = v.y, .vis = vis };
            } else {
                cur_now = .{ .id = self.focusedId(), .x = 0, .y = 0, .vis = vis };
            }
        }
        if (!std.meta.eql(self.last_cursor, cur_now)) any_dirty = true;
        self.last_cursor = cur_now;
        // OSC 52 from any visible pane goes straight to the glass; the
        // client is dumb, so it rides the draw channel as raw bytes.
        self.forwardClips();
        self.mirrorKitty();

        if (!any_dirty) return;

        const g = self.geometry();
        var status_buf: [256]u8 = undefined;
        const status = self.statusLine(&status_buf);

        var cur_over: ?struct { x: u16, y: u16 } = null;
        if (self.scrolling) {
            for (self.placed.items) |pl| {
                if (pl.pane == self.focusedId()) {
                    cur_over = .{
                        .x = pl.rect.x + @min(self.scur.x, pl.rect.w -| 1),
                        .y = pl.rect.y + @min(self.scur.y, pl.rect.h -| 1),
                    };
                }
            }
        }
        const bytes = self.frame.build(self.panes.items, self.placed.items, self.focusedId(), g.cols, g.rows, status, self.full, if (cur_over) |co| .{ .x = co.x, .y = co.y } else null, if (self.popup) |id| .{ .pane = id, .rect = self.popupRect() } else null, self.dock_x);
        self.full = false;
        var shipped = false;
        for (self.clients.items) |c| {
            if (!c.attached) continue;
            self.sendTo(c, @intFromEnum(proto.s2c.draw), bytes);
            self.bytes_sent += bytes.len;
            shipped = true;
        }
        if (shipped) {
            self.frames_sent += 1;
            self.lat.frame();
        }
    }

    fn forwardClips(self: *Server) void {
        var text_buf: [64 * 1024]u8 = undefined;
        for (self.panes.items) |p| {
            const text = p.takeClip(&text_buf) orelse continue;
            self.shipClip(text);
        }
    }

    /// Keep the glass's kitty keyboard mode equal to the focused
    /// pane's flags. ghostty-vt already tracks the stack and answers
    /// the query per pane; this makes the outer terminal actually
    /// encode input the way that pane was promised. A terminal that
    /// doesn't know CSI = u ignores it.
    fn mirrorKitty(self: *Server) void {
        var buf: [256]u8 = undefined;
        var out: std.ArrayList(u8) = .initBuffer(&buf);
        const fp = self.focusedPane();
        const kf: u8 = if (fp) |p| p.kittyFlags() else 0;
        if (kf != self.glass_kitty) {
            self.glass_kitty = kf;
            var kb: [16]u8 = undefined;
            if (std.fmt.bufPrint(&kb, "\x1b[={d};1u", .{kf})) |seq| {
                out.appendSliceBounded(seq) catch {};
            } else |_| {}
        }
        // bracketed paste and focus reporting ride along: the glass
        // wraps pastes / sends focus in-out only if someone tells it
        const paste = if (fp) |p| p.modeSet(.bracketed_paste) else false;
        if (paste != self.glass_paste) {
            self.glass_paste = paste;
            out.appendSliceBounded(if (paste) "\x1b[?2004h" else "\x1b[?2004l") catch {};
        }
        const focus = if (fp) |p| p.modeSet(.focus_event) else false;
        if (focus != self.glass_focus) {
            self.glass_focus = focus;
            out.appendSliceBounded(if (focus) "\x1b[?1004h" else "\x1b[?1004l") catch {};
        }
        // the outer window is titled by the focused pane (OSC 2)
        var tb: [128]u8 = undefined;
        const t = if (fp) |p| p.title(&tb) else "";
        const shown = if (t.len > 0) t else "rook";
        if (!std.mem.eql(u8, shown, self.glass_title[0..self.glass_title_len])) {
            self.glass_title_len = @min(shown.len, self.glass_title.len);
            @memcpy(self.glass_title[0..self.glass_title_len], shown[0..self.glass_title_len]);
            out.appendSliceBounded("\x1b]2;") catch {};
            out.appendSliceBounded(shown[0..self.glass_title_len]) catch {};
            out.appendSliceBounded("\x07") catch {};
        }
        if (out.items.len == 0) return;
        for (self.clients.items) |c| {
            if (!c.attached) continue;
            self.sendTo(c, @intFromEnum(proto.s2c.draw), out.items);
        }
    }

    /// Send text to every attached glass as OSC 52.
    fn shipClip(self: *Server, text: []const u8) void {
        const b64_len = std.base64.standard.Encoder.calcSize(text.len);
        const b64_buf = self.gpa.alloc(u8, b64_len) catch return;
        defer self.gpa.free(b64_buf);
        const b64 = std.base64.standard.Encoder.encode(b64_buf, text);
        var osc: std.ArrayList(u8) = .empty;
        defer osc.deinit(self.gpa);
        osc.appendSlice(self.gpa, "\x1b]52;c;") catch return;
        osc.appendSlice(self.gpa, b64) catch return;
        osc.appendSlice(self.gpa, "\x07") catch return;
        for (self.clients.items) |c| {
            if (!c.attached) continue;
            self.sendTo(c, @intFromEnum(proto.s2c.draw), osc.items);
        }
    }

    // ---- resurrect: sessions/windows/cwds across server restarts ----

    /// v1 format, line-oriented:
    ///   v1
    ///   session <name> [*]
    ///   window <cwd> [*]
    /// Windows come back as one pane in the saved cwd (splits are
    /// cheap to remake; sessions and cwds are the tedium).
    fn saveState(self: *Server) void {
        if (self.state_path[0] == 0) return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        out.appendSlice(self.gpa, "v1\n") catch return;
        for (self.global_pins.items) |id| {
            var pb: [1024]u8 = undefined;
            var pc: []const u8 = "";
            if (self.pane(id)) |p| {
                if (p.fgCwd(&pb)) |c| pc = c;
            }
            out.appendSlice(self.gpa, "gpin ") catch return;
            out.appendSlice(self.gpa, pc) catch return;
            out.append(self.gpa, '\n') catch return;
        }
        for (self.sessions.items, 0..) |sn, si| {
            out.appendSlice(self.gpa, "session ") catch return;
            out.appendSlice(self.gpa, sn.label()) catch return;
            if (si == self.cur_sess) out.appendSlice(self.gpa, " *") catch return;
            out.append(self.gpa, '\n') catch return;
            for (sn.pins.items) |id| {
                var pb: [1024]u8 = undefined;
                var pc: []const u8 = "";
                if (self.pane(id)) |p| {
                    if (p.fgCwd(&pb)) |c| pc = c;
                }
                out.appendSlice(self.gpa, "pin ") catch return;
                out.appendSlice(self.gpa, pc) catch return;
                out.append(self.gpa, '\n') catch return;
            }
            for (sn.windows.items, 0..) |w, wi| {
                var cwd_buf: [1024]u8 = undefined;
                var cwd: []const u8 = "";
                if (self.pane(w.focused)) |p| {
                    if (p.fgCwd(&cwd_buf)) |c| cwd = c;
                }
                out.appendSlice(self.gpa, "window ") catch return;
                out.appendSlice(self.gpa, cwd) catch return;
                if (wi == sn.cur) out.appendSlice(self.gpa, " *") catch return;
                out.append(self.gpa, '\n') catch return;
            }
        }
        ptypkg.writeFileSmall(@ptrCast(&self.state_path), @ptrCast(&self.state_tmp), out.items);
    }

    /// Rebuild sessions from the state file. False when there is
    /// nothing to restore (caller seeds the default session).
    fn restoreState(self: *Server) !bool {
        if (self.state_path[0] == 0) return false;
        var buf: [64 * 1024]u8 = undefined;
        const data = ptypkg.readFileSmall(@ptrCast(&self.state_path), &buf) orelse return false;
        var lines = std.mem.splitScalar(u8, data, '\n');
        const head = lines.next() orelse return false;
        if (!std.mem.eql(u8, head, "v1")) return false;
        var made_any = false;
        var want_sess: usize = 0;
        var sess_has_window = false;
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "session ")) {
                var name = line["session ".len..];
                const starred = std.mem.endsWith(u8, name, " *");
                if (starred) name = name[0 .. name.len - 2];
                if (name.len == 0) continue;
                const sn = try self.gpa.create(Session);
                sn.* = .{};
                sn.setName(name);
                try self.sessions.append(self.gpa, sn);
                self.cur_sess = self.sessions.items.len - 1;
                if (starred) want_sess = self.cur_sess;
                sess_has_window = false;
                made_any = true;
            } else if (std.mem.startsWith(u8, line, "pin ") or std.mem.startsWith(u8, line, "gpin ")) {
                const is_global = line[0] == 'g';
                const dir = if (is_global) line["gpin ".len..] else line["pin ".len..];
                if (!is_global and self.sessions.items.len == 0) continue;
                var cwd_z: [1024]u8 = undefined;
                const cwd_arg: ?[*:0]const u8 = if (dir.len > 0 and dir.len < cwd_z.len) blk: {
                    @memcpy(cwd_z[0..dir.len], dir);
                    cwd_z[dir.len] = 0;
                    break :blk @ptrCast(&cwd_z);
                } else null;
                const p = try self.startPane(cwd_arg);
                if (is_global) {
                    try self.global_pins.append(self.gpa, p.id);
                } else {
                    try self.sess().pins.append(self.gpa, p.id);
                }
            } else if (std.mem.startsWith(u8, line, "window ") and self.sessions.items.len > 0) {
                var cwd = line["window ".len..];
                const starred = std.mem.endsWith(u8, cwd, " *");
                if (starred) cwd = cwd[0 .. cwd.len - 2];
                var cwd_z: [1024]u8 = undefined;
                const cwd_arg: ?[*:0]const u8 = if (cwd.len > 0 and cwd.len < cwd_z.len) blk: {
                    @memcpy(cwd_z[0..cwd.len], cwd);
                    cwd_z[cwd.len] = 0;
                    break :blk @ptrCast(&cwd_z);
                } else null;
                const sn = self.sess();
                const w = try self.gpa.create(Window);
                w.* = .{ .layout = layoutpkg.Layout.init(self.gpa) };
                try sn.windows.append(self.gpa, w);
                const p = try self.startPane(cwd_arg);
                try w.layout.seed(p.id);
                w.focused = p.id;
                if (starred) sn.cur = sn.windows.items.len - 1;
                sess_has_window = true;
            }
        }
        // a session line with no windows would be an empty shell; give
        // it one so the invariant (every session has a window) holds
        if (made_any and !sess_has_window and self.sess().windows.items.len == 0) {
            try self.newWindow(null);
        }
        if (!made_any) return false;
        // drop any restored session that ended up windowless
        var si: usize = self.sessions.items.len;
        while (si > 0) {
            si -= 1;
            const sn = self.sessions.items[si];
            if (sn.windows.items.len == 0) {
                sn.windows.deinit(self.gpa);
                self.gpa.destroy(sn);
                _ = self.sessions.orderedRemove(si);
            }
        }
        if (self.sessions.items.len == 0) return false;
        self.cur_sess = @min(want_sess, self.sessions.items.len - 1);
        try self.relayout();
        return true;
    }

    /// The tab bar: ♜, then one chip per window named by its focused
    /// pane's foreground program, the current one marked. Scroll and
    /// zoom wear their state on the right.
    fn statusLine(self: *Server, buf: []u8) []const u8 {
        var w2: std.ArrayList(u8) = .initBuffer(buf);
        w2.appendSliceBounded("♜ ") catch {};
        w2.appendSliceBounded(self.sess().label()) catch {};
        if (self.sessions.items.len > 1) {
            var nb: [16]u8 = undefined;
            if (std.fmt.bufPrint(&nb, " ({d})", .{self.sessions.items.len})) |chip| {
                w2.appendSliceBounded(chip) catch {};
            } else |_| {}
        }
        for (self.sess().windows.items, 0..) |w, i| {
            var name_buf: [64]u8 = undefined;
            var name: []const u8 = "shell";
            if (self.pane(w.focused)) |p| {
                // fgName, not title: shell prompts stamp titles at
                // every prompt and go stale while apps run — the
                // foreground program is the truth. The title still
                // reaches the outer window via mirrorKitty.
                if (p.fgName(&name_buf)) |fg| name = fg;
            }
            var chip: [96]u8 = undefined;
            const mark: []const u8 = if (i == self.sess().cur) "*" else " ";
            const s = std.fmt.bufPrint(&chip, "  {d}:{s}{s}", .{ i + 1, name, mark }) catch continue;
            w2.appendSliceBounded(s) catch break;
        }
        if (self.scrolling) {
            w2.appendSliceBounded(if (self.selecting)
                "  [copy · VISUAL: y yanks, v cancels]"
            else
                "  [copy: hjkl/u/d/g/G move, v selects, y yanks, q quits]") catch {};
        }
        if (self.window().zoomed) w2.appendSliceBounded("  [zoom]") catch {};
        return w2.items;
    }
};

fn containsId(list: []const u32, id: u32) bool {
    for (list) |x| if (x == id) return true;
    return false;
}

fn removeId(list: *std.ArrayList(u32), id: u32) void {
    var i: usize = 0;
    while (i < list.items.len) : (i += 1) {
        if (list.items[i] == id) {
            _ = list.orderedRemove(i);
            return;
        }
    }
}

/// The four vim-navigator control bytes → their direction letter.
fn ctrlNavDir(b: u8) ?u8 {
    return switch (b) {
        0x08 => 'h', // C-h
        0x0a => 'j', // C-j (Enter is 0x0d in raw mode, so this is safe)
        0x0b => 'k', // C-k
        0x0c => 'l', // C-l
        else => null,
    };
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}
