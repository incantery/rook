//! rook-host: the client, and the lifecycle.
//!
//! `internal/host` is the product's server half — threads, review, asks,
//! attention, transcripts, decisions, worktrees. It speaks localhost
//! HTTP with a bearer token, and `~/.local/state/rook/host.json` is how
//! anything finds it (port + token + pid + build). rookctl and the MCP
//! server use the same door; this is rook walking through it.
//!
//! THE LIFECYCLE INVERSION. The wails app deliberately *rides* a healthy
//! daemon and never kills it, so shells outlive an app restart
//! (internal/hostclient). rook owns its ptys in-process, so that trade
//! buys nothing here, and the standing rule is the opposite: nothing runs
//! while rook is closed. So rook spawns the daemon and SIGTERMs it on
//! quit.
//!
//! With one guard. We shut down only a daemon our own spawn became —
//! `owned` is literally `host.json`'s pid == the pid we forked. rook-host
//! is idempotent (cmd/rook-host/main.go): run it and it either replaces a
//! daemon of a different build or prints "already running" and exits. So
//! we always spawn and let the Go side keep its own build-identity rule
//! — the one hostclient's `shouldRide` tests — instead of reimplementing
//! it here. If our spawn exited because someone else's daemon was already
//! healthy, that someone else is responsible for it and we leave it
//! alone. Today that someone is the wails app during the cutover; after
//! it, nobody, and every launch owns what it started.
//!
//! Known gap: a rook that crashes (SIGKILL, panic) leaves its daemon
//! behind, and the next launch adopts rather than owns it. It is then
//! reaped by the next build change. Same as today's behaviour, so not a
//! regression — but it is why `owned` is reported by ctl `version`.
//!
//! Fail-open everywhere, like usage.zig: no host.json, no binary, a dead
//! daemon, bad JSON → null. The terminal must open with or without a host.

const std = @import("std");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn socket(domain: c_int, tp: c_int, protocol: c_int) c_int;
extern "c" fn connect(fd: c_int, addr: *const sockaddr_in, len: u32) c_int;
extern "c" fn setsockopt(fd: c_int, level: c_int, opt: c_int, val: *const anyopaque, len: u32) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn fork() c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn dup2(old: c_int, new: c_int) c_int;
extern "c" fn getdtablesize() c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn setsid() c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn usleep(us: c_uint) c_int;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn _NSGetExecutablePath(buf: [*]u8, size: *u32) c_int;

const sockaddr_in = extern struct {
    sin_len: u8 = @sizeOf(sockaddr_in),
    sin_family: u8 = 2, // AF_INET
    sin_port: u16, // network order
    sin_addr: u32, // network order
    sin_zero: [8]u8 = @splat(0),
};

const timeval = extern struct { sec: i64, usec: i32 };

const X_OK = 1;
const WNOHANG = 1;
const SIGTERM = 15;
const O_RDWR = 2;

/// What host.json says, flattened into fixed storage so callers can hold
/// it without owning an allocation. The daemon rewrites the file on every
/// start (new port, new token), so anything cached goes stale on restart
/// — `usage.zig` re-reads per fetch for exactly that reason, and long
/// -lived holders should refresh through `App.hostInfo()`.
pub const Info = struct {
    port: u16 = 0,
    pid: i32 = 0,
    tok: [160]u8 = undefined,
    tok_len: usize = 0,
    bld: [96]u8 = undefined,
    bld_len: usize = 0,
    rel: [40]u8 = undefined,
    rel_len: usize = 0,

    pub fn token(self: *const Info) []const u8 {
        return self.tok[0..self.tok_len];
    }
    pub fn build(self: *const Info) []const u8 {
        return self.bld[0..self.bld_len];
    }
    pub fn release(self: *const Info) []const u8 {
        return self.rel[0..self.rel_len];
    }
};

/// The JSON shape (internal/host/state.go). binHash is deliberately not
/// read: it exists for hostclient's unstamped-build staleness check,
/// which rook-host itself now performs on our behalf.
const StateJson = struct {
    port: u16 = 0,
    token: []const u8 = "",
    pid: i32 = 0,
    release: []const u8 = "",
    build: []const u8 = "",
};

fn statePath(buf: []u8) ?[]const u8 {
    if (getenv("XDG_STATE_HOME")) |x|
        return std.fmt.bufPrint(buf, "{s}/rook/host.json", .{std.mem.span(x)}) catch null;
    const home = getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/rook/host.json", .{std.mem.span(home)}) catch null;
}

