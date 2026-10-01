#!/usr/bin/env python3
"""`rook shot`, end to end: a sandboxed engine and no terminal at all.

    make -C mux build && python3 scripts/shot-fixture.py [outdir]

What is on the glass, as a grid (docs/shot.md). The server here has no
glass attached for most of this — that is the point: a test, or an
agent, sets the size and reads what rook would show.

  01-headless   --size sets the glass; the shot is chrome and panes
  02-forms      text, --ansi and --json agree; runs carry the colours
  03-layout     a split, a second window, a styled tab: the shot moves
                with the state, and says the fill a rule gave a tab
  04-pane       a pane by id is its own grid — a hidden one, and one in
                the background
  05-png        --png writes a picture the size of the grid
  06-attached   with a glass attached the shot is that glass's, cell
                for cell what a terminal decoding the frames shows
                (needs pyte; skipped without), and --size is refused

Stdlib only, but for 06. Exit status 1 when an assertion fails.
"""
import fcntl, json, os, pty, select, signal, struct, subprocess, sys, tempfile, termios, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENGINE = os.path.join(REPO, "mux", "zig-out", "bin", "engine")
OUT = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="/tmp/rook-shot-")
os.makedirs(OUT, exist_ok=True)
FRONT = os.path.join(tempfile.mkdtemp(prefix="/tmp/rk-front-"), "rook")
subprocess.run(["go", "build", "-o", FRONT, "./cmd/rook"], cwd=REPO, check=True)

fails = []


def check(name, ok, extra=""):
    print(("PASS  " if ok else "FAIL  ") + name + ("  " + str(extra) if extra and not ok else ""))
    if not ok:
        fails.append(name)


CONF = '''[tmux]
prefix = "`"
[mux]
startup = "last-space"
[[style.tab]]
index = 2
color = "#44aff5"
'''


