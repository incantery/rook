#!/usr/bin/env python3
"""Home, end to end: a sandboxed engine behind a real glass.

    make -C mux build && python3 scripts/home-fixture.py [outdir]

Home is the one workspace outside the list of spaces (docs/home.md).
This drives an engine — its own socket, HOME and config, never the
live one — through a pty decoded with pyte, and asserts on the glass
and on the state feed:

  01-land         plain rook lands at home: one shell in ~, the chip
                  says home, the feed says scope home
  02-toggle       the home key goes to the space you came from and back;
                  C-o never lands on home; `rook ls` does not list it
  03-return       its last pane closed: back to where you were, and home
                  is gone until it is gone to again — then fresh
  04-stay         `on_empty = "stay"`: it starts over in place
  05-seeded       [[home.window]]s, their panes, commands and dirs
  06-alone        nothing else open: closing home starts it over, and
                  rook does not end
  07-last-space   `startup = "last-space"` lands in the space
  08-restore      home is never saved; the space it goes back to is
  09-keys         the defaults float no program; [keys] binds, rebinds
                  and unbinds

Frames are written as text (and PNGs with pillow). Exit status 1 when
an assertion fails. Needs `pip install pyte`.
"""
import fcntl, json, os, pty, select, signal, struct, subprocess, sys, tempfile, termios, time

try:
    import pyte
except ImportError:
    sys.stderr.write("home-fixture: needs pyte (pip install pyte)\n")
    sys.exit(2)
try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    Image = None

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENGINE = os.path.join(REPO, "mux", "zig-out", "bin", "engine")
OUT = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="/tmp/rook-home-")
os.makedirs(OUT, exist_ok=True)
# The front door compiles rook.toml for the engine (`rook config json`):
# this checkout's, built once, never the installed one.
FRONT = os.path.join(tempfile.mkdtemp(prefix="/tmp/rk-front-"), "rook")
subprocess.run(["go", "build", "-o", FRONT, "./cmd/rook"], cwd=REPO, check=True)

fails = []


def check(name, ok, extra=""):
    print(("PASS  " if ok else "FAIL  ") + name + ("  " + str(extra) if extra and not ok else ""))
    if not ok:
        fails.append(name)


def real(p):
    return os.path.realpath(p).rstrip("/")


