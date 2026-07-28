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
//! Panes: `panes` lists them; `split right|down` splits the focused
//! pane; `focus <id|left|right|up|down>` moves focus; dump/type/enter/
//! ctrlc/key default to the focused pane and take an `@<id>` suffix to
//! target another (`dump@2`, `type@3 ls`).
//!
//! `shot` reads back our own CAMetalLayer drawable — no screen-recording
//! permission, works occluded or on another Space.

const std = @import("std");
const macos = @import("macos.zig");
const panespkg = @import("panes.zig");
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

/// Resolve a pane by id (searching every tab), or the active tab's
/// focused pane when id is null. Caller holds app.draw_lock.
fn findPane(app: *macos.App, pane_id: ?u32) ?*panespkg.Pane {
    const id = pane_id orelse return app.tabs.items[app.active_tab].focused;
    for (app.tabs.items) |t| {
        for (t.panes.items) |p| {
            if (p.id == id) return p;
        }
    }
    return null;
}

/// Write input bytes to a pane's pty under the scene lock. Only writes
/// to the FOCUSED pane arm the key-to-photon mark — a background pane's
/// echo must not be measured as input latency.
fn writeTarget(app: *macos.App, pane_id: ?u32, bytes: []const u8) bool {
    app.draw_lock.lock();
    defer app.draw_lock.unlock();
    const p = findPane(app, pane_id) orelse return false;
    if (p == app.tabs.items[app.active_tab].focused) app.markInput(CACurrentMediaTime());
    switch (p.content) {
        .term => |*tm| tm.session.write(bytes),
        .edit => |ed| ed.key(bytes),
    }
    return true;
}