class Rook:
    """A sandboxed engine with no glass, until one is attached."""

    def __init__(self, tag="shot"):
        self.root = tempfile.mkdtemp(prefix="/tmp/rk-%s-" % tag)
        os.makedirs(self.root + "/.config/rook")
        with open(self.root + "/.config/rook/rook.toml", "w") as f:
            f.write(CONF)
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
        self.server = subprocess.Popen([ENGINE, "server"], env=self.env, cwd=self.root,
                                       stdout=subprocess.DEVNULL, stderr=open(self.root + "/server.log", "w"))
        for _ in range(150):
            if os.path.exists(self.sock):
                break
            time.sleep(0.02)
        self.fd = None

    def rook(self, *args):
        p = subprocess.run([FRONT] + list(args), env=self.env, cwd=self.root,
                           capture_output=True, text=True, timeout=30)
        return p.returncode, p.stdout, p.stderr.strip()

    def shot(self, *args):
        return self.rook("shot", *args)[1]

    def grid(self, *args):
        return json.loads(self.shot("--json", *args))

    def first_pane(self):
        return int(self.rook("blocks")[1].split("\t")[0])

    def attach(self, cols, rows):
        import pyte
        self.screen = pyte.Screen(cols, rows)
        self.stream = pyte.ByteStream(self.screen)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execve(ENGINE, [ENGINE], self.env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.settle(1.0)

    def settle(self, secs=0.4):
        end = time.time() + secs
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    self.stream.feed(os.read(self.fd, 65536))
                except OSError:
                    return

    def close(self):
        self.rook("kill")
        if self.fd is not None:
            try:
                os.kill(self.pid, signal.SIGKILL)
            except Exception:
                pass
        try:
            self.server.wait(timeout=5)
        except Exception:
            self.server.kill()


def runs_with(grid, y, text):
    return [r for r in grid["lines"][y]["runs"] if text in r["text"]]


r = Rook()
try:
    # ---- 01: headless
    code, out, err = r.rook("shot", "--size", "100x24")
    lines = out.split("\n")
    open(os.path.join(OUT, "01-headless.txt"), "w").write(out)
    check("--size sets the glass of a server nobody is attached to", code == 0 and len(lines) == 25 and lines[24] == "", (code, len(lines), err))
    check("the tab bar is in the shot", "main" in lines[0] and "1 " in lines[0], lines[0])
    check("the calm bar is in the shot", lines[23].startswith(" you"), lines[23])
    check("the pane's prompt is in the shot", lines[1].startswith("$"), lines[1])
    st = json.loads(r.rook("state")[1])
    check("the state feed has the same geometry", st["geometry"] == {"cols": 100, "rows": 24}, st["geometry"])
    pane = r.first_pane()
    p = next(x for x in st["panes"] if x["id"] == pane)
    check("the pane was laid out for that glass", p["cols"] == 100 and p["rows"] == 22, (p["cols"], p["rows"]))

    # ---- 02: the forms agree
    r.rook("run", str(pane), r'printf "\033[1;31mRED\033[0m and \033[48;2;10;20;30m TINT \033[0m\n"')
    time.sleep(0.5)
    text = r.shot()
    g = r.grid()
    ansi = r.shot("--ansi")
    open(os.path.join(OUT, "02-forms.json"), "w").write(json.dumps(g, indent=1))
    check("the grid is the size of the glass", g["cols"] == 100 and g["rows"] == 24 and len(g["lines"]) == 24, (g["cols"], g["rows"]))
    check("JSON lines are the text shot's lines", [l["text"] for l in g["lines"]] == text.split("\n")[:-1])
    y = next(i for i, l in enumerate(g["lines"]) if l["text"].startswith("RED and"))
    red = runs_with(g, y, "RED")
    tint = runs_with(g, y, "TINT")
    check("a run carries its colour and weight", red and red[0].get("bold") and red[0].get("fg", "").startswith("#") and red[0]["x"] == 0 and red[0]["w"] == 3, red)
    check("a background is on the run that has it", tint and tint[0].get("bg") == "#0a141e" and tint[0]["w"] == 6, tint)
    import re
    stripped = re.sub(r"\x1b\[[0-9;]*m", "", ansi)
    check("--ansi is the text with its SGR", [l.rstrip() for l in stripped.split("\n")] == [l.rstrip() for l in text.split("\n")] and "\x1b[0;1;38;2;" in ansi)
    cur = g["cursor"]
    check("the cursor is where the prompt is", cur and cur["visible"] and g["lines"][cur["y"]]["text"].startswith("$") and cur["x"] == 2, cur)

    # ---- 03: layout and style
    code, out, _ = r.rook("split", str(pane))
    right = json.loads(out)["pane"]
    time.sleep(0.4)
    g = r.grid()
    seam = [l for l in g["lines"][1:23] if any(run["text"] == "│" for run in l["runs"])]
    check("a split shows its seam down the window", len(seam) == 22, len(seam))
    code, out, _ = r.rook("window", str(pane), "--focus")
    time.sleep(0.4)
    g = r.grid()
    tab = runs_with(g, 0, "sh")
    two = [run for run in g["lines"][0]["runs"] if run.get("bg") == "#44aff5"]
    check("the second window is on the tab bar, and it is the one showing", len(tab) >= 2 and not any(run["text"] == "│" for l in g["lines"][1:23] for run in l["runs"]), g["lines"][0]["text"])
    check("the tab a rule coloured is filled in that colour", len(two) >= 1, g["lines"][0]["runs"])

    # ---- 04: a pane by id
    hidden = r.shot(str(pane))
    check("a pane in a window not showing is shot by id", "RED and  TINT" in hidden and len(hidden.split("\n")) == 23, hidden[:200])
    code, out, _ = r.rook("bg", "run", "-g", "svc", "--", "echo from the background; sleep 60")
    svc = json.loads(out)["pane"]
    time.sleep(0.5)
    pg = r.grid(str(svc))
    check("a pane in the background is shot by id", pg["lines"][0]["text"] == "from the background", pg["lines"][0])
    check("a pane that is not there is refused", r.rook("shot", "9999")[0] == 1)

    # ---- 04b: the things a reader needs to stay in step
    r.rook("switch", "main")
    r.rook("focus", str(pane))
    r.rook("run", str(pane), r"clear; printf 'a\xe6\x97\xa5b\xe2\x9c\x85c e\xcc\x81z\n'")
    g = r.grid(str(pane))
    line = next(l for l in g["lines"] if l["text"].startswith("a日b"))
    clusters = [run for run in line["runs"] if run.get("cluster")]
    check("a wide glyph is a run of its own, marked", [(c["text"], c["w"]) for c in clusters[:2]] == [("日", 2), ("✅", 2)], line["runs"])
    cols = 0
    ok = True
    for run in line["runs"]:
        ok = ok and run["x"] >= cols and (run.get("cluster") or len(run["text"]) == run["w"])
        cols = run["x"] + run["w"]
    check("runs are in order, and one character a cell outside a cluster", ok and line["runs"][-1]["text"] == "z" and line["runs"][-1]["x"] == 9, line["runs"])
    plain = next(l for l in r.grid(str(pane))["lines"] if l["text"].startswith("$"))
    check("a default-style run ends at its last glyph", plain["runs"][0]["text"] == "$" and plain["runs"][0]["w"] == 1, plain["runs"])
    gg = r.grid()
    me = next((p for p in gg.get("panes", []) if p["id"] == pane), None)
    check("the glass says where each pane is", me and me["y"] == 1 and me["h"] == 22 and me["focused"], gg.get("panes"))
    check("a filled row says its fill", "bg" in gg["lines"][23] and "bg" not in gg["lines"][5], (gg["lines"][23].get("bg"), gg["lines"][5].get("bg")))

    # a key, then a shot: the frame after the program answered it
    app = os.path.join(r.root, "app.py")
    open(app, "w").write("""import curses, time
def main(s):
    curses.curs_set(0); s.keypad(True); n = 0
    while True:
        s.erase(); s.addstr(0, 0, "count %d" % n); s.refresh()
        k = s.getch()
        if k == 27: break
        time.sleep(0.03)  # a program that takes a moment to answer
        if k == curses.KEY_DOWN: n += 1
        if k == curses.KEY_UP: n -= 1
curses.wrapper(main)
""")
    r.rook("run", str(pane), "python3 " + app)
    time.sleep(0.8)
    seen = []
    for i in range(1, 9):
        r.rook("key", str(pane), "down")
        seen.append(r.shot(str(pane)).split("\n")[0])
    check("named arrows reach a curses program as arrows, and each shot is the frame after its key", seen == ["count %d" % i for i in range(1, 9)], seen)
    # the glass is still when every pane on it is: a shell beside the
    # program, typed at after the key, is not the program's answer
    side = json.loads(r.rook("split", str(pane))[1])["pane"]
    time.sleep(0.6)
    stale = 0
    for i in range(9, 14):
        r.rook("key", str(pane), "down")
        r.rook("send", str(side), "x")
        first = next(l for l in r.shot().split("\n")[1:] if "count" in l)
        stale += ("count %d" % i) not in first
    check("a neighbour answering does not stand in for the program asked", stale == 0, stale)
    r.rook("close-pane", str(side))
    time.sleep(0.4)
    r.rook("key", str(pane), "esc")
    code, _, err = r.rook("shot", "--json", "--png", "/tmp/x.png")
    check("--png with another form is refused", code == 1 and "form of its own" in err, err)
    for bad in (["--settle", "abc"], ["--size", "banana"], ["--bogus"]):
        code, out, err = r.rook("shot", *bad)
        check("shot %s: one line, no error name" % " ".join(bad), code == 1 and err.startswith("rook shot:") and "error:" not in err and "BadArgs" not in err, err)
    check("shot --help is the usage, with --png", "--png" in r.rook("shot", "--help")[1])

    # ---- 04c: a busy screen is a large answer, and still an answer
    r.rook("shot", "--size", "200x60")
    busy = os.path.join(r.root, "busy.txt")
    with open(busy, "w") as f:
        for y in range(70):
            f.write("".join("\x1b[38;5;%d;48;5;%dm%c" % ((x + y) % 256, (x * 3 + y) % 256, 65 + (x + y) % 26) for x in range(198)) + "\x1b[0m\n")
    r.rook("run", str(pane), "clear; cat " + busy)
    time.sleep(0.5)
    code, out, err = r.rook("shot", "--json")
    check("a screen of one-cell runs comes back whole (%d bytes)" % len(out), code == 0 and len(out) > 300000 and json.loads(out)["cols"] == 200, (code, err, len(out)))
    code, out, err = r.rook("shot", "--png", os.path.join(OUT, "04c-busy.png"))
    check("and is drawn", code == 0, err)
    p = subprocess.Popen("%s shot --json | true" % FRONT, shell=True, env=r.env, cwd=r.root)
    p.wait(timeout=10)
    left, t0 = ["?"], time.time()
    while left and time.time() - t0 < 6:
        time.sleep(0.2)
        left = subprocess.run(["pgrep", "-f", "engine shot --json"], capture_output=True, text=True).stdout.split()
    took = time.time() - t0
    check("a shot whose reader went away ends, and soon (%.1fs)" % took, not left and took < 2.5, (left, took))
    r.rook("run", str(pane), r"clear; printf 'see \033[8mhidden\033[0m end\n'")
    g = r.grid(str(pane))
    hid = [run for l in g["lines"] for run in l["runs"] if run["text"] == "hidden"]
    check("concealed text is marked", hid and hid[0].get("invisible"), hid)
    r.rook("run", str(pane), r"clear; printf '\033[38;2;255;255;255mWHITE\033[0m \033[48;2;0;0;0mBLACK\033[0m\n'")
    for g in (r.grid(str(pane)), r.grid()):
        runs = [run for l in g["lines"] for run in l["runs"]]
        white = [run for run in runs if run["text"] == "WHITE"]
        black = [run for run in runs if run["text"] == "BLACK"]
        check("a colour a program named is in the shot, even one a terminal calls its own", white and white[0].get("fg") == "#ffffff" and black and black[0].get("bg") == "#000000", (white, black))
    r.rook("shot", "--size", "100x24")

    # ---- 05: the picture
    png = os.path.join(OUT, "05-glass.png")
    code, out, err = r.rook("shot", "--png", png)
    head = open(png, "rb").read(24) if code == 0 else b""
    w, h = struct.unpack(">II", head[16:24]) if len(head) == 24 else (0, 0)
    info = json.loads(out) if code == 0 else {}
    check("--png writes a picture of the grid", head[:8] == b"\x89PNG\r\n\x1a\n" and info.get("cols") == 100 and w == info.get("width") and w % 100 == 0 and h % 24 == 0 and h > 0, (code, err, w, h))
    check("a bad size is refused", r.rook("shot", "--size", "3x3")[0] == 1)
finally:
    r.close()

# ---- 06: an attached glass, against a terminal decoding the frames
try:
    import pyte  # noqa: F401
    have_pyte = True
except ImportError:
    have_pyte = False
    print("SKIP  06-attached (no pyte)")
if have_pyte:
    r = Rook(tag="glass")
    try:
        r.attach(96, 20)
        pane = r.first_pane()
        r.rook("run", str(pane), "ls -la /")
        r.rook("split", str(pane), "--down")
        r.rook("notify", "--mark", "ok", "said on the bar")
        r.settle(0.8)
        text = r.shot().split("\n")[:-1]
        r.settle(0.5)
        glass = [l.rstrip() for l in r.screen.display]
        diff = [(i, a, b) for i, (a, b) in enumerate(zip(text, glass)) if a != b]
        check("the shot is the attached glass, row for row", len(text) == 20 and not diff, diff[:3])
        g = r.grid()
        y = 19
        bar = g["lines"][y]["runs"]
        cell = r.screen.buffer[y][1]
        check("and its colours are the glass's", any(run.get("bg", "#")[1:] == cell.bg for run in bar), (bar[:2], cell.bg))
        code, _, err = r.rook("shot", "--size", "120x40")
        check("--size is refused while a glass is attached", code == 1 and "attached at 96x20" in err, err)
        check("the glass's own size is not", r.rook("shot", "--size", "96x20")[0] == 0)
        # a second workspace, and back: nothing of the first is left on
        # the glass where the second paints nothing
        r.rook("new", "two", r.root)
        r.settle(0.6)
        text = r.shot().split("\n")[:-1]
        r.settle(0.4)
        glass = [l.rstrip() for l in r.screen.display]
        diff = [(i, a, b) for i, (a, b) in enumerate(zip(text, glass)) if a != b]
        check("after a switch the glass and the shot still agree", not diff, diff[:3])
        # the glass goes away: the shot is laid out for what is left
        os.kill(r.pid, signal.SIGKILL)
        os.waitpid(r.pid, 0)
        r.fd = None
        time.sleep(0.5)
        r.rook("run", str(r.first_pane()), "echo still here")
        g = r.grid()
        st = json.loads(r.rook("state")[1])
        sizes = [(p["cols"], p["rows"]) for p in st["panes"] if p["visible"]]
        check("with the glass gone the panes are laid out for the size that is left", (g["cols"], g["rows"]) == (100, 24) or (g["cols"], g["rows"]) == (80, 24), (g["cols"], g["rows"]))
        check("and the shot shows them", all(c <= g["cols"] for c, _ in sizes) and any("still here" in l["text"] for l in g["lines"]) or any("$" in l["text"] for l in g["lines"][1:]), (sizes, [l["text"] for l in g["lines"][:4]]))
    finally:
        r.close()

print("\nframes in " + OUT)
print("%d failed" % len(fails) if fails else "all passed")
sys.exit(1 if fails else 0)