class Rook:
    """A sandboxed engine behind a pyte glass."""

    def __init__(self, conf="", tag="home", cols=100, rows=24, attach=None, dirs=(), front=None):
        self.root = tempfile.mkdtemp(prefix="/tmp/rk-%s-" % tag)
        self.cols, self.rows = cols, rows
        os.makedirs(self.root + "/.config/rook")
        for d in dirs:
            os.makedirs(os.path.join(self.root, d), exist_ok=True)
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
            "PATH": "/usr/bin:/bin", "ROOK_FRONT_DOOR": front or FRONT, "ROOK_ENGINE": ENGINE,
        })
        with open(self.root + "/.shrc", "w") as f:
            f.write("PS1='$ '\n")
        self.server = subprocess.Popen([ENGINE, "server"], env=self.env, cwd=self.root,
                                       stdout=subprocess.DEVNULL, stderr=open(self.root + "/server.log", "w"))
        for _ in range(100):
            if os.path.exists(self.sock):
                break
            time.sleep(0.02)
        self.screen = pyte.Screen(cols, rows)
        self.stream = pyte.ByteStream(self.screen)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execve(ENGINE, [ENGINE] + (attach or []), self.env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
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

    def settle(self, secs=0.35):
        end = time.time() + secs
        while time.time() < end:
            self.pump(0.05)

    def keys(self, s, settle=0.4):
        os.write(self.fd, s.encode() if isinstance(s, str) else s)
        self.settle(settle)

    def write_conf(self, conf):
        with open(self.root + "/.config/rook/rook.toml", "w") as f:
            f.write('[tmux]\nprefix = "`"\n' + conf)

    def front(self, *args):
        p = subprocess.run([FRONT] + list(args), env=self.env, cwd=self.root,
                           capture_output=True, text=True, timeout=10)
        return p.returncode, (p.stdout + p.stderr).strip()

    def rook(self, *args):
        p = subprocess.run([ENGINE] + list(args), env=self.env, cwd=self.root,
                           capture_output=True, text=True, timeout=10)
        return (p.stdout + p.stderr).strip()

    def state(self):
        return json.loads(self.rook("state"))

    def current(self):
        return next((w for w in self.state()["workspaces"] if w["current"]), None)

    def home_ws(self):
        return next((w for w in self.state()["workspaces"] if w.get("home")), None)

    def panes_of(self, ws):
        """Pane ids in a workspace's windows, in layout order."""
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

        for w in ws["windows"]:
            walk(w["layout"])
        return out

    def pane(self, pid):
        return next((p for p in self.state()["panes"] if p["id"] == pid), None)

    def lines(self):
        return [line.rstrip() for line in self.screen.display]

    def snap(self, name):
        with open(os.path.join(OUT, name + ".txt"), "w") as f:
            f.write("\n".join(self.lines()) + "\n")
        if Image is None:
            return
        cw, ch = 8, 16
        img = Image.new("RGB", (self.cols * cw, self.rows * ch), (30, 30, 46))
        d = ImageDraw.Draw(img)
        try:
            font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 13)
        except Exception:
            font = ImageFont.load_default()

        def color(c, default):
            try:
                return tuple(int(c[i:i + 2], 16) for i in (0, 2, 4))
            except Exception:
                return default

        for y in range(self.rows):
            row = self.screen.buffer[y]
            for x in range(self.cols):
                cell = row[x]
                fg_ = color(cell.fg, (205, 214, 244))
                bg_ = color(cell.bg, (30, 30, 46))
                if cell.reverse:
                    fg_, bg_ = bg_, fg_
                if bg_ != (30, 30, 46):
                    d.rectangle([x * cw, y * ch, (x + 1) * cw - 1, (y + 1) * ch - 1], fill=bg_)
                if cell.data and cell.data != " ":
                    d.text((x * cw, y * ch), cell.data, fill=fg_, font=font)
        img.save(os.path.join(OUT, name + ".png"))

    def close(self):
        try:
            self.rook("kill")
        except Exception:
            pass
        try:
            os.kill(self.pid, signal.SIGKILL)
        except Exception:
            pass
        try:
            self.server.wait(timeout=3)
        except Exception:
            self.server.kill()


def top(r):
    return r.lines()[0]


