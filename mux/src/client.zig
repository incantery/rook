//! The attach side: raw mode, alt screen, stdin → server, frames →
//! stdout. Dumb on purpose — every decision lives in the server.
const std = @import("std");
const ptypkg = @import("pty.zig");
const proto = @import("proto.zig");

extern "c" fn tcgetattr(fd: c_int, t: *Termios) c_int;
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
    if (op != 'l') return;
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
