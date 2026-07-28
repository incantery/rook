//! rookz — experimental native rook in Zig on libghostty-vt.
//!
//! Subcommands:
//!   demo            headless proof: bytes → vt → screen dump
//!   exec <cmd...>   run a command under a real PTY, dump the final screen

const std = @import("std");
const vt = @import("ghostty-vt");
const ptypkg = @import("pty.zig");

pub fn main(init: std.process.Init) !void {
    const argv = init.minimal.args.vector;
    const cmd: []const u8 = if (argv.len > 1) std.mem.span(argv[1]) else "demo";

    if (std.mem.eql(u8, cmd, "demo")) return demo(init);
    if (std.mem.eql(u8, cmd, "exec")) return exec(init, argv[2..]);
    if (std.mem.eql(u8, cmd, "win")) {
        var app = try @import("macos.zig").App.init();
        app.run();
        return;
    }

    std.debug.print("usage: rookz [demo|exec <cmd...>|win]\n", .{});
    return error.UnknownCommand;
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
