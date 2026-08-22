//! Minimal macOS PTY: openpty + fork/exec a child attached to the slave.
//! Shape borrowed from ghostty's src/pty.zig, reduced to what rook needs.
//! Libc is addressed directly — Zig 0.16's std.posix no longer wraps the
//! process-control calls, and this file is exactly the C incantation anyway.

const std = @import("std");

pub const fd_t = c_int;
pub const pid_t = c_int;

pub const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16 = 0,
    ws_ypixel: u16 = 0,
};

extern "c" fn openpty(master: *fd_t, slave: *fd_t, name: ?[*]u8, termp: ?*const anyopaque, winp: ?*const Winsize) c_int;
extern "c" fn fcntl(fd: fd_t, cmd: c_int, ...) c_int;
extern "c" fn ioctl(fd: fd_t, request: c_ulong, ...) c_int;
extern "c" fn fork() pid_t;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn setsid() pid_t;
extern "c" fn dup2(old: fd_t, new: fd_t) c_int;
extern "c" fn close(fd: fd_t) c_int;
extern "c" fn execvp(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn getdtablesize() c_int;
extern "c" fn waitpid(pid: pid_t, status: ?*c_int, options: c_int) pid_t;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn read(fd: fd_t, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: fd_t, buf: [*]const u8, n: usize) isize;

// Values from macOS headers.
const F_GETFD = 1;
const F_SETFD = 2;
const F_GETFL = 3;
const F_SETFL = 4;
const FD_CLOEXEC = 1;
const O_NONBLOCK = 0x0004;
const TIOCSCTTY = 0x20007461;
const TIOCSWINSZ = 0x80087467;
extern "c" var environ: [*:null]const ?[*:0]const u8;

pub const Pollfd = extern struct {
    fd: fd_t,
    events: i16,
    revents: i16 = 0,
};
pub const POLLIN: i16 = 0x0001;
pub const POLLOUT: i16 = 0x0004;
pub const POLLERR: i16 = 0x0008;
pub const POLLHUP: i16 = 0x0010;
extern "c" fn poll(fds: [*]Pollfd, nfds: u32, timeout_ms: c_int) c_int;

/// One poll on one fd — the shape both the gather loop's waits and
/// writeMaster's backpressure need. Returns the revents, 0 on timeout,
/// and folds a poll error into POLLERR so callers have one channel.
pub fn pollOne(fd: fd_t, events: i16, timeout_ms: c_int) i16 {
    var fds = [1]Pollfd{.{ .fd = fd, .events = events }};
    const r = poll(&fds, 1, timeout_ms);
    if (r < 0) return POLLERR;
    if (r == 0) return 0;
    return fds[0].revents;
}

/// The many-fd spelling, for the bridge poll's pty+idle-pipe pair.
pub fn pollMany(fds: [*]Pollfd, n: u32, timeout_ms: c_int) c_int {
    return poll(fds, n, timeout_ms);
}

extern "c" fn pipe(fds: *[2]fd_t) c_int;

/// A non-blocking, cloexec self-pipe — the parse stage's way to
/// interrupt a gather-stage bridge poll. Null when the OS refuses;
/// the pipeline still runs, bridge polls just ride out their timeout.
pub fn makePipeNb() ?[2]fd_t {
    var fds: [2]fd_t = undefined;
    if (pipe(&fds) < 0) return null;
    for (fds) |fd| {
        _ = fcntl(fd, F_SETFD, @as(c_int, FD_CLOEXEC));
        _ = setNonblock(fd);
    }
    return fds;
}

pub fn writeByte(fd: fd_t, b: u8) bool {
    return write(fd, &[1]u8{b}, 1) == 1;
}

/// Empty a non-blocking fd (the idle pipe, after its wake fired).
pub fn drainFd(fd: fd_t) void {
    var t: [16]u8 = undefined;
    while (read(fd, &t, t.len) > 0) {}
}

pub fn closeFd(fd: fd_t) void {
    _ = close(fd);
}

/// Put the fd in non-blocking mode. The gather loop cannot run on a
/// blocking master — a blocking read would park it on a quiet pty
/// with no way to notice the parse stage. True on success.
pub fn setNonblock(fd: fd_t) bool {
    const flags = fcntl(fd, F_GETFL, @as(c_int, 0));
    if (flags < 0) return false;
    return fcntl(fd, F_SETFL, @as(c_int, flags | O_NONBLOCK)) >= 0;
}

extern "c" fn killpg(pgrp: pid_t, sig: c_int) c_int;
extern "c" fn tcgetpgrp(fd: fd_t) pid_t;
extern "c" fn usleep(us: u32) c_int;
extern "c" fn __error() *c_int;
const EAGAIN = 35; // macOS EAGAIN == EWOULDBLOCK

fn errno() c_int {
    return __error().*;
}

extern "c" fn pthread_set_qos_class_self_np(qos: c_uint, rel: c_int) c_int;
const QOS_CLASS_USER_INITIATED: c_uint = 0x19;

/// Raise the calling thread to user-initiated QoS. Both halves of the
/// read pipeline feed content the user is watching, and at default QoS
/// the scheduler parks them on efficiency cores whose wakeup latency
/// is large against the ~10µs producer/consumer cadence — ghostty
/// measured 15% throughput on this alone (their termio setQosClass).
pub fn setQosUserInitiated() void {
    _ = pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
}

pub const SIGHUP: c_int = 1;
pub const SIGKILL: c_int = 9;
pub const SIGTERM: c_int = 15;

/// How long a hung-up process group gets to exit before the next,
/// harder signal. Two of these bound the whole escalation at 200ms —
/// long enough for a shell to save its history, short enough that ⌘Q
/// waiting on it is imperceptible.
pub const grace_us: u32 = 100_000;

/// The process groups a closing pane must signal, captured while the
/// pty master is still open — tcgetpgrp only answers on a live fd —
/// and held as plain ids so the escalation can outlive the Session
/// that owned them.
///
/// Two groups, not one: SIGHUP to the shell is not teardown on its
/// own. Under job control the foreground job runs in its OWN process
/// group, which a signal to the shell's group never reaches, and a
/// job that traps SIGHUP shrugs off the kernel's hangup when the
/// master closes. zed shipped that orphan twice (zed#47412, #61467);
/// this is their eventual shape.
pub const ProcessGroups = struct {
    /// The shell leads its own session (spawnIn's child calls setsid
    /// before exec), so its pid IS its process-group id.
    shell: pid_t,
    /// Whoever the tty says is foreground right now; -1 when nobody is.
    fg: pid_t,

    pub fn capture(master: fd_t, shell_pid: pid_t) ProcessGroups {
        return .{ .shell = shell_pid, .fg = tcgetpgrp(master) };
    }

    /// Signal both groups. Ids that aren't real groups never get
    /// through: killpg(0) signals ROOK's own process group — the whole
    /// app — and tcgetpgrp's failure spelling is negative.
    pub fn signal(self: ProcessGroups, sig: c_int) void {
        if (self.shell > 0) _ = killpg(self.shell, sig);
        if (self.fg > 0 and self.fg != self.shell) _ = killpg(self.fg, sig);
    }

    /// Signal 0 is the existence probe: nothing is delivered, but the
    /// group lookup still happens. An unreaped zombie still counts as
    /// alive here, which only costs a harmless extra signal later.
    pub fn alive(self: ProcessGroups) bool {
        if (self.shell > 0 and killpg(self.shell, 0) == 0) return true;
        if (self.fg > 0 and self.fg != self.shell and killpg(self.fg, 0) == 0) return true;
        return false;
    }

    /// The escalation tail after a SIGHUP already went out: grace, then
    /// SIGTERM survivors, grace again, then SIGKILL what remains. Runs
    /// on a detached thread (pane close) or blocking (app quit); by
    /// value, because the Session that captured these ids is freed the
    /// moment its shell exits. The alive() gates keep an id whose group
    /// already died — and could in principle be reused — from being
    /// signalled again.
    pub fn escalate(self: ProcessGroups) void {
        _ = usleep(grace_us);
        if (!self.alive()) return;
        self.signal(SIGTERM);
        _ = usleep(grace_us);
        if (!self.alive()) return;
        self.signal(SIGKILL);
    }
};

/// App-quit teardown for every session at once, BLOCKING: this runs on
/// the last observable moment before the process exits, and a detached
/// thread would not survive that exit. Process exit closes every
/// master, but the kernel's hangup on a closing master reaches only
/// the foreground group and does nothing to a job that traps SIGHUP —
/// so quit sends SIGHUP and SIGTERM together (everything is going down
/// now; there is no politer second chance coming), waits one grace,
/// and SIGKILLs survivors. Nothing reaps during quit, so a dead shell
/// reads as an alive zombie — signalling it anyway is harmless.
pub fn terminateAll(groups: []const ProcessGroups) void {
    if (groups.len == 0) return;
    for (groups) |g| {
        g.signal(SIGHUP);
        g.signal(SIGTERM);
    }
    _ = usleep(grace_us);
    for (groups) |g| if (g.alive()) g.signal(SIGKILL);
}

pub const Pty = struct {
    master: fd_t,
    slave: fd_t,

    pub fn open(size: Winsize) !Pty {
        var master_fd: fd_t = undefined;
        var slave_fd: fd_t = undefined;
        if (openpty(&master_fd, &slave_fd, null, null, &size) < 0)
            return error.OpenptyFailed;
        errdefer {
            _ = close(master_fd);
            _ = close(slave_fd);
        }

        // Only the slave side may be inherited by the child.
        const flags = fcntl(master_fd, F_GETFD);
        if (flags < 0) return error.FcntlFailed;
        if (fcntl(master_fd, F_SETFD, flags | FD_CLOEXEC) < 0) return error.FcntlFailed;

        return .{ .master = master_fd, .slave = slave_fd };
    }

    pub fn deinit(self: *Pty) void {
        _ = close(self.master);
        self.* = undefined;
    }

    pub fn setSize(self: *Pty, size: Winsize) !void {
        if (ioctl(self.master, TIOCSWINSZ, @intFromPtr(&size)) < 0)
            return error.IoctlFailed;
    }

    /// Read from the master into buf. Returns 0 at EOF/EIO (child gone).
    pub fn readMaster(self: *Pty, buf: []u8) usize {
        const n = read(self.master, buf.ptr, buf.len);
        if (n <= 0) return 0;
        return @intCast(n);
    }

    /// The non-blocking spelling, for the gather loop: it has to tell
    /// "queue momentarily dry" (bridgeable) apart from "child gone"
    /// (the stream is over), which the blocking read folds together.
    pub const ReadNb = union(enum) { got: usize, dry, gone };
    pub fn readMasterNb(self: *Pty, buf: []u8) ReadNb {
        const n = read(self.master, buf.ptr, buf.len);
        if (n > 0) return .{ .got = @intCast(n) };
        // n == 0 is EOF; a negative with EAGAIN is an empty queue and
        // anything else (EIO, EBADF) is the child going away.
        if (n < 0 and errno() == EAGAIN) return .dry;
        return .gone;
    }

    /// Write input bytes to the master (keystrokes for the child).
    ///
    /// The master runs non-blocking once a session's read pipeline is
    /// up (O_NONBLOCK is a property of the file description, so the
    /// read side's choice binds this side too). A full input queue —
    /// a large paste into a slow reader — then answers EAGAIN, and
    /// dropping the rest of the paste on the floor is not an option:
    /// wait for writability and continue.
    pub fn writeMaster(self: *Pty, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = write(self.master, bytes.ptr + off, bytes.len - off);
            if (n < 0 and errno() == EAGAIN) {
                const ev = pollOne(self.master, POLLOUT, 1000);
                if (ev & (POLLERR | POLLHUP) != 0) return error.WriteFailed;
                continue;
            }
            if (n <= 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }

    /// Fork and exec argv (PATH-resolved) with the slave as controlling tty
    /// on stdio. env entries are appended to the inherited environment by
    /// setenv semantics — we just prepend via execvp using the parent env,
    /// so callers should set anything custom with setenv() before spawn.
    /// Returns the child pid in the parent; never returns in the child.
    /// Closes the slave fd in the parent.
    pub fn spawn(self: *Pty, argv: []const [*:0]const u8) !pid_t {
        return self.spawnIn(argv, null);
    }

    /// spawn with an optional working directory for the child (a
    /// failed chdir falls through to the inherited cwd).
    pub fn spawnIn(self: *Pty, argv: []const [*:0]const u8, cwd: ?[*:0]const u8) !pid_t {
        var argv_buf: [64:null]?[*:0]const u8 = undefined;
        if (argv.len >= argv_buf.len) return error.TooManyArgs;
        for (argv, 0..) |a, i| argv_buf[i] = a;
        argv_buf[argv.len] = null;

        const pid = fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            // Child. New session, controlling terminal, stdio on the slave.
            if (setsid() < 0) _exit(127);
            if (ioctl(self.slave, TIOCSCTTY, @as(c_ulong, 0)) < 0) _exit(127);
            if (dup2(self.slave, 0) < 0) _exit(127);
            if (dup2(self.slave, 1) < 0) _exit(127);
            if (dup2(self.slave, 2) < 0) _exit(127);
            // Everything above stdio dies here: inherited fds leak into
            // the shell otherwise — a ctl CONNECTION held by a child
            // kept nc from ever seeing EOF (a spawn racing an open ctl
            // conn: leader-c from `press`), and pty masters/sockets
            // shouldn't outlive the app in children either.
            var cfd: c_int = 3;
            const maxfd = getdtablesize();
            while (cfd < maxfd) : (cfd += 1) _ = close(cfd);
            if (cwd) |d| _ = chdir(d);

            _ = execvp(argv[0], &argv_buf);
            _exit(127);
        }

        // Parent.
        _ = close(self.slave);
        return pid;
    }

    pub fn wait(pid: pid_t) c_int {
        var status: c_int = 0;
        _ = waitpid(pid, &status, 0);
        return status;
    }
};

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// Set an environment variable in this process (inherited by spawned children).
pub fn setEnv(name: [*:0]const u8, value: [*:0]const u8) void {
    _ = setenv(name, value, 1);
}

extern "c" fn unsetenv(name: [*:0]const u8) c_int;
pub fn unsetEnv(name: [*:0]const u8) void {
    _ = unsetenv(name);
}

// ---- teardown escalation tests ----
//
// These spawn real shells on a real pty, in the lsp.zig tradition of
// the two tests that DO spawn: the property under test is a kernel
// behaviour (signal dispositions across process groups), and no mock
// can fail the way the kernel does.

/// Drain the master until `marker` shows up — the shell echoes it AFTER
/// installing its traps, so seeing it proves the traps are in place and
/// the test can't pass vacuously by signalling a shell that hadn't
/// gotten around to ignoring the signal yet.
fn readUntil(pty: *Pty, marker: []const u8) !void {
    var seen: [4096]u8 = undefined;
    var len: usize = 0;
    while (len < seen.len) {
        const n = pty.readMaster(seen[len..]);
        if (n == 0) return error.ChildGone;
        len += n;
        if (std.mem.indexOf(u8, seen[0..len], marker) != null) return;
    }
    return error.MarkerNotSeen;
}

/// Reap the child within ~2s or fail — a blocking waitpid here would
/// turn a regression (the child survived escalation) into a hung test
/// run instead of a red one.
fn reapWithin(pid: pid_t) !c_int {
    const WNOHANG: c_int = 1;
    var tries: u32 = 0;
    while (tries < 200) : (tries += 1) {
        var status: c_int = 0;
        if (waitpid(pid, &status, WNOHANG) == pid) return status;
        _ = usleep(10_000);
    }
    return error.ChildStillAlive;
}

/// Poll until the group probe says gone, up to ~2s — the inner job of
/// the job-control test is a grandchild launchd reaps on its own
/// schedule, so "dead" is eventually-consistent from out here.
fn expectGroupGone(pgid: pid_t) !void {
    var tries: u32 = 0;
    while (tries < 200) : (tries += 1) {
        if (killpg(pgid, 0) != 0) return;
        _ = usleep(10_000);
    }
    return error.GroupStillAlive;
}

test "escalation kills a shell that traps SIGHUP and SIGTERM" {
    var pty = try Pty.open(.{ .ws_row = 24, .ws_col = 80 });
    defer pty.deinit();
    // `trap ''` = ignore, and ignored dispositions are INHERITED, so
    // the `sleep` children shrug off HUP and TERM exactly like the
    // shell — only the SIGKILL step can end this group.
    const argv = [_][*:0]const u8{ "/bin/sh", "-c", "trap '' HUP TERM; echo R34DY; while :; do sleep 1; done" };
    const pid = try pty.spawnIn(&argv, null);
    try readUntil(&pty, "R34DY");

    const groups = ProcessGroups.capture(pty.master, pid);

    // Vacuity guard: SIGHUP alone — the pre-fix teardown — must NOT
    // kill this shell, or the escalation below proves nothing.
    groups.signal(SIGHUP);
    _ = usleep(grace_us + grace_us / 2);
    try std.testing.expect(groups.alive());

    groups.escalate();
    // escalate's last word was SIGKILL; the shell must be reapable now,
    // and by that signal — anything else means something ELSE killed it.
    const status = try reapWithin(pid);
    try std.testing.expectEqual(SIGKILL, status & 0x7f);
    try expectGroupGone(pid);
}

test "escalation reaches a foreground job in its own process group" {
    var pty = try Pty.open(.{ .ws_row = 24, .ws_col = 80 });
    defer pty.deinit();
    // `set -m` turns on job control: the inner sh runs as a foreground
    // job in its OWN process group, which is the exact topology where
    // signalling only the shell's group orphans the job (zed#47412).
    const argv = [_][*:0]const u8{ "/bin/sh", "-c", "trap '' HUP TERM; set -m; sh -c 'trap \"\" HUP TERM; echo R34DY; while :; do sleep 1; done'" };
    const pid = try pty.spawnIn(&argv, null);
    try readUntil(&pty, "R34DY");

    const groups = ProcessGroups.capture(pty.master, pid);
    // The scenario must be real: a foreground group DISTINCT from the
    // shell's, or this test collapses into the one above.
    try std.testing.expect(groups.fg > 0);
    try std.testing.expect(groups.fg != groups.shell);

    groups.signal(SIGHUP);
    groups.escalate();
    _ = try reapWithin(pid);
    // The inner job is a grandchild we cannot waitpid; the group probe
    // going dark is what "not orphaned" means from the outside.
    try expectGroupGone(groups.fg);
    try expectGroupGone(groups.shell);
}

// ---- rook-mux additions: raw-fd helpers the server/client loops use ----

pub fn setNonblockFd(fd: fd_t) bool {
    return setNonblock(fd);
}

/// Nonblocking read on any fd: bytes read, 0 on EOF, -1 when dry/error.
pub fn readNb(fd: fd_t, buf: []u8) isize {
    const n = read(fd, buf.ptr, buf.len);
    return n;
}

/// Blocking-ish write-all on any fd (spins on EAGAIN with a poll).
/// One nonblocking write: bytes written, 0 when the kernel buffer is
/// full (EAGAIN — poll for POLLOUT), error otherwise.
pub fn writeNbFd(fd: fd_t, bytes: []const u8) !usize {
    const n = write(fd, bytes.ptr, bytes.len);
    if (n < 0) {
        if (errno() == EAGAIN) return 0;
        return error.WriteFailed;
    }
    return @intCast(n);
}

pub fn writeAllFd(fd: fd_t, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes.ptr + off, bytes.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        if (n < 0) {
            // EAGAIN: wait for writability; anything else is fatal.
            if (pollOne(fd, POLLOUT, 1000) & POLLERR != 0) return false;
            continue;
        }
        return false;
    }
    return true;
}

