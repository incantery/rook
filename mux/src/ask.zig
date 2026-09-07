//! The intent boundary: what bare text at rook's home becomes.
//!
//! Rook does not interpret. A request typed at the root goes, as
//! typed, to the companion's own command — `[companion] ask`, `vera
//! say -c rook` by default — run as a child with pipes, never a pty:
//! its stdout is the reply and its stderr is its running commentary,
//! and neither is scraped for state. The child runs in the server's
//! poll loop, so the frame never waits on it.
//!
//! A reply is words, unless it is one JSON object — then it is a
//! *reflection*, the typed shape a producer that understands intent
//! can answer with:
//!
//!     {"intent":   "what I understood",
//!      "plan":     ["step", "step"],
//!      "space":    "api",                    the space this is about
//!      "question": "one thing I need first",
//!      "actions":  [{"label":"start an agent on it",
//!                    "run":  "vera task new --project api 'fix auth'"}]}
//!
//! Every field is optional. Actions are proposals: rook shows each
//! one with the command it would run, verbatim, and runs it only when
//! a person confirms it (↵ on the row), through the same runner, and
//! shows what it printed as the receipt. Nothing here runs on its
//! own, and nothing that ran is hidden. Vera does not answer in this
//! shape yet; her prose reply is shown as a reply, and this file is
//! the contract for when she does.
const std = @import("std");
const ptypkg = @import("pty.zig");
const panepkg = @import("pane.zig");

