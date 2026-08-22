//! The rook-mux server: panes, layout, clients, one poll loop. Reader
//! threads parse pty output into each pane's Terminal and poke the
//! self-pipe; this loop snapshots dirty panes and pushes frames to
//! every attached client.
const std = @import("std");
const vt = @import("ghostty-vt");
const ptypkg = @import("pty.zig");
const panepkg = @import("pane.zig");
const layoutpkg = @import("layout.zig");
const renderpkg = @import("render.zig");
const proto = @import("proto.zig");

const prefix_key: u8 = 0x02; // C-b

const Client = struct {
    fd: ptypkg.fd_t,
    reader: proto.Reader,
    cols: u16 = 80,
    rows: u16 = 24,
    attached: bool = false,
    prefix: bool = false,
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    listener: ptypkg.fd_t,
    sock_path: []const u8,
    panes: std.ArrayList(*panepkg.Pane) = .empty,
    layout: layoutpkg.Layout,
    focused: u32 = 0,
    next_id: u32 = 1,
    clients: std.ArrayList(*Client) = .empty,
    wake_r: ptypkg.fd_t,
    wake_w: ptypkg.fd_t,
    frame: renderpkg.Frame,
    placed: std.ArrayList(layoutpkg.Placed) = .empty,
    shell: [:0]const u8,
    cwd: ?[:0]const u8,

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
            .layout = layoutpkg.Layout.init(gpa),
            .wake_r = pipefds[0],
            .wake_w = pipefds[1],
            .frame = renderpkg.Frame.init(gpa),
            .shell = shell,
            .cwd = cwd,
        };
        defer self.deinitAll();

        // First pane exists before the first client attaches.
        try self.spawnPane(null, true);
        try self.loop();
    }

    fn deinitAll(self: *Server) void {
        for (self.clients.items) |c| {
            ptypkg.closeFd(c.fd);
            c.reader.deinit();
            self.gpa.destroy(c);
        }
        self.clients.deinit(self.gpa);
        for (self.panes.items) |p| {
            p.hangup();
        }
        for (self.panes.items) |p| p.deinit();
        self.panes.deinit(self.gpa);
        self.layout.deinit();
        self.frame.deinit();
        self.placed.deinit(self.gpa);
        ptypkg.unlinkPath(self.sock_path);
    }

    fn spawnPane(self: *Server, split_from: ?u32, side_by_side: bool) !void {
        const geo = self.paneGeometryGuess();
        const p = try panepkg.Pane.start(self.gpa, self.io, self.shell.ptr, if (self.cwd) |c| c.ptr else null, geo.cols, geo.rows, self.wake_w, self.next_id);
        try self.panes.append(self.gpa, p);
        if (split_from) |at| {
            try self.layout.split(at, p.id, side_by_side);
        } else {
            try self.layout.seed(p.id);
        }
        self.focused = p.id;
        self.next_id += 1;
        try self.relayout();
    }

    fn paneGeometryGuess(self: *Server) struct { cols: u16, rows: u16 } {
        var cols: u16 = 80;
        var rows: u16 = 24;
        for (self.clients.items) |c| {
            if (c.attached) {
                cols = c.cols;
                rows = c.rows -| 1;
            }
        }
        return .{ .cols = cols, .rows = rows };
    }

    fn geometry(self: *Server) proto.Geometry {
        var g: proto.Geometry = .{ .cols = 80, .rows = 24 };
        for (self.clients.items) |c| {
            if (c.attached) {
                g = .{ .cols = c.cols, .rows = c.rows };
            }
        }
        return g;
    }

    /// Recompute rects and push sizes into panes.
    fn relayout(self: *Server) !void {
        const g = self.geometry();
        self.placed.clearRetainingCapacity();
        try self.layout.place(.{ .x = 0, .y = 0, .w = g.cols, .h = g.rows -| 1 }, &self.placed);
        for (self.placed.items) |pl| {
            if (self.pane(pl.pane)) |p| {
                if (p.cols != pl.rect.w or p.rows != pl.rect.h) p.resize(pl.rect.w, pl.rect.h);
            }
        }
    }

    fn pane(self: *Server, id: u32) ?*panepkg.Pane {
        for (self.panes.items) |p| {
            if (p.id == id) return p;
        }
        return null;
    }

    fn loop(self: *Server) !void {
        var fds: std.ArrayList(ptypkg.Pollfd) = .empty;
        defer fds.deinit(self.gpa);
        while (true) {
            fds.clearRetainingCapacity();
            try fds.append(self.gpa, .{ .fd = self.wake_r, .events = ptypkg.POLLIN });
            try fds.append(self.gpa, .{ .fd = self.listener, .events = ptypkg.POLLIN });
            for (self.clients.items) |c| {
                try fds.append(self.gpa, .{ .fd = c.fd, .events = ptypkg.POLLIN });
            }
            const n = ptypkg.pollMany(fds.items.ptr, @intCast(fds.items.len), 1000);
            if (n < 0) continue;

            // 1. wake pipe: pty output or a pane exit
            if (fds.items[0].revents & ptypkg.POLLIN != 0) {
                var drain: [256]u8 = undefined;
                _ = ptypkg.readNb(self.wake_r, &drain);
            }

            // 2. new client (grows clients; fds was sized before, so
            // client handling below matches by fd, never by index)
            if (fds.items[1].revents & ptypkg.POLLIN != 0) self.accept();

            // 3. client input
            for (fds.items[2..]) |pfd| {
                if (pfd.revents == 0) continue;
                const idx = self.clientIndex(pfd.fd) orelse continue;
                const c = self.clients.items[idx];
                if (pfd.revents & (ptypkg.POLLHUP | ptypkg.POLLERR) != 0 or !self.serveClient(c)) {
                    self.dropClient(idx);
                }
            }

            // 4. reap exited panes
            try self.reap();
            if (self.panes.items.len == 0) return;

            // 5. redraw
            try self.redraw();
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
                @intFromEnum(proto.c2s.attach) => {
                    if (proto.Geometry.decode(msg.payload)) |g| {
                        c.cols = g.cols;
                        c.rows = g.rows;
                        c.attached = true;
                        self.relayout() catch {};
                        self.forceRedraw();
                    }
                },
                @intFromEnum(proto.c2s.resize) => {
                    if (proto.Geometry.decode(msg.payload)) |g| {
                        c.cols = g.cols;
                        c.rows = g.rows;
                        self.relayout() catch {};
                        self.forceRedraw();
                    }
                },
                @intFromEnum(proto.c2s.stdin) => self.input(c, msg.payload),
                @intFromEnum(proto.c2s.detach) => return false,
                else => {},
            }
        }
        return true;
    }

    var force_redraw: bool = false;
    fn forceRedraw(_: *Server) void {
        force_redraw = true;
    }

    /// Route stdin: prefix commands here, everything else to the
    /// focused pane.
    fn input(self: *Server, c: *Client, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            if (c.prefix) {
                c.prefix = false;
                self.command(c, rest[0]);
                rest = rest[1..];
                continue;
            }
            const idx = std.mem.indexOfScalar(u8, rest, prefix_key) orelse {
                self.toFocused(rest);
                return;
            };
            if (idx > 0) self.toFocused(rest[0..idx]);
            c.prefix = true;
            rest = rest[idx + 1 ..];
        }
    }

    fn toFocused(self: *Server, bytes: []const u8) void {
        if (self.pane(self.focused)) |p| p.write(bytes);
    }

    fn command(self: *Server, c: *Client, key: u8) void {
        switch (key) {
            prefix_key => self.toFocused(&[_]u8{prefix_key}),
            'v', '|' => self.spawnPane(self.focused, true) catch {},
            '-' => self.spawnPane(self.focused, false) catch {},
            'h' => self.move(-1, 0),
            'l' => self.move(1, 0),
            'j' => self.move(0, 1),
            'k' => self.move(0, -1),
            'x' => if (self.pane(self.focused)) |p| p.hangup(),
            'd' => {
                proto.write(c.fd, @intFromEnum(proto.s2c.exit), "") catch {};
                c.attached = false;
            },
            else => {},
        }
        force_redraw = true;
    }

    fn move(self: *Server, dx: i32, dy: i32) void {
        if (layoutpkg.navigate(self.placed.items, self.focused, dx, dy)) |id| self.focused = id;
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
            _ = self.layout.remove(p.id);
            if (self.focused == p.id and self.panes.items.len > 1) {
                for (self.panes.items) |q| {
                    if (q.id != p.id) {
                        self.focused = q.id;
                        break;
                    }
                }
            }
            p.deinit();
            _ = self.panes.swapRemove(i);
            removed = true;
        }
        if (removed) {
            try self.relayout();
            force_redraw = true;
        }
    }

    fn redraw(self: *Server) !void {
        var any_dirty = force_redraw;
        for (self.panes.items) |p| {
            p.snapshot() catch continue;
            if (p.rs.dirty != .false) any_dirty = true;
            p.rs.dirty = .false;
        }
        if (!any_dirty) return;
        force_redraw = false;

        const g = self.geometry();
        var status_buf: [128]u8 = undefined;
        const status = std.fmt.bufPrint(&status_buf, "rook-mux · {d} pane{s} · C-b v/- split · hjkl move · x kill · d detach", .{
            self.panes.items.len,
            if (self.panes.items.len == 1) "" else "s",
        }) catch "rook-mux";

        const bytes = self.frame.build(self.panes.items, self.placed.items, self.focused, g.cols, g.rows, status);
        for (self.clients.items) |c| {
            if (!c.attached) continue;
            proto.write(c.fd, @intFromEnum(proto.s2c.draw), bytes) catch {};
        }
    }
};
