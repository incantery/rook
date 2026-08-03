//! rook — the app and the CLI, one binary on libghostty-vt.
//!
//! Local subcommands:
//!   win             the app (the default; a Dock launch gets here)
//!   edit <file>     open a file in the running app's editor (`re`)
//!   demo            headless proof: bytes → vt → screen dump
//!   exec <cmd...>   run a command under a real PTY, dump the final screen
//!
//! EVERY OTHER subcommand is a control verb, sent to the running rook
//! over its socket: `rook panes`, `rook workspaces`, `rook worktree add
//! rook feat`, `rook run pane.zoom`, `rook shot /tmp/x.png`. The CLI is
//! a ctl client — the same forty-odd verbs rook-ctl(7) documents, with
//! the `printf | nc -U` ceremony removed and nothing to keep in step,
//! because there is no verb table here to drift: the server answers or
//! it doesn't. A lone argument naming an existing file opens it in the
//! editor instead, so `rook main.go` does what a hand expects.
//!
//! Flags:
//!   --config=DIR    run against DIR instead of ~/.config/rook, with the
//!                   socket and data alongside it — a whole rook in one
//!                   directory you can delete. Composes with verbs:
//!                   `rook --config=DIR panes` asks DIR's instance.
//!
//! Unknown verbs once exec'd rookctl, which carried everything over HTTP
//! to a Go daemon; both are gone. This time the verb goes to the app
//! itself, because the app is the only process there is.

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
    // The plugin cache lives under $XDG_DATA_HOME/rook/plugins, so this
    // points it at DIR/rook/plugins — empty, which is exactly what "from
    // scratch" means. Deleting DIR deletes everything the instance grew.
    if (std.fmt.bufPrintZ(&buf, "{s}", .{dir})) |data| {
        _ = setenv("XDG_DATA_HOME", data.ptr, 0);
    } else |_| {}
    return true;
}

pub fn main(init: std.process.Init) !void {
    const argv = init.minimal.args.vector;
    // Invoked as `re` (the ~/.local/bin symlink): straight to edit —
    // `re foo.zig` is the daily-driver spelling.
    if (argv.len > 0 and std.mem.eql(u8, std.fs.path.basename(std.mem.span(argv[0])), "re")) {
        edit(argv[1..]) catch _exit(1);
        return;
    }
    const first: []const u8 = if (argv.len > 1) std.mem.span(argv[1]) else "";
    // Before the flag-swallowing below: a Dock launch hands us -psn_…,
    // so `-` normally means "the app" — but these two are answers, not
    // window requests.
    if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-V")) {
        const bo = @import("build_options");
        std.debug.print("rook {s} (build {s})\n", .{ bo.version, bo.id });
        return;
    }
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "help"))
        return help();
    // --config BEFORE the dispatch below, because everything after this
    // reads config: App.create loads it, and every socket client
    // resolves the socket that --config moves.
    {
        var i: usize = 1;
        while (i < argv.len) : (i += 1) {
            const arg = std.mem.span(argv[i]);
            if (std.mem.startsWith(u8, arg, "--config=")) {
                if (!useConfigDir(arg["--config=".len..])) _exit(1);
            } else if (std.mem.eql(u8, arg, "--config")) {
                // The spaced form too. People type both, and refusing one
                // of them is a paper cut with no upside.
                if (i + 1 >= argv.len) {
                    std.debug.print("rook: --config needs a directory\n", .{});
                    _exit(1);
                }
                i += 1;
                if (!useConfigDir(std.mem.span(argv[i]))) _exit(1);
            }
        }
    }

    // The subcommand is the FIRST NON-FLAG argument, wherever it sits —
    // `rook --config=DIR panes` composes. None = the app (a Dock launch
    // has no argv to give, or hands us -psn_… / --no-activate directly).
    var cmd: []const u8 = "win";
    var cmd_idx: usize = 0;
    {
        var i: usize = 1;
        while (i < argv.len) : (i += 1) {
            const a = std.mem.span(argv[i]);
            if (a.len == 0 or a[0] == '-') {
                if (std.mem.eql(u8, a, "--config")) i += 1; // skip its value
                continue;
            }
            cmd = a;
            cmd_idx = i;
            break;
        }
    }

    if (std.mem.eql(u8, cmd, "demo")) return demo(init);
    if (std.mem.eql(u8, cmd, "install")) return install(argv[cmd_idx + 1 ..]);
    if (std.mem.eql(u8, cmd, "exec")) return exec(init, argv[cmd_idx + 1 ..]);
    if (std.mem.eql(u8, cmd, "edit")) {
        edit(argv[cmd_idx + 1 ..]) catch _exit(1);
        return;
    }
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
        for (argv[1..]) |arg| {
            if (std.mem.eql(u8, std.mem.span(arg), "--no-activate")) app.activate = false;
        }
        app.run();
        return;
    }

    // Everything else is a control verb for the running instance.
    ctlPass(argv[cmd_idx..]);
}

