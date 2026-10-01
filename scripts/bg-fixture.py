#!/usr/bin/env python3
"""The background, end to end: a sandboxed engine behind a real glass.

    make -C mux build && python3 scripts/bg-fixture.py

Panes that run in no window (docs/background.md). This drives an
engine — its own socket, HOME and config, never the live one — through
a pty decoded with pyte, and asserts on the glass, the state feed and
`rook bg`:

  01-run       a service starts in the background: in no workspace, the
               glass untouched, the bar counting it, readable by id
  02-health    the promised port answers: healthy, and the port is its
  03-show      a group comes into the window, and goes back whole
  04-keys      the background key sends the focused pane's group back,
               the foreground key brings this workspace's group in
  05-last      the last pane stays
  06-death     a service that exits is kept and said; kill lets it go
  07-close     closing a workspace takes its group with it
  08-restore   a service is run again, in the background, after a restart
  09-auto      `--port auto` hands out a port as $PORT
  10-hard      what stress testing broke: labels, a stolen port, eighty
               services, close and a group shown elsewhere, a dead
               pane, the whole group or none, a pin, the last window
  11-big       a restore file past 64KB
  12-round2    a directory named to forge restore lines, a command of
               several lines, group:NAME, a 160KB state snapshot, a pin
               whose workspace lost its last window pane

Exit status 1 when an assertion fails. Needs `pip install pyte`.
"""
import fcntl, json, os, pty, select, signal, socket, struct, subprocess, sys, tempfile, termios, time

try:
    import pyte
except ImportError:
    sys.stderr.write("bg-fixture: needs pyte (pip install pyte)\n")
    sys.exit(2)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENGINE = os.path.join(REPO, "mux", "zig-out", "bin", "engine")
FRONT = os.path.join(tempfile.mkdtemp(prefix="/tmp/rk-front-"), "rook")
subprocess.run(["go", "build", "-o", FRONT, "./cmd/rook"], cwd=REPO, check=True)

fails = []


