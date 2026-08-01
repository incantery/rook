//! rook — the app and the CLI, one binary on libghostty-vt.
//!
//! Subcommands:
//!   win             the app (the default; a Dock launch gets here)
//!   edit <file>     open a file in the running app's editor (`re`)
//!   demo            headless proof: bytes → vt → screen dump
//!   exec <cmd...>   run a command under a real PTY, dump the final screen
//!
//! Flags:
//!   --config=DIR    run against DIR instead of ~/.config/rook, with the
//!                   socket and data alongside it — a whole rook in one
//!                   directory you can delete
//!
//! Unknown verbs used to exec rookctl, which carried everything rook did
//! over HTTP to a Go daemon. Both are gone: rook is one binary now, and
//! anything it cannot do it does not pretend to hand off. What the CLI
//! surface becomes is the ctl socket (ctl.zig) and, for external systems,
//! providers (sdk/provider).

const std = @import("std");
const vt = @import("ghostty-vt");
const ptypkg = @import("pty.zig");

extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]const u8;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn mkdir(path: [*:0]const u8, mode: u16) c_int;
extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// `--config=DIR` — everything this instance touches, under one directory.
///
/// The point is a rook you can throw away: a scratch config, its own ctl
/// socket, its own data. Without the socket part it would not be isolated
/// at all — a second instance on /tmp/rook.sock either loses the race to
/// bind or answers a `quit` meant for the other one, and the second is
/// worse because it looks like it worked.
///
/// Set as ENVIRONMENT, not just internal state, because shells inside the
/// instance inherit it: `rook edit` from a pane then reaches THIS rook,
/// which is the whole reason ROOK_SOCK is a variable and not a constant.
/// Never with overwrite — an explicit ROOK_SOCK still wins.
///
/// Returns false if the directory could not be made, which is fatal: a
/// caller who named a config directory and silently got the default one
/// would be testing the wrong rook.
fn useConfigDir(raw: []const u8) bool {
    if (raw.len == 0 or raw.len > 900) {
        std.debug.print("rook: --config needs a directory\n", .{});
        return false;
    }
    var z: [1024]u8 = undefined;
    @memcpy(z[0..raw.len], raw);
    z[raw.len] = 0;

    // Created rather than required. "rook from scratch" starts with a
    // directory that does not exist yet, and the socket needs somewhere to
    // live before the app comes up. EEXIST is the normal case.
    _ = mkdir(@ptrCast(&z), 0o755);

    // ABSOLUTE from here on: the app chdirs, and panes chdir further. A
    // relative --config would resolve against whatever directory a shell
    // happened to be in by the time something read it.
    var abs: [1024]u8 = undefined;
    const resolved = realpath(@ptrCast(&z), &abs) orelse {
        std.debug.print("rook: --config: cannot use {s}\n", .{raw});
        return false;
    };
    const dir = std.mem.span(resolved);

    @import("config.zig").setDir(dir);

    var buf: [1024]u8 = undefined;
    if (std.fmt.bufPrintZ(&buf, "{s}/rook.sock", .{dir})) |sock| {
        _ = setenv("ROOK_SOCK", sock.ptr, 0);
    } else |_| {}
    // The registry lives at $XDG_DATA_HOME/rook/rook.db, so this points at
    // DIR/rook/rook.db — a path that will not exist, which is exactly what
    // "from scratch" means. It is read-only and absent is a normal state.
    if (std.fmt.bufPrintZ(&buf, "{s}", .{dir})) |data| {
        _ = setenv("XDG_DATA_HOME", data.ptr, 0);
    } else |_| {}
    return true;
}