/// `rook install <target>` — teach a tool about rook.
///
/// `claude` writes the rook skill into ~/.claude/skills/rook, where
/// Claude Code loads it on demand: one description line rides along in
/// every session, the full instructions only when rook is relevant —
/// which is why this is a skill and not a CLAUDE.md paragraph. The
/// content is EMBEDDED (build.zig), so the skill always matches the
/// binary that wrote it; re-run after an upgrade, or just re-run
/// anytime — overwriting rook's own file is the idempotent case.
fn install(args: []const [*:0]const u8) void {
    const target: []const u8 = if (args.len > 0) std.mem.span(args[0]) else "";
    if (!std.mem.eql(u8, target, "claude")) {
        std.debug.print(
            \\usage: rook install claude
            \\  claude   the rook skill into ~/.claude/skills/rook, so Claude
            \\           Code knows how to see and drive rook (man rook-ctl)
            \\
        , .{});
        _exit(1);
    }
    const home = getenv("HOME") orelse {
        std.debug.print("rook install: no $HOME\n", .{});
        _exit(1);
    };
    var dir_buf: [1024]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}/.claude/skills/rook", .{std.mem.span(home)}) catch _exit(1);
    makePath(dir);
    var path_buf: [1024]u8 = undefined;
    const pathz = std.fmt.bufPrintZ(&path_buf, "{s}/SKILL.md", .{dir}) catch _exit(1);

    const skill = @embedFile("claude_skill");
    const fd = open(pathz.ptr, 0x601, @as(c_uint, 0o644)); // O_WRONLY|O_CREAT|O_TRUNC
    if (fd < 0) {
        std.debug.print("rook install: cannot write {s}\n", .{pathz});
        _exit(1);
    }
    defer _ = close(fd);
    var off: usize = 0;
    while (off < skill.len) {
        const n = write(fd, skill.ptr + off, skill.len - off);
        if (n <= 0) {
            std.debug.print("rook install: short write to {s}\n", .{pathz});
            _exit(1);
        }
        off += @intCast(n);
    }
    std.debug.print(
        \\installed {s}
        \\Claude Code picks it up from the next session on.
        \\(remove with: rm -r ~/.claude/skills/rook — or re-run this after upgrades)
        \\
    , .{pathz});
}

fn makePath(dir: []const u8) void {
    var buf: [1024]u8 = undefined;
    if (dir.len >= buf.len) return;
    @memcpy(buf[0..dir.len], dir);
    buf[dir.len] = 0;
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or buf[i] == '/') {
            const save = buf[i];
            buf[i] = 0;
            _ = mkdir(@ptrCast(&buf), 0o755);
            buf[i] = save;
        }
    }
}

