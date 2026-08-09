//! One FSEvents stream over one directory tree — the eyes behind
//! workspace/didChangeWatchedFiles.
//!
//! WHY FSEVENTS and not kqueue: kqueue watches file descriptors, one
//! per directory, and does not recurse — watching a repo would mean
//! opening every directory in it and racing mkdir for the new ones.
//! FSEvents is the kernel's own journal of "something under this root
//! changed": it recurses for free and it coalesces bursts, so a git
//! checkout is a few callbacks rather than ten thousand.
//!
//! CLASSIFICATION: FSEvents flags are cumulative per file within the
//! stream's window — a create followed quickly by a write can arrive as
//! one event wearing both bits, and an event after a delete-and-recreate
//! wears all three. The filesystem is the tiebreaker: a path that no
//! longer exists is a delete no matter what the flags say, one that
//! exists with a create bit is a create, and anything else that exists
//! is a change. Consumers get {path, created|changed|deleted} and never
//! see a raw flag.
//!
//! THREADING: the callback fires on a private serial dispatch queue.
//! Consumers must be callable from that queue — lsp.Server takes its own
//! lock and pokes its pump, which is the same contract its other
//! cross-thread callers follow. stop() fences the queue before freeing,
//! so after it returns the callback is not in flight and never will be.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum(u8) { created = 1, changed = 2, deleted = 3 };

/// One classified change. `path` is BORROWED from the callback frame —
/// copy anything that must outlive the call.
pub const Change = struct { path: []const u8, kind: Kind };

pub const Callback = *const fn (ctx: *anyopaque, changes: []const Change) void;

/// Changes handed to one callback invocation at most. FSEvents itself
/// batches without bound (a branch switch touches thousands of files);
/// past this the consumer just hears about it in slices, which costs an
/// extra notification and saves an unbounded stack.
pub const max_batch = 256;

// ------------------------------------------------------------ C surface

const CFIndex = isize;
const CFRef = *anyopaque;

const CFArrayCallBacks = extern struct {
    version: CFIndex,
    retain: ?*const anyopaque,
    release: ?*const anyopaque,
    copyDescription: ?*const anyopaque,
    equal: ?*const anyopaque,
};
extern const kCFTypeArrayCallBacks: CFArrayCallBacks;

extern "c" fn CFStringCreateWithBytes(alloc: ?CFRef, bytes: [*]const u8, len: CFIndex, encoding: u32, external: u8) ?CFRef;
extern "c" fn CFArrayCreate(alloc: ?CFRef, values: [*]const ?*const anyopaque, count: CFIndex, cbs: ?*const CFArrayCallBacks) ?CFRef;
extern "c" fn CFRelease(ref: CFRef) void;
const utf8_encoding: u32 = 0x0800_0100;

const FSEventStreamContext = extern struct {
    version: CFIndex = 0,
    info: ?*anyopaque = null,
    retain: ?*const anyopaque = null,
    release: ?*const anyopaque = null,
    copyDescription: ?*const anyopaque = null,
};
const FSCallbackFn = *const fn (
    stream: CFRef,
    info: ?*anyopaque,
    num: usize,
    paths: [*][*:0]const u8,
    flags: [*]const u32,
    ids: [*]const u64,
) callconv(.c) void;

extern "c" fn FSEventStreamCreate(alloc: ?CFRef, cb: FSCallbackFn, ctx: *const FSEventStreamContext, paths: CFRef, since: u64, latency: f64, flags: u32) ?CFRef;
extern "c" fn FSEventStreamSetDispatchQueue(stream: CFRef, queue: CFRef) void;
extern "c" fn FSEventStreamStart(stream: CFRef) u8;
extern "c" fn FSEventStreamStop(stream: CFRef) void;
extern "c" fn FSEventStreamInvalidate(stream: CFRef) void;
extern "c" fn FSEventStreamRelease(stream: CFRef) void;

const since_now: u64 = 0xFFFF_FFFF_FFFF_FFFF;
const flag_no_defer: u32 = 0x02;
const flag_file_events: u32 = 0x10;
// Per-event flags.
const ev_must_scan: u32 = 0x0000_0001;
const ev_created: u32 = 0x0000_0100;
const ev_renamed: u32 = 0x0000_0800;