extern "c" fn fork() ptypkg.pid_t;
extern "c" fn pipe(fds: *[2]ptypkg.fd_t) c_int;
extern "c" fn dup2(old: ptypkg.fd_t, new: ptypkg.fd_t) c_int;
extern "c" fn close(fd: ptypkg.fd_t) c_int;
extern "c" fn execvp(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn waitpid(pid: ptypkg.pid_t, status: *c_int, options: c_int) ptypkg.pid_t;
extern "c" fn kill(pid: ptypkg.pid_t, sig: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_int) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn getdtablesize() c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const WNOHANG: c_int = 1;
const X_OK: c_int = 1;

pub const max_text = 256;
pub const max_reply = 4096;
pub const max_note = 512;

/// A child with its stdout and stderr on pipes. One at a time: the
/// ask, or one of its actions.
pub const Job = struct {
    pid: ptypkg.pid_t = 0,
    out_fd: ptypkg.fd_t = -1,
    err_fd: ptypkg.fd_t = -1,
    out: [max_reply]u8 = undefined,
    out_len: usize = 0,
    err: [max_note]u8 = undefined,
    err_len: usize = 0,
    /// Bytes past the buffers are dropped, and the drop is noted.
    truncated: bool = false,
    done: bool = false,
    code: i32 = 0,
    started_ms: i64 = 0,

    /// `sh -c '<cmd> "$0"' -- <text>`: the command as configured, the
    /// text as one argument, no quoting of the text by rook.
    pub fn spawn(cmd: []const u8, text: []const u8) !Job {
        var line_buf: [1024]u8 = undefined;
        const line = std.fmt.bufPrintZ(&line_buf, "{s} \"$0\"", .{cmd}) catch return error.TooLong;
        return spawnShell(line, text);
    }

    /// `sh -c '<line>'`: an action's command, verbatim.
    pub fn spawnLine(line: []const u8) !Job {
        var line_buf: [1024]u8 = undefined;
        const z = std.fmt.bufPrintZ(&line_buf, "{s}", .{line}) catch return error.TooLong;
        return spawnShell(z, "");
    }

    fn spawnShell(line: [*:0]const u8, arg0: []const u8) !Job {
        var arg_buf: [max_text + 1]u8 = undefined;
        const arg0_z = std.fmt.bufPrintZ(&arg_buf, "{s}", .{arg0}) catch return error.TooLong;
        var out_p: [2]ptypkg.fd_t = undefined;
        var err_p: [2]ptypkg.fd_t = undefined;
        if (pipe(&out_p) != 0) return error.PipeFailed;
        if (pipe(&err_p) != 0) {
            _ = close(out_p[0]);
            _ = close(out_p[1]);
            return error.PipeFailed;
        }
        const pid = fork();
        if (pid < 0) {
            inline for (.{ out_p[0], out_p[1], err_p[0], err_p[1] }) |fd| _ = close(fd);
            return error.ForkFailed;
        }
        if (pid == 0) {
            const devnull = open("/dev/null", 0, 0);
            if (devnull >= 0) _ = dup2(devnull, 0);
            _ = dup2(out_p[1], 1);
            _ = dup2(err_p[1], 2);
            var fd: c_int = 3;
            const maxfd = getdtablesize();
            while (fd < maxfd) : (fd += 1) _ = close(fd);
            const argv = [_:null]?[*:0]const u8{ "sh", "-c", line, arg0_z.ptr };
            _ = execvp("/bin/sh", &argv);
            _exit(127);
        }
        _ = close(out_p[1]);
        _ = close(err_p[1]);
        _ = ptypkg.setNonblockFd(out_p[0]);
        _ = ptypkg.setNonblockFd(err_p[0]);
        return .{ .pid = pid, .out_fd = out_p[0], .err_fd = err_p[0], .started_ms = panepkg.epochMs() };
    }

    /// Read what the pipes hold; reap the child once both have
    /// closed. True the turn the job finishes.
    pub fn pump(self: *Job) bool {
        if (self.done) return false;
        if (self.out_fd >= 0) self.drain(&self.out_fd, self.out[0..], &self.out_len);
        if (self.err_fd >= 0) self.drain(&self.err_fd, self.err[0..], &self.err_len);
        if (self.out_fd >= 0 or self.err_fd >= 0) return false;
        var status: c_int = 0;
        const r = waitpid(self.pid, &status, WNOHANG);
        if (r == 0) return false;
        self.done = true;
        // WEXITSTATUS / WIFSIGNALED, by hand
        self.code = if (status & 0x7f == 0) (status >> 8) & 0xff else 128 + (status & 0x7f);
        return true;
    }

    fn drain(self: *Job, fd: *ptypkg.fd_t, buf: []u8, len: *usize) void {
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = ptypkg.readNb(fd.*, &tmp);
            if (n < 0) return; // dry
            if (n == 0) {
                _ = close(fd.*);
                fd.* = -1;
                return;
            }
            const got: usize = @intCast(n);
            const room = buf.len - len.*;
            const n_take = @min(room, got);
            @memcpy(buf[len.* .. len.* + n_take], tmp[0..n_take]);
            len.* += n_take;
            if (n_take < got) self.truncated = true;
        }
    }

    /// The fds the loop should watch, so a reply wakes the server.
    pub fn fds(self: *const Job, out: []ptypkg.Pollfd) usize {
        var n: usize = 0;
        if (self.out_fd >= 0 and n < out.len) {
            out[n] = .{ .fd = self.out_fd, .events = ptypkg.POLLIN };
            n += 1;
        }
        if (self.err_fd >= 0 and n < out.len) {
            out[n] = .{ .fd = self.err_fd, .events = ptypkg.POLLIN };
            n += 1;
        }
        return n;
    }

    pub fn cancel(self: *Job) void {
        if (self.done) return;
        if (self.pid > 0) _ = kill(self.pid, ptypkg.SIGTERM);
        if (self.out_fd >= 0) _ = close(self.out_fd);
        if (self.err_fd >= 0) _ = close(self.err_fd);
        self.out_fd = -1;
        self.err_fd = -1;
        var status: c_int = 0;
        _ = waitpid(self.pid, &status, WNOHANG);
        self.done = true;
        self.code = -1;
    }

    pub fn stdout(self: *const Job) []const u8 {
        return self.out[0..self.out_len];
    }

    pub fn stderr(self: *const Job) []const u8 {
        return self.err[0..self.err_len];
    }
};