/// The whole help. Deliberately short: the real reference is the man
/// pages, and a --help that scrolls is a --help nobody reads.
fn help() void {
    const text =
        \\rook — terminal, multiplexer, editor. One binary.
        \\
        \\usage:
        \\  rook [--config DIR] [--no-activate]   open the app
        \\  rook <file>                           open a file in the running rook (also: re <file>)
        \\  rook <verb> [args...]                 send a control verb to the running rook
        \\  rook exec <cmd...> | demo             headless probes
        \\  rook install claude                   teach Claude Code to drive rook
        \\  rook --version | --help
        \\
        \\verbs answer over the control socket ($ROOK_SOCK, default
        \\/tmp/rook.sock); the full list is man rook-ctl. A taste:
        \\  panes  dump  workspaces  worktree add|remove <ws> <name>
        \\  attention  plugins  env [apply]  run <command>  shot <path>
        \\
        \\config: ~/.config/rook — man rook-config. the app: man rook.
        \\
    ;
    _ = write(1, text.ptr, text.len);
}

/// The CLI is a ctl client: the verb and its arguments go to the
/// running rook as one line, the reply streams back, `err` becomes
/// exit 1. `rook panes` IS `printf 'panes\n' | nc -U /tmp/rook.sock`
/// with the ceremony removed — one vocabulary, no client-side verb
/// table to drift.
///
/// A LONE argument that the server does not know but the filesystem
/// does is handed to `edit` — `rook main.go` opens the file. Verb
/// first, file second: an agent's muscle memory must never depend on
/// what happens to be in the working directory.
fn ctlPass(args: []const [*:0]const u8) void {
    var line_buf: [4096]u8 = undefined;
    var len: usize = 0;
    for (args, 0..) |a, i| {
        const s = std.mem.span(a);
        if (len + s.len + 2 > line_buf.len) {
            std.debug.print("rook: command too long\n", .{});
            _exit(1);
        }
        if (i > 0) {
            line_buf[len] = ' ';
            len += 1;
        }
        @memcpy(line_buf[len..][0..s.len], s);
        len += s.len;
    }
    line_buf[len] = '\n';
    len += 1;

    const sock_env = getenv("ROOK_SOCK");
    const sock: []const u8 = if (sock_env) |sp| std.mem.span(sp) else "/tmp/rook.sock";
    const fd = socket(1, 1, 0); // AF_UNIX, SOCK_STREAM
    if (fd < 0) _exit(1);
    defer _ = close(fd);
    var addr: sockaddr_un = .{};
    if (sock.len >= addr.sun_path.len) _exit(1);
    @memcpy(addr.sun_path[0..sock.len], sock);
    if (connect(fd, &addr, @sizeOf(sockaddr_un)) != 0) {
        std.debug.print("rook: no app listening on {s} (is rook running?)\n", .{sock});
        _exit(1);
    }
    var off: usize = 0;
    while (off < len) {
        const n = write(fd, line_buf[off..].ptr, len - off);
        if (n <= 0) _exit(1);
        off += @intCast(n);
    }
    // Half-close: the server replies per line and closes on EOF, so the
    // reply is everything until our read returns 0.
    _ = shutdown(fd, 1); // SHUT_WR

    // The first chunk decides three ways: an ok reply streams to
    // stdout; `err unknown` on a lone existing file becomes `edit`;
    // any other `err` streams too but exits 1.
    var buf: [65536]u8 = undefined;
    var got = read(fd, &buf, buf.len);
    if (got < 0) _exit(1);
    const head = buf[0..@intCast(got)];
    if (std.mem.startsWith(u8, head, "err unknown") and args.len == 1) {
        if (access(args[0], 0) == 0) {
            edit(args) catch _exit(1);
            return;
        }
    }
    const failed = std.mem.startsWith(u8, head, "err");
    while (got > 0) {
        _ = write(1, &buf, @intCast(got));
        got = read(fd, &buf, buf.len);
    }
    if (failed) _exit(1);
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
extern "c" fn shutdown(fd: c_int, how: c_int) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn _exit(code: c_int) noreturn;

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