extern "c" fn dispatch_queue_create(label: [*:0]const u8, attr: ?*anyopaque) CFRef;
extern "c" fn dispatch_sync_f(queue: CFRef, ctx: ?*anyopaque, work: *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn dispatch_release(obj: CFRef) void;
extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

/// macOS arm64 struct stat, declared by hand the way crash.zig declares
/// Dirent — there is no @cImport in this build, and the layout IS the
/// contract. Only birthtime is read; everything else is spacing. (The
/// x86_64 $INODE64 symbol dance does not exist on arm64: plain `stat`
/// is already the 64-bit-inode variant.)
const Timespec = extern struct { sec: i64, nsec: i64 };
const Stat = extern struct {
    dev: i32,
    mode: u16,
    nlink: u16,
    ino: u64,
    uid: u32,
    gid: u32,
    rdev: i32,
    atime: Timespec,
    mtime: Timespec,
    ctime: Timespec,
    birthtime: Timespec,
    size: i64,
    blocks: i64,
    blksize: i32,
    flags: u32,
    gen: u32,
    lspare: i32,
    qspare: [2]i64,
};
extern "c" fn stat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn clock_gettime(clk: c_int, ts: *Timespec) c_int;
const clock_realtime: c_int = 0;

// -------------------------------------------------------------- Stream

pub const Stream = struct {
    gpa: Allocator,
    stream: CFRef,
    queue: CFRef,
    ctx: *anyopaque,
    cb: Callback,
    /// The root as the CALLER spells it, owned. FSEvents resolves
    /// symlinks and delivers events in the kernel's spelling — watch
    /// /tmp/x on macOS and events arrive under /private/tmp/x. The
    /// consumer's globs live in the caller's spelling, so events are
    /// re-spelled back before they're handed over.
    root: []const u8,
    /// realpath(root) when it differs from root, else null (the common
    /// case, where events pass through untouched).
    real: ?[]const u8,
    /// Re-spelled path bytes for the batch in flight. Callback-queue
    /// private; reused across callbacks.
    respell: std.ArrayListUnmanaged(u8) = .empty,
    /// Wall clock at start. FSEvents flags are HISTORY, not news — a
    /// write to a file created seconds ago still wears the created bit.
    /// A file whose birthtime predates the stream is never "created",
    /// whatever the flags say.
    began: Timespec = .{ .sec = 0, .nsec = 0 },

    /// Watch `root` recursively. null when the stream could not be made
    /// — the caller carries on unwatched, same fail-open shape as a
    /// server that would not spawn.
    pub fn start(gpa: Allocator, root: []const u8, ctx: *anyopaque, cb: Callback) ?*Stream {
        const self = gpa.create(Stream) catch return null;
        const root_owned = gpa.dupe(u8, root) catch {
            gpa.destroy(self);
            return null;
        };
        self.* = .{
            .gpa = gpa,
            .stream = undefined,
            .queue = undefined,
            .ctx = ctx,
            .cb = cb,
            .root = root_owned,
            .real = resolvedRoot(gpa, root),
        };
        _ = clock_gettime(clock_realtime, &self.began);

        const str = CFStringCreateWithBytes(null, root.ptr, @intCast(root.len), utf8_encoding, 0) orelse {
            self.freeOwned();
            gpa.destroy(self);
            return null;
        };
        const vals = [_]?*const anyopaque{str};
        const arr = CFArrayCreate(null, &vals, 1, &kCFTypeArrayCallBacks) orelse {
            CFRelease(str);
            self.freeOwned();
            gpa.destroy(self);
            return null;
        };
        // The array retained the string, and FSEventStreamCreate copies
        // the paths out of the array — both are ours to drop here.
        defer CFRelease(arr);
        CFRelease(str);

        var sctx: FSEventStreamContext = .{ .info = self };
        // 200ms latency batches a burst; NoDefer delivers the FIRST
        // event of a quiet period immediately and only throttles the
        // followers — a save reaches the server now, a checkout still
        // coalesces.
        const stream = FSEventStreamCreate(null, &fsCallback, &sctx, arr, since_now, 0.2, flag_no_defer | flag_file_events) orelse {
            self.freeOwned();
            gpa.destroy(self);
            return null;
        };
        self.stream = stream;
        self.queue = dispatch_queue_create("rook.fswatch", null);
        FSEventStreamSetDispatchQueue(stream, self.queue);
        if (FSEventStreamStart(stream) == 0) {
            FSEventStreamInvalidate(stream);
            FSEventStreamRelease(stream);
            dispatch_release(self.queue);
            self.freeOwned();
            gpa.destroy(self);
            return null;
        }
        return self;
    }

    /// realpath(root) when it differs, owned — else null. A root that
    /// fails to resolve gets no re-spelling, which fails toward "events
    /// arrive in kernel spelling", not toward silence.
    fn resolvedRoot(gpa: Allocator, root: []const u8) ?[]const u8 {
        var zbuf: [1024]u8 = undefined;
        const rz = std.fmt.bufPrintZ(&zbuf, "{s}", .{root}) catch return null;
        var rbuf: [1024]u8 = undefined;
        const resolved = realpath(rz.ptr, &rbuf) orelse return null;
        const r = std.mem.span(resolved);
        if (std.mem.eql(u8, r, root)) return null;
        return gpa.dupe(u8, r) catch null;
    }

    fn freeOwned(self: *Stream) void {
        self.gpa.free(self.root);
        if (self.real) |r| self.gpa.free(r);
        self.respell.deinit(self.gpa);
    }

    /// Stop, fence out any in-flight callback, free. The caller must
    /// not hold a lock the callback takes — the fence would wait on it.
    pub fn stop(self: *Stream) void {
        FSEventStreamStop(self.stream);
        FSEventStreamInvalidate(self.stream);
        dispatch_sync_f(self.queue, null, drainNoop);
        FSEventStreamRelease(self.stream);
        dispatch_release(self.queue);
        const gpa = self.gpa;
        self.freeOwned();
        gpa.destroy(self);
    }

    fn drainNoop(_: ?*anyopaque) callconv(.c) void {}

    fn fsCallback(
        _: CFRef,
        info: ?*anyopaque,
        num: usize,
        paths: [*][*:0]const u8,
        flags: [*]const u32,
        _: [*]const u64,
    ) callconv(.c) void {
        const self: *Stream = @ptrCast(@alignCast(info orelse return));
        var batch: [max_batch]Change = undefined;
        // Where in `respell` each re-spelled path starts; passthrough
        // paths (already in the caller's spelling) mark themselves with
        // the sentinel. Two passes because appending can move the
        // buffer — slices are cut only once the batch is full.
        var offs: [max_batch]usize = undefined;
        const passthrough = std.math.maxInt(usize);
        self.respell.clearRetainingCapacity();
        var n: usize = 0;
        var i: usize = 0;
        while (i < num) : (i += 1) {
            // Dropped events: the kernel only says "rescan this
            // subtree", and enumerating it here would be a directory
            // walk on the event queue. Rare enough to skip — the next
            // real change re-syncs the server.
            if (flags[i] & ev_must_scan != 0) continue;
            const path = std.mem.span(paths[i]);
            // A git operation is thousands of object writes nobody
            // asked about by name — but `**` matches them all, so the
            // filter has to happen before the globs see them. VS Code
            // excludes the same directory for the same reason.
            if (std.mem.indexOf(u8, path, "/.git/") != null or std.mem.endsWith(u8, path, "/.git")) continue;
            offs[n] = passthrough;
            batch[n].path = path;
            if (self.real) |real| {
                if (std.mem.startsWith(u8, path, real) and
                    (path.len == real.len or path[real.len] == '/'))
                {
                    offs[n] = self.respell.items.len;
                    const ok = blk: {
                        self.respell.appendSlice(self.gpa, self.root) catch break :blk false;
                        self.respell.appendSlice(self.gpa, path[real.len..]) catch break :blk false;
                        break :blk true;
                    };
                    if (!ok) {
                        // Drop the event, not the process — and drop the
                        // half-appended bytes, or the previous entry's
                        // end lands inside them.
                        self.respell.shrinkRetainingCapacity(offs[n]);
                        continue;
                    }
                }
            }
            var st: Stat = undefined;
            const exists = stat(paths[i], &st) == 0;
            // created = the flags claim it AND the file was born after
            // the stream. A rename-in keeps its old birthtime and reads
            // as changed — the server re-reads either way. A filesystem
            // with no birthtime (always 0) degrades the same direction.
            const born_after = st.birthtime.sec > self.began.sec or
                (st.birthtime.sec == self.began.sec and st.birthtime.nsec >= self.began.nsec);
            batch[n].kind = if (!exists)
                .deleted
            else if (flags[i] & (ev_created | ev_renamed) != 0 and born_after)
                .created
            else
                .changed;
            n += 1;
            if (n == batch.len) {
                self.flushBatch(&batch, &offs, n);
                n = 0;
                self.respell.clearRetainingCapacity();
            }
        }
        if (n > 0) self.flushBatch(&batch, &offs, n);
    }

    fn flushBatch(self: *Stream, batch: *[max_batch]Change, offs: *const [max_batch]usize, n: usize) void {
        const passthrough = std.math.maxInt(usize);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (offs[i] == passthrough) continue;
            batch[i].path = self.respell.items[offs[i]..endAfter(offs, i, n, self.respell.items.len)];
        }
        self.cb(self.ctx, batch[0..n]);
    }

    /// The respell buffer holds re-spelled paths back to back; one
    /// entry ends where the NEXT re-spelled entry starts, or at the
    /// buffer's end.
    fn endAfter(offs: *const [max_batch]usize, i: usize, n: usize, total: usize) usize {
        const passthrough = std.math.maxInt(usize);
        var j = i + 1;
        while (j < n) : (j += 1) {
            if (offs[j] != passthrough) return offs[j];
        }
        return total;
    }
};

