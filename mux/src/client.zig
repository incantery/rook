//! The attach side: raw mode, alt screen, stdin → server, frames →
//! stdout. Dumb on purpose — every decision lives in the server.
const std = @import("std");
const ptypkg = @import("pty.zig");
const proto = @import("proto.zig");

extern "c" fn tcgetattr(fd: c_int, t: *Termios) c_int;
extern "c" fn isatty(fd: c_int) c_int;
extern "c" fn tcsetattr(fd: c_int, opt: c_int, t: *const Termios) c_int;

const Termios = extern struct {
    iflag: c_ulong,
    oflag: c_ulong,
    cflag: c_ulong,
    lflag: c_ulong,
    cc: [20]u8,
    ispeed: c_ulong,
    ospeed: c_ulong,
};

const TCSANOW = 0;
// lflag bits (macOS)
const ECHO: c_ulong = 0x08;
const ICANON: c_ulong = 0x100;
const ISIG: c_ulong = 0x80;
const IEXTEN: c_ulong = 0x400;
// iflag bits
const IXON: c_ulong = 0x200;
const ICRNL: c_ulong = 0x100;
const BRKINT: c_ulong = 0x02;
const INPCK: c_ulong = 0x10;
const ISTRIP: c_ulong = 0x20;
// oflag
const OPOST: c_ulong = 0x01;

const TIOCGWINSZ = 0x40087468;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