pub fn fork_() pid_t {
    return fork();
}
pub fn setsid_() pid_t {
    return setsid();
}
pub fn dup2_(old: fd_t, new: fd_t) c_int {
    return dup2(old, new);
}
pub fn execvp_(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int {
    return execvp(path, argv);
}
pub fn exit_(code: c_int) noreturn {
    _exit(code);
}

extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

pub fn unlinkPath(path: []const u8) void {
    var buf: [1024]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = unlink(buf[0..path.len :0]);
}

/// mkdir -p, C spelling. Silently best-effort.
pub fn makePath(path: []const u8) void {
    var buf: [1024]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or buf[i] == '/') {
            const save = buf[i];
            buf[i] = 0;
            _ = mkdir(buf[0..i :0], 0o755);
            buf[i] = save;
        }
    }
}

// ---- unix sockets, C spelling (std.net left for std.Io.net in 0.16) ----
const sockaddr_un = extern struct {
    len: u8 = 0,
    family: u8 = 1, // AF_UNIX
    path: [104]u8 = @splat(0),
};
extern "c" fn socket(domain: c_int, tp: c_int, protocol: c_int) fd_t;
extern "c" fn bind(fd: fd_t, addr: *const sockaddr_un, len: c_uint) c_int;
extern "c" fn listen(fd: fd_t, backlog: c_int) c_int;
extern "c" fn accept(fd: fd_t, addr: ?*sockaddr_un, len: ?*c_uint) fd_t;
extern "c" fn connect(fd: fd_t, addr: *const sockaddr_un, len: c_uint) c_int;
const AF_UNIX: c_int = 1;
const SOCK_STREAM: c_int = 1;

fn unAddr(path: []const u8) ?sockaddr_un {
    if (path.len >= 104) return null;
    var a: sockaddr_un = .{};
    @memcpy(a.path[0..path.len], path);
    a.len = @intCast(2 + path.len + 1);
    return a;
}

/// Listen on a unix socket path; nonblocking. -1 on failure.
pub fn unixListen(path: []const u8) fd_t {
    const a = unAddr(path) orelse return -1;
    const fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    unlinkPath(path);
    if (bind(fd, &a, @sizeOf(sockaddr_un)) != 0 or listen(fd, 16) != 0) {
        closeFd(fd);
        return -1;
    }
    _ = setNonblock(fd);
    return fd;
}

/// Accept one connection; -1 when none pending.
pub fn unixAccept(fd: fd_t) fd_t {
    return accept(fd, null, null);
}

/// Connect to a unix socket path (blocking connect); -1 on failure.
pub fn unixConnect(path: []const u8) fd_t {
    const a = unAddr(path) orelse return -1;
    const fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (connect(fd, &a, @sizeOf(sockaddr_un)) != 0) {
        closeFd(fd);
        return -1;
    }
    return fd;
}