// ----------------------------------------------------------------- test

extern "c" fn getpid() c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn rmdir(path: [*:0]const u8) c_int;
extern "c" fn usleep(us: c_uint) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;

const TestLog = struct {
    created: std.atomic.Value(bool) = .init(false),
    changed: std.atomic.Value(bool) = .init(false),
    deleted: std.atomic.Value(bool) = .init(false),
    /// An event arrived spelled outside the given root. /tmp IS a
    /// symlink on macOS, so this test exercises the re-spelling for
    /// real: without it, events come back under /private/tmp and this
    /// trips.
    misspelled: std.atomic.Value(bool) = .init(false),
    root: []const u8 = "",

    /// The elder file predates the stream: any "created" for it is the
    /// stale-flag bug the birthtime rule exists to stop.
    elder_changed: std.atomic.Value(bool) = .init(false),
    elder_created: std.atomic.Value(bool) = .init(false),

    fn cb(ctx: *anyopaque, changes: []const Change) void {
        const self: *TestLog = @ptrCast(@alignCast(ctx));
        for (changes) |ch| {
            if (!std.mem.startsWith(u8, ch.path, self.root)) self.misspelled.store(true, .release);
            if (std.mem.endsWith(u8, ch.path, "watched.txt")) {
                switch (ch.kind) {
                    .created => self.created.store(true, .release),
                    .changed => self.changed.store(true, .release),
                    .deleted => self.deleted.store(true, .release),
                }
            }
            if (std.mem.endsWith(u8, ch.path, "elder.txt")) {
                switch (ch.kind) {
                    .created => self.elder_created.store(true, .release),
                    .changed => self.elder_changed.store(true, .release),
                    .deleted => {},
                }
            }
        }
    }

    fn waitFor(v: *std.atomic.Value(bool)) bool {
        var waited: u32 = 0;
        while (waited < 5_000_000) : (waited += 20_000) {
            if (v.load(.acquire)) return true;
            _ = usleep(20_000);
        }
        return false;
    }
};