/// Is the command's first word something the shell would find? A
/// path is checked as one; a bare word is looked for on PATH. Cheap
/// enough to ask on every entry to the root, and the only availability
/// rook can honestly claim without running anything.
pub fn available(cmd: []const u8) bool {
    const word = std.mem.sliceTo(std.mem.trimStart(u8, cmd, " \t"), ' ');
    if (word.len == 0) return false;
    var z: [1024]u8 = undefined;
    if (std.mem.indexOfScalar(u8, word, '/') != null) {
        const p = std.fmt.bufPrintZ(&z, "{s}", .{word}) catch return false;
        return access(p, X_OK) == 0;
    }
    const path = std.mem.span(getenv("PATH") orelse return false);
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const p = std.fmt.bufPrintZ(&z, "{s}/{s}", .{ dir, word }) catch continue;
        if (access(p, X_OK) == 0) return true;
    }
    return false;
}

// ---- the reflection ----

pub const max_plan = 8;
pub const max_actions = 6;

pub const Action = struct {
    label: [96]u8 = undefined,
    label_len: usize = 0,
    run: [256]u8 = undefined,
    run_len: usize = 0,
    /// pending until a hand confirms it; then what it printed
    ran: bool = false,
    running: bool = false,
    code: i32 = 0,
    receipt: [max_note]u8 = undefined,
    receipt_len: usize = 0,

    pub fn labelSlice(self: *const Action) []const u8 {
        return self.label[0..self.label_len];
    }
    pub fn runSlice(self: *const Action) []const u8 {
        return self.run[0..self.run_len];
    }
    pub fn receiptSlice(self: *const Action) []const u8 {
        return self.receipt[0..self.receipt_len];
    }
};

pub const Reflection = struct {
    intent: [256]u8 = undefined,
    intent_len: usize = 0,
    plan: [max_plan][160]u8 = undefined,
    plan_lens: [max_plan]usize = @splat(0),
    plan_n: usize = 0,
    space: [32]u8 = undefined,
    space_len: usize = 0,
    question: [256]u8 = undefined,
    question_len: usize = 0,
    actions: [max_actions]Action = undefined,
    actions_n: usize = 0,

    pub fn intentSlice(self: *const Reflection) []const u8 {
        return self.intent[0..self.intent_len];
    }
    pub fn planLine(self: *const Reflection, i: usize) []const u8 {
        return self.plan[i][0..self.plan_lens[i]];
    }
    pub fn spaceSlice(self: *const Reflection) []const u8 {
        return self.space[0..self.space_len];
    }
    pub fn questionSlice(self: *const Reflection) []const u8 {
        return self.question[0..self.question_len];
    }
};

