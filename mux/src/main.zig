//! rook-mux: a terminal multiplexer with ghostty-vt in-process.
//!   rook-mux            attach (starting the server if needed)
//!   rook-mux server     run the server in the foreground
//!   rook-mux nav <dir>  move focus h/j/k/l (vim plugins call this at edges)
//!   rook-mux popup <cmd> float a command over the current window
//!   rook-mux ls / switch / new <name> [cwd] / close <name>   workspaces
//!   rook-mux state / watch       the state feed: snapshot, or subscribe
//!   rook-mux side [-]            push side-panel models (JSON frames on stdin)
//!   rook-mux side demo           print the demo models, to pipe into the above
//!   rook-mux blocks / raw <id>   block table; raw single-block attach
//!   rook-mux capture <id>        one pane's viewport as plain text
//!   rook-mux kill       stop the server
const std = @import("std");
const server = @import("server.zig");
const chrome = @import("chrome.zig");
const client = @import("client.zig");
const ptypkg = @import("pty.zig");

test {
    _ = @import("layout.zig");
    _ = @import("proto.zig");
    _ = @import("config.zig");
    _ = @import("chrome.zig");
}

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn usleep(us: u32) c_int;

fn sockPath(gpa: std.mem.Allocator) ![]const u8 {
    if (getenv("ROOK_MUX_SOCK")) |p| return try gpa.dupe(u8, std.mem.span(p));
    const home = std.mem.span(getenv("HOME") orelse return error.NoHome);
    const dir = try std.fmt.allocPrint(gpa, "{s}/.local/state/rook", .{home});
    defer gpa.free(dir);
    ptypkg.makePath(dir);
    return std.fmt.allocPrint(gpa, "{s}/mux.sock", .{dir});
}

fn shellPath(gpa: std.mem.Allocator) [:0]const u8 {
    if (getenv("SHELL")) |s| return gpa.dupeZ(u8, std.mem.span(s)) catch "/bin/zsh";
    return "/bin/zsh";
}

extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;

