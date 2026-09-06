//! The engine: a terminal multiplexer with ghostty-vt in-process.
//! It is not on $PATH and nobody types it — `rook` execs it, verb and
//! all, so the verbs read as the front door spells them:
//!   rook                attach (starting the server if needed)
//!   rook server         run the server in the foreground
//!   rook nav <dir>      move focus h/j/k/l (vim plugins call this at edges)
//!   rook popup <cmd>    float a command over the current window
//!   rook ls / switch / new <name> [cwd] / close <name>   workspaces
//!   rook state / watch       the state feed: snapshot, or subscribe
//!   rook side [-]            push side-panel models (JSON frames on stdin)
//!   rook side demo           print the demo models, to pipe into the above
//!   rook blocks / raw <id>   block table; raw single-block attach
//!   rook capture <id>        one pane's viewport as plain text
//!   rook read <id> [-n N]    the same, or its last N lines with history
//!   rook send <id> <text>    type into a pane; `run` adds Enter, `key` names keys
//!   rook wait <id> [--match S] [--quiet MS] [--timeout MS]
//!   rook split <id> [--down] [--focus] [--cwd DIR]   a pane beside/below it
//!   rook window <id> [--focus] [--cwd DIR]           a new window in its workspace
//!   rook focus <id> / rook jump / rook close-pane <id>
//!   rook resume <id> <cmd...>  how to bring the pane's program back after a restart
//!   rook own <id> <actor> | --paused <actor> | --release | --request | --take
//!                       who holds a pane's keyboard (docs/altitude.md)
//!   rook rename <name>  name the current tab; it never renames itself again
//!   rook kill           stop the server
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
    _ = @import("companion.zig");
    _ = @import("altitude.zig");
    _ = @import("ui.zig");
    _ = @import("server.zig");
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
        //     rook side demo | rook side -
        if (std.mem.eql(u8, arg, "demo")) {
            for (chrome.demo_frames) |frame| {
                _ = ptypkg.writeAllFd(1, frame);
                _ = ptypkg.writeAllFd(1, "\n");
            }
            return;
        }
        if (!std.mem.eql(u8, arg, "-")) {
            std.debug.print("usage: rook side [-|demo]   (frames on stdin)\n", .{});
            return error.BadArgs;
        }
        try client.sidePush(churn_gpa, path);
        return;
    }
    if (std.mem.eql(u8, cmd, "blocks")) {
        try client.blocks(gpa, path);
        return;
    }
    if (std.mem.eql(u8, cmd, "capture") or std.mem.eql(u8, cmd, "read")) {
        // rook read <id> [-n LINES]: the viewport, or the last LINES
        // lines with the history above the screen filling in.
        if (argv.len < 3) {
            std.debug.print("usage: rook {s} <pane> [-n lines]\n", .{cmd});
            return error.BadArgs;
        }
        const id = try paneArgLoud(std.mem.span(argv[2]));
        var lines: u32 = 0;
        var i: usize = 3;
        while (i < argv.len) : (i += 1) {
            const a = std.mem.span(argv[i]);
            if ((std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--lines")) and i + 1 < argv.len) {
                i += 1;
                lines = try std.fmt.parseInt(u32, std.mem.span(argv[i]), 10);
            }
        }
        try client.capture(churn_gpa, path, id, lines);
        return;
    }
    if (std.mem.eql(u8, cmd, "send") or std.mem.eql(u8, cmd, "run") or std.mem.eql(u8, cmd, "key")) {
        // send: the words, verbatim. run: the words and Enter, the way
        // a command is typed. key: named keys — enter, esc, tab,
        // up/down/left/right, space, backspace, ctrl-x.
        if (argv.len < 4) {
            std.debug.print("usage: rook {s} <pane> <text...>\n", .{cmd});
            return error.BadArgs;
        }
        const id = try paneArgLoud(std.mem.span(argv[2]));
        var bytes: std.ArrayList(u8) = .empty;
        if (std.mem.eql(u8, cmd, "key")) {
            for (argv[3..]) |a| {
                const name = std.mem.span(a);
                try bytes.appendSlice(gpa, keyBytes(name) orelse {
                    std.debug.print("rook key: unknown key {s}\n", .{name});
                    return error.BadArgs;
                });
            }
        } else {
            for (argv[3..], 0..) |a, i| {
                if (i > 0) try bytes.append(gpa, ' ');
                try bytes.appendSlice(gpa, std.mem.span(a));
            }
            if (std.mem.eql(u8, cmd, "run")) try bytes.append(gpa, '\r');
        }
        try client.send(churn_gpa, path, id, bytes.items);
        return;
    }
    if (std.mem.eql(u8, cmd, "wait")) {
        if (argv.len < 3) {
            std.debug.print("usage: rook wait <pane> [--match text] [--quiet ms] [--timeout ms] [-n lines]\n", .{});
            return error.BadArgs;
        }
        const id = try paneArgLoud(std.mem.span(argv[2]));
        var match: ?[]const u8 = null;
        var quiet: u32 = 0;
        var timeout: u32 = 0;
        var lines: u32 = 200;
        var i: usize = 3;
        while (i < argv.len) : (i += 1) {
            const a = std.mem.span(argv[i]);
            const val: ?[]const u8 = if (i + 1 < argv.len) std.mem.span(argv[i + 1]) else null;
            if (std.mem.eql(u8, a, "--match") and val != null) {
                match = val;
                i += 1;
            } else if (std.mem.eql(u8, a, "--quiet") and val != null) {
                quiet = try std.fmt.parseInt(u32, val.?, 10);
                i += 1;
            } else if (std.mem.eql(u8, a, "--timeout") and val != null) {
                timeout = try std.fmt.parseInt(u32, val.?, 10);
                i += 1;
            } else if ((std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--lines")) and val != null) {
                lines = try std.fmt.parseInt(u32, val.?, 10);
                i += 1;
            } else {
                std.debug.print("rook wait: unknown option {s}\n", .{a});
                return error.BadArgs;
            }
        }
        if (match == null and quiet == 0) {
            std.debug.print("rook wait: say what to wait for: --match text, or --quiet ms\n", .{});
            return error.BadArgs;
        }
        client.wait(churn_gpa, path, id, match, quiet, timeout, lines) catch |e| switch (e) {
            error.Timeout => {
                std.debug.print("rook wait: timed out\n", .{});
                ptypkg.exit_(1);
            },
            else => return e,
        };
        return;
    }
    if (std.mem.eql(u8, cmd, "split") or std.mem.eql(u8, cmd, "window") or std.mem.eql(u8, cmd, "close-pane") or std.mem.eql(u8, cmd, "focus")) {
        // Pane verbs by id. The desk is never pulled unless --focus
        // asks: a split beside an agent's own pane appears; focus
        // stays where the person left it.
        if (argv.len < 3) {
            std.debug.print("usage: rook {s} <pane> [--down] [--focus] [--cwd dir]\n", .{cmd});
            return error.BadArgs;
        }
        const id = try paneArgLoud(std.mem.span(argv[2]));
        var op: u8 = if (std.mem.eql(u8, cmd, "split")) 'v' else if (std.mem.eql(u8, cmd, "window")) 'c' else if (std.mem.eql(u8, cmd, "focus")) 'f' else 'x';
        var focus = false;
        var cwd: []const u8 = "";
        var i: usize = 3;
        while (i < argv.len) : (i += 1) {
            const a = std.mem.span(argv[i]);
            if (std.mem.eql(u8, a, "--down") or std.mem.eql(u8, a, "-")) {
                op = '-';
            } else if (std.mem.eql(u8, a, "--focus")) {
                focus = true;
            } else if (std.mem.eql(u8, a, "--cwd") and i + 1 < argv.len) {
                i += 1;
                cwd = std.mem.span(argv[i]);
            } else {
                std.debug.print("rook {s}: unknown option {s}\n", .{ cmd, a });
                return error.BadArgs;
            }
        }
        try client.paneCmd(churn_gpa, path, id, op, focus, cwd);
        return;
    }
    if (std.mem.eql(u8, cmd, "resume")) {
        // rook resume <id> <cmd...> | rook resume <id> --clear
        // Written for a hook: outside rook, or against a server that
        // does not answer, there is nothing to remember and nothing to
        // say — exit 0 in silence, so a SessionStart hook that runs
        // everywhere never becomes noise where rook is not.
        if (argv.len < 4) {
            std.debug.print("usage: rook resume <pane> <command...> | --clear\n", .{});
            return error.BadArgs;
        }
        const id = paneArg(std.mem.span(argv[2])) catch return;
        var joined: std.ArrayList(u8) = .empty;
        if (!std.mem.eql(u8, std.mem.span(argv[3]), "--clear")) {
            for (argv[3..], 0..) |a, i| {
                if (i > 0) try joined.append(gpa, ' ');
                try joined.appendSlice(gpa, std.mem.span(a));
            }
        }
        client.setResume(churn_gpa, path, id, joined.items) catch |e| switch (e) {
            error.ConnectFailed, error.Timeout, error.ServerGone => return,
            else => return e,
        };
        return;
    }
    if (std.mem.eql(u8, cmd, "own")) {
        // rook own <id> <actor>          the actor owns input
        // rook own <id> --paused <actor> attached, not operating
        // rook own <id> --release        hand it back (or yield, if asked)
        // rook own <id> --request        ask for a handoff (the gate's ⏎)
        // rook own <id> --take           take the keyboard now (the gate's T)
        if (argv.len < 4) {
            std.debug.print("usage: rook own <pane> <actor> | --paused <actor> | --release | --request | --take\n", .{});
            return error.BadArgs;
        }
        const id = try paneArgLoud(std.mem.span(argv[2]));
        const flag = std.mem.span(argv[3]);
        var op: u8 = 'c';
        var actor: []const u8 = flag;
        if (std.mem.eql(u8, flag, "--release")) {
            op = 'r';
            actor = "";
        } else if (std.mem.eql(u8, flag, "--request")) {
            op = 'h';
            actor = "";
        } else if (std.mem.eql(u8, flag, "--take")) {
            op = 't';
            actor = "";
        } else if (std.mem.eql(u8, flag, "--paused")) {
            if (argv.len < 5) {
                std.debug.print("usage: rook own <pane> --paused <actor>\n", .{});
                return error.BadArgs;
            }
            op = 'p';
            actor = std.mem.span(argv[4]);
        } else if (flag.len > 0 and flag[0] == '-') {
            std.debug.print("rook own: unknown option {s}\n", .{flag});
            return error.BadArgs;
        }
        try client.own(churn_gpa, path, id, op, actor);
        return;
    }
    if (std.mem.eql(u8, cmd, "rename")) {
        if (argv.len < 3) {
            std.debug.print("usage: rook rename <name>\n", .{});
            return error.BadArgs;
        }
        var joined: std.ArrayList(u8) = .empty;
        for (argv[2..], 0..) |a, i| {
            if (i > 0) try joined.append(gpa, ' ');
            try joined.appendSlice(gpa, std.mem.span(a));
        }
        try client.session(gpa, path, 'r', joined.items);
        return;
    }
    if (std.mem.eql(u8, cmd, "jump")) {
        try client.paneCmd(churn_gpa, path, 0, 'u', false, "");
        return;
    }
    if (std.mem.eql(u8, cmd, "raw")) {
        if (argv.len < 3) {
            std.debug.print("usage: rook raw <block-id>\n", .{});
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
            std.debug.print("usage: rook popup <command...>\n", .{});
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
        // rook nav h|j|k|l (or left/down/up/right)
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
            std.debug.print("usage: rook nav h|j|k|l\n", .{});
            return error.BadArgs;
        };
        try client.nav(path, dir);
        return;
    }

    if (getenv("ROOK_MUX_PANE") != null) {
        std.debug.print("already inside rook; nesting comes later\n", .{});
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

/// Fork+exec ourselves as the `server` verb, detached from this tty.
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

/// `paneArg`, saying so when there is no current pane: the verbs a
/// person types want the sentence; a hook wants silence.
fn paneArgLoud(arg: []const u8) !u32 {
    return paneArg(arg) catch |e| switch (e) {
        error.NotInside => {
            std.debug.print("rook: not inside a rook pane, so there is no current one\n", .{});
            return error.BadArgs;
        },
        else => return e,
    };
}

/// A pane argument: an id, or `.` / `current` / `--current` for the
/// pane this command runs in ($ROOK_MUX_PANE, the id the server set).
fn paneArg(arg: []const u8) !u32 {
    if (std.mem.eql(u8, arg, ".") or std.mem.eql(u8, arg, "current") or std.mem.eql(u8, arg, "--current")) {
        const env = getenv("ROOK_MUX_PANE") orelse return error.NotInside;
        return std.fmt.parseInt(u32, std.mem.span(env), 10) catch {
            std.debug.print("rook: this pane predates ids in $ROOK_MUX_PANE; name it by number (`rook blocks`)\n", .{});
            return error.BadArgs;
        };
    }
    return std.fmt.parseInt(u32, arg, 10) catch {
        std.debug.print("rook: a pane is a number, or `.` for this one\n", .{});
        return error.BadArgs;
    };
}

/// The bytes a named key sends a program: the legacy encoding every
/// program understands. `ctrl-x` is the control character; a single
/// character is itself.
fn keyBytes(name: []const u8) ?[]const u8 {
    const T = struct { n: []const u8, b: []const u8 };
    const table = [_]T{
        .{ .n = "enter", .b = "\r" },         .{ .n = "return", .b = "\r" },
        .{ .n = "esc", .b = "\x1b" },         .{ .n = "escape", .b = "\x1b" },
        .{ .n = "tab", .b = "\t" },           .{ .n = "space", .b = " " },
        .{ .n = "backspace", .b = "\x7f" },   .{ .n = "delete", .b = "\x1b[3~" },
        .{ .n = "up", .b = "\x1b[A" },        .{ .n = "down", .b = "\x1b[B" },
        .{ .n = "right", .b = "\x1b[C" },     .{ .n = "left", .b = "\x1b[D" },
        .{ .n = "home", .b = "\x1b[H" },      .{ .n = "end", .b = "\x1b[F" },
        .{ .n = "pageup", .b = "\x1b[5~" },   .{ .n = "pagedown", .b = "\x1b[6~" },
        .{ .n = "shift-tab", .b = "\x1b[Z" },
    };
    for (table) |t| {
        if (std.ascii.eqlIgnoreCase(name, t.n)) return t.b;
    }
    if (name.len == 1) return name;
    if ((std.ascii.startsWithIgnoreCase(name, "ctrl-") or std.ascii.startsWithIgnoreCase(name, "ctrl+")) and name.len == 6) {
        const ch = std.ascii.toLower(name[5]);
        if (ch >= 'a' and ch <= 'z') return ctrl_bytes[ch - 'a' ..][0..1];
        if (ch == '[') return "\x1b";
    }
    return null;
}

const ctrl_bytes = blk: {
    var b: [26]u8 = undefined;
    for (&b, 0..) |*c, i| c.* = @intCast(i + 1);
    break :blk b;
};

test "key names encode as the bytes a program expects" {
    const eq = std.testing.expectEqualStrings;
    try eq("\r", keyBytes("enter").?);
    try eq("\r", keyBytes("Enter").?);
    try eq("\x1b", keyBytes("esc").?);
    try eq("\x03", keyBytes("ctrl-c").?);
    try eq("\x03", keyBytes("ctrl+c").?);
    try eq("\x1b[Z", keyBytes("shift-tab").?);
    try eq("q", keyBytes("q").?);
    try std.testing.expect(keyBytes("hyperspace") == null);
}