var winch = std.atomic.Value(bool).init(false);
fn onWinch(_: c_int) callconv(.c) void {
    winch.store(true, .release);
}
extern "c" fn signal(sig: c_int, f: ?*const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;
const SIGWINCH = 28;

fn winsize() proto.Geometry {
    var ws: ptypkg.Winsize = .{ .ws_row = 24, .ws_col = 80 };
    _ = ioctl(0, TIOCGWINSZ, &ws);
    return .{ .cols = ws.ws_col, .rows = ws.ws_row };
}

/// One-shot: ask the server for stats, print, exit.
pub fn stats(gpa: std.mem.Allocator, sock_path: []const u8) !void {
    const sock = ptypkg.unixConnect(sock_path);
    if (sock < 0) return error.ConnectFailed;
    defer ptypkg.closeFd(sock);
    try proto.write(sock, @intFromEnum(proto.c2s.stats), "");
    _ = ptypkg.setNonblockFd(sock);
    var reader = proto.Reader.init(gpa);
    defer reader.deinit();
    var fds = [1]ptypkg.Pollfd{.{ .fd = sock, .events = ptypkg.POLLIN }};
    var waited: usize = 0;
    while (waited < 2000) : (waited += 100) {
        _ = ptypkg.pollMany(&fds, 1, 100);
        if (!reader.fill(sock)) return error.ServerGone;
        while (reader.next()) |msg| {
            defer reader.consume();
            if (msg.kind == @intFromEnum(proto.s2c.stats_text)) {
                _ = ptypkg.writeAllFd(1, msg.payload);
                return;
            }
        }
    }
    return error.Timeout;
}

/// One-shot: move focus one pane in `dir` ('h'/'j'/'k'/'l'). This is
/// what nvim calls when Ctrl-h/j/k/l hits a window edge.
pub fn nav(sock_path: []const u8, dir: u8) !void {
    const sock = ptypkg.unixConnect(sock_path);
    if (sock < 0) return error.ConnectFailed;
    defer ptypkg.closeFd(sock);
    try proto.write(sock, @intFromEnum(proto.c2s.nav), &[_]u8{dir});
}

/// One-shot: open a popup running `cmd` (via $SHELL -c) over the
/// current window. This is how rook's Go tools open their UIs.
pub fn popup(sock_path: []const u8, cmd: []const u8) !void {
    const sock = ptypkg.unixConnect(sock_path);
    if (sock < 0) return error.ConnectFailed;
    defer ptypkg.closeFd(sock);
    try proto.write(sock, @intFromEnum(proto.c2s.popup), cmd);
}

/// Print the block table (id, session:window, fg, size, cwd).
pub fn blocks(gpa: std.mem.Allocator, sock_path: []const u8) !void {
    const sock = ptypkg.unixConnect(sock_path);
    if (sock < 0) return error.ConnectFailed;
    defer ptypkg.closeFd(sock);
    try proto.write(sock, @intFromEnum(proto.c2s.blocks), "");
    _ = ptypkg.setNonblockFd(sock);
    var reader = proto.Reader.init(gpa);
    defer reader.deinit();
    var fds = [1]ptypkg.Pollfd{.{ .fd = sock, .events = ptypkg.POLLIN }};
    var waited: usize = 0;
    while (waited < 2000) : (waited += 100) {
        _ = ptypkg.pollMany(&fds, 1, 100);
        if (!reader.fill(sock)) return error.ServerGone;
        while (reader.next()) |msg| {
            defer reader.consume();
            if (msg.kind == @intFromEnum(proto.s2c.blocks_text)) {
                _ = ptypkg.writeAllFd(1, msg.payload);
                return;
            }
        }
    }
    return error.Timeout;
}

/// One-shot: print the state snapshot as one line of JSON.
pub fn state(gpa: std.mem.Allocator, sock_path: []const u8) !void {
    return stateFeed(gpa, sock_path, false);
}

/// Subscribe: the snapshot first, then one line per change, forever.
/// A consumer in any language is spawn-read-lines-parse — no polling,
/// no file watching, no framing.
pub fn watch(gpa: std.mem.Allocator, sock_path: []const u8) !void {
    return stateFeed(gpa, sock_path, true);
}

fn stateFeed(gpa: std.mem.Allocator, sock_path: []const u8, subscribe: bool) !void {
    const sock = ptypkg.unixConnect(sock_path);
    if (sock < 0) return error.ConnectFailed;
    defer ptypkg.closeFd(sock);
    try proto.write(sock, @intFromEnum(proto.c2s.state), &[_]u8{if (subscribe) 1 else 0});
    _ = ptypkg.setNonblockFd(sock);
    var reader = proto.Reader.init(gpa);
    defer reader.deinit();
    var fds = [1]ptypkg.Pollfd{.{ .fd = sock, .events = ptypkg.POLLIN }};
    var waited: usize = 0;
    while (subscribe or waited < 2000) : (waited += 100) {
        _ = ptypkg.pollMany(&fds, 1, 100);
        if (!reader.fill(sock)) return if (subscribe) {} else error.ServerGone;
        while (reader.next()) |msg| {
            defer reader.consume();
            if (msg.kind != @intFromEnum(proto.s2c.state_json)) continue;
            // the payload already ends in a newline: one JSON object
            // per line is the whole contract
            if (!ptypkg.writeAllFd(1, msg.payload)) return;
            if (!subscribe) return;
        }
    }
    return error.Timeout;
}

/// Push side-panel models: one `items.push` frame per line of stdin,
/// each sent the moment its line completes. A producer is a program
/// that keeps writing lines — `my-producer | rook-mux side -` is a
/// live rail, not a one-shot — so nothing here waits for EOF before
/// the first frame lands.
///
/// The server answers each frame with a serial, or with the reason it
/// refused one: a producer that pushes into the void and is told
/// nothing debugs by squinting at a rail. Read-your-writes on the last
/// frame is printed at EOF, and only when stdout is not a terminal —
/// the rule every other command follows.
pub fn sidePush(gpa: std.mem.Allocator, sock_path: []const u8) !void {
    const sock = ptypkg.unixConnect(sock_path);
    if (sock < 0) return error.ConnectFailed;
    defer ptypkg.closeFd(sock);
    _ = ptypkg.setNonblockFd(sock); // writeAllFd still writes it all

    var reader = proto.Reader.init(gpa);
    defer reader.deinit();
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);

    var sent: usize = 0;
    var acked: usize = 0;
    var serial: u64 = 0;

    // Replies as they turn up. False means the server hung up.
    const Sink = struct {
        fn drain(rd: *proto.Reader, fd: ptypkg.fd_t, n_acked: *usize, last: *u64) !bool {
            if (!rd.fill(fd)) return false;
            while (rd.next()) |msg| {
                defer rd.consume();
                switch (msg.kind) {
                    @intFromEnum(proto.s2c.ack) => {
                        if (msg.payload.len >= 8) last.* = std.mem.readInt(u64, msg.payload[0..8], .little);
                        n_acked.* += 1;
                    },
                    @intFromEnum(proto.s2c.text) => {
                        _ = ptypkg.writeAllFd(2, "rook-mux: ");
                        _ = ptypkg.writeAllFd(2, msg.payload);
                        return error.PushRejected;
                    },
                    else => {},
                }
            }
            return true;
        }
    };

    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = ptypkg.readNb(0, &chunk); // stdin is blocking: this waits
        if (n <= 0) break; // EOF (or a read error, which reads the same here)
        try pending.appendSlice(gpa, chunk[0..@intCast(n)]);
        while (std.mem.indexOfScalar(u8, pending.items, '\n')) |nl| {
            const line = std.mem.trim(u8, pending.items[0..nl], " \t\r");
            if (line.len > 0) {
                try proto.write(sock, @intFromEnum(proto.c2s.side), line);
                sent += 1;
            }
            const rest = pending.items.len - (nl + 1);
            std.mem.copyForwards(u8, pending.items[0..rest], pending.items[nl + 1 ..]);
            pending.shrinkRetainingCapacity(rest);
        }
        if (!try Sink.drain(&reader, sock, &acked, &serial)) return error.ServerGone;
    }
    // a last line with no newline behind it
    const tail = std.mem.trim(u8, pending.items, " \t\r");
    if (tail.len > 0) {
        try proto.write(sock, @intFromEnum(proto.c2s.side), tail);
        sent += 1;
    }
    if (sent == 0) return error.NoFrames;

    var fds = [1]ptypkg.Pollfd{.{ .fd = sock, .events = ptypkg.POLLIN }};
    var waited: usize = 0;
    while (acked < sent and waited < 2000) : (waited += 100) {
        _ = ptypkg.pollMany(&fds, 1, 100);
        if (!try Sink.drain(&reader, sock, &acked, &serial)) return error.ServerGone;
    }
    if (acked < sent) return error.Timeout;
    if (isatty(1) == 0) {
        var b: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&b, "{{\"ok\":true,\"serial\":{d}}}\n", .{serial}) catch return;
        _ = ptypkg.writeAllFd(1, line);
    }
}

