//! Minimal macOS PTY: openpty + fork/exec a child attached to the slave.
//! Shape borrowed from ghostty's src/pty.zig, reduced to what rookz needs.
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
extern "c" fn waitpid(pid: pid_t, status: ?*c_int, options: c_int) pid_t;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn read(fd: fd_t, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: fd_t, buf: [*]const u8, n: usize) isize;

// Values from macOS headers.
const F_GETFD = 1;
const F_SETFD = 2;
const FD_CLOEXEC = 1;
const TIOCSCTTY = 0x20007461;
const TIOCSWINSZ = 0x80087467;
extern "c" var environ: [*:null]const ?[*:0]const u8;

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

    /// Write input bytes to the master (keystrokes for the child).
    pub fn writeMaster(self: *Pty, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = write(self.master, bytes.ptr + off, bytes.len - off);
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
            if (self.slave > 2) _ = close(self.slave);
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