/// Read host.json. Null when absent or unparseable — never an error.
pub fn readInfo(gpa: std.mem.Allocator, io: std.Io) ?Info {
    var pathbuf: [1024]u8 = undefined;
    const path = statePath(&pathbuf) orelse return null;
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024)) catch return null;
    defer gpa.free(raw);
    const parsed = std.json.parseFromSlice(StateJson, gpa, raw, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const v = parsed.value;
    if (v.port == 0 or v.token.len == 0) return null;

    var info: Info = .{ .port = v.port, .pid = v.pid };
    info.tok_len = @min(v.token.len, info.tok.len);
    @memcpy(info.tok[0..info.tok_len], v.token[0..info.tok_len]);
    info.bld_len = @min(v.build.len, info.bld.len);
    @memcpy(info.bld[0..info.bld_len], v.build[0..info.bld_len]);
    info.rel_len = @min(v.release.len, info.rel.len);
    @memcpy(info.rel[0..info.rel_len], v.release[0..info.rel_len]);
    return info;
}

pub const Response = struct {
    status: u16,
    body: []u8,

    pub fn deinit(self: *Response, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
        self.* = undefined;
    }
};

/// One HTTP/1.1 request over a fresh localhost conn, blocking with 3s
/// socket timeouts — call from a background thread, never the render
/// path. `body` non-null makes it a POST-shaped request with a JSON
/// content type. The response body is allocated and owned by the caller.
///
/// Hand-rolled rather than std.http on purpose: one origin, one hop, no
/// TLS, no redirects, no keep-alive. This is the whole client.
pub fn request(
    gpa: std.mem.Allocator,
    info: *const Info,
    method: []const u8,
    path: []const u8,
    body: ?[]const u8,
    max_body: usize,
) ?Response {
    const fd = socket(2, 1, 0); // AF_INET, SOCK_STREAM
    if (fd < 0) return null;
    defer _ = close(fd);
    const tv: timeval = .{ .sec = 3, .usec = 0 };
    _ = setsockopt(fd, 0xffff, 0x1006, &tv, @sizeOf(timeval)); // SOL_SOCKET, SO_RCVTIMEO
    _ = setsockopt(fd, 0xffff, 0x1005, &tv, @sizeOf(timeval)); // SO_SNDTIMEO
    const addr: sockaddr_in = .{
        .sin_port = std.mem.nativeToBig(u16, info.port),
        .sin_addr = std.mem.nativeToBig(u32, 0x7f000001), // 127.0.0.1
    };
    if (connect(fd, &addr, @sizeOf(sockaddr_in)) != 0) return null;

    var head_buf: [1024]u8 = undefined;
    const head = if (body) |b| std.fmt.bufPrint(
        &head_buf,
        "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ method, path, info.token(), b.len },
    ) catch return null else std.fmt.bufPrint(
        &head_buf,
        "{s} {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {s}\r\nConnection: close\r\n\r\n",
        .{ method, path, info.token() },
    ) catch return null;

    if (!writeAll(fd, head)) return null;
    if (body) |b| if (!writeAll(fd, b)) return null;

    // Read to EOF (Connection: close), growing by doubling to max_body.
    var cap: usize = 16 * 1024;
    var buf = gpa.alloc(u8, cap) catch return null;
    errdefer gpa.free(buf);
    var len: usize = 0;
    while (true) {
        if (len == cap) {
            if (cap >= max_body) break;
            cap = @min(cap * 2, max_body);
            buf = gpa.realloc(buf, cap) catch break;
        }
        const n = read(fd, buf[len..].ptr, cap - len);
        if (n <= 0) break;
        len += @intCast(n);
    }

    // "HTTP/1.1 200 OK\r\n...\r\n\r\n<body>"
    const head_end = std.mem.indexOf(u8, buf[0..len], "\r\n\r\n") orelse {
        gpa.free(buf);
        return null;
    };
    if (len < 12 or !std.mem.startsWith(u8, buf[0..len], "HTTP/1.")) {
        gpa.free(buf);
        return null;
    }
    const status = std.fmt.parseInt(u16, buf[9..12], 10) catch {
        gpa.free(buf);
        return null;
    };

    // Shift the body to the front so the caller owns one clean slice.
    const body_start = head_end + 4;
    const body_len = len - body_start;
    std.mem.copyForwards(u8, buf[0..body_len], buf[body_start..len]);
    const out = gpa.realloc(buf, body_len) catch buf[0..body_len];
    return .{ .status = status, .body = out };
}

pub fn get(gpa: std.mem.Allocator, info: *const Info, path: []const u8, max_body: usize) ?Response {
    return request(gpa, info, "GET", path, null, max_body);
}

pub fn post(gpa: std.mem.Allocator, info: *const Info, path: []const u8, body: []const u8, max_body: usize) ?Response {
    return request(gpa, info, "POST", path, body, max_body);
}

/// GET /health == 200. The state file alone proves nothing: it outlives
/// the process that wrote it.
pub fn healthy(gpa: std.mem.Allocator, info: *const Info) bool {
    var resp = get(gpa, info, "/health", 8 * 1024) orelse return false;
    defer resp.deinit(gpa);
    return resp.status == 200;
}