# ---- 01: plain rook lands at home, a scratch pad
r = Rook(tag="land")
try:
    r.snap("01-land")
    st = r.state()
    h = r.home_ws()
    check("plain rook lands at home", st["scope"] == "home" and h is not None and h["current"], (st["scope"], h))
    check("home with nothing configured is one window, one shell", h and len(h["windows"]) == 1 and len(r.panes_of(h)) == 1, h)
    pid = r.panes_of(h)[0]
    check("…in ~", real(r.pane(pid)["cwd"]) == real(r.root), (r.pane(pid)["cwd"], r.root))
    check("the chip says home, with its mark", top(r).strip().startswith("⌂ home"), repr(top(r)[:30]))
    check("so does the calm bar, first", r.lines()[-1].strip().startswith("⌂ home"), repr(r.lines()[-1][:30]))
    home_ground = (r.screen.buffer[0][30].bg, r.screen.buffer[r.rows - 1][60].bg)
    check("the corner names the way back to the space", top(r).rstrip().endswith("`o main"), repr(top(r)[-20:]))
    check("`rook ls` lists the spaces, not home", r.rook("ls").split() == ["main"], r.rook("ls"))

    # ---- 02: home and back, one key
    r.keys("`o")
    r.snap("02-toggle-space")
    check("the home key from home goes back to the space", r.state()["scope"] == "space" and r.current()["name"] == "main", r.current())
    check("in a space the corner offers home", top(r).rstrip().endswith("`o home"), repr(top(r)[-20:]))
    space_ground = (r.screen.buffer[0][30].bg, r.screen.buffer[r.rows - 1][60].bg)
    check("home's bars stand on a ground of their own", home_ground[0] != space_ground[0] and home_ground[1] != space_ground[1], (home_ground, space_ground))
    check("and a space's calm bar does not say home", "home" not in r.lines()[-1], repr(r.lines()[-1][:30]))
    r.keys("`o")
    check("and again is home, the same home", r.state()["scope"] == "home" and r.panes_of(r.home_ws()) == [pid], r.panes_of(r.home_ws()))
    r.rook("new", "-q", "api")
    r.rook("switch", "api")
    r.settle(0.4)
    r.keys("`o")
    r.keys("`o")
    check("home goes back to the space it was left from", r.current()["name"] == "api", r.current()["name"])
    r.keys("\x60\x0f")
    check("C-o is the space before, never home", r.current()["name"] == "main" and r.state()["scope"] == "space", r.current()["name"])

    # ---- 03: its last pane closed: back, and home starts over
    r.keys("`o")
    r.keys("exit\r", settle=1.0)
    r.snap("03-return")
    check("closing home's last pane goes back to the space you came from", r.state()["scope"] == "space" and r.current()["name"] == "main", (r.state()["scope"], r.current()["name"]))
    check("and home is gone until it is gone to", r.home_ws() is None, r.home_ws())
    r.keys("`o")
    h2 = r.home_ws()
    check("gone to again, it is seeded fresh", h2 is not None and r.panes_of(h2) != [pid] and len(r.panes_of(h2)) == 1, h2 and r.panes_of(h2))
finally:
    r.close()

# ---- 04: on_empty = "stay"
r = Rook(tag="stay", conf='[home]\non_empty = "stay"\n')
try:
    first = r.panes_of(r.home_ws())
    r.keys("exit\r", settle=1.0)
    r.snap("04-stay")
    h = r.home_ws()
    check("on_empty = stay: closing its last pane starts home over in place", r.state()["scope"] == "home" and h and r.panes_of(h) != first, (r.state()["scope"], h and r.panes_of(h)))
finally:
    r.close()

# ---- 05: seeded windows, panes, commands and dirs
SEED = '''[home]
dir = "work"
[[home.window]]
name = "me"
panes = ["echo SEEDED-ONE", ""]
[[home.window]]
name = "notes"
dir = "~/notes"
[[home.window.pane]]
command = "echo SEEDED-NOTES"
[[home.window.pane]]
dir = "notes/archive"
split = "down"
'''
r = Rook(tag="seed", conf=SEED, dirs=("work", "notes", "notes/archive"))
try:
    r.settle(2.0)
    r.snap("05-seeded-me")
    h = r.home_ws()
    names = [w["name"] for w in h["windows"]]
    check("windows are the config's, named", names == ["me", "notes"], names)
    me_panes = r.panes_of({"windows": [h["windows"][0]]})
    check("the first window has its two panes, side by side", len(me_panes) == 2 and h["windows"][0]["layout"].get("split") == "v", h["windows"][0]["layout"])
    cwds = [r.pane(p)["cwd"] for p in me_panes]
    check("its panes start in home's dir", all(real(c) == real(r.root + "/work") for c in cwds), cwds)
    text = "\n".join(r.lines())
    check("a pane's command is typed into its shell", "SEEDED-ONE" in text, text[:200])
    check("home opens on its first window", h["windows"][0]["current"], [w["current"] for w in h["windows"]])
    r.keys("`2", settle=0.8)
    r.snap("05-seeded-notes")
    notes = r.panes_of({"windows": [h["windows"][1]]})
    ncwd = [real(r.pane(p)["cwd"]) for p in notes]
    check("the window's dir, and a pane's own over it", ncwd == [real(r.root + "/notes"), real(r.root + "/notes/archive")], ncwd)
    check("split = down stacks it under", h["windows"][1]["layout"].get("split") == "h", h["windows"][1]["layout"])
    check("the second window's command ran too", "SEEDED-NOTES" in "\n".join(r.lines()))
    # `echo` has long finished: run under `sh -c` its pane would be
    # gone; typed into a shell, the shell is still there
    check("a seeded command that has finished leaves its shell: the pane stays", len(r.panes_of({"windows": [r.home_ws()["windows"][1]]})) == 2, r.home_ws()["windows"][1]["layout"])