fn take(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

fn objStr(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// A reply that is one JSON object is a reflection; anything else is
/// words. A JSON object with none of the fields is still a
/// reflection, empty — the producer chose the shape.
pub fn parse(reply: []const u8) ?Reflection {
    const body = std.mem.trim(u8, reply, " \t\r\n");
    if (body.len < 2 or body[0] != '{' or body[body.len - 1] != '}') return null;
    var scratch: [32 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const doc = std.json.parseFromSlice(std.json.Value, fba.allocator(), body, .{ .allocate = .alloc_always }) catch return null;
    const root = switch (doc.value) {
        .object => |o| o,
        else => return null,
    };
    var r: Reflection = .{};
    if (objStr(root, "intent")) |s| r.intent_len = take(&r.intent, s);
    if (objStr(root, "space")) |s| r.space_len = take(&r.space, s);
    if (objStr(root, "question")) |s| r.question_len = take(&r.question, s);
    if (root.get("plan")) |pv| {
        if (pv == .array) {
            for (pv.array.items) |item| {
                if (r.plan_n == max_plan) break;
                if (item != .string) continue;
                r.plan_lens[r.plan_n] = take(&r.plan[r.plan_n], item.string);
                r.plan_n += 1;
            }
        }
    }
    if (root.get("actions")) |av| {
        if (av == .array) {
            for (av.array.items) |item| {
                if (r.actions_n == max_actions) break;
                const o = switch (item) {
                    .object => |m| m,
                    else => continue,
                };
                const run = objStr(o, "run") orelse continue;
                var act: Action = .{};
                act.run_len = take(&act.run, run);
                act.label_len = take(&act.label, objStr(o, "label") orelse run);
                r.actions[r.actions_n] = act;
                r.actions_n += 1;
            }
        }
    }
    return r;
}

pub const State = enum {
    /// nothing asked
    none,
    /// the command is running; the reply is on its way
    running,
    /// it answered: words, or a reflection
    replied,
    /// it exited nonzero, or could not be run
    failed,
    /// the command is not on PATH: rook can find and command, and
    /// says so
    offline,
};

/// One request and what became of it. Lives on the root's state; the
/// receipt stays until the next request or Esc.
pub const Request = struct {
    state: State = .none,
    text: [max_text]u8 = undefined,
    text_len: usize = 0,
    reply: [max_reply]u8 = undefined,
    reply_len: usize = 0,
    note: [max_note]u8 = undefined,
    note_len: usize = 0,
    code: i32 = 0,
    started_ms: i64 = 0,
    ended_ms: i64 = 0,
    ref: ?Reflection = null,
    job: ?Job = null,
    /// the action whose command is running, when one is
    running_action: ?usize = null,

    pub fn textSlice(self: *const Request) []const u8 {
        return self.text[0..self.text_len];
    }
    pub fn replySlice(self: *const Request) []const u8 {
        return self.reply[0..self.reply_len];
    }
    pub fn noteSlice(self: *const Request) []const u8 {
        return self.note[0..self.note_len];
    }

    /// Send `text` through `cmd`. A command that cannot be found is
    /// `offline` at once; one that cannot be forked is `failed`.
    pub fn send(self: *Request, cmd: []const u8, text: []const u8) void {
        self.cancel();
        self.* = .{};
        self.text_len = take(&self.text, text);
        self.started_ms = panepkg.epochMs();
        if (cmd.len == 0 or !available(cmd)) {
            self.state = .offline;
            self.ended_ms = self.started_ms;
            return;
        }
        self.job = Job.spawn(cmd, self.textSlice()) catch {
            self.state = .failed;
            self.note_len = take(&self.note, "could not start the command");
            self.ended_ms = self.started_ms;
            return;
        };
        self.state = .running;
    }

    /// Run the i-th proposed action, by hand.
    pub fn confirm(self: *Request, i: usize) void {
        const r = &(self.ref orelse return);
        if (i >= r.actions_n or self.job != null) return;
        const act = &r.actions[i];
        if (act.ran or act.running) return;
        self.job = Job.spawnLine(act.runSlice()) catch {
            act.ran = true;
            act.code = -1;
            act.receipt_len = take(&act.receipt, "could not start it");
            return;
        };
        act.running = true;
        self.running_action = i;
    }

    /// Pump the child. True when something changed on the glass.
    pub fn pump(self: *Request) bool {
        const job = &(self.job orelse return false);
        const before = job.out_len + job.err_len;
        const finished = job.pump();
        if (!finished) return job.out_len + job.err_len != before;
        if (self.running_action) |i| {
            const act = &self.ref.?.actions[i];
            act.running = false;
            act.ran = true;
            act.code = job.code;
            // the receipt: what it printed, stdout then stderr, the
            // first of it
            act.receipt_len = take(&act.receipt, job.stdout());
            if (act.receipt_len < act.receipt.len and job.err_len > 0) {
                act.receipt_len += take(act.receipt[act.receipt_len..], job.stderr());
            }
            self.running_action = null;
        } else {
            self.reply_len = take(&self.reply, job.stdout());
            self.note_len = take(&self.note, job.stderr());
            self.code = job.code;
            self.ended_ms = panepkg.epochMs();
            self.state = if (job.code == 0) .replied else .failed;
            if (self.state == .replied) self.ref = parse(self.replySlice());
        }
        self.job = null;
        return true;
    }

    pub fn cancel(self: *Request) void {
        if (self.job) |*j| {
            j.cancel();
            self.job = null;
        }
        if (self.running_action) |i| {
            if (self.ref) |*r| {
                r.actions[i].running = false;
            }
            self.running_action = null;
        } else if (self.state == .running) {
            self.state = .failed;
            self.note_len = take(&self.note, "cancelled");
            self.ended_ms = panepkg.epochMs();
        }
    }

    pub fn busy(self: *const Request) bool {
        return self.job != null;
    }

    /// Esc: forget the receipt. True when there was one to forget.
    pub fn dismiss(self: *Request) bool {
        if (self.state == .none) return false;
        self.cancel();
        self.* = .{};
        return true;
    }

    pub fn fds(self: *const Request, out: []ptypkg.Pollfd) usize {
        if (self.job) |*j| return j.fds(out);
        return 0;
    }
};

/// The first line of a reply, for the bar and the corner.
pub fn firstLine(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    return std.mem.sliceTo(t, '\n');
}

test "a reply that is one JSON object is a reflection, words are words" {
    try std.testing.expect(parse("Sure — I started one in api.") == null);
    try std.testing.expect(parse("") == null);
    const r = parse(
        \\{"intent":"fix the flaky auth test","plan":["read the failure","patch the retry"],"space":"api",
        \\ "actions":[{"label":"start an agent on it","run":"vera task new --project api 'fix auth'"},{"run":"echo hi"}],
        \\ "question":"the retry limit?"}
    ).?;
    try std.testing.expectEqualStrings("fix the flaky auth test", r.intentSlice());
    try std.testing.expectEqual(@as(usize, 2), r.plan_n);
    try std.testing.expectEqualStrings("patch the retry", r.planLine(1));
    try std.testing.expectEqualStrings("api", r.spaceSlice());
    try std.testing.expectEqualStrings("the retry limit?", r.questionSlice());
    try std.testing.expectEqual(@as(usize, 2), r.actions_n);
    try std.testing.expectEqualStrings("start an agent on it", r.actions[0].labelSlice());
    try std.testing.expectEqualStrings("vera task new --project api 'fix auth'", r.actions[0].runSlice());
    // an action with no label is labelled by what it runs
    try std.testing.expectEqualStrings("echo hi", r.actions[1].labelSlice());
    // an action without a command is not an action
    const none = parse("{\"actions\":[{\"label\":\"x\"}]}").?;
    try std.testing.expectEqual(@as(usize, 0), none.actions_n);
    // an object that is not an object
    try std.testing.expect(parse("[1,2]") == null);
    try std.testing.expect(parse("{not json}") == null);
}

test "availability is the shell's own answer" {
    try std.testing.expect(available("/bin/sh -c x"));
    try std.testing.expect(available("sh"));
    try std.testing.expect(!available("no-such-program-rook-asks-for"));
    try std.testing.expect(!available(""));
}

test "a job runs to a reply and the request reads it" {
    var req: Request = .{};
    req.send("/bin/echo reply:", "hello there");
    try std.testing.expectEqual(State.running, req.state);
    var fds: [2]ptypkg.Pollfd = undefined;
    var spins: usize = 0;
    while (req.busy() and spins < 500) : (spins += 1) {
        const n = req.fds(&fds);
        if (n > 0) _ = ptypkg.pollMany(&fds, @intCast(n), 20);
        _ = req.pump();
    }
    try std.testing.expectEqual(State.replied, req.state);
    try std.testing.expectEqualStrings("reply: hello there\n", req.replySlice());
    try std.testing.expect(req.ref == null);
    // a command that is not there is offline, at once
    var off: Request = .{};
    off.send("no-such-program-rook-asks-for say", "x");
    try std.testing.expectEqual(State.offline, off.state);
    // a nonzero exit is a failure, and what it said on stderr is kept
    var bad: Request = .{};
    bad.send("/bin/sh -c 'echo nope >&2; exit 3' --", "x");
    spins = 0;
    while (bad.busy() and spins < 500) : (spins += 1) {
        const n = bad.fds(&fds);
        if (n > 0) _ = ptypkg.pollMany(&fds, @intCast(n), 20);
        _ = bad.pump();
    }
    try std.testing.expectEqual(State.failed, bad.state);
    try std.testing.expectEqualStrings("nope\n", bad.noteSlice());
    try std.testing.expect(bad.dismiss());
    try std.testing.expectEqual(State.none, bad.state);
}