fn handleLine(app: *macos.App, fd: c_int, line: []const u8) void {
    // Split off the verb and an optional @<id> pane suffix.
    const sp = std.mem.indexOfScalar(u8, line, ' ');
    const verb_full = if (sp) |i| line[0..i] else line;
    const rest = if (sp) |i| line[i + 1 ..] else "";
    var verb = verb_full;
    var pane_id: ?u32 = null;
    if (std.mem.indexOfScalar(u8, verb_full, '@')) |at| {
        verb = verb_full[0..at];
        pane_id = std.fmt.parseInt(u32, verb_full[at + 1 ..], 10) catch {
            reply(fd, "err pane id\n");
            return;
        };
    }

    if (std.mem.eql(u8, verb, "dump") and rest.len == 0) {
        app.draw_lock.lock();
        const p = findPane(app, pane_id) orelse {
            app.draw_lock.unlock();
            reply(fd, "err no pane\n");
            return;
        };
        const str = switch (p.content) {
            .term => |*tm| blk: {
                tm.session.mutex.lock();
                defer tm.session.mutex.unlock();
                break :blk tm.session.term.plainString(app.gpa) catch null;
            },
            .edit => |ed| ed.dumpText(app.gpa, p.cols, p.rows) catch null,
        } orelse {
            app.draw_lock.unlock();
            reply(fd, "err dump\n");
            return;
        };
        var head: [64]u8 = undefined;
        const h = std.fmt.bufPrint(&head, "pane {d} grid {d}x{d}\n", .{ p.id, p.cols, p.rows }) catch {
            app.draw_lock.unlock();
            app.gpa.free(str);
            return;
        };
        app.draw_lock.unlock();
        defer app.gpa.free(str);
        reply(fd, h);
        reply(fd, str);
        reply(fd, "\n");
    } else if (std.mem.eql(u8, verb, "panes") and rest.len == 0) {
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        app.draw_lock.lock();
        for (app.tabs.items, 0..) |t, ti| {
            for (t.panes.items) |p| {
                w.print("{s}t{d} {s}{d} rect {d}x{d}+{d}+{d} grid {d}x{d}\n", .{
                    @as([]const u8, if (ti == app.active_tab) "*" else " "),
                    ti + 1,
                    @as([]const u8, if (p == t.focused) "*" else " "),
                    p.id,
                    @as(u32, @intFromFloat(p.rect.w)),
                    @as(u32, @intFromFloat(p.rect.h)),
                    @as(u32, @intFromFloat(p.rect.x)),
                    @as(u32, @intFromFloat(p.rect.y)),
                    p.cols,
                    p.rows,
                }) catch break;
            }
        }
        app.draw_lock.unlock();
        reply(fd, buf[0..w.end]);
    } else if (std.mem.eql(u8, verb, "tabs") and rest.len == 0) {
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        app.draw_lock.lock();
        for (app.tabs.items, 0..) |t, ti| {
            w.print("{s}{d} ({d} pane{s})\n", .{
                @as([]const u8, if (ti == app.active_tab) "*" else " "),
                ti + 1,
                t.panes.items.len,
                @as([]const u8, if (t.panes.items.len == 1) "" else "s"),
            }) catch break;
        }
        app.draw_lock.unlock();
        reply(fd, buf[0..w.end]);
    } else if (std.mem.eql(u8, verb, "tab")) {
        if (std.mem.eql(u8, rest, "new")) {
            app.newTab();
            reply(fd, "ok\n");
        } else if (std.mem.eql(u8, rest, "next")) {
            app.cycleTab(1);
            reply(fd, "ok\n");
        } else if (std.mem.eql(u8, rest, "prev")) {
            app.cycleTab(-1);
            reply(fd, "ok\n");
        } else if (std.fmt.parseInt(usize, rest, 10) catch null) |n| {
            reply(fd, if (n >= 1 and app.selectTab(n - 1)) "ok\n" else "err no tab\n");
        } else reply(fd, "err tab new|next|prev|<n>\n");
    } else if (std.mem.eql(u8, verb, "edit") and rest.len > 0) {
        // Open a file in an editor pane: a focused editor retargets in
        // place, else one splits off to the right. Paths resolve
        // against the APP's cwd — send absolute paths (rookz edit does).
        reply(fd, if (app.openEditor(rest)) "ok\n" else "err open\n");
    } else if (std.mem.eql(u8, verb, "click")) {
        var it = std.mem.tokenizeScalar(u8, rest, ' ');
        const x = std.fmt.parseFloat(f32, it.next() orelse "") catch -1;
        const y = std.fmt.parseFloat(f32, it.next() orelse "") catch -1;
        if (x < 0 or y < 0) {
            reply(fd, "err click <x_px> <y_px>\n");
            return;
        }
        app.clickAt(x, y);
        reply(fd, "ok\n");
    } else if (std.mem.eql(u8, verb, "wheel")) {
        var it = std.mem.tokenizeScalar(u8, rest, ' ');
        const x = std.fmt.parseFloat(f32, it.next() orelse "") catch -1;
        const y = std.fmt.parseFloat(f32, it.next() orelse "") catch -1;
        const lines = std.fmt.parseInt(i64, it.next() orelse "", 10) catch 0;
        if (x < 0 or y < 0 or lines == 0) {
            reply(fd, "err wheel <x_px> <y_px> <±lines>\n");
            return;
        }
        app.wheelAt(x, y, lines);
        reply(fd, "ok\n");
    } else if (std.mem.eql(u8, verb, "split")) {
        if (std.mem.eql(u8, rest, "right")) {
            app.splitFocused(true);
            reply(fd, "ok\n");
        } else if (std.mem.eql(u8, rest, "down")) {
            app.splitFocused(false);
            reply(fd, "ok\n");
        } else reply(fd, "err split right|down\n");
    } else if (std.mem.eql(u8, verb, "focus")) {
        const dir: ?panespkg.NavDir = if (std.mem.eql(u8, rest, "left"))
            .left
        else if (std.mem.eql(u8, rest, "right"))
            .right
        else if (std.mem.eql(u8, rest, "up"))
            .up
        else if (std.mem.eql(u8, rest, "down"))
            .down
        else
            null;
        if (dir) |d| {
            reply(fd, if (app.focusMove(d)) "ok\n" else "err edge\n");
        } else if (std.fmt.parseInt(u32, rest, 10) catch null) |id| {
            reply(fd, if (app.focusById(id)) "ok\n" else "err no pane\n");
        } else reply(fd, "err focus <id|left|right|up|down>\n");
    } else if (std.mem.eql(u8, verb, "press") and rest.len > 0) {
        // Drive the REAL key path (leader state machine included) with
        // one character — chords are testable blind. `press SPACE`,
        // `press TAB`, `press ESC` for named keys.
        const ch: ?u8 = if (rest.len == 1)
            rest[0]
        else if (std.mem.eql(u8, rest, "TAB"))
            '\t'
        else if (std.mem.eql(u8, rest, "SPACE"))
            ' '
        else if (std.mem.eql(u8, rest, "ESC"))
            0x1b
        else
            null;
        if (ch) |c| {
            if (app.handleCharKey(c, CACurrentMediaTime())) {
                reply(fd, "consumed\n");
            } else {
                app.writeFocused(&[1]u8{c}, CACurrentMediaTime());
                reply(fd, "typed\n");
            }
        } else reply(fd, "err press <char|TAB|SPACE|ESC>\n");
    } else if (std.mem.eql(u8, verb, "type") and rest.len > 0) {
        reply(fd, if (writeTarget(app, pane_id, rest)) "ok\n" else "err no pane\n");
    } else if (std.mem.eql(u8, verb, "enter") and rest.len == 0) {
        reply(fd, if (writeTarget(app, pane_id, "\r")) "ok\n" else "err no pane\n");
    } else if (std.mem.eql(u8, verb, "ctrlc") and rest.len == 0) {
        reply(fd, if (writeTarget(app, pane_id, "\x03")) "ok\n" else "err no pane\n");
    } else if (std.mem.eql(u8, verb, "key") and rest.len > 0) {
        // Raw escape injection: `key 1b5b41` (hex bytes).
        var bytes: [64]u8 = undefined;
        const hex = rest;
        if (hex.len / 2 > bytes.len or hex.len % 2 != 0) {
            reply(fd, "err hex\n");
            return;
        }
        const out = std.fmt.hexToBytes(bytes[0 .. hex.len / 2], hex) catch {
            reply(fd, "err hex\n");
            return;
        };
        reply(fd, if (writeTarget(app, pane_id, out)) "ok\n" else "err no pane\n");
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
    } else if (std.mem.eql(u8, line, "fullscreen")) {
        app.requestFullscreen();
        reply(fd, "ok\n");
    } else if (std.mem.eql(u8, line, "hud")) {
        app.draw_lock.lock();
        var buf: [256]u8 = undefined;
        const out = std.fmt.bufPrint(&buf, "{s} | {s}\n", .{
            app.hud_left[0..app.hud_left_len],
            app.hud_right[0..app.hud_right_len],
        }) catch {
            app.draw_lock.unlock();
            return;
        };
        app.draw_lock.unlock();
        reply(fd, out);
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
        reply(fd, "err unknown (panes|edit <path>|split right|down|focus <id|dir>|dump[@id]|type[@id] <s>|enter[@id]|ctrlc[@id]|key[@id] <hex>|shot <path>|winsize <w> <h>|stats|quit)\n");
    }
}