finally:
    r.close()

# ---- 06: home alone
r = Rook(tag="alone")
try:
    r.rook("close", "main")
    r.settle(0.6)
    check("with main closed, only home is left", [w["name"] for w in r.state()["workspaces"]] == ["home"], r.state()["workspaces"])
    r.keys("exit\r", settle=1.2)
    r.snap("06-alone")
    alive = r.rook("ls") is not None and r.home_ws() is not None
    check("closing it with nowhere to go starts it over, and rook does not end", alive and r.state()["scope"] == "home", r.rook("ls"))
finally:
    r.close()

# ---- 07: startup = "last-space"
r = Rook(tag="last", conf='[mux]\nstartup = "last-space"\n')
try:
    r.snap("07-last-space")
    check("startup = last-space lands in the space", r.state()["scope"] == "space" and r.current()["name"] == "main", r.state()["scope"])
    check("and home is not made until it is gone to", r.home_ws() is None)
finally:
    r.close()

# ---- 08: restore never saves home
r = Rook(tag="restore")
try:
    r.rook("new", "-q", "api")
    r.settle(2.2)  # a structural change saves after 1s
    saved = open(r.sock + ".state").read() if os.path.exists(r.sock + ".state") else ""
    sessions = [l for l in saved.splitlines() if l.startswith("session ")]
    check("the saved state has the spaces and not home", sessions and not any(l.split()[1] == "home" for l in sessions), sessions)
    check("the space home goes back to wears the star", any(l == "session main *" for l in sessions), sessions)
finally:
    r.close()

# ---- 10: the config is the front door's, and it reloads
r = Rook(tag="reload")
try:
    r.keys("`o")  # into main
    mode = lambda: r.state()["focus"]["mode"]
    r.keys("`e", settle=0.5)
    check("before: e is unbound", mode() == "pane", mode())
    r.write_conf('[keys]\ne = "popup 40x40 cat"\n[home]\ncolor = "#00ff00"\n')
    code, out = r.front("reload")
    check("rook reload hands the running engine the new file", code == 0 and "reloaded" in out, out)
    r.keys("`e", settle=0.8)
    check("after: the new row is live, no restart", mode() == "popup", mode())
    r.keys("\x04", settle=0.8)
    r.keys("`o", settle=0.6)
    r.snap("10-reload-home")
    check("home wears the colour the reload gave it", r.screen.buffer[0][1].bg == "00ff00", r.screen.buffer[0][1].bg)
    r.write_conf('[keys]\ne = "popop cat"\n')
    code, out = r.front("reload")
    check("a file that does not load is refused, and says why", code != 0 and "popop" in out, out)
    r.keys("`o", settle=0.5)
    r.keys("`e", settle=0.8)
    check("and the config that was running stays", mode() == "popup", mode())
    r.keys("\x04", settle=0.8)
    code, out = r.front("config", "check")
    check("rook config check says the same, without a server", code != 0 and "popop" in out, out)
finally:
    r.close()

# ---- 11: no front door: the defaults, and the calm bar says so
r = Rook(tag="nofront", conf='[keys]\ne = "popup 40x40 cat"\n', front="/nonexistent/rook")
try:
    r.snap("11-no-front-door")
    check("with no rook to compile the file, the engine boots on its defaults", r.state()["scope"] == "home")
    check("and the calm bar says why", "config:" in r.lines()[-1], repr(r.lines()[-1][:60]))
