#!/usr/bin/env python3
"""The altitude fixture: a deterministic rook, looked at.

A sandboxed engine — its own socket, HOME, config and state, never the
live one — is driven through the front door into a representative
state, then read back through a real glass (a pty, decoded with pyte)
in the frames the design is judged on:

    make -C mux build && python3 scripts/altitude-fixture.py [outdir]

The state it builds (docs/altitude.md, "the fixture"):

  rook   a space literally named rook, one tab `shell`, quiet, no history
  vera   tabs deploy · main ◐ (main claims a pane running claude, which
         keeps producing, so it is working),
         logs; a producer says the agent there is waiting on you
  api    tabs tests · codex ◐ (codex claims a pane running codex, working),
         server; an unread bell in server
  infra  one tab, quiet
  ⊕g     a global pin promoted out of api, `tail -f`

Frames captured (text, and PNGs when pillow is installed):

  01-space        ordinary work in vera, full width, no sidebar
  02-altitude     altitude with the representative state
  03-altitude-one altitude over one quiet space (a second engine)
  04-narrow       58 columns: the ledger
  05-find         the input with results
  06-return       back in vera, the exact pane and layout

The frames are asserted on, so this doubles as the rendering test:
no sidebar columns, full-width bars, the badge only at altitude, a
space named rook distinct from the scope, no PTY resized by altitude,
and an exact return. Exit status 1 when an assertion fails. Nothing
here touches a running rook: the socket is /tmp/rk-fixture-<pid>.sock.
Needs `pip install pyte` (and `pillow` for the PNGs).
"""
import fcntl, json, os, pty, select, shutil, signal, struct, subprocess, sys, tempfile, termios, time

try:
    import pyte
except ImportError:
    sys.stderr.write("altitude-fixture: needs pyte (pip install pyte)\n")
    sys.exit(2)
try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    Image = None

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENGINE = os.path.join(REPO, "mux", "zig-out", "bin", "engine")
OUT = sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="/tmp/rook-altitude-")
os.makedirs(OUT, exist_ok=True)

CONFIG = '''
[tmux]
prefix = "`"
[mux]
agents = ["claude", "codex"]
%s
[companion]
program = "vera"
'''

fails = []


def check(name, ok, extra=""):
    print(("PASS  " if ok else "FAIL  ") + name + ("  " + extra if extra else ""))
    if not ok:
        fails.append(name)


