//! Subscription usage — READ side of rook-host's cost-weighted prober.
//! The host scrapes `claude -p /usage` and caches the windows; rookz
//! GETs the cached snapshot over the host's localhost HTTP (port +
//! bearer token from ~/.local/state/rook/host.json, re-read every
//! fetch — host restarts change both). Fail-open everywhere: no
//! host.json, dead host, bad JSON → an empty cluster, never an error.
//! Labels compact the wails way: session → 5h, week (all models) →
//! wk, week (X) → lowercased X.

const std = @import("std");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn socket(domain: c_int, tp: c_int, protocol: c_int) c_int;
extern "c" fn connect(fd: c_int, addr: *const sockaddr_in, len: u32) c_int;
extern "c" fn setsockopt(fd: c_int, level: c_int, opt: c_int, val: *const anyopaque, len: u32) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;

const sockaddr_in = extern struct {
    sin_len: u8 = @sizeOf(sockaddr_in),
    sin_family: u8 = 2, // AF_INET
    sin_port: u16, // network order
    sin_addr: u32, // network order
    sin_zero: [8]u8 = @splat(0),
};

const timeval = extern struct { sec: i64, usec: i32 };

pub const Snapshot = struct {
    text: [96]u8 = undefined,
    len: usize = 0,
    /// Worst window's percentage — drives the cluster's color.
    worst: u8 = 0,

    pub fn slice(self: *const Snapshot) []const u8 {
        return self.text[0..self.len];
    }
};

fn shortWindow(label: []const u8) []const u8 {
    if (std.mem.eql(u8, label, "session")) return "5h";
    if (std.mem.startsWith(u8, label, "week (all")) return "wk";
    if (std.mem.startsWith(u8, label, "week (") and label.len > 7)
        return label[6 .. label.len - 1]; // "week (Fable)" → "Fable"
    return label;
}

const HostInfo = struct { port: u16, token: []const u8 };
const UsageWindow = struct { label: []const u8 = "", pct: i64 = 0 };
const UsageBody = struct { windows: []UsageWindow = &.{} };

/// One fetch, blocking (3s socket timeouts) — call from a background
/// thread, never the render path.
pub fn fetch(gpa: std.mem.Allocator, io: std.Io) Snapshot {
    var snap: Snapshot = .{};

    // host.json: port + token.
    var pathbuf: [1024]u8 = undefined;
    const home = getenv("HOME") orelse return snap;
    const path = std.fmt.bufPrint(&pathbuf, "{s}/.local/state/rook/host.json", .{std.mem.span(home)}) catch return snap;
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024)) catch return snap;
    defer gpa.free(raw);
    const hi = std.json.parseFromSlice(HostInfo, gpa, raw, .{ .ignore_unknown_fields = true }) catch return snap;
    defer hi.deinit();

    // GET /usage — hand-rolled HTTP/1.1 over one localhost TCP conn.
    const fd = socket(2, 1, 0); // AF_INET, SOCK_STREAM
    if (fd < 0) return snap;
    defer _ = close(fd);
    const tv: timeval = .{ .sec = 3, .usec = 0 };
    _ = setsockopt(fd, 0xffff, 0x1006, &tv, @sizeOf(timeval)); // SOL_SOCKET, SO_RCVTIMEO
    _ = setsockopt(fd, 0xffff, 0x1005, &tv, @sizeOf(timeval)); // SO_SNDTIMEO
    const addr: sockaddr_in = .{
        .sin_port = std.mem.nativeToBig(u16, hi.value.port),
        .sin_addr = std.mem.nativeToBig(u32, 0x7f000001), // 127.0.0.1
    };
    if (connect(fd, &addr, @sizeOf(sockaddr_in)) != 0) return snap;

    var req_buf: [512]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "GET /usage HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {s}\r\nConnection: close\r\n\r\n", .{hi.value.token}) catch return snap;
    var off: usize = 0;
    while (off < req.len) {
        const n = write(fd, req.ptr + off, req.len - off);
        if (n <= 0) return snap;
        off += @intCast(n);
    }

    var resp: [8192]u8 = undefined;
    var rlen: usize = 0;
    while (rlen < resp.len) {
        const n = read(fd, resp[rlen..].ptr, resp.len - rlen);
        if (n <= 0) break;
        rlen += @intCast(n);
    }
    const head_end = std.mem.indexOf(u8, resp[0..rlen], "\r\n\r\n") orelse return snap;
    if (!std.mem.startsWith(u8, resp[0..rlen], "HTTP/1.1 200")) return snap;
    const body = resp[head_end + 4 .. rlen];

    const parsed = std.json.parseFromSlice(UsageBody, gpa, body, .{ .ignore_unknown_fields = true }) catch return snap;
    defer parsed.deinit();

    // "5h 27% · wk 44% · fable 73%"
    var w: std.Io.Writer = .fixed(&snap.text);
    for (parsed.value.windows, 0..) |win, i| {
        const pct: u8 = @intCast(std.math.clamp(win.pct, 0, 100));
        if (pct > snap.worst) snap.worst = pct;
        var lbl_buf: [24]u8 = undefined;
        const short = shortWindow(win.label);
        const lbl = std.ascii.lowerString(lbl_buf[0..@min(short.len, lbl_buf.len)], short[0..@min(short.len, lbl_buf.len)]);
        w.print("{s}{s} {d}%", .{ @as([]const u8, if (i == 0) "" else " · "), lbl, pct }) catch break;
    }
    snap.len = w.end;
    return snap;
}