pub fn main(init: std.process.Init) !void {
    const argv = init.minimal.args.vector;
    // Invoked as `re` (the ~/.local/bin symlink): straight to edit —
    // `re foo.zig` is the daily-driver spelling.
    if (argv.len > 0 and std.mem.eql(u8, std.fs.path.basename(std.mem.span(argv[0])), "re"))
        return edit(argv[1..]);
    const first: []const u8 = if (argv.len > 1) std.mem.span(argv[1]) else "";
    // Before the default below, which swallows anything flag-shaped:
    // a Dock launch hands us -psn_…, so `-` normally means "the app".
    if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-V")) {
        const bo = @import("build_options");
        std.debug.print("rook {s} (build {s})\n", .{ bo.version, bo.id });
        return;
    }
    // --config BEFORE the dispatch below, because everything after this
    // reads config: App.create loads it, and `edit` resolves the socket
    // that --config moves.
    {
        var i: usize = 1;
        while (i < argv.len) : (i += 1) {
            const arg = std.mem.span(argv[i]);
            if (std.mem.startsWith(u8, arg, "--config=")) {
                if (!useConfigDir(arg["--config=".len..])) return error.BadConfigDir;
            } else if (std.mem.eql(u8, arg, "--config")) {
                // The spaced form too. People type both, and refusing one
                // of them is a paper cut with no upside.
                if (i + 1 >= argv.len) {
                    std.debug.print("rook: --config needs a directory\n", .{});
                    return error.BadConfigDir;
                }
                i += 1;
                if (!useConfigDir(std.mem.span(argv[i]))) return error.BadConfigDir;
            }
        }
    }

    // No subcommand = the app (a Dock launch has no argv to give, or
    // hands us flags like -psn_… / --no-activate directly).
    const cmd: []const u8 = if (argv.len > 1 and argv[1][0] != '-') first else "win";

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

    std.debug.print("rook: unknown command '{s}'\n", .{cmd});
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

/// `rook edit <file>` — the dogfood door: from a shell inside rook,
/// open the file in an editor pane of THIS instance (shells inherit
/// ROOK_SOCK, so a dev instance's shells talk to the dev socket).
fn edit(args: []const [*:0]const u8) !void {
    if (args.len == 0) {
        std.debug.print("usage: rook edit <file>\n", .{});
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

    const sock_env = getenv("ROOK_SOCK");
    const sock: []const u8 = if (sock_env) |sp| std.mem.span(sp) else "/tmp/rook.sock";

    const fd = socket(1, 1, 0); // AF_UNIX, SOCK_STREAM
    if (fd < 0) return error.SocketFailed;
    defer _ = close(fd);
    var addr: sockaddr_un = .{};
    if (sock.len >= addr.sun_path.len) return error.PathTooLong;
    @memcpy(addr.sun_path[0..sock.len], sock);
    if (connect(fd, &addr, @sizeOf(sockaddr_un)) != 0) {
        std.debug.print("rook edit: no app listening on {s} (is rook running?)\n", .{sock});
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
        std.debug.print("rook edit: {s}", .{reply_buf[0..@intCast(n)]});
        return error.EditFailed;
    }
}

fn demo(init: std.process.Init) !void {
    var t: vt.Terminal = try .init(init.io, init.gpa, .{ .cols = 80, .rows = 24 });
    defer t.deinit(init.gpa);

    var stream = t.vtStream();
    defer stream.deinit();

    stream.nextSlice("rook \x1b[1;32malive\x1b[0m on libghostty-vt\r\n");
    stream.nextSlice("wide: \xe4\xbd\xa0\xe5\xa5\xbd  emoji: \xf0\x9f\x91\xbb\r\n");
    stream.nextSlice("\x1b[38;2;137;180;250mtruecolor\x1b[0m and \x1b[7mreverse\x1b[0m\r\n");

    const str = try t.plainString(init.gpa);
    defer init.gpa.free(str);
    std.debug.print("{s}\n", .{str});
}

fn exec(init: std.process.Init, cmd_argv: []const [*:0]const u8) !void {
    if (cmd_argv.len == 0) {
        std.debug.print("usage: rook exec <cmd...>\n", .{});
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
