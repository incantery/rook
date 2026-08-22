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
    panes: std.ArrayList(*panepkg.Pane) = .empty,
    windows: std.ArrayList(*Window) = .empty,
    cur: usize = 0,
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

    pub fn run(gpa: std.mem.Allocator, io: std.Io, sock_path: []const u8, shell: [:0]const u8, cwd: ?[:0]const u8) !void {
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
            .wake_r = pipefds[0],
            .wake_w = pipefds[1],
            .frame = renderpkg.Frame.init(gpa),
            .shell = shell,
            .cwd = cwd,
            .started_ms = nowMs(),
        };
        defer self.deinitAll();

        try self.newWindow();
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
        for (self.windows.items) |w| {
            w.layout.deinit();
            self.gpa.destroy(w);
        }
        self.windows.deinit(self.gpa);
        self.frame.deinit();
        self.placed.deinit(self.gpa);
        ptypkg.unlinkPath(self.sock_path);
    }

    // ---- windows and panes ----

    fn window(self: *Server) *Window {
        return self.windows.items[self.cur];
    }

    fn newWindow(self: *Server) !void {
        // inherit the cwd of whatever the user is looking at now
        var cwd_buf: [1024]u8 = undefined;
        const cwd = if (self.windows.items.len > 0) self.focusedCwd(&cwd_buf) else null;
        const prev_focused: ?u32 = if (self.windows.items.len > 0) self.window().focused else null;
        const w = try self.gpa.create(Window);
        w.* = .{ .layout = layoutpkg.Layout.init(self.gpa) };
        try self.windows.append(self.gpa, w);
        self.cur = self.windows.items.len - 1;
        const p = try self.startPane(cwd);
        try w.layout.seed(p.id);
        w.focused = p.id;
        if (prev_focused) |old_id| self.focusEvents(old_id, p.id);
        try self.relayout();
    }

    fn startPane(self: *Server, cwd: ?[*:0]const u8) !*panepkg.Pane {
        const g = self.geometry();
        const dir: ?[*:0]const u8 = cwd orelse if (self.cwd) |c| c.ptr else null;
        const p = try panepkg.Pane.start(self.gpa, self.io, self.shell.ptr, dir, g.cols, g.rows -| 1, self.wake_w, self.next_id, null);
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
        const p = try panepkg.Pane.start(self.gpa, self.io, self.shell.ptr, cwd orelse (if (self.cwd) |c| c.ptr else null), r.w -| 2, r.h -| 2, self.wake_w, self.next_id, cmd_z.ptr);
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
        self.focusEvents(w.focused, p.id);
        w.focused = p.id;
        try self.relayout();
    }

    fn pane(self: *Server, id: u32) ?*panepkg.Pane {
        for (self.panes.items) |p| {
            if (p.id == id) return p;
        }
        return null;
    }

    fn focusedPane(self: *Server) ?*panepkg.Pane {
        return self.pane(self.window().focused);
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
        if (w.zoomed) {
            try self.placed.append(self.gpa, .{ .pane = w.focused, .rect = region });
        } else {
            try w.layout.place(region, &self.placed);
        }
        for (self.placed.items) |pl| {
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
            const timeout: c_int = if (self.pending)
                @intCast(@max(0, frame_gap_ms - (nowMs() - last_frame)))
            else
                1000;
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
            if (self.windows.items.len == 0 or self.shutdown) return;

            if (self.pending and nowMs() - last_frame >= frame_gap_ms) {
                try self.redraw();
                last_frame = nowMs();
                self.pending = false;
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
        ptypkg.closeFd(c.fd);
        c.reader.deinit();
        c.out.deinit(self.gpa);
        self.gpa.destroy(c);
        _ = self.clients.swapRemove(i);
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
                @intFromEnum(proto.c2s.stdin) => self.input(c, msg.payload),
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
                    // polite server exit: HUP everything and leave
                    for (self.panes.items) |p| p.hangup();
                    self.shutdown = true;
                },
                else => {},
            }
        }
        return alive;
    }

    fn sendStats(self: *Server, c: *Client) void {
        var buf: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "rook-mux up {d}s · {d} window{s} · {d} pane{s} · {d} client{s}\nframes {d} · {d:.1} MB shipped\ninput→frame p50 {d}µs · p99 {d}µs · samples {d}\n", .{
            @divTrunc(nowMs() - self.started_ms, 1000),
            self.windows.items.len,
            plural(self.windows.items.len),
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
            // style: vim and friends own the key (vim's plugin hands the
            // edge move back via `rook-mux nav`); everywhere else the mux
            // moves focus, and the key falls through to the pane when
            // there is nowhere to go — C-l still clears a lone shell.
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
        const w = self.window();
        var hit: ?layoutpkg.Placed = null;
        for (self.placed.items) |pl| {
            if (cx >= pl.rect.x and cx < pl.rect.x + pl.rect.w and cy >= pl.rect.y and cy < pl.rect.y + pl.rect.h) hit = pl;
        }
        const pl = hit orelse return;
        const is_press_click = ev.btn < 3 and !ev.release;
        if (is_press_click and pl.pane != w.focused) {
            self.focusEvents(w.focused, pl.pane);
            w.focused = pl.pane;
            self.full = true;
            self.pending = true;
        }
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
            'c' => self.newWindow() catch {},
            'n' => self.selectWindow((self.cur + 1) % self.windows.items.len),
            'p' => self.selectWindow((self.cur + self.windows.items.len - 1) % self.windows.items.len),
            '1'...'9' => {
                const i: usize = key - '1';
                if (i < self.windows.items.len) self.selectWindow(i);
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
        layoutpkg.adjust(&w.layout, w.focused, axis, delta);
        self.relayout() catch {};
    }

    fn selectWindow(self: *Server, i: usize) void {
        if (i == self.cur) return;
        const old_focused = self.window().focused;
        self.cur = i;
        self.scrolling = false;
        self.selecting = false;
        self.focusEvents(old_focused, self.window().focused);
        self.relayout() catch {};
    }

    /// 'h'/'j'/'k'/'l' → directional focus move. Returns true when
    /// focus actually moved (false at an edge, or zoomed).
    fn navigate(self: *Server, dir: u8) bool {
        const w = self.window();
        if (w.zoomed) return false;
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
        if (layoutpkg.navigate(self.placed.items, w.focused, dx, dy)) |id| {
            if (id != w.focused) {
                self.focusEvents(w.focused, id);
                w.focused = id;
                self.full = true; // border accents + cursor move
                self.pending = true;
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

    /// Programs that own Ctrl-h/j/k/l themselves: vim navigates its own
    /// windows first (its plugin calls `rook-mux nav` at an edge), fzf
    /// lives on C-j/C-k.
    fn fgOwnsCtrlNav(self: *Server) bool {
        const p = self.focusedPane() orelse return false;
        var buf: [64]u8 = undefined;
        const name = p.fgName(&buf) orelse return false;
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
            // remove from whichever window holds it
            var wi: usize = 0;
            while (wi < self.windows.items.len) : (wi += 1) {
                const w = self.windows.items[wi];
                if (!w.layout.contains(p.id)) continue;
                const still = w.layout.remove(p.id);
                if (!still) {
                    w.layout.deinit();
                    self.gpa.destroy(w);
                    _ = self.windows.orderedRemove(wi);
                    if (self.cur >= self.windows.items.len and self.cur > 0) self.cur -= 1;
                } else {
                    w.zoomed = false;
                    if (w.focused == p.id) w.focused = w.layout.firstLeaf() orelse 0;
                }
                break;
            }
            p.deinit();
            _ = self.panes.swapRemove(i);
            removed = true;
        }
        if (removed and self.windows.items.len > 0) try self.relayout();
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
                if (pl.pane == self.window().focused) {
                    cur_over = .{
                        .x = pl.rect.x + @min(self.scur.x, pl.rect.w -| 1),
                        .y = pl.rect.y + @min(self.scur.y, pl.rect.h -| 1),
                    };
                }
            }
        }
        const bytes = self.frame.build(self.panes.items, self.placed.items, self.window().focused, g.cols, g.rows, status, self.full, if (cur_over) |co| .{ .x = co.x, .y = co.y } else null, if (self.popup) |id| .{ .pane = id, .rect = self.popupRect() } else null);
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

    /// The tab bar: ♜, then one chip per window named by its focused
    /// pane's foreground program, the current one marked. Scroll and
    /// zoom wear their state on the right.
    fn statusLine(self: *Server, buf: []u8) []const u8 {
        var w2: std.ArrayList(u8) = .initBuffer(buf);
        w2.appendSliceBounded("♜") catch {};
        for (self.windows.items, 0..) |w, i| {
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
            const mark: []const u8 = if (i == self.cur) "*" else " ";
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