finally:
    r.close()

# ---- 12: the stylesheet: rook's rules, then [style], then matches
STYLE = """[style]
fill = "╌"
[[style.match]]
repo = "github.com/acme/*"
bar = "#302030"
chip = "bracket"
label = "{REPO}:{branch}"
[[style.match]]
home = true
label = "{icon} HOME"
"""
r = Rook(tag="style", conf=STYLE, dirs=("app/.git", "app/src"), cols=100, rows=16)
try:
    with open(r.root + "/app/.git/HEAD", "w") as f:
        f.write("ref: refs/heads/trunk\n")
    with open(r.root + "/app/.git/config", "w") as f:
        f.write('[remote "origin"]\n\turl = git@github.com:acme/app.git\n')
    check("home keeps rook's own look, under a file rule's label", top(r).strip().startswith("⌂ HOME"), repr(top(r)[:20]))
    r.rook("new", "-q", "app", r.root + "/app/src")
    r.rook("switch", "app")
    r.settle(1.0)
    r.snap("12-style-repo")
    t0 = top(r)
    check("a repo rule's label, over the facts: {REPO}:{branch}", t0.strip().startswith("[ APP:trunk ]"), repr(t0[:24]))
    check("its bar colour is the bar's ground", r.screen.buffer[0][40].bg == "302030", r.screen.buffer[0][40].bg)
    check("[style] fill draws the bar's empty cells", "╌" in t0, repr(t0))
    code, out = r.front("style", "--json")
    ex = json.loads(out) if code == 0 else {}
    facts = ex.get("facts", {})
    check("rook style sees the repo and branch from .git, no git process", facts.get("repo") == "github.com/acme/app" and facts.get("branch") == "trunk", facts)
    matched = [(x["source"], x["index"], x["matched"]) for x in ex.get("rules", [])]
    check("and says which rules held", matched == [("rook", 0, False), ("config", 0, True), ("config", 1, False)], matched)
    check("and where each property came from", ex.get("from", {}).get("bar") == "config:0" and ex.get("from", {}).get("fill") == "style", ex.get("from"))
    code, out = r.front("style")
    check("the human form lists the rules with their conditions", "✓ config:0   repo = \"github.com/acme/*\"" in out, out)
    r.rook("switch", "main")
    r.settle(0.8)
    t1 = top(r)
    check("a space no rule matches keeps rook's own chip", t1.strip().startswith("main "), repr(t1[:12]))
    check("…and the ground", r.screen.buffer[0][40].bg != "302030")
finally:
    r.close()

# ---- 09: the prefix table is the config's
r = Rook(tag="keys", conf='[keys]\ne = "popup 50x50 cat"\n"=" = "split-right"\nx = ""\n')
try:
    r.keys("`o")  # into main
    mode = lambda: r.state()["focus"]["mode"]
    count = lambda: len(r.state()["panes"])
    r.keys("`g", settle=0.5)
    r.keys("`w", settle=0.5)
    check("unbound by the config, prefix-g and prefix-w float nothing: rook binds no program", mode() == "pane", mode())
    r.keys("`e", settle=0.8)
    r.snap("09-keys-popup")
    check("a [keys] popup row floats its program", mode() == "popup", mode())
    r.keys("`x", settle=0.6)
    check("x unbound, prefix-x does not reach past the popup", mode() == "popup", mode())
    r.keys("\x04", settle=0.8)
    check("and the popup goes when its program does", mode() == "pane", mode())
    n = count()
    r.keys("`=", settle=0.6)
    check("a key the defaults leave alone, bound to a split, splits", count() == n + 1, (n, count()))
    r.keys("`x", settle=0.6)
    check('a default unbound with "" does nothing', count() == n + 1, (n, count()))
finally:
    r.close()

print("frames in", OUT)
if fails:
    print("FAILED:", ", ".join(fails))
    sys.exit(1)
print("all good")