fn writeAll(fd: c_int, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// Find one of our sibling Go binaries (`rook-host`, `rookctl`) in the
/// order that makes each context work: beside our own executable (the
/// installed bundle, where they ship), then PATH, then the bundle by
/// absolute path — the last one only so a `zig build run` from a dev
/// tree, whose binary has nothing beside it, finds them at all.
pub fn siblingBinary(name: []const u8, buf: []u8) ?[:0]const u8 {
    var exe_buf: [1024]u8 = undefined;
    var size: u32 = exe_buf.len;
    if (_NSGetExecutablePath(&exe_buf, &size) == 0) {
        const exe = std.mem.sliceTo(&exe_buf, 0);
        if (std.mem.lastIndexOfScalar(u8, exe, '/')) |slash| {
            if (std.fmt.bufPrintZ(buf, "{s}/{s}", .{ exe[0..slash], name })) |p| {
                if (access(p.ptr, X_OK) == 0) return p;
            } else |_| {}
        }
    }
    if (getenv("PATH")) |path_env| {
        var it = std.mem.splitScalar(u8, std.mem.span(path_env), ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const p = std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, name }) catch continue;
            if (access(p.ptr, X_OK) == 0) return p;
        }
    }
    const p = std.fmt.bufPrintZ(buf, "/Applications/rook.app/Contents/MacOS/{s}", .{name}) catch return null;
    if (access(p.ptr, X_OK) == 0) return p;
    return null;
}

fn hostBinary(buf: []u8) ?[:0]const u8 {
    return siblingBinary("rook-host", buf);
}

/// Fork+exec the daemon detached from our stdio. Returns its pid.
///
/// Every fd above stdio is closed in the child for the same reason
/// pty.zig does it: a long-lived daemon holding our ctl listener or a
/// pty master would keep those alive past their owner — and an inherited
/// ctl connection once kept `nc` from ever seeing EOF.
fn spawnHost(path: [:0]const u8) ?c_int {
    const pid = fork();
    if (pid < 0) return null;
    if (pid == 0) {
        // Child. Its own session so a signal aimed at our process group
        // (or a controlling terminal, when rook runs from a shell)
        // doesn't take the daemon with it — we kill it deliberately or
        // not at all.
        _ = setsid();
        const devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) {
            _ = dup2(devnull, 0);
            _ = dup2(devnull, 1);
            _ = dup2(devnull, 2);
        }
        var fd: c_int = 3;
        const maxfd = getdtablesize();
        while (fd < maxfd) : (fd += 1) _ = close(fd);
        var argv: [1:null]?[*:0]const u8 = .{path.ptr};
        _ = execv(path.ptr, &argv);
        _exit(127);
    }
    return pid;
}

pub const Handle = struct {
    info: Info = .{},
    /// True when the daemon is the process we forked — the only case in
    /// which we are allowed to shut it down.
    owned: bool = false,
    /// Where the binary was found, for ctl `version` to report.
    path: [512]u8 = undefined,
    path_len: usize = 0,

    pub fn binary(self: *const Handle) []const u8 {
        return self.path[0..self.path_len];
    }
};

/// Bring a healthy daemon up and report what we got. Blocking for up to
/// ~5s in the spawn case — background thread only.
pub fn ensure(gpa: std.mem.Allocator, io: std.Io) ?Handle {
    var pathbuf: [512]u8 = undefined;
    const bin = hostBinary(&pathbuf);

    // No binary to spawn: ride whatever is already up, if anything.
    if (bin == null) {
        const info = readInfo(gpa, io) orelse return null;
        if (!healthy(gpa, &info)) return null;
        return .{ .info = info, .owned = false };
    }

    const child = spawnHost(bin.?) orelse return null;

    // rook-host now decides: replace a stale daemon, or exit because a
    // healthy same-build one is already listening. Either way what we
    // wait for is the same — a health check that passes.
    var waited_ms: u32 = 0;
    while (waited_ms < 5000) : (waited_ms += 100) {
        if (readInfo(gpa, io)) |info| {
            if (healthy(gpa, &info)) {
                // Reap it if it took the "already running" exit; if it
                // became the daemon this is a no-op (WNOHANG).
                _ = waitpid(child, null, WNOHANG);
                var h: Handle = .{ .info = info, .owned = info.pid == child };
                h.path_len = @min(bin.?.len, h.path.len);
                @memcpy(h.path[0..h.path_len], bin.?[0..h.path_len]);
                return h;
            }
        }
        _ = usleep(100 * 1000);
    }
    _ = waitpid(child, null, WNOHANG);
    return null;
}

/// SIGTERM the daemon, but only one we started. rook-host traps it and
/// takes its children down with it (cmd/rook-host/main.go).
pub fn shutdown(h: *const Handle) void {
    if (!h.owned or h.info.pid <= 0) return;
    _ = kill(h.info.pid, SIGTERM);
}