def check(name, ok, extra=""):
    print(("PASS  " if ok else "FAIL  ") + name + ("  " + str(extra) if extra and not ok else ""))
    if not ok:
        fails.append(name)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class Rook:
    """A sandboxed engine behind a pyte glass."""

    def __init__(self, conf="", tag="bg", cols=110, rows=24):
        self.root = tempfile.mkdtemp(prefix="/tmp/rk-%s-" % tag)
        self.cols, self.rows = cols, rows
        os.makedirs(self.root + "/.config/rook")
        with open(self.root + "/.config/rook/rook.toml", "w") as f:
            f.write('[tmux]\nprefix = "`"\n' + conf)
        self.env = dict(os.environ)
        for k in ("ROOK_MUX_PANE", "TMUX", "TMUX_PANE", "ROOK_MUX_SOCK"):
            self.env.pop(k, None)
        self.sock = "/tmp/rk-%s-%d.sock" % (tag, os.getpid())
        self.env.update({
            "ROOK_MUX_SOCK": self.sock, "SHELL": "/bin/sh", "HOME": self.root,
            "XDG_STATE_HOME": self.root + "/state", "XDG_CONFIG_HOME": self.root + "/.config",
            "TERM": "xterm-256color", "PS1": "$ ", "ENV": self.root + "/.shrc",
            "PATH": "/usr/bin:/bin", "ROOK_FRONT_DOOR": FRONT, "ROOK_ENGINE": ENGINE,
        })
        with open(self.root + "/.shrc", "w") as f:
            f.write("PS1='$ '\n")
        self.boot()

    def boot(self):
        self.server = subprocess.Popen([ENGINE, "server"], env=self.env, cwd=self.root,
                                       stdout=subprocess.DEVNULL, stderr=open(self.root + "/server.log", "a"))
        for _ in range(150):
            if os.path.exists(self.sock):
                break
            time.sleep(0.02)
        self.screen = pyte.Screen(self.cols, self.rows)
        self.stream = pyte.ByteStream(self.screen)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execve(ENGINE, [ENGINE], self.env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", self.rows, self.cols, 0, 0))
        self.settle(0.8)

    def pump(self, timeout=0.05):
        while True:
            r, _, _ = select.select([self.fd], [], [], timeout)
            if not r:
                return
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                return
            if not data:
                return
            self.stream.feed(data)
            timeout = 0.02

    def settle(self, secs=0.4):
        end = time.time() + secs
        while time.time() < end:
            self.pump(0.05)

    def keys(self, s, settle=0.5):
        os.write(self.fd, s.encode())
        self.settle(settle)

    def front(self, *args, pane=None):
        env = dict(self.env)
        if pane is not None:
            env["ROOK_MUX_PANE"] = str(pane)
        p = subprocess.run([FRONT] + list(args), env=env, cwd=self.root,
                           capture_output=True, text=True, timeout=30)
        self.settle(0.3)
        return p.returncode, p.stdout.strip(), p.stderr.strip()

    def state(self):
        return json.loads(self.front("state")[1])

    def bg(self):
        return json.loads(self.front("bg", "--json")[1])

    def run(self, *args, pane=None):
        code, out, err = self.front("bg", "run", *args, pane=pane)
        return json.loads(out)["pane"] if code == 0 else None

    def placed(self, st=None):
        """Pane ids in any window of any workspace."""
        out = []

        def walk(n):
            if isinstance(n, dict):
                if "pane" in n:
                    out.append(n["pane"])
                for v in n.values():
                    walk(v)
            elif isinstance(n, list):
                for v in n:
                    walk(v)

        for ws in (st or self.state())["workspaces"]:
            for w in ws["windows"]:
                walk(w["layout"])
        return out

    def pane(self, pid):
        return next((p for p in self.state()["panes"] if p["id"] == pid), None)

    def bar(self):
        return self.screen.display[self.rows - 1].rstrip()

    def stop(self):
        self.front("kill")
        try:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        except Exception:
            pass
        try:
            self.server.wait(timeout=5)
        except Exception:
            self.server.kill()

    def close(self):
        try:
            self.stop()
        except Exception:
            pass


def until(fn, secs=8.0):
    end = time.time() + secs
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(0.25)
    return fn()


SPACE = '[mux]\nstartup = "last-space"\n'

# ---- 01-03: run, health, show and hide
r = Rook(conf=SPACE, tag="run")
try:
    port = free_port()
    before = r.placed()
    sid = r.run("-g", "web", "--by", "vera", "--port", str(port), "--", "python3", "-m", "http.server", str(port))
    check("run answers with the pane it made", isinstance(sid, int), sid)
    st = r.state()
    p = next((x for x in st["panes"] if x["id"] == sid), None)
    check("the pane is in the background, in a group", p and p["background"] and p.get("group") == "web", p)
    check("it carries what it was started as, and by whom", p and p["service"]["command"].startswith("python3") and p["service"]["by"] == "vera", p)
    check("it is in no window, and the glass is as it was", sid not in r.placed(st) and r.placed(st) == before, r.placed(st))
    check("the bar counts it", "bg 1" in r.bar(), r.bar())
    blocks = r.front("blocks")[1]
    check("`rook blocks` lists it under bg:group", ("%d\tbg:web" % sid) in blocks, blocks)

    row = until(lambda: next((x for x in r.bg() if x["id"] == sid and x["health"] == "healthy"), None))
    check("the promised port answers: healthy", row is not None, r.bg())
    check("the port is found on its own processes", row and port in row["ports"], row)
    check("`bg wait` returns once it is healthy", r.front("bg", "wait", "web", "--timeout", "8000")[0] == 0)
    code, text, _ = r.front("read", str(sid))
    check("it is read without bringing it forward", code == 0 and "Serving HTTP" in text, text)
    table = r.front("bg")[1]
    check("the table says group, state and port", "web" in table and "healthy" in table and (":%d" % port) in table, table)

    second = r.run("-g", "web", "--", "sleep", "600")
    code, _, err = r.front("bg", "show", "web")
    st = r.state()
    cur = next(w for w in st["workspaces"] if w["current"])
    check("show brings the group into the window on the glass", code == 0 and sid in r.placed(st) and second in r.placed(st), (err, r.placed(st)))
    check("and they are not in the background any more", not r.pane(sid)["background"] and "bg " not in r.bar(), r.bar())
    check("focus stayed where it was", st["focus"]["pane"] == before[0], st["focus"])
    check("the group stays on the panes", r.pane(sid).get("group") == "web")
    code, _, err = r.front("bg", "hide", "web")
    check("hide sends the group back whole", code == 0 and r.placed() == before and "bg 2" in r.bar(), (err, r.placed(), r.bar()))

    # ---- 04: the keys
    r.front("bg", "show", "web", "--focus")
    check("show --focus lands on the group", r.state()["focus"]["pane"] == sid, r.state()["focus"])
    r.keys("`b")
    check("the background key sends the focused pane's group back", r.placed() == before and "background" in r.bar(), (r.placed(), r.bar()))
    r.keys("x", 0.2)  # a key, so the notice may go
    r.keys("\x7f", 0.2)
    r.keys("`B")
    st = r.state()
    check("the foreground key brings it into the window, focused", sid in r.placed(st) and st["focus"]["pane"] == sid, (r.placed(st), st["focus"]))
    r.front("bg", "hide", "web")

    # a plain pane, sent back: named for its workspace
    code, out, _ = r.front("split", str(before[0]))
    plain = json.loads(out)["pane"]
    code, _, err = r.front("bg", "hide", str(plain))
    ws = next(w["name"] for w in r.state()["workspaces"] if w["current"])
    check("a plain pane goes back under its workspace's name", code == 0 and r.pane(plain)["background"] and r.pane(plain).get("group") == ws, (err, r.pane(plain)))
    r.front("focus", str(plain))
    check("focusing a pane in the background brings it forward", plain in r.placed() and r.state()["focus"]["pane"] == plain, r.placed())
    r.front("close-pane", str(plain))

    # ---- 05: the last pane stays
    code, _, err = r.front("bg", "hide", str(before[0]))
    check("the last pane placed anywhere is refused", code == 1 and "last pane" in err and before[0] in r.placed(), (code, err))

    # ---- 06: death
    dead = r.run("-g", "job", "--", "echo boom; exit 3")
    row = until(lambda: next((x for x in r.bg() if x["id"] == dead and x["health"] == "exited"), None))
    check("a service that exits is kept, and says exited", row is not None, r.bg())
    r.settle(0.3)
    check("the bar says it once, and counts it", "exited" in r.bar(), r.bar())
    code, text, _ = r.front("read", str(dead))
    check("its last words are still there to read", "boom" in text, text)
    check("the feed carries the exit", r.pane(dead)["exited"] and r.pane(dead)["service"]["exitMs"] > 0, r.pane(dead))
    code, out, err = r.front("bg", "wait", "job", "--timeout", "3000")
    check("`bg wait` on it fails, saying so", code == 1 and "exited" in err, (code, err))
    check("`bg wait --exit` on it succeeds", r.front("bg", "wait", "job", "--exit", "--timeout", "3000")[0] == 0)
    r.front("bg", "kill", "job")
    check("kill lets a dead one go", until(lambda: r.pane(dead) is None))

    # ---- 07: closing a workspace takes its group
    code, out, _ = r.front("new", "-q", "wt", r.root)
    wt_pane = json.loads(out)["pane"]
    svc = r.run("--", "sleep", "600", pane=wt_pane)
    check("a service started from a pane takes its workspace as its group", r.pane(svc).get("group") == "wt", r.pane(svc))
    r.front("close", "wt")
    check("closing the workspace hangs its group up", until(lambda: r.pane(svc) is None and r.pane(wt_pane) is None), r.bg())

    r.front("bg", "kill", "web")
    check("kill hangs a group up", until(lambda: r.pane(sid) is None and r.pane(second) is None), r.bg())
finally:
    r.close()

# ---- 08: restore
r = Rook(conf='[mux]\nstartup = "last-space"\nrestore = true\n', tag="restore")
try:
    a = r.run("-g", "api", "--by", "me", "--port", "1", "--", "sleep", "600")
    code, out, _ = r.front("split", str(r.placed()[0]))
    plain = json.loads(out)["pane"]
    r.front("bg", "hide", str(plain), "-g", "api")
    n_placed = len(r.placed())
    r.stop()
    saved = open(r.sock + ".state").read()
    check("the restore file holds the background", "bg api\tme\t1\t" in saved and "sleep 600" in saved, saved)
    r.boot()
    rows = r.bg()
    svc = [x for x in rows if x["command"] == "sleep 600"]
    check("a service is run again, in the background", len(svc) == 1 and svc[0]["place"] == "bg" and svc[0]["group"] == "api" and svc[0]["by"] == "me" and svc[0]["port"] == 1 and not svc[0]["exited"], rows)
    check("a plain pane sent back is a shell there again", len([x for x in rows if x["command"] == "" and x["place"] == "bg"]) == 1, rows)
    check("the windows came back as they were", len(r.placed()) == n_placed, r.placed())
finally:
    r.close()

# ---- 09: --port auto
r = Rook(conf=SPACE, tag="auto")
try:
    code, out, err = r.front("bg", "run", "--port", "auto", "--", "python3 -m http.server $PORT")
    sid = json.loads(out)["pane"] if code == 0 else None
    row = until(lambda: next((x for x in r.bg() if x["id"] == sid and x["health"] == "healthy"), None))
    check("--port auto hands a free port to the service as $PORT", row is not None and row["port"] > 0 and row["port"] in row["ports"] and ("PORT=%d" % row["port"]) in err, (err, r.bg()))
finally:
    r.close()

# ---- 10: what broke under stress, and must not again
r = Rook(conf=SPACE, tag="hard")
try:
    first = r.placed()[0]
    # labels: what cannot be said as a target, or would break the wire
    # or the restore file, is refused when it is given
    for bad, why in (("tab\there", "a tab"), ("line\nbreak", "a newline"), ("x" * 33, "33 bytes"),
                     ("123", "a number"), ("-dash", "a leading dash"), (".", "a dot")):
        code, _, err = r.front("bg", "run", "-g", bad, "--", "sleep", "5")
        check("a group with %s is refused" % why, code == 1 and "group" in err, (code, err))
    check("nothing was started by any of them", r.bg() == [], r.bg())
    code, _, err = r.front("bg", "run", "--cwd", "/nonexistent/dir", "--", "pwd")
    check("a directory that is not there is refused", code == 1 and "no directory" in err, (code, err))
    os.makedirs(r.root + "/sub", exist_ok=True)
    rel = r.run("-g", "rel", "--cwd", "sub", "--", "pwd; sleep 60")
    time.sleep(0.4)
    check("a relative --cwd is the caller's", r.front("read", str(rel))[1].strip().endswith("/sub"), r.front("read", str(rel))[1])
    code, _, err = r.front("bg", "run", "--port", "auto")
    check("--port auto with no command is usage, not a service", code == 1 and r.bg() == [x for x in r.bg() if x["group"] == "rel"], (code, err))
    code, out, err = r.front("bg", "run", "-g", "own", "--", "echo", "--port", "auto")
    own = json.loads(out)["pane"] if code == 0 else None
    time.sleep(0.4)
    check("a --port auto in the service's own words is the service's", own and "--port auto" in r.front("read", str(own))[1] and "PORT=" not in err, (err, r.front("read", str(own))[1]))
    r.front("bg", "kill", "own")
    r.front("bg", "kill", "rel")

    # a port somebody else holds is not this service's health
    held = socket.socket()
    held.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    held.bind(("127.0.0.1", 0))
    held.listen(1)
    stolen = r.run("-g", "stolen", "--port", str(held.getsockname()[1]), "--", "sleep", "60")
    row = next(x for x in r.bg() if x["id"] == stolen)
    check("a promised port held by another process is a conflict", row["health"] == "conflict", row)
    code, _, err = r.front("bg", "wait", "stolen", "--timeout", "3000")
    check("and `bg wait` says so at once", code == 1 and "held by" in err, (code, err))
    held.close()
    r.front("bg", "kill", "stolen")
    check("`bg wait` refuses a negative timeout", r.front("bg", "wait", "x", "--timeout", "-5")[0] == 1)

    # many: a group is not capped at what a small buffer holds
    for i in range(80):
        r.front("bg", "run", "-g", "many", "--", "sleep", "300")
    check("eighty services are eighty rows", len([x for x in r.bg() if x["group"] == "many"]) == 80)
    r.front("bg", "kill", "many")
    check("one kill takes the whole group", until(lambda: not [x for x in r.bg() if x["group"] == "many"], 15), len(r.bg()))

    # close takes the group wherever its panes are
    code, out, _ = r.front("new", "-q", "w2", r.root)
    w2 = json.loads(out)["pane"]
    s1 = r.run("-g", "w2", "--", "sleep", "300")
    s2 = r.run("-g", "w2", "--", "sleep", "300")
    r.front("bg", "show", str(s2))  # into the workspace on the glass, not w2
    r.front("close", "w2")
    check("closing a workspace takes its group's panes shown elsewhere too", until(lambda: r.pane(s1) is None and r.pane(s2) is None and r.pane(w2) is None), r.bg())

    # a dead pane takes no typing
    dead = r.run("-g", "dead", "--", "true")
    until(lambda: next((x for x in r.bg() if x["id"] == dead and x["exited"]), None))
    code, _, err = r.front("run", str(dead), "echo hi")
    check("typing at a dead service is refused", code == 1 and "exited" in err, (code, err))
    r.front("bg", "kill", "dead")

    # a group goes back whole or not at all
    code, out, _ = r.front("split", str(first))
    other = json.loads(out)["pane"]
    r.front("bg", "hide", str(first), "-g", "all")
    r.front("bg", "show", "all")
    r.front("bg", "hide", str(other), "-g", "all")
    r.front("bg", "show", "all")
    code, _, err = r.front("bg", "hide", "all")
    check("hiding every pane there is refuses, and sends none back", code == 1 and sorted(r.placed()) == sorted([first, other]), (code, err, r.placed()))

    # a workspace's last window pane stays while it has pinned panes:
    # this crashed the server
    r.front("focus", str(other))
    r.keys("`P")
    st = r.state()
    pinned = [p for w in st["workspaces"] for p in w["pins"]]
    check("the pin key docked a pane", len(pinned) == 1, st["workspaces"])
    left = [x for x in (first, other) if x not in pinned][0]
    code, _, err = r.front("bg", "hide", str(left))
    check("the last window pane of a workspace with a pin is refused", code == 1 and "last pane" in err and r.front("state")[0] == 0, (code, err))
    r.keys("`P")

    # the last window closes with services running: rook stays up
    svc = r.run("-g", "keep", "--", "sleep", "300")
    for pid_ in r.placed():
        r.front("close-pane", str(pid_))
    alive = until(lambda: r.front("state")[0] == 0 and any(w.get("home") for w in r.state()["workspaces"]))
    check("the last window closing does not end a server with services running", alive and r.pane(svc) is not None and not r.pane(svc)["exited"], r.front("state")[2])
finally:
    r.close()

# ---- 11: a restore file bigger than any one buffer
r = Rook(conf='[mux]\nstartup = "last-space"\nrestore = true\n', tag="bigrestore")
try:
    big = "sleep 300; : " + "z" * 4000
    for i in range(20):
        r.front("bg", "run", "-g", "big", "--", big)
    time.sleep(1.5)
    r.stop()
    size = os.path.getsize(r.sock + ".state")
    r.boot()
    rows = [x for x in r.bg() if x["group"] == "big"]
    check("a restore file past 64KB comes back whole (%d bytes)" % size, size > 70000 and len(rows) == 20 and all(x["command"] == big for x in rows), (size, len(rows), sorted(set(len(x["command"]) for x in rows))))
finally:
    r.close()

# ---- 12: the second round of stress
r = Rook(conf='[mux]\nstartup = "last-space"\nrestore = true\n', tag="round2")
try:
    first = r.placed()[0]
    # a directory can be named anything; the restore file is lines
    evil = os.path.join(r.root, "ev\nbg inj\t\t0\t/tmp\ttouch %s; sleep 60" % os.path.join(r.root, "INJECTED"))
    os.makedirs(evil)
    hostile = r.run("-g", "hostile", "--", "cd %s/ev* && exec sleep 300" % r.root)
    multi = r.run("-g", "multi", "--", "echo one\nprintf 'a\\\\b\\n'\nsleep 300")
    # a group named for a workspace that is a number is said outright
    code, out, _ = r.front("new", "-q", "5", r.root)
    five = json.loads(out)["pane"]
    num = r.run("--", "sleep", "300", pane=five)
    check("a group named for a numeric workspace is reached as group:5", r.pane(num).get("group") == "5" and r.front("bg", "show", "group:5")[0] == 0 and num in r.placed(), r.pane(num))
    r.front("bg", "hide", "group:5")
    # a long, multibyte directory name as the default group is cut on a character
    longdir = os.path.join(r.root, "a" + "\u00e9" * 17)
    os.makedirs(longdir)
    p = subprocess.run([FRONT, "bg", "run", "--", "sleep", "300"], env=r.env, cwd=longdir, capture_output=True, text=True)
    raw = subprocess.run([FRONT, "state"], env=r.env, capture_output=True).stdout
    try:
        raw.decode("utf-8")
        valid = True
    except UnicodeDecodeError:
        valid = False
    check("a default group cut at 32 bytes is still UTF-8 in the feed", p.returncode == 0 and valid, p.stderr)
    # the feed, past what one read holds
    for i in range(40):
        r.front("bg", "run", "-g", "fat", "--", "sleep 300; : " + "y" * 4000)
    code, out, err = r.front("state")
    check("a state snapshot past 160KB comes back whole (%d bytes)" % len(out), code == 0 and len(out) > 160000 and json.loads(out)["pid"] > 0, (code, err[:80]))
    r.front("bg", "kill", "fat")
    until(lambda: not [x for x in r.bg() if x["group"] == "fat"], 15)
    time.sleep(1.5)
    r.stop()
    saved = open(r.sock + ".state").read()
    check("a directory with a newline in its name is not written into the restore file", "bg inj" not in saved and "INJECTED" not in saved, saved)
    r.boot()
    time.sleep(1.0)
    check("and nothing it named ran on restart", not os.path.exists(os.path.join(r.root, "INJECTED")) and not [x for x in r.bg() if x["group"] == "inj"], r.bg())
    back = [x for x in r.bg() if x["group"] == "multi"]
    check("a command of several lines is saved and run again whole", len(back) == 1 and back[0]["command"] == "echo one\nprintf 'a\\\\b\\n'\nsleep 300" and not back[0]["exited"], back)
    time.sleep(0.5)
    check("and it ran as it was written", "one" in r.front("read", str(back[0]["id"]))[1] and "a\\b" in r.front("read", str(back[0]["id"]))[1], r.front("read", str(back[0]["id"]))[1])

    # a workspace's pinned pane is not left nowhere when its last
    # window pane closes: it becomes the window
    code, out, _ = r.front("new", "beta", r.root)
    b1 = json.loads(out)["pane"]
    code, out, _ = r.front("split", str(b1), "--focus")
    b2 = json.loads(out)["pane"]
    r.keys("`P")
    st = r.state()
    beta = next(w for w in st["workspaces"] if w["name"] == "beta")
    check("the pin key docked the focused pane", beta["pins"] == [b2], beta)
    r.front("close-pane", str(b1))
    ok = until(lambda: r.pane(b1) is None)
    st = r.state()
    beta = next((w for w in st["workspaces"] if w["name"] == "beta"), None)
    check("its last window pane closed: the pinned pane is its window now", beta is not None and beta["pins"] == [] and b2 in r.placed(st) and r.pane(b2) is not None, beta)
    every = set(p["id"] for p in st["panes"])
    somewhere = set(r.placed(st)) | set(p for w in st["workspaces"] for p in w["pins"]) | set(p["id"] for p in st["panes"] if p["background"])
    check("every pane is somewhere: a window, a rail, or the background", every == somewhere, sorted(every - somewhere))
finally:
    r.close()

print("\n%d failed" % len(fails) if fails else "\nall passed")
sys.exit(1 if fails else 0)
