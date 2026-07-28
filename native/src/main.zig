//! rookz — experimental native rook in Zig on libghostty-vt.
//!
//! Subcommands:
//!   demo            headless proof: bytes → vt → screen dump
//!   exec <cmd...>   run a command under a real PTY, dump the final screen

const std = @import("std");
const vt = @import("ghostty-vt");
const ptypkg = @import("pty.zig");

extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]const u8;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub fn main(init: std.process.Init) !void {
    const argv = init.minimal.args.vector;
    // No subcommand = the app (a Dock launch has no argv to give, or
    // hands us flags like -psn_… / --no-activate directly).
    const cmd: []const u8 = if (argv.len > 1 and argv[1][0] != '-') std.mem.span(argv[1]) else "win";

    if (std.mem.eql(u8, cmd, "demo")) return demo(init);
    if (std.mem.eql(u8, cmd, "exec")) return exec(init, argv[2..]);
    if (std.mem.eql(u8, cmd, "edit")) return edit(argv[2..]);
    if (std.mem.eql(u8, cmd, "win")) {
        // Dock/Finder launches start at "/" — a terminal's shells
        // belong in $HOME.
        var cwdbuf: [1024]u8 = undefined;
        if (getcwd(&cwdbuf, cwdbuf.len)) |cwd| {
            if (cwd[0] == '/' and cwd[1] == 0) {
                if (getenv("HOME")) |home| _ = chdir(home);
            }
        }
        const app = try @import("macos.zig").App.create(init);
        const flag_start: usize = if (argv.len > 1 and argv[1][0] == '-') 1 else 2;
        for (argv[@min(flag_start, argv.len)..]) |arg| {
            if (std.mem.eql(u8, std.mem.span(arg), "--no-activate")) app.activate = false;
        }
        app.run();
        return;
    }

    std.debug.print("usage: rookz [win|edit <file>|demo|exec <cmd...>]\n", .{});
    return error.UnknownCommand;
}

const sockaddr_un = extern struct {
    sun_len: u8 = 0,
    sun_family: u8 = 1, // AF_UNIX
    sun_path: [104]u8 = @splat(0),
};
extern "c" fn socket(domain: c_int, tp: c_int, protocol: c_int) c_int;
extern "c" fn connect(fd: c_int, addr: *const sockaddr_un, len: u32) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;

/// `rookz edit <file>` — the dogfood door: from a shell inside rookz,
/// open the file in an editor pane of THIS instance (shells inherit
/// ROOKZ_SOCK, so a dev instance's shells talk to the dev socket).
fn edit(args: []const [*:0]const u8) !void {
    if (args.len == 0) {
        std.debug.print("usage: rookz edit <file>\n", .{});
        return error.MissingPath;
    }
    const path = std.mem.span(args[0]);

    // The app resolves relative paths against ITS cwd — make ours
    // absolute before sending.
    var abs_buf: [1024 + 1200]u8 = undefined;
    var abs: []const u8 = path;
    if (path.len == 0 or path[0] != '/') {
        var cwdbuf: [1024]u8 = undefined;
        const cwd = getcwd(&cwdbuf, cwdbuf.len) orelse return error.NoCwd;
        abs = try std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ std.mem.span(cwd), path });
    }

    const sock_env = getenv("ROOKZ_SOCK");
    const sock: []const u8 = if (sock_env) |sp| std.mem.span(sp) else "/tmp/rookz.sock";

    const fd = socket(1, 1, 0); // AF_UNIX, SOCK_STREAM
    if (fd < 0) return error.SocketFailed;
    defer _ = close(fd);
    var addr: sockaddr_un = .{};
    if (sock.len >= addr.sun_path.len) return error.PathTooLong;
    @memcpy(addr.sun_path[0..sock.len], sock);
    if (connect(fd, &addr, @sizeOf(sockaddr_un)) != 0) {
        std.debug.print("rookz edit: no app listening on {s} (is rookz running?)\n", .{sock});
        return error.ConnectFailed;
    }

    var msg_buf: [2400]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "edit {s}\n", .{abs});
    var off: usize = 0;
    while (off < msg.len) {
        const n = write(fd, msg.ptr + off, msg.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
    var reply_buf: [256]u8 = undefined;
    const n = read(fd, &reply_buf, reply_buf.len);
    if (n > 0 and !std.mem.startsWith(u8, reply_buf[0..@intCast(n)], "ok")) {
        std.debug.print("rookz edit: {s}", .{reply_buf[0..@intCast(n)]});
        return error.EditFailed;
    }
}

fn demo(init: std.process.Init) !void {
    var t: vt.Terminal = try .init(init.io, init.gpa, .{ .cols = 80, .rows = 24 });
    defer t.deinit(init.gpa);

    var stream = t.vtStream();
    defer stream.deinit();

    stream.nextSlice("rookz \x1b[1;32malive\x1b[0m on libghostty-vt\r\n");
    stream.nextSlice("wide: \xe4\xbd\xa0\xe5\xa5\xbd  emoji: \xf0\x9f\x91\xbb\r\n");
    stream.nextSlice("\x1b[38;2;137;180;250mtruecolor\x1b[0m and \x1b[7mreverse\x1b[0m\r\n");

    const str = try t.plainString(init.gpa);
    defer init.gpa.free(str);
    std.debug.print("{s}\n", .{str});
}

fn exec(init: std.process.Init, cmd_argv: []const [*:0]const u8) !void {
    if (cmd_argv.len == 0) {
        std.debug.print("usage: rookz exec <cmd...>\n", .{});
        return error.MissingCommand;
    }

    const cols: u16 = 80;
    const rows: u16 = 24;

    var t: vt.Terminal = try .init(init.io, init.gpa, .{ .cols = cols, .rows = rows });
    defer t.deinit(init.gpa);
    var stream = t.vtStream();
    defer stream.deinit();

    var pty = try ptypkg.Pty.open(.{ .ws_row = rows, .ws_col = cols });
    defer pty.deinit();

    ptypkg.setEnv("TERM", "xterm-256color");
    ptypkg.setEnv("COLORTERM", "truecolor");

    const pid = try pty.spawn(cmd_argv);

    // Read pump: master → vt stream, until the child side goes away
    // (EOF or EIO on macOS when the slave closes).
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = pty.readMaster(&buf);
        if (n == 0) break;
        stream.nextSlice(buf[0..n]);
    }

    _ = ptypkg.Pty.wait(pid);

    const str = try t.plainString(init.gpa);
    defer init.gpa.free(str);
    std.debug.print("{s}\n", .{str});
}