test "a change under the root comes back classified" {
    var dbuf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dbuf, "/tmp/rook-fswatch-{d}", .{getpid()});
    _ = mkdir(dir.ptr, 0o755);
    var fbuf: [160]u8 = undefined;
    const file = try std.fmt.bufPrintZ(&fbuf, "{s}/watched.txt", .{dir});
    defer {
        _ = unlink(file.ptr);
        _ = rmdir(dir.ptr);
    }

    // Born BEFORE the stream: its later write event will still wear
    // the created flag (FSEvents flags are history), and only the
    // birthtime rule reads it correctly.
    var ebuf: [160]u8 = undefined;
    const elder = try std.fmt.bufPrintZ(&ebuf, "{s}/elder.txt", .{dir});
    {
        const fd = open(elder.ptr, 0x601, @as(c_int, 0o644)); // O_WRONLY|O_CREAT|O_TRUNC
        try std.testing.expect(fd >= 0);
        _ = write(fd, "old\n", 4);
        _ = close(fd);
    }
    defer _ = unlink(elder.ptr);

    var log: TestLog = .{ .root = dir };
    const ws = Stream.start(std.testing.allocator, dir, &log, TestLog.cb) orelse return error.NoStream;
    defer ws.stop();

    // Create — a file that did not exist when the stream started.
    {
        const fd = open(file.ptr, 0x601, @as(c_int, 0o644));
        try std.testing.expect(fd >= 0);
        _ = write(fd, "one\n", 4);
        _ = close(fd);
    }
    try std.testing.expect(TestLog.waitFor(&log.created));

    // Change — on the elder, whose stale created flag must lose to its
    // birthtime.
    {
        const fd = open(elder.ptr, 0x601, @as(c_int, 0o644));
        try std.testing.expect(fd >= 0);
        _ = write(fd, "new\n", 4);
        _ = close(fd);
    }
    try std.testing.expect(TestLog.waitFor(&log.elder_changed));
    try std.testing.expect(!log.elder_created.load(.acquire));

    // Delete — stat is the tiebreaker, so this must classify deleted
    // even if the event still carries created|modified history.
    _ = unlink(file.ptr);
    try std.testing.expect(TestLog.waitFor(&log.deleted));

    // Every event arrived spelled under the root WE gave, not the
    // kernel's resolution of it — /tmp IS a symlink, so this run
    // exercised the re-spelling for real.
    try std.testing.expect(!log.misspelled.load(.acquire));
}
