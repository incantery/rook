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
};

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
    /// Scroll mode: viewport moved back in the focused pane's
    /// scrollback; plain keys navigate until q/Esc.
    scrolling: bool = false,
    lat: Lat = .{},
    frames_sent: u64 = 0,
    bytes_sent: u64 = 0,
    started_ms: i64 = 0,

    pub fn run(gpa: std.mem.Allocator, io: std.Io, sock_path: []const u8, shell: [:0]const u8, cwd: ?[:0]const u8) !void {
        const listener = ptypkg.unixListen(sock_path);
        if (listener < 0) {
            std.debug.print("rook-mux: cannot listen on {s} (unix socket paths max ~100 bytes)\n", .{sock_path});
            return error.ListenFailed;
        }
        defer ptypkg.closeFd(listener);

        const pipefds = ptypkg.makePipeNb() orelse return error.PipeFailed;

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
        const w = try self.gpa.create(Window);
        w.* = .{ .layout = layoutpkg.Layout.init(self.gpa) };
        try self.windows.append(self.gpa, w);
        self.cur = self.windows.items.len - 1;
        const p = try self.startPane();
        try w.layout.seed(p.id);
        w.focused = p.id;
        try self.relayout();
    }

    fn startPane(self: *Server) !*panepkg.Pane {
        const g = self.geometry();
        const p = try panepkg.Pane.start(self.gpa, self.io, self.shell.ptr, if (self.cwd) |c| c.ptr else null, g.cols, g.rows -| 1, self.wake_w, self.next_id);
        try self.panes.append(self.gpa, p);
        self.next_id += 1;
        return p;
    }

    fn splitPane(self: *Server, side_by_side: bool) !void {
        const w = self.window();
        w.zoomed = false;
        const p = try self.startPane();
        try w.layout.split(w.focused, p.id, side_by_side);
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
                try fds.append(self.gpa, .{ .fd = c.fd, .events = ptypkg.POLLIN });
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

            for (fds.items[2..]) |pfd| {
                if (pfd.revents == 0) continue;
                const idx = self.clientIndex(pfd.fd) orelse continue;
                const c = self.clients.items[idx];
                if (pfd.revents & (ptypkg.POLLHUP | ptypkg.POLLERR) != 0 or !self.serveClient(c)) {
                    self.dropClient(idx);
                }
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
        self.gpa.destroy(c);
        _ = self.clients.swapRemove(i);
    }

    /// Returns false when the client is gone.
    fn serveClient(self: *Server, c: *Client) bool {
        if (!c.reader.fill(c.fd)) return false;
        while (c.reader.next()) |msg| {
            defer c.reader.consume();
            switch (msg.kind) {
                @intFromEnum(proto.c2s.attach), @intFromEnum(proto.c2s.resize) => {
                    if (proto.Geometry.decode(msg.payload)) |g| {
                        c.cols = g.cols;
                        c.rows = g.rows;
                        c.attached = true;
                        self.relayout() catch {};
                    }
                },
                @intFromEnum(proto.c2s.stdin) => self.input(c, msg.payload),
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
        return true;
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
        proto.write(c.fd, @intFromEnum(proto.s2c.stats_text), text) catch {};
    }

    /// Route stdin: prefix commands here, scroll-mode keys in scroll
    /// mode, everything else to the focused pane.
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
            if (self.scrolling) {
                self.scrollKey(rest[0]);
                rest = rest[1..];
                continue;
            }
            const idx = std.mem.indexOfScalar(u8, rest, self.prefix_key) orelse {
                self.toFocused(rest);
                return;
            };
            if (idx > 0) self.toFocused(rest[0..idx]);
            c.prefix = true;
            rest = rest[idx + 1 ..];
        }
    }

    fn toFocused(self: *Server, bytes: []const u8) void {
        if (self.focusedPane()) |p| p.write(bytes);
    }

    fn command(self: *Server, c: *Client, key: u8) void {
        switch (key) {
            'v', '|' => self.splitPane(true) catch {},
            '-' => self.splitPane(false) catch {},
            'h' => self.move(-1, 0),
            'l' => self.move(1, 0),
            'j' => self.move(0, 1),
            'k' => self.move(0, -1),
            'c' => self.newWindow() catch {},
            'n' => self.selectWindow((self.cur + 1) % self.windows.items.len),
            'p' => self.selectWindow((self.cur + self.windows.items.len - 1) % self.windows.items.len),
            '1'...'9' => {
                const i: usize = key - '1';
                if (i < self.windows.items.len) self.selectWindow(i);
            },
            'z' => {
                self.window().zoomed = !self.window().zoomed;
                self.relayout() catch {};
            },
            '[' => self.scrollStart(),
            'x' => if (self.focusedPane()) |p| p.hangup(),
            'd' => {
                proto.write(c.fd, @intFromEnum(proto.s2c.exit), "") catch {};
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
        self.scrolling = true;
        self.full = true;
    }

    fn scrollKey(self: *Server, key: u8) void {
        const p = self.focusedPane() orelse {
            self.scrolling = false;
            return;
        };
        const page: i32 = @intCast(@max(1, p.rows / 2));
        switch (key) {
            'k' => p.scroll(-1),
            'j' => p.scroll(1),
            'u' => p.scroll(-page),
            'd' => p.scroll(page),
            'g' => p.scrollTop(),
            'G' => p.scrollBottom(),
            'q', 0x1b => {
                p.scrollBottom();
                self.scrolling = false;
            },
            else => {},
        }
        self.full = true;
        self.pending = true;
    }

    fn selectWindow(self: *Server, i: usize) void {
        if (i == self.cur) return;
        self.cur = i;
        self.scrolling = false;
        self.relayout() catch {};
    }

    fn move(self: *Server, dx: i32, dy: i32) void {
        const w = self.window();
        if (w.zoomed) return;
        if (layoutpkg.navigate(self.placed.items, w.focused, dx, dy)) |id| {
            if (id != w.focused) {
                w.focused = id;
                self.full = true; // border accents + cursor move
                self.pending = true;
            }
        }
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
        var any_dirty = self.full;
        for (self.placed.items) |pl| {
            const p = self.pane(pl.pane) orelse continue;
            p.snapshot() catch continue;
            if (p.rs.dirty != .false) any_dirty = true;
            p.rs.dirty = .false;
        }
        // OSC 52 from any visible pane goes straight to the glass; the
        // client is dumb, so it rides the draw channel as raw bytes.
        self.forwardClips();

        if (!any_dirty) return;

        const g = self.geometry();
        var status_buf: [256]u8 = undefined;
        const status = self.statusLine(&status_buf);

        const bytes = self.frame.build(self.panes.items, self.placed.items, self.window().focused, g.cols, g.rows, status, self.full);
        self.full = false;
        var shipped = false;
        for (self.clients.items) |c| {
            if (!c.attached) continue;
            proto.write(c.fd, @intFromEnum(proto.s2c.draw), bytes) catch {};
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
            var b64_buf: [96 * 1024]u8 = undefined;
            const b64 = std.base64.standard.Encoder.encode(&b64_buf, text);
            var osc: std.ArrayList(u8) = .empty;
            defer osc.deinit(self.gpa);
            osc.appendSlice(self.gpa, "\x1b]52;c;") catch return;
            osc.appendSlice(self.gpa, b64) catch return;
            osc.appendSlice(self.gpa, "\x07") catch return;
            for (self.clients.items) |c| {
                if (!c.attached) continue;
                proto.write(c.fd, @intFromEnum(proto.s2c.draw), osc.items) catch {};
            }
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
                if (p.fgName(&name_buf)) |fg| name = fg;
            }
            var chip: [96]u8 = undefined;
            const mark: []const u8 = if (i == self.cur) "*" else " ";
            const s = std.fmt.bufPrint(&chip, "  {d}:{s}{s}", .{ i + 1, name, mark }) catch continue;
            w2.appendSliceBounded(s) catch break;
        }
        if (self.scrolling) w2.appendSliceBounded("  [scroll: j/k/u/d/g/G, q quits]") catch {};
        if (self.window().zoomed) w2.appendSliceBounded("  [zoom]") catch {};
        return w2.items;
    }
};

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}
