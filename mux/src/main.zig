//! rook-mux: a terminal multiplexer with ghostty-vt in-process.
//!   rook-mux            attach (starting the server if needed)
//!   rook-mux server     run the server in the foreground
//!   rook-mux nav <dir>  move focus h/j/k/l (vim plugins call this at edges)
//!   rook-mux kill       stop the server
const std = @import("std");
const server = @import("server.zig");
const client = @import("client.zig");
const ptypkg = @import("pty.zig");

test {
    _ = @import("layout.zig");
    _ = @import("proto.zig");
    _ = @import("config.zig");
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
