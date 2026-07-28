//! Dev control socket — playwright-grade visibility for a native app.
//! A unix socket (default /tmp/rookz.sock, override ROOKZ_SOCK) speaks a
//! line protocol drivable with plain `nc -U`:
//!
//!   printf 'dump\n'            | nc -U /tmp/rookz.sock   # screen text
//!   printf 'type ls\n'         | nc -U /tmp/rookz.sock   # keystrokes → pty
//!   printf 'enter\n'           | nc -U /tmp/rookz.sock
//!   printf 'shot /tmp/s.png\n' | nc -U /tmp/rookz.sock   # own-pixels PNG
//!   printf 'quit\n'            | nc -U /tmp/rookz.sock
//!
//! `shot` reads back our own CAMetalLayer drawable — no screen-recording
//! permission, works occluded or on another Space.

const std = @import("std");
const macos = @import("macos.zig");
const stats = @import("stats.zig");

extern "c" fn CACurrentMediaTime() f64;

const sockaddr_un = extern struct {
    sun_len: u8 = 0,
    sun_family: u8 = 1, // AF_UNIX
    sun_path: [104]u8 = @splat(0),
};

extern "c" fn socket(domain: c_int, tp: c_int, protocol: c_int) c_int;
extern "c" fn bind(fd: c_int, addr: *const sockaddr_un, len: u32) c_int;
extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn usleep(us: u32) c_int;
extern "c" fn _exit(code: c_int) noreturn;

pub fn start(app: *macos.App) !void {
    const thread = try std.Thread.spawn(.{}, serve, .{app});
    thread.detach();
}

fn sockPath() [*:0]const u8 {
    return getenv("ROOKZ_SOCK") orelse "/tmp/rookz.sock";
}

fn serve(app: *macos.App) void {
    const path = sockPath();
    _ = unlink(path);

    const fd = socket(1, 1, 0); // AF_UNIX, SOCK_STREAM
    if (fd < 0) return;
    var addr: sockaddr_un = .{};
    const span = std.mem.span(path);
    if (span.len >= addr.sun_path.len) return;
    @memcpy(addr.sun_path[0..span.len], span);
    if (bind(fd, &addr, @sizeOf(sockaddr_un)) != 0) {
        std.debug.print("rookz ctl: bind failed on {s}\n", .{path});
        return;
    }
    if (listen(fd, 4) != 0) return;
    std.debug.print("rookz ctl: listening on {s}\n", .{path});

    while (true) {
        const conn = accept(fd, null, null);
        if (conn < 0) continue;
        handleConn(app, conn);
        _ = close(conn);
    }
}

fn handleConn(app: *macos.App, fd: c_int) void {
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    // Read lines until EOF; execute each as a command.
    while (true) {
        const n = read(fd, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
        while (std.mem.indexOfScalar(u8, buf[0..len], '\n')) |nl| {
            handleLine(app, fd, std.mem.trimEnd(u8, buf[0..nl], "\r"));
            std.mem.copyForwards(u8, &buf, buf[nl + 1 .. len]);
            len -= nl + 1;
        }
        if (len == buf.len) break; // oversized line, drop conn
    }
}

fn reply(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn handleLine(app: *macos.App, fd: c_int, line: []const u8) void {
    if (std.mem.eql(u8, line, "dump")) {
        app.session.mutex.lock();
        const str = app.session.term.plainString(app.gpa) catch {
            app.session.mutex.unlock();
            reply(fd, "err dump\n");
            return;
        };
        app.session.mutex.unlock();
        defer app.gpa.free(str);
        var head: [64]u8 = undefined;
        const h = std.fmt.bufPrint(&head, "grid {d}x{d}\n", .{ app.cols, app.rows }) catch return;
        reply(fd, h);
        reply(fd, str);
        reply(fd, "\n");
    } else if (std.mem.startsWith(u8, line, "type ")) {
        app.markInput(CACurrentMediaTime());
        app.session.write(line[5..]);
        reply(fd, "ok\n");
    } else if (std.mem.eql(u8, line, "enter")) {
        app.markInput(CACurrentMediaTime());
        app.session.write("\r");
        reply(fd, "ok\n");
    } else if (std.mem.eql(u8, line, "ctrlc")) {
        app.markInput(CACurrentMediaTime());
        app.session.write("\x03");
        reply(fd, "ok\n");
    } else if (std.mem.startsWith(u8, line, "key ")) {
        // Raw escape injection: `key 1b5b41` (hex bytes).
        var bytes: [64]u8 = undefined;
        const hex = line[4..];
        if (hex.len / 2 > bytes.len or hex.len % 2 != 0) {
            reply(fd, "err hex\n");
            return;
        }
        const out = std.fmt.hexToBytes(bytes[0 .. hex.len / 2], hex) catch {
            reply(fd, "err hex\n");
            return;
        };
        app.markInput(CACurrentMediaTime());
        app.session.write(out);
        reply(fd, "ok\n");
    } else if (std.mem.startsWith(u8, line, "shot ")) {
        if (app.requestShot(line[5..])) {
            // Wait for the render thread to service it (≤2s).
            var waited: u32 = 0;
            while (app.shotPending() and waited < 2_000_000) : (waited += 10_000) {
                _ = usleep(10_000);
            }
            reply(fd, if (app.shotPending()) "err timeout\n" else "ok\n");
        } else reply(fd, "err busy\n");
    } else if (std.mem.startsWith(u8, line, "winsize ")) {
        var it = std.mem.tokenizeScalar(u8, line[8..], ' ');
        const w = std.fmt.parseFloat(f64, it.next() orelse "") catch 0;
        const h = std.fmt.parseFloat(f64, it.next() orelse "") catch 0;
        if (w < 100 or h < 100) {
            reply(fd, "err winsize <w> <h> (points, >=100)\n");
            return;
        }
        app.requestWinSize(w, h);
        reply(fd, "ok\n");
    } else if (std.mem.eql(u8, line, "stats")) {
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        stats.writeReport(&w) catch {};
        reply(fd, buf[0..w.end]);
    } else if (std.mem.eql(u8, line, "stats reset")) {
        stats.global.reset();
        reply(fd, "ok\n");
    } else if (std.mem.eql(u8, line, "quit")) {
        reply(fd, "ok\n");
        _exit(0);
    } else {
        reply(fd, "err unknown (dump|type <s>|enter|ctrlc|key <hex>|shot <path>|winsize <w> <h>|quit)\n");
    }
}