class Rook:
    """A sandboxed engine behind a pyte glass."""

    def __init__(self, cols=120, rows=32, extra_conf="", tag="fixture"):
        self.root = tempfile.mkdtemp(prefix="/tmp/rk-%s-" % tag)
        self.cols, self.rows = cols, rows
        os.makedirs(self.root + "/.config/rook")
        with open(self.root + "/.config/rook/rook.toml", "w") as f:
            f.write(CONFIG % extra_conf)
        os.makedirs(self.root + "/bin")
        # real processes with the names the fixture needs: an agent
        # is a program by name, so a shell under another name is one —
        # and one that keeps talking is one that is working
        for name in ("claude", "codex"):
            shutil.copy("/bin/bash", self.root + "/bin/" + name)  # /bin/sh re-execs bash and loses the name
        shutil.copy("/bin/sleep", self.root + "/bin/vera")
        self.env = dict(os.environ)
        for k in ("ROOK_MUX_PANE", "TMUX", "TMUX_PANE", "ROOK_MUX_SOCK"):
            self.env.pop(k, None)
        self.sock = "/tmp/rk-%s-%d.sock" % (tag, os.getpid())
        self.env.update({
            "ROOK_MUX_SOCK": self.sock, "SHELL": "/bin/sh", "HOME": self.root,
            "XDG_STATE_HOME": self.root + "/state", "XDG_CONFIG_HOME": self.root + "/.config",
            "TERM": "xterm-256color", "PS1": "$ ", "ENV": self.root + "/.shrc",
            "PATH": self.root + "/bin:" + os.environ.get("PATH", ""),
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
            os.execve(ENGINE, [ENGINE], self.env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.settle(0.6)

    def pump(self, timeout=0.05):
        got = False
        while True:
            r, _, _ = select.select([self.fd], [], [], timeout)
            if not r:
                return got
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                return got
            if not data:
                return got
            self.stream.feed(data)
            got = True
            timeout = 0.02

    def settle(self, secs=0.35):
        end = time.time() + secs
        while time.time() < end:
            self.pump(0.05)

    def keys(self, s, settle=0.25):
        os.write(self.fd, s.encode() if isinstance(s, str) else s)
        self.settle(settle)

    def rook(self, *args, stdin=None):
        p = subprocess.run([ENGINE] + list(args), env=self.env, cwd=self.root, input=stdin,
                           capture_output=True, text=True, timeout=10)
        return (p.stdout + p.stderr).strip()

    def state(self):
        return json.loads(self.rook("state"))

    def pane_running(self, program):
        for p in self.state()["panes"]:
            if p["program"] == program:
                return p["id"]
        return None

    def text(self):
        return "\n".join(line.rstrip() for line in self.screen.display)

    def lines(self):
        return self.text().split("\n")

    def png(self, path):
        if Image is None:
            return None
        cw, ch = 8, 16
        img = Image.new("RGB", (self.cols * cw, self.rows * ch), (30, 30, 46))
        d = ImageDraw.Draw(img)
        try:
            font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 13)
        except Exception:
            font = ImageFont.load_default()

        def color(c, default):
            if c == "default":
                return default
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
        img.save(path)
        return path

    def snap(self, name):
        with open(os.path.join(OUT, name + ".txt"), "w") as f:
            f.write(self.text() + "\n")
        self.png(os.path.join(OUT, name + ".png"))

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


def build_fixture(r):
    """Drive the sandbox into the representative state, through the
    same verbs a producer or an agent would use."""
    # the default space is `main`; the fixture wants its four by name
    for ws in ("rook", "vera", "api", "infra"):
        r.rook("new", "-q", ws)
    r.rook("close", "main")
    r.settle(0.5)
    st = r.state()
    first_pane = {w["name"]: w["windows"][0]["focus"] for w in st["workspaces"]}

    # vera: tab deploy (claude, claimed by main), tab logs
    r.rook("run", str(first_pane["vera"]), "exec claude -c 'while :; do echo \"› Reading migrations/0042_session_audit.sql\"; sleep 1; done'")
    r.settle(2.5)
    r.rook("switch", "vera"); r.settle(0.3)
    r.rook("rename", "deploy")
    claude = r.pane_running("claude")
    r.rook("own", str(claude), "main")
    logs = json.loads(r.rook("window", str(claude)))["pane"]
    r.settle(0.3)
    r.rook("switch", "vera"); r.settle(0.2)
    r.keys("`2", settle=0.3); r.rook("rename", "logs"); r.keys("`1", settle=0.3)
    r.rook("run", str(logs), "echo 14:20:11 GET /health 200")
    # the companion, open in a tab of her own space
    chat = json.loads(r.rook("window", str(claude)))["pane"]
    r.settle(0.3)
    r.keys("`3", settle=0.3); r.rook("rename", "chat"); r.keys("`1", settle=0.2)
    r.rook("run", str(chat), "exec vera 600")
    r.settle(2.5)

    # api: tab tests (codex, claimed by codex), tab server with a bell
    r.rook("run", str(first_pane["api"]), "exec codex -c 'while :; do echo \"✗ revoked session rejected — flaky\"; sleep 1; done'")
    r.settle(2.5)
    r.rook("switch", "api"); r.settle(0.3)
    r.rook("rename", "tests")
    codex = r.pane_running("codex")
    r.rook("own", str(codex), "codex")
    server = json.loads(r.rook("window", str(codex)))["pane"]
    r.settle(0.3)
    r.keys("`2", settle=0.3); r.rook("rename", "server")
    # a global pin, promoted out of api: split, pin, make global
    r.keys("`v", settle=0.3)
    r.keys("tail -f /dev/null\r", settle=0.8)
    r.keys("`P", settle=0.3); r.keys("`G", settle=0.3)
    r.keys("`l", settle=0.2)
    r.keys("`1", settle=0.3)
    # back to vera, then a bell rings in api's server tab: unread
    r.rook("switch", "vera"); r.settle(0.4)
    r.rook("send", str(server), "printf '\\a'\r")
    r.settle(0.8)
    # a producer says vera's agent needs you (the rail's own wire)
    frame = json.dumps({"v": 1, "op": "items.push", "params": {"surface": "agents", "items": [
        {"id": "t1", "title": "Deploy plan", "subtitle": "3 approvals", "state": "waiting", "workspace": "vera"},
        {"id": "t2", "title": "Fix flaky auth", "subtitle": "attempt 2", "state": "working", "workspace": "api"},
    ]}})
    r.rook("side", "-", stdin=frame + "\n")
    r.settle(0.5)
    return st


def chip_is_block(r, top):
    """The scope chip's cells carry the accent background at altitude;
    a space's name in the same slot carries the bar's."""
    x = top.index("rook") if "rook" in top else -1
    if x < 0:
        return False
    cell = r.screen.buffer[0][x]
    return cell.bg not in ("default", "1e1e2e")


def body_of(lines):
    return "\n".join(lines)


def no_sidebar(lines):
    """No column of the frame is the rail: the first row starts with
    the scope slot, and no row has the panel's seam at column 30."""
    return not any(len(l) > 30 and l[30] == "│" for l in lines[1:-1])


def main():
    if not os.path.exists(ENGINE):
        sys.stderr.write("altitude-fixture: build the engine first (make -C mux build)\n")
        sys.exit(2)
    r = Rook(cols=120, rows=32)
    try:
        build_fixture(r)
        st = r.state()
        r.settle(0.3)

        # 01: ordinary work in vera
        r.snap("01-space")
        top, bar = r.lines()[0], r.lines()[-1]
        slot = top.split("┃")[-1]  # past the global pin dock
        check("in a space the scope slot is the space's name", slot.startswith(" vera "), repr(slot[:40]))
        vx = top.index("vera")
        check("a space's name is not a block", r.screen.buffer[0][vx].bg in ("default", "1e1e2e"), r.screen.buffer[0][vx].bg)
        check("no sidebar in a space", no_sidebar(r.lines()))
        check("the tab bar is full width", len(top.rstrip()) > 100, str(len(top)))
        check("the tab reads name · actor, never the tool", "deploy · main" in top and "claude" not in top, repr(top[:60]))
        check("the calm bar names actor ▸ tool", "main ▸ claude" in bar and "owns input" in bar, repr(bar[:70]))
        check("the bar's right edge counts unread and pins", "● 1" in bar and "⊕g 1" in bar, repr(bar[-30:]))
        vera_pane = [p for p in st["panes"] if p["id"] == st["focus"]["pane"]][0]
        sizes_before = {p["id"]: (p["cols"], p["rows"]) for p in st["panes"]}
        dock = len(top.split("┃")[0]) + 1 if "┃" in top else 0
        check("the work has every column the dock left", vera_pane["cols"] == 120 - dock, "%d of %d" % (vera_pane["cols"], 120 - dock))

        # 02: altitude
        r.keys("`o", settle=0.8)
        r.snap("02-altitude")
        lines = r.lines()
        slot = lines[0].split("┃")[-1]
        check("at altitude the scope slot is the system's chip", slot.startswith(" rook  "), repr(slot[:40]))
        check("the chip is the accent block, which a space's name never is", chip_is_block(r, lines[0]), "")
        check("the world is summarised where the tabs were", "4 spaces · 2 agents working · 2 need you" in slot, repr(slot[:60]))
        check("the corner says where back is", "esc ↩ vera" in slot, repr(slot[-20:]))
        check("the spaces are figures, and the bar agrees", "┌┤" in body_of(lines) and "orbit" in lines[-1], repr(lines[-1][:30]))
        check("no sidebar at altitude", no_sidebar(lines))
        body = "\n".join(lines)
        check("the space named rook is listed as a space, plain", any(l.strip().startswith("rook ") for l in lines[1:]), "")
        check("every space is on the canvas", all(n in body for n in ("vera", "api", "infra", "rook")))
        check("the producer's ask is an attention row", "Deploy plan" in body and "needs you" in body)
        check("the unread bell is an attention row", "rang the bell" in body)
        check("actors are named on the tabs, tools are not", "deploy · main" in body and "tests · codex" in body)
        check("the global pin says where it came from", "⊕g" in body and "from api" in body)
        check("the quiet space says so", "infra" in body and "quiet" in body)
        check("the input is a band with the prompt", any("›" in l for l in lines[1:4]))
        st_alt = r.state()
        check("focus.mode is altitude", st_alt["focus"]["mode"] == "altitude")
        sizes_alt = {p["id"]: (p["cols"], p["rows"]) for p in st_alt["panes"]}
        check("altitude resized no pane", sizes_alt == sizes_before)
        check("the bar persists at the same row", lines[-1].startswith(" rook · orbit"), repr(lines[-1][:30]))

        # 05: find
        r.keys("serv", settle=0.4)
        r.snap("05-find")
        body = "\n".join(r.lines())
        check("typing finds the tab by name", "api › server" in body)
        check("the companion row closes the results", "✦" in body and "vera:" in body)
        r.keys("\x1b", settle=0.3)
        check("esc clears the query and stays at altitude", r.state()["focus"]["mode"] == "altitude" and "serv" not in "\n".join(r.lines()[1:3]))

        # 06: exact return
        r.keys("\x1b", settle=0.5)
        r.snap("06-return")
        st_back = r.state()
        check("esc returns to the same pane", st_back["focus"] == st["focus"], str(st_back["focus"]))
        layouts = lambda s: [w["layout"] for ws in s["workspaces"] for w in ws["windows"]]
        check("the layout is untouched", layouts(st_back) == layouts(st))
        check("the frame is the one you left", r.lines()[0] == "\n".join(open(os.path.join(OUT, "01-space.txt")).read().split("\n")[:1]))

        # 04: narrow — a second glass on the same engine would share
        # geometry; resize this one instead
        fcntl.ioctl(r.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 58, 0, 0))
        os.kill(r.pid, signal.SIGWINCH)
        r.screen.resize(24, 58); r.cols, r.rows = 58, 24
        r.settle(0.8)
        r.keys("`o", settle=0.8)
        r.snap("04-narrow")
        body = "\n".join(r.lines())
        check("narrow glass draws the ledger", "ledger" in r.lines()[-1] and "┌" not in body, repr(r.lines()[-1]))
        check("the ledger still lists every space", all(n in body for n in ("vera", "api", "infra", "rook")))
        r.keys("\x1b", settle=0.3)
    finally:
        r.close()

    # 03: one quiet space, nothing else
    r2 = Rook(cols=100, rows=28, tag="one")
    try:
        r2.keys("`o", settle=0.8)
        r2.snap("03-altitude-one")
        body = "\n".join(r2.lines())
        check("one quiet space: the chip, the summary, the space, nothing invented", "1 space · all quiet" in body and "main" in body and "quiet" in body and "┌" not in body)
        check("the empty state says what there is to do", ":new" in body)
        r2.keys("\x1b", settle=0.3)
    finally:
        r2.close()

    print("frames in", OUT)
    if fails:
        print("FAILED:", ", ".join(fails))
        sys.exit(1)
    print("all good")


if __name__ == "__main__":
    main()