/// One-shot: print a pane's viewport as plain text.
pub fn capture(gpa: std.mem.Allocator, sock_path: []const u8, id: u32) !void {
    const sock = ptypkg.unixConnect(sock_path);
    if (sock < 0) return error.ConnectFailed;
    defer ptypkg.closeFd(sock);
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, id, .little);
    try proto.write(sock, @intFromEnum(proto.c2s.capture), &b);
    _ = ptypkg.setNonblockFd(sock);
    var reader = proto.Reader.init(gpa);
    defer reader.deinit();
    var fds = [1]ptypkg.Pollfd{.{ .fd = sock, .events = ptypkg.POLLIN }};
    var waited: usize = 0;
    while (waited < 2000) : (waited += 100) {
        _ = ptypkg.pollMany(&fds, 1, 100);
        if (!reader.fill(sock)) return error.ServerGone;
        while (reader.next()) |msg| {
            defer reader.consume();
            if (msg.kind == @intFromEnum(proto.s2c.text)) {
                _ = ptypkg.writeAllFd(1, msg.payload);
                return;
            }
        }
    }
    return error.Timeout;
}

/// Raw single-block attach: this terminal becomes block `id` — no
/// chrome, no prefix, near-SSH fidelity. Takes the resize lease.
pub fn rawAttach(gpa: std.mem.Allocator, sock_path: []const u8, id: u32) !void {
    const sock = ptypkg.unixConnect(sock_path);
    if (sock < 0) return error.ConnectFailed;
    defer ptypkg.closeFd(sock);
    _ = ptypkg.setNonblockFd(sock);

    var orig: Termios = undefined;
    if (tcgetattr(0, &orig) != 0) return error.NotATty;
    var raw = orig;
    raw.lflag &= ~(ECHO | ICANON | ISIG | IEXTEN);
    raw.iflag &= ~(IXON | ICRNL | BRKINT | INPCK | ISTRIP);
    raw.oflag &= ~OPOST;
    _ = tcsetattr(0, TCSANOW, &raw);
    defer _ = tcsetattr(0, TCSANOW, &orig);

    _ = ptypkg.writeAllFd(1, "\x1b[?1049h\x1b[2J");
    defer _ = ptypkg.writeAllFd(1, "\x1b[=0;1u\x1b[?1049l\x1b[?25h\x1b[0m");

    _ = signal(SIGWINCH, &onWinch);

    const g = winsize();
    var ab: [9]u8 = undefined;
    std.mem.writeInt(u32, ab[0..4], id, .little);
    std.mem.writeInt(u16, ab[4..6], g.cols, .little);
    std.mem.writeInt(u16, ab[6..8], g.rows, .little);
    ab[8] = 1; // take the lease
    try proto.write(sock, @intFromEnum(proto.c2s.attach_block), &ab);

    var reader = proto.Reader.init(gpa);
    defer reader.deinit();
    _ = ptypkg.setNonblockFd(0);

    var fds = [2]ptypkg.Pollfd{
        .{ .fd = 0, .events = ptypkg.POLLIN },
        .{ .fd = sock, .events = ptypkg.POLLIN },
    };
    while (true) {
        _ = ptypkg.pollMany(&fds, 2, 500);
        if (winch.swap(false, .acq_rel)) {
            proto.write(sock, @intFromEnum(proto.c2s.resize), &winsize().encode()) catch {};
        }
        if (fds[0].revents & ptypkg.POLLIN != 0) {
            var buf: [4096]u8 = undefined;
            const n = ptypkg.readNb(0, &buf);
            if (n > 0) try proto.write(sock, @intFromEnum(proto.c2s.stdin), buf[0..@intCast(n)]);
        }
        if (fds[1].revents & (ptypkg.POLLHUP | ptypkg.POLLERR) != 0) return;
        if (fds[1].revents & ptypkg.POLLIN != 0) {
            if (!reader.fill(sock)) return;
            while (reader.next()) |msg| {
                defer reader.consume();
                switch (msg.kind) {
                    @intFromEnum(proto.s2c.draw) => _ = ptypkg.writeAllFd(1, msg.payload),
                    @intFromEnum(proto.s2c.exit) => return,
                    else => {},
                }
            }
        }
    }
}

