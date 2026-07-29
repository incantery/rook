//! e2e harness — spawn a sandboxed rook, drive its ctl socket, assert.
//!
//! This is the Zig replacement for what `make e2e` used to be: a
//! Playwright suite that drove the webview app so an AGENT could verify
//! its own UI work instead of asking a human to look. The cutover
//! deleted that, and the ctl socket alone is per-command — this is the
//! runner around it.
//!
//! The shape is bench.sh's, generalized: every scenario gets its OWN
//! instance, with its own socket, config, and state dir, so scenarios
//! cannot see each other's tabs, panes, or shells. The webview suite
//! learned that the expensive way — a failed spec leaked its workspace
//! and poisoned unrelated specs until someone ran e2e-clean, and the
//! symptoms read as renderer regressions.
//!
//! Two kinds of truth, and a scenario should use both where it can:
//! `dump` is what the emulator holds, `shot` is what the renderer did
//! with it. The atlas-flip bug was invisible to the first and obvious in
//! the second.

const std = @import("std");

// libc directly, in the app's own style. std's process/fs APIs move
// between Zig releases and this file is not worth re-fixing each time.
extern "c" fn fork() c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn setsid() c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
// NOTE: Instance's own lifecycle methods are stop()/hardKill(), not
// close()/kill(). A method sharing a name with one of these externs is an
// "ambiguous reference" at every call site inside the struct — and
// renaming the EXTERN instead just moves the problem to link time, since
// the symbol it looks for is its Zig name.
extern "c" fn close(fd: c_int) c_int;
extern "c" fn dup2(old: c_int, new: c_int) c_int;
extern "c" fn getdtablesize() c_int;
extern "c" fn getpid() c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: u16) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn usleep(us: c_uint) c_int;
extern "c" fn socket(domain: c_int, tp: c_int, protocol: c_int) c_int;
extern "c" fn connect(fd: c_int, addr: *const sockaddr_un, len: u32) c_int;
extern "c" fn shutdown(fd: c_int, how: c_int) c_int;
extern "c" fn _exit(code: c_int) noreturn;

const O_RDWR: c_int = 2;
const O_CREAT: c_int = 0o1000;
const O_TRUNC: c_int = 0o2000;
const O_WRONLY: c_int = 1;
const SHUT_WR: c_int = 1;
const SIGKILL: c_int = 9;
const WNOHANG: c_int = 1;

const sockaddr_un = extern struct {
    sun_len: u8 = 0,
    sun_family: u8 = 1, // AF_UNIX
    sun_path: [104]u8 = @splat(0),
};

pub const Error = error{
    AssertFailed,
    SpawnFailed,
    NeverCameUp,
    CtlFailed,
    Timeout,
    ShotFailed,
};

/// Recorded so a failing scenario can print the app's own stderr. A
/// bind failure or a bad config key is otherwise completely silent —
/// the instance just never answers, and every assertion times out
/// pointing at the wrong thing.
pub const Opts = struct {
    /// Pinned to /bin/sh on purpose. The user's real shell drags in
    /// oh-my-zsh/zinit, whose cold bootstrap is what made the first run
    /// after a wipe flake in the webview suite: input raced a shell that
    /// wasn't reading yet. /bin/sh starts instantly and has a prompt we
    /// can predict.
    shell: [*:0]const u8 = "/bin/sh",
    /// Extra lines appended to the sandbox config.toml.
    config_extra: []const u8 = "",
    /// How long start() waits for the socket, then for a live shell.
    boot_timeout_ms: u32 = 15_000,
};

var instance_seq: u32 = 0;

