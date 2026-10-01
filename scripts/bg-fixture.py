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

print("\n%d failed" % len(fails) if fails else "\nall passed")
sys.exit(1 if fails else 0)