/// Session ops. op 'l' lists (prints the reply), 's' switches by
/// name, 'n' creates (or switches to) a named session.
pub fn session(gpa: std.mem.Allocator, sock_path: []const u8, op: u8, name: []const u8) !void {
    const sock = ptypkg.unixConnect(sock_path);
    if (sock < 0) return error.ConnectFailed;
    defer ptypkg.closeFd(sock);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try payload.append(gpa, op);
    try payload.appendSlice(gpa, name);
    try proto.write(sock, @intFromEnum(proto.c2s.session), payload.items);
    _ = ptypkg.setNonblockFd(sock);
    var reader = proto.Reader.init(gpa);
    defer reader.deinit();
    var fds = [1]ptypkg.Pollfd{.{ .fd = sock, .events = ptypkg.POLLIN }};
    var waited: usize = 0;
    while (waited < 2000) : (waited += 100) {
        _ = ptypkg.pollMany(&fds, 1, 100);
        if (!reader.fill(sock)) return error.ServerGone;
        while (reader.next()) |msg| {
            defer reader.consume();
            if (op == 'l' and msg.kind == @intFromEnum(proto.s2c.stats_text)) {
                _ = ptypkg.writeAllFd(1, msg.payload);
                return;
            }
            if (op != 'l' and msg.kind == @intFromEnum(proto.s2c.ack)) {
                // Read-your-writes, without making an interactive
                // pipeline noisy: the serial goes out only when stdout
                // is not a terminal, i.e. when something is reading it.
                if (msg.payload.len >= 8 and isatty(1) == 0) {
                    const serial = std.mem.readInt(u64, msg.payload[0..8], .little);
                    var b: [64]u8 = undefined;
                    const line = std.fmt.bufPrint(&b, "{{\"ok\":true,\"serial\":{d}}}\n", .{serial}) catch return;
                    _ = ptypkg.writeAllFd(1, line);
                }
                return;
            }
        }
    }
    return error.Timeout;
}