pub const Instance = struct {
    gpa: std.mem.Allocator,
    pid: c_int,
    dir: [128]u8 = @splat(0),
    dir_len: usize = 0,
    sock: [128]u8 = @splat(0),
    sock_len: usize = 0,
    log_path: [160]u8 = @splat(0),
    log_len: usize = 0,
    /// Replies are bounded: `dump` is the SCREEN not the scrollback, and
    /// `panes` writes into a 4KB fixed buffer app-side.
    buf: [256 * 1024]u8 = undefined,

    pub fn dirPath(self: *const Instance) []const u8 {
        return self.dir[0..self.dir_len];
    }
    pub fn sockPath(self: *const Instance) []const u8 {
        return self.sock[0..self.sock_len];
    }
    pub fn logPath(self: *const Instance) []const u8 {
        return self.log_path[0..self.log_len];
    }

    /// Spawn a sandboxed instance and wait until its shell is answering.
    pub fn start(gpa: std.mem.Allocator, rook_bin: []const u8, opts: Opts) !*Instance {
        const self = try gpa.create(Instance);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .pid = 0 };

        instance_seq += 1;
        const seq = instance_seq;

        // Everything under /tmp and SHORT. sun_path caps at 104 bytes and
        // an over-long path fails bind() SILENTLY — the app comes up
        // looking fine and nothing can talk to it. This bit the scratchpad
        // directory once; it is why these are not under the build dir.
        const dir = try std.fmt.bufPrint(&self.dir, "/tmp/rook-e2e-{d}-{d}", .{ getpid(), seq });
        self.dir_len = dir.len;
        const sock = try std.fmt.bufPrint(&self.sock, "{s}/s", .{dir});
        self.sock_len = sock.len;
        if (sock.len >= 100) return error.SpawnFailed;
        const log = try std.fmt.bufPrint(&self.log_path, "{s}/app.log", .{dir});
        self.log_len = log.len;

        try mkdirZ(dir);
        recordDir(dir);
        var cfgdir_buf: [160]u8 = undefined;
        const cfgdir = try std.fmt.bufPrint(&cfgdir_buf, "{s}/config", .{dir});
        try mkdirZ(cfgdir);
        var rookcfg_buf: [176]u8 = undefined;
        const rookcfg = try std.fmt.bufPrint(&rookcfg_buf, "{s}/rook", .{cfgdir});
        try mkdirZ(rookcfg);

        // A PINNED config, for bench.sh's reason: the developer's live
        // theme/opacity/font must not decide whether a test passes.
        var cfgfile_buf: [192]u8 = undefined;
        const cfgfile = try std.fmt.bufPrint(&cfgfile_buf, "{s}/config.toml", .{rookcfg});
        var cfg_buf: [1024]u8 = undefined;
        // A leader is set here because there is NO default one
        // (`Keybinds.leader` is `?u8 = null` — the user picks it), and
        // without it `handleCharKey` returns immediately, so every
        // leader chord is silently inert. A scenario testing `<leader>a`
        // would fail against a perfectly working app.
        const cfg = try std.fmt.bufPrint(&cfg_buf,
            \\font-family = "Menlo"
            \\font-size = 14
            \\leader = "`"
            \\{s}
            \\
        , .{opts.config_extra});
        try writeFileZ(cfgfile, cfg);

        // The sandbox gets its own HOME, for two reasons.
        //
        // Isolation: without it the test shell reads the developer's real
        // dotfiles, so whether a scenario passes depends on whose machine
        // it runs on.
        //
        // And determinism: rook starts LOGIN shells, so /etc/profile runs
        // and sets PS1 — an inherited PS1 from the environment is
        // overwritten before the first prompt is ever drawn. ~/.profile is
        // sourced after /etc/profile, so this is the one hook that wins.
        var home_buf: [160]u8 = undefined;
        const home = try std.fmt.bufPrint(&home_buf, "{s}/home", .{dir});
        try mkdirZ(home);
        var prof_buf: [192]u8 = undefined;
        const prof = try std.fmt.bufPrint(&prof_buf, "{s}/.profile", .{home});
        try writeFileZ(prof, "PS1='e2e$ '\nunset HISTFILE\n");

        const pid = try self.spawn(rook_bin, opts);
        self.pid = pid;

        // The socket appearing means the ctl thread bound; it does NOT
        // mean a shell is running yet.
        self.waitSocket(opts.boot_timeout_ms) catch |e| {
            self.dumpLog("instance never opened its ctl socket");
            self.hardKill();
            return e;
        };
        self.settle(opts.boot_timeout_ms) catch |e| {
            self.dumpLog("instance came up but its shell never answered");
            self.hardKill();
            return e;
        };
        return self;
    }

    fn spawn(self: *Instance, rook_bin: []const u8, opts: Opts) !c_int {
        var bin_z: [512]u8 = undefined;
        if (rook_bin.len >= bin_z.len) return error.SpawnFailed;
        @memcpy(bin_z[0..rook_bin.len], rook_bin);
        bin_z[rook_bin.len] = 0;

        var sock_z: [128]u8 = undefined;
        @memcpy(sock_z[0..self.sock_len], self.sockPath());
        sock_z[self.sock_len] = 0;
        var cfg_z: [160]u8 = undefined;
        const cfg = try std.fmt.bufPrint(&cfg_z, "{s}/config\x00", .{self.dirPath()});
        var data_z: [160]u8 = undefined;
        const data = try std.fmt.bufPrint(&data_z, "{s}/data\x00", .{self.dirPath()});
        var log_z: [160]u8 = undefined;
        @memcpy(log_z[0..self.log_len], self.logPath());
        log_z[self.log_len] = 0;
        var home_z: [160]u8 = undefined;
        const home = try std.fmt.bufPrint(&home_z, "{s}/home\x00", .{self.dirPath()});

        const pid = fork();
        if (pid < 0) return error.SpawnFailed;
        if (pid == 0) {
            _ = setsid();
            // stdio into the instance's own log. This is the difference
            // between "assertions timed out" and "the config had a typo
            // on line 3" — the app prints the latter and nothing was
            // listening before.
            const fd = open(@ptrCast(&log_z), O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
            if (fd >= 0) {
                _ = dup2(fd, 1);
                _ = dup2(fd, 2);
                const devnull = open("/dev/null", O_RDWR);
                if (devnull >= 0) _ = dup2(devnull, 0);
            }
            var f: c_int = 3;
            const maxfd = getdtablesize();
            while (f < maxfd) : (f += 1) _ = close(f);

            _ = setenv("ROOK_SOCK", @ptrCast(&sock_z), 1);
            _ = setenv("XDG_CONFIG_HOME", @ptrCast(cfg.ptr), 1);
            _ = setenv("XDG_DATA_HOME", @ptrCast(data.ptr), 1);
            // No rook-host, for bench.sh's reason: adopting the daily
            // driver's daemon would put its background work inside our
            // measurements, and spawning our own would REPLACE it and
            // kill the developer's live shells. An unwritable state dir
            // fails the spawn fast.
            _ = setenv("XDG_STATE_HOME", "/dev/null/no-host", 1);
            _ = setenv("SHELL", opts.shell, 1);
            _ = setenv("TERM", "xterm-256color", 1);
            // Not PS1 — a login shell's /etc/profile overwrites it. The
            // sandbox's own ~/.profile is what actually sets the prompt.
            _ = setenv("HOME", @ptrCast(home.ptr), 1);

            var argv: [3:null]?[*:0]const u8 = .{ @ptrCast(&bin_z), "win", "--no-activate" };
            _ = execv(@ptrCast(&bin_z), &argv);
            _exit(127);
        }
        return pid;
    }

    fn waitSocket(self: *Instance, timeout_ms: u32) !void {
        var waited: u32 = 0;
        while (waited < timeout_ms) {
            if (self.tryConnect()) |fd| {
                _ = close(fd);
                return;
            }
            _ = usleep(50_000);
            waited += 50;
        }
        return error.NeverCameUp;
    }

    /// Prove the shell is actually executing before any scenario types at
    /// it. Waiting for a prompt to be DRAWN is not enough — the pty can
    /// hold bytes the shell has not read yet, and that race is exactly
    /// what made the old suite flake on a cold sandbox.
    fn settle(self: *Instance, timeout_ms: u32) !void {
        var marker_buf: [64]u8 = undefined;
        const marker = try std.fmt.bufPrint(&marker_buf, "RDY{d}X", .{getpid()});
        // Deadline covers both halves; a prompt that never draws and a
        // shell that never runs are the same failure to a caller.
        var waited: u32 = 0;
        while (waited < timeout_ms) {
            const d = self.ctl("dump") catch "";
            if (std.mem.indexOf(u8, d, "$") != null) break;
            _ = usleep(100_000);
            waited += 100;
        }
        var cmd_buf: [128]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&cmd_buf, "type echo {s}", .{marker});
        _ = try self.ctl(cmd);
        _ = try self.ctl("enter");
        // Two occurrences: the echoed command line, then its output.
        try self.waitTextCount(marker, 2, timeout_ms -| waited);
    }

    fn tryConnect(self: *Instance) ?c_int {
        var addr: sockaddr_un = .{};
        const p = self.sockPath();
        if (p.len >= addr.sun_path.len) return null;
        @memcpy(addr.sun_path[0..p.len], p);
        const fd = socket(1, 1, 0);
        if (fd < 0) return null;
        if (connect(fd, &addr, @sizeOf(sockaddr_un)) != 0) {
            _ = close(fd);
            return null;
        }
        return fd;
    }

    /// One command, one connection — matching `nc -U`. The server reads
    /// lines until EOF and replies are NOT framed, so half-closing after
    /// the write is the only way to know where a reply ends.
    pub fn ctl(self: *Instance, cmd: []const u8) ![]const u8 {
        const fd = self.tryConnect() orelse return error.CtlFailed;
        defer _ = close(fd);
        var line: [4096]u8 = undefined;
        if (cmd.len + 1 > line.len) return error.CtlFailed;
        @memcpy(line[0..cmd.len], cmd);
        line[cmd.len] = '\n';
        var off: usize = 0;
        while (off < cmd.len + 1) {
            const n = write(fd, line[off..].ptr, cmd.len + 1 - off);
            if (n <= 0) return error.CtlFailed;
            off += @intCast(n);
        }
        _ = shutdown(fd, SHUT_WR);
        var len: usize = 0;
        while (len < self.buf.len) {
            const n = read(fd, self.buf[len..].ptr, self.buf.len - len);
            if (n <= 0) break;
            len += @intCast(n);
        }
        return self.buf[0..len];
    }

    pub fn ctlFmt(self: *Instance, comptime fmt: []const u8, args: anytype) ![]const u8 {
        var cmd: [2048]u8 = undefined;
        return self.ctl(try std.fmt.bufPrint(&cmd, fmt, args));
    }

    /// The screen with the `pane N grid CxR` header removed, every line
    /// right-trimmed, and newlines dropped.
    ///
    /// Joining is deliberate: a pane wraps at its width, so a shell
    /// printing "total" can land as "t" + "otal" across two rows and a
    /// naive grep reports a stall that isn't happening. That cost 15
    /// minutes once and is now the default matching mode.
    pub fn screen(self: *Instance, out: []u8) ![]const u8 {
        const raw = try self.ctl("dump");
        const body = if (std.mem.indexOfScalar(u8, raw, '\n')) |nl| raw[nl + 1 ..] else raw;
        var len: usize = 0;
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |row| {
            const trimmed = std.mem.trimEnd(u8, row, " \t\r");
            if (len + trimmed.len > out.len) break;
            @memcpy(out[len..][0..trimmed.len], trimmed);
            len += trimmed.len;
        }
        return out[0..len];
    }

    pub fn waitText(self: *Instance, needle: []const u8, timeout_ms: u32) !void {
        return self.waitTextCount(needle, 1, timeout_ms);
    }

    pub fn waitTextCount(self: *Instance, needle: []const u8, want: usize, timeout_ms: u32) !void {
        var scratch: [256 * 1024]u8 = undefined;
        var waited: u32 = 0;
        while (true) {
            const s = self.screen(&scratch) catch "";
            var seen: usize = 0;
            var i: usize = 0;
            while (std.mem.indexOfPos(u8, s, i, needle)) |at| {
                seen += 1;
                i = at + needle.len;
            }
            if (seen >= want) return;
            if (waited >= timeout_ms) {
                std.debug.print(
                    "      waited {d}ms for {d}x \"{s}\" in the screen, saw {d}\n",
                    .{ timeout_ms, want, needle, seen },
                );
                self.showScreen();
                return error.Timeout;
            }
            _ = usleep(100_000);
            waited += 100;
        }
    }

    /// Number of panes across every tab (`panes` prints one per line).
    pub fn paneCount(self: *Instance) !usize {
        const r = try self.ctl("panes");
        return countLines(r);
    }

    pub fn tabCount(self: *Instance) !usize {
        const r = try self.ctl("tabs");
        return countLines(r);
    }

    /// The id of the focused pane of the ACTIVE tab.
    ///
    /// `panes` prints TWO markers per row and they mean different things:
    /// column 0 is "this row's space+tab is the active one", and the `*`
    /// before the id is "focused within its own tab". Every tab has one
    /// of the latter, so matching on it alone always reports tab 1 and
    /// makes tab switching look like a no-op.
    pub fn focusedPane(self: *Instance) !u32 {
        const r = try self.ctl("panes");
        var it = std.mem.splitScalar(u8, r, '\n');
        while (it.next()) |row| {
            if (row.len == 0 or row[0] != '*') continue;
            // "* label t1 *3 rect ..." — find the marker before the id.
            const t = std.mem.indexOf(u8, row, " t") orelse continue;
            const after = row[t + 2 ..];
            const sp = std.mem.indexOfScalar(u8, after, ' ') orelse continue;
            const rest = after[sp + 1 ..];
            if (rest.len == 0 or rest[0] != '*') continue;
            const idstr = rest[1..];
            const end = std.mem.indexOfScalar(u8, idstr, ' ') orelse idstr.len;
            return std.fmt.parseInt(u32, idstr[0..end], 10) catch continue;
        }
        return error.AssertFailed;
    }

    pub fn shot(self: *Instance, path: []const u8) !Shot {
        _ = try self.ctlFmt("shot {s}", .{path});
        return Shot.load(path);
    }

    /// Print the current screen, indented. Called automatically whenever
    /// a wait times out — a failure that shows the screen is a failure an
    /// agent can act on without a second round trip.
    pub fn showScreen(self: *Instance) void {
        const raw = self.ctl("dump") catch return;
        std.debug.print("      --- screen ---\n", .{});
        var it = std.mem.splitScalar(u8, raw, '\n');
        var n: usize = 0;
        while (it.next()) |row| : (n += 1) {
            if (n > 60) break;
            const t = std.mem.trimEnd(u8, row, " \t\r");
            if (t.len > 0) std.debug.print("      | {s}\n", .{t});
        }
    }

    /// Tail of the app's own stdout/stderr.
    pub fn dumpLog(self: *Instance, why: []const u8) void {
        std.debug.print("      {s}\n", .{why});
        const fd = open(@ptrCast(nullTerm(self.logPath(), &log_scratch)), 0);
        if (fd < 0) return;
        defer _ = close(fd);
        var buf: [8192]u8 = undefined;
        const n = read(fd, &buf, buf.len);
        if (n <= 0) return;
        std.debug.print("      --- app log ({s}) ---\n", .{self.logPath()});
        var it = std.mem.splitScalar(u8, buf[0..@intCast(n)], '\n');
        while (it.next()) |row| {
            if (row.len > 0) std.debug.print("      | {s}\n", .{row});
        }
    }

    /// Ask nicely, then insist. A lingering instance is not just a leaked
    /// process: it still holds its socket, and the never-steal rule means
    /// the NEXT instance at that path refuses to serve rather than
    /// stealing it.
    pub fn stop(self: *Instance) void {
        _ = self.ctl("quit") catch {};
        var waited: u32 = 0;
        while (waited < 3000) {
            if (waitpid(self.pid, null, WNOHANG) == self.pid) break;
            _ = usleep(50_000);
            waited += 50;
        }
        self.hardKill();
    }

    fn hardKill(self: *Instance) void {
        if (self.pid > 0) {
            _ = kill(self.pid, SIGKILL);
            _ = waitpid(self.pid, null, 0);
            self.pid = 0;
        }
        var z: [128]u8 = undefined;
        _ = unlink(@ptrCast(nullTerm(self.sockPath(), &z)));
    }

    pub fn deinit(self: *Instance) void {
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

var log_scratch: [256]u8 = undefined;

fn nullTerm(s: []const u8, buf: []u8) [*:0]const u8 {
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return @ptrCast(buf.ptr);
}

fn mkdirZ(path: []const u8) !void {
    var z: [256]u8 = undefined;
    _ = mkdir(nullTerm(path, &z), 0o755);
}

fn writeFileZ(path: []const u8, data: []const u8) !void {
    var z: [256]u8 = undefined;
    const fd = open(nullTerm(path, &z), O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
    if (fd < 0) return error.SpawnFailed;
    defer _ = close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const n = write(fd, data.ptr + off, data.len - off);
        if (n <= 0) return error.SpawnFailed;
        off += @intCast(n);
    }
}

pub fn readFile(path: []const u8, out: []u8) ![]const u8 {
    var z: [256]u8 = undefined;
    const fd = open(nullTerm(path, &z), 0);
    if (fd < 0) return error.AssertFailed;
    defer _ = close(fd);
    const n = read(fd, out.ptr, out.len);
    if (n < 0) return error.AssertFailed;
    return out[0..@intCast(n)];
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    return writeFileZ(path, data);
}

/// std.Thread.sleep does not exist in Zig 0.16; scenarios that poll for
/// state the ctl socket cannot block on use this.
pub fn sleepMs(ms: u32) void {
    _ = usleep(ms * 1000);
}

const timeval = extern struct { sec: i64, usec: i32 };
extern "c" fn gettimeofday(tv: *timeval, tz: ?*anyopaque) c_int;

/// std.time.milliTimestamp is gone in 0.16 too.
pub fn nowMs() i64 {
    var tv: timeval = undefined;
    _ = gettimeofday(&tv, null);
    return tv.sec * 1000 + @divTrunc(@as(i64, tv.usec), 1000);
}

/// Sandbox dirs created this run, so a clean run can tidy up after
/// itself. A FAILING run deliberately leaves them: the app log and any
/// shot are in there, and they are most of what makes a failure
/// diagnosable without re-running it.
var made_dirs: [64][128]u8 = undefined;
var made_lens: [64]usize = @splat(0);
var made_n: usize = 0;

fn recordDir(path: []const u8) void {
    if (made_n >= made_dirs.len or path.len > made_dirs[0].len) return;
    @memcpy(made_dirs[made_n][0..path.len], path);
    made_lens[made_n] = path.len;
    made_n += 1;
}

/// fork+exec `rm -rf` rather than a std recursive delete: std.fs.cwd()
/// does not exist in Zig 0.16 (nor std.Thread.sleep, nor
/// std.time.milliTimestamp — this file has now hit three). The paths are
/// ours and namespaced by our own pid, so the blast radius is fixed.
pub fn cleanupSandboxes() void {
    for (0..made_n) |i| {
        var z: [130]u8 = undefined;
        const p = nullTerm(made_dirs[i][0..made_lens[i]], &z);
        const pid = fork();
        if (pid < 0) continue;
        if (pid == 0) {
            var argv: [4:null]?[*:0]const u8 = .{ "/bin/rm", "-rf", p, null };
            _ = execv("/bin/rm", &argv);
            _exit(127);
        }
        _ = waitpid(pid, null, 0);
    }
    made_n = 0;
}

pub fn sandboxCount() usize {
    return made_n;
}

fn countLines(s: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |row| {
        if (std.mem.trim(u8, row, " \t\r").len > 0) n += 1;
    }
    return n;
}

// ---------------------------------------------------------------- pixels

extern "c" fn CFURLCreateFromFileSystemRepresentation(alloc: ?*anyopaque, path: [*]const u8, len: isize, is_dir: bool) ?*anyopaque;
extern "c" fn CFRelease(obj: ?*anyopaque) void;
extern "c" fn CGImageSourceCreateWithURL(url: ?*anyopaque, opts: ?*anyopaque) ?*anyopaque;
extern "c" fn CGImageSourceCreateImageAtIndex(src: ?*anyopaque, idx: usize, opts: ?*anyopaque) ?*anyopaque;
extern "c" fn CGImageGetWidth(img: ?*anyopaque) usize;
extern "c" fn CGImageGetHeight(img: ?*anyopaque) usize;
extern "c" fn CGImageGetBytesPerRow(img: ?*anyopaque) usize;
extern "c" fn CGImageGetDataProvider(img: ?*anyopaque) ?*anyopaque;
extern "c" fn CGDataProviderCopyData(p: ?*anyopaque) ?*anyopaque;
extern "c" fn CFDataGetBytePtr(d: ?*anyopaque) [*]const u8;
extern "c" fn CFDataGetLength(d: ?*anyopaque) isize;

/// A screenshot read back as pixels.
///
/// `shot` writing a file only proves the round trip; it does not prove
/// the renderer drew anything. Decoding it is what makes pixel truth
/// ASSERTABLE — which is the half of "Claude can see rook" that a text
/// dump structurally cannot give you.
pub const Shot = struct {
    width: usize,
    height: usize,
    stride: usize,
    data: ?*anyopaque, // CFData, released in deinit
    px: []const u8, // BGRX

    pub fn load(path: []const u8) !Shot {
        const url = CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), false) orelse return error.ShotFailed;
        defer CFRelease(url);
        const src = CGImageSourceCreateWithURL(url, null) orelse return error.ShotFailed;
        defer CFRelease(src);
        const img = CGImageSourceCreateImageAtIndex(src, 0, null) orelse return error.ShotFailed;
        defer CFRelease(img);
        const provider = CGImageGetDataProvider(img) orelse return error.ShotFailed;
        const data = CGDataProviderCopyData(provider) orelse return error.ShotFailed;
        const len = CFDataGetLength(data);
        if (len <= 0) {
            CFRelease(data);
            return error.ShotFailed;
        }
        return .{
            .width = CGImageGetWidth(img),
            .height = CGImageGetHeight(img),
            .stride = CGImageGetBytesPerRow(img),
            .data = data,
            .px = CFDataGetBytePtr(data)[0..@intCast(len)],
        };
    }

    pub fn deinit(self: *Shot) void {
        if (self.data) |d| CFRelease(d);
        self.data = null;
    }

    pub fn pixel(self: *const Shot, x: usize, y: usize) u32 {
        const off = y * self.stride + x * 4;
        if (off + 3 >= self.px.len) return 0;
        return (@as(u32, self.px[off]) << 16) | (@as(u32, self.px[off + 1]) << 8) | @as(u32, self.px[off + 2]);
    }

    /// Pixels in a band that differ from the background, sampled at
    /// full resolution. "Did this actually draw" for a REGION, where
    /// `distinctColors` only answers it for the whole window.
    pub fn ink(self: *const Shot, y0: usize, y1: usize) usize {
        const bg = self.pixel(self.width - 2, y0);
        var n: usize = 0;
        var y = y0;
        while (y < @min(y1, self.height)) : (y += 1) {
            var x: usize = 0;
            while (x < self.width) : (x += 1) {
                if (self.pixel(x, y) != bg) n += 1;
            }
        }
        return n;
    }

    /// Distinct colours, capped. A window that drew nothing is one
    /// colour; a window with a prompt and chrome is many. This is the
    /// cheapest assertion that separates "rendered" from "cleared".
    pub fn distinctColors(self: *const Shot, cap: usize) usize {
        var seen: [64]u32 = undefined;
        var n: usize = 0;
        var y: usize = 0;
        while (y < self.height) : (y += @max(1, self.height / 64)) {
            var x: usize = 0;
            while (x < self.width) : (x += @max(1, self.width / 64)) {
                const c = self.pixel(x, y);
                var found = false;
                for (seen[0..n]) |s| {
                    if (s == c) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    if (n < seen.len) seen[n] = c;
                    n += 1;
                    if (n >= cap) return n;
                }
            }
        }
        return n;
    }
};

// ------------------------------------------------------------ assertions

pub fn expect(ok: bool, comptime fmt: []const u8, args: anytype) !void {
    if (ok) return;
    std.debug.print("      assertion failed: " ++ fmt ++ "\n", args);
    return error.AssertFailed;
}

pub fn expectEq(comptime label: []const u8, want: usize, got: usize) !void {
    if (want == got) return;
    std.debug.print("      assertion failed: {s} — want {d}, got {d}\n", .{ label, want, got });
    return error.AssertFailed;
}

pub fn expectContains(haystack: []const u8, needle: []const u8, comptime label: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) return;
    std.debug.print("      assertion failed: {s} — no \"{s}\" in:\n", .{ label, needle });
    var it = std.mem.splitScalar(u8, haystack, '\n');
    var n: usize = 0;
    while (it.next()) |row| : (n += 1) {
        if (n > 40) break;
        if (row.len > 0) std.debug.print("      | {s}\n", .{row});
    }
    return error.AssertFailed;
}