pub fn main(init: std.process.Init) !void {
    // Paths and argv copies are process-lifetime: arena. The server
    // and client loops churn (frames, queues, clips) and run for days:
    // they need a real allocator or the churn is permanent RSS.
    const gpa = init.arena.allocator();
    const churn_gpa = init.gpa;
    const io = init.io;
    const argv = init.minimal.args.vector;
    const cmd: []const u8 = if (argv.len > 1) std.mem.span(argv[1]) else "";

    const path = try sockPath(gpa);

    if (std.mem.eql(u8, cmd, "server")) {
        const shell = shellPath(gpa);
        var cwd_buf: [1024]u8 = undefined;
        const cwd: ?[:0]const u8 = if (getcwd(&cwd_buf, cwd_buf.len)) |c| try gpa.dupeZ(u8, std.mem.span(c)) else null;
        try server.Server.run(churn_gpa, io, path, shell, cwd);
        return;
    }
    if (std.mem.eql(u8, cmd, "stats")) {
        try client.stats(churn_gpa, path);
        return;
    }
    if (std.mem.eql(u8, cmd, "kill")) {
        try client.kill(gpa, path);
        return;
    }
    if (std.mem.eql(u8, cmd, "state")) {
        try client.state(churn_gpa, path);
        return;
    }
    if (std.mem.eql(u8, cmd, "watch")) {
        try client.watch(churn_gpa, path);
        return;
    }
    if (std.mem.eql(u8, cmd, "side")) {
        const arg: []const u8 = if (argv.len > 2) std.mem.span(argv[2]) else "-";
        // `side demo` prints frames rather than sending any, so the
        // wire has a worked example you can read, edit and pipe back:
        //     rook-mux side demo | rook-mux side -
        if (std.mem.eql(u8, arg, "demo")) {
            for (chrome.demo_frames) |frame| {
                _ = ptypkg.writeAllFd(1, frame);
                _ = ptypkg.writeAllFd(1, "\n");
            }
            return;
        }
        if (!std.mem.eql(u8, arg, "-")) {
            std.debug.print("usage: rook-mux side [-|demo]   (frames on stdin)\n", .{});
            return error.BadArgs;
        }
        try client.sidePush(churn_gpa, path);
        return;
    }
    if (std.mem.eql(u8, cmd, "blocks")) {
        try client.blocks(gpa, path);
        return;
    }
    if (std.mem.eql(u8, cmd, "capture")) {
        if (argv.len < 3) {
            std.debug.print("usage: rook-mux capture <block-id>\n", .{});
            return error.BadArgs;
        }
        const id = try std.fmt.parseInt(u32, std.mem.span(argv[2]), 10);
        try client.capture(churn_gpa, path, id);
        return;
    }
    if (std.mem.eql(u8, cmd, "raw")) {
        if (argv.len < 3) {
            std.debug.print("usage: rook-mux raw <block-id>\n", .{});
            return error.BadArgs;
        }
        const id = try std.fmt.parseInt(u32, std.mem.span(argv[2]), 10);
        try client.rawAttach(gpa, path, id);
        return;
    }
    if (std.mem.eql(u8, cmd, "ls")) {
        try client.session(gpa, path, 'l', "");
        return;
    }
    if (std.mem.eql(u8, cmd, "switch")) {
        if (argv.len < 3) return error.BadArgs;
        try client.session(gpa, path, 's', std.mem.span(argv[2]));
        return;
    }
    if (std.mem.eql(u8, cmd, "new")) {
        // `new -q` creates the workspace without moving the person —
        // what an agent spawns with.
        var rest = argv[2..];
        var op: u8 = 'n';
        if (rest.len > 0 and std.mem.eql(u8, std.mem.span(rest[0]), "-q")) {
            op = 'N';
            rest = rest[1..];
        }
        if (rest.len < 1) return error.BadArgs;
        var arg: []const u8 = std.mem.span(rest[0]);
        if (rest.len > 1) {
            arg = try std.fmt.allocPrint(gpa, "{s}\t{s}", .{ arg, std.mem.span(rest[1]) });
        }
        try client.session(gpa, path, op, arg);
        return;
    }
    if (std.mem.eql(u8, cmd, "close")) {
        if (argv.len < 3) return error.BadArgs;
        try client.session(gpa, path, 'k', std.mem.span(argv[2]));
        return;
    }
    if (std.mem.eql(u8, cmd, "popup")) {
        if (argv.len < 3) {
            std.debug.print("usage: rook-mux popup <command...>\n", .{});
            return error.BadArgs;
        }
        var joined: std.ArrayList(u8) = .empty;
        for (argv[2..], 0..) |a, i| {
            if (i > 0) try joined.append(gpa, ' ');
            try joined.appendSlice(gpa, std.mem.span(a));
        }
        try client.popup(path, joined.items);
        return;
    }
    if (std.mem.eql(u8, cmd, "nav")) {
        // rook-mux nav h|j|k|l (or left/down/up/right)
        const arg: []const u8 = if (argv.len > 2) std.mem.span(argv[2]) else "";
        const dir: u8 = if (arg.len == 1 and (arg[0] == 'h' or arg[0] == 'j' or arg[0] == 'k' or arg[0] == 'l'))
            arg[0]
        else if (std.mem.eql(u8, arg, "left"))
            'h'
        else if (std.mem.eql(u8, arg, "down"))
            'j'
        else if (std.mem.eql(u8, arg, "up"))
            'k'
        else if (std.mem.eql(u8, arg, "right"))
            'l'
        else {
            std.debug.print("usage: rook-mux nav h|j|k|l\n", .{});
            return error.BadArgs;
        };
        try client.nav(path, dir);
        return;
    }

    if (getenv("ROOK_MUX_PANE") != null) {
        std.debug.print("already inside rook-mux; nesting comes later\n", .{});
        return;
    }

    // Default: attach, booting a server when none listens.
    const probe = ptypkg.unixConnect(path);
    if (probe >= 0) {
        ptypkg.closeFd(probe);
    } else {
        try daemonizeServer(gpa);
        var tries: usize = 0;
        while (tries < 100) : (tries += 1) {
            const p2 = ptypkg.unixConnect(path);
            if (p2 >= 0) {
                ptypkg.closeFd(p2);
                break;
            }
            _ = usleep(20_000);
        }
    }
    try client.attach(churn_gpa, path);
}

/// Fork+exec ourselves as `rook-mux server`, detached from this tty.
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_int) c_int;
extern "c" fn _NSGetExecutablePath(buf: [*]u8, size: *u32) c_int;

fn daemonizeServer(gpa: std.mem.Allocator) !void {
    var exe_buf: [1024]u8 = undefined;
    var exe_len: u32 = exe_buf.len;
    if (_NSGetExecutablePath(&exe_buf, &exe_len) != 0) return error.NoExePath;
    const exe = std.mem.sliceTo(exe_buf[0..], 0);
    const exe_z = try gpa.dupeZ(u8, exe);
    defer gpa.free(exe_z);

    const pid = ptypkg.fork_();
    if (pid < 0) return error.ForkFailed;
    if (pid > 0) return; // parent
    // child: new session, quiet fds, exec the server
    _ = ptypkg.setsid_();
    const devnull = open("/dev/null", 2, 0); // O_RDWR
    _ = ptypkg.dup2_(devnull, 0);
    _ = ptypkg.dup2_(devnull, 1);
    _ = ptypkg.dup2_(devnull, 2);
    const argv = [_:null]?[*:0]const u8{ exe_z.ptr, "server" };
    _ = ptypkg.execvp_(exe_z.ptr, &argv);
    ptypkg.exit_(1);
}