/// Ask the server to shut down (HUPs every pane).
pub fn kill(gpa: std.mem.Allocator, sock_path: []const u8) !void {
    _ = gpa;
    const sock = ptypkg.unixConnect(sock_path);
    if (sock < 0) return error.ConnectFailed;
    defer ptypkg.closeFd(sock);
    try proto.write(sock, @intFromEnum(proto.c2s.shutdown), "");
    // give it a beat to act before we drop the connection
    var fds = [1]ptypkg.Pollfd{.{ .fd = sock, .events = ptypkg.POLLIN }};
    _ = ptypkg.pollMany(&fds, 1, 500);
}

pub fn attach(gpa: std.mem.Allocator, sock_path: []const u8) !void {
    const sock = ptypkg.unixConnect(sock_path);
    if (sock < 0) return error.ConnectFailed;
    defer ptypkg.closeFd(sock);
    _ = ptypkg.setNonblockFd(sock);

    // raw mode
    var orig: Termios = undefined;
    if (tcgetattr(0, &orig) != 0) return error.NotATty;
    var raw = orig;
    raw.lflag &= ~(ECHO | ICANON | ISIG | IEXTEN);
    raw.iflag &= ~(IXON | ICRNL | BRKINT | INPCK | ISTRIP);
    raw.oflag &= ~OPOST;
    _ = tcsetattr(0, TCSANOW, &raw);
    defer _ = tcsetattr(0, TCSANOW, &orig);

    // alt screen + SGR mouse on; both restored on the way out
    _ = ptypkg.writeAllFd(1, "\x1b[?1049h\x1b[2J\x1b[?1002;1006h");
    defer _ = ptypkg.writeAllFd(1, "\x1b[=0;1u\x1b[?2004l\x1b[?1004l\x1b[?1002;1006l\x1b[?1049l\x1b[?25h\x1b[0m");

    _ = signal(SIGWINCH, &onWinch);

    try proto.write(sock, @intFromEnum(proto.c2s.attach), &winsize().encode());

    var reader = proto.Reader.init(gpa);
    defer reader.deinit();
    _ = ptypkg.setNonblockFd(0);

    var fds = [2]ptypkg.Pollfd{
        .{ .fd = 0, .events = ptypkg.POLLIN },
        .{ .fd = sock, .events = ptypkg.POLLIN },
    };
    while (true) {
        _ = ptypkg.pollMany(&fds, 2, 500);

        if (winch.swap(false, .acq_rel)) {
            proto.write(sock, @intFromEnum(proto.c2s.resize), &winsize().encode()) catch {};
        }

        if (fds[0].revents & ptypkg.POLLIN != 0) {
            var buf: [4096]u8 = undefined;
            const n = ptypkg.readNb(0, &buf);
            if (n > 0) try proto.write(sock, @intFromEnum(proto.c2s.stdin), buf[0..@intCast(n)]);
        }

        if (fds[1].revents & (ptypkg.POLLHUP | ptypkg.POLLERR) != 0) return;
        if (fds[1].revents & ptypkg.POLLIN != 0) {
            if (!reader.fill(sock)) return;
            while (reader.next()) |msg| {
                defer reader.consume();
                switch (msg.kind) {
                    @intFromEnum(proto.s2c.draw) => _ = ptypkg.writeAllFd(1, msg.payload),
                    @intFromEnum(proto.s2c.exit) => return,
                    else => {},
                }
            }
        }
    }
}
