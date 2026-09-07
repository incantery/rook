#!/usr/bin/env python3
"""The root fixture: a deterministic rook, looked at from home.

A sandboxed engine — its own socket, HOME, config, state and a fake
`vera` on PATH, never the live one — is driven through the front door
into a representative state, then read back through a real glass (a
pty, decoded with pyte) in the frames the design is judged on:

    make -C mux build && python3 scripts/altitude-fixture.py [outdir]

The state it builds (docs/altitude.md, "the fixture"):

  rook   a space literally named rook, one tab `shell`, quiet, no history
  vera   tabs deploy · main ◐ (main claims a pane running claude, which
         keeps producing, so it is working), logs, chat (the companion);
         a producer says the task there is waiting on you
  api    tabs tests · codex ◐ (codex claims a pane running codex, working),
         server; an unread bell in server; a producer says its task is
         working, and another finished
  infra  one tab, quiet
  ⊕g     a global pin promoted out of api, `tail -f`

Frames captured (text, and PNGs when pillow is installed):

  01-home           rook's home over the representative state
  02-ask            a request sent to vera, and her reflection: intent,
                    plan, space, proposed actions; then one confirmed
  03-ask-words      a request vera answers in words
  04-find           `/` with results
  05-command        `:` with completions
  06-drill          ↵ on a work item lands in its exact pane
  07-return         prefix-o from that space is home again; esc there stays
  08-orbit          prefix-s: orbit as a subview, esc back home
  09-space          inside a space: chip, tabs, the corner, the bar's counts
  10-narrow         58 columns: home, and orbit as the ledger
  11-wide           160 columns
  12-quiet          one space with history: the quiet home
  13-cold           a fresh rook with vera on PATH
  14-offline        a fresh rook without vera: the grammar still works
  15-start-dot      `rook .`: the space for the directory, entered
  16-start-last     `startup = "last-space"`: the space, not home
  17-space-rook     a space literally named rook, and home from it
  18-tabs           five tab states, and the ladder at 84 and 44 columns;
                    the bar's global attention while inside a space
  19-ascii          home and a space with `glyphs = "ascii"`
  20-inspector      the inspector and the gate over dense output
  21-split          a split: you drive the left pane, an agent works right

The frames are asserted on, so this doubles as the rendering test.
Exit status 1 when an assertion fails. Nothing here touches a running
rook: the socket is /tmp/rk-<tag>-<pid>.sock. Needs `pip install
pyte` (and `pillow` for the PNGs).
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

# The fake companion: `vera say -c rook <text>` answers — a reflection
# (ask.zig's shape) when the text mentions deploying, words otherwise —
# and anything else runs the bash copy named vera, so a pane can hold
# her. `vera say` is the one verb rook assumes of her.
FAKE_VERA = r'''#!/bin/sh
if [ "$1" = "say" ]; then
  shift
  while [ $# -gt 0 ]; do case "$1" in -c) shift 2;; *) break;; esac; done
  echo "· thinking" >&2
  case "$*" in
    *deploy*) printf '%s\n' '{"intent":"deploy the api from its current branch","plan":["run the tests in api","tag the release","roll it out to staging"],"space":"api","actions":[{"label":"start an agent on the deploy","run":"echo started deploy-agent in api"},{"label":"open the runbook","run":"echo runbook: docs/deploy.md"}]}' ;;
    *) printf 'Two things are running: the auth fix in api and the deploy plan in vera.\nThe deploy plan is waiting on you.\n' ;;
  esac
  exit 0
fi
exec "$ROOK_FIXTURE_LIB/vera" "$@"
'''

fails = []


def check(name, ok, extra=""):
    print(("PASS  " if ok else "FAIL  ") + name + ("  " + str(extra) if extra else ""))
    if not ok:
        fails.append(name)


class Rook:
    """A sandboxed engine behind a pyte glass."""

    def __init__(self, cols=120, rows=32, extra_conf="", tag="fixture", vera=True, attach=None):
        self.root = tempfile.mkdtemp(prefix="/tmp/rk-%s-" % tag)
        self.cols, self.rows = cols, rows
        os.makedirs(self.root + "/.config/rook")
        with open(self.root + "/.config/rook/rook.toml", "w") as f:
            f.write(CONFIG % extra_conf)
        os.makedirs(self.root + "/bin")
        os.makedirs(self.root + "/lib")
        # real processes with the names the fixture needs: an agent
        # is a program by name, so a shell under another name is one —
        # and one that keeps talking is one that is working
        for name in ("claude", "codex"):
            shutil.copy("/bin/bash", self.root + "/bin/" + name)  # /bin/sh re-execs bash and loses the name
        shutil.copy("/bin/bash", self.root + "/lib/vera")
        if vera:
            with open(self.root + "/bin/vera", "w") as f:
                f.write(FAKE_VERA)
            os.chmod(self.root + "/bin/vera", 0o755)
        self.env = dict(os.environ)
        for k in ("ROOK_MUX_PANE", "TMUX", "TMUX_PANE", "ROOK_MUX_SOCK"):
            self.env.pop(k, None)
        self.sock = "/tmp/rk-%s-%d.sock" % (tag, os.getpid())
        # a PATH of the sandbox's own, so the live vera is never found
        self.env.update({
            "ROOK_MUX_SOCK": self.sock, "SHELL": "/bin/sh", "HOME": self.root,
            "XDG_STATE_HOME": self.root + "/state", "XDG_CONFIG_HOME": self.root + "/.config",
            "TERM": "xterm-256color", "PS1": "$ ", "ENV": self.root + "/.shrc",
            "PATH": self.root + "/bin:/usr/bin:/bin", "ROOK_FIXTURE_LIB": self.root + "/lib",
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

    def resize(self, cols, rows):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        os.kill(self.pid, signal.SIGWINCH)
        self.screen.resize(rows, cols)
        self.cols, self.rows = cols, rows
        self.settle(0.8)

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

    def enter(self, space):
        """From home into a space, the way a hand does it: `:go`."""
        self.keys(":go " + space + "\r", settle=0.4)

    def home(self):
        self.keys("`o", settle=0.4)

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
                if cell.underscore:
                    d.line([x * cw, (y + 1) * ch - 2, (x + 1) * cw - 1, (y + 1) * ch - 2], fill=(203, 166, 247), width=1)
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
    same verbs a producer or an agent would use, entering a space from
    home when a key has to land in it."""
    for ws in ("rook", "vera", "api", "infra"):
        r.rook("new", "-q", ws)
    r.rook("close", "main")
    r.settle(0.5)
    st = r.state()
    first_pane = {w["name"]: w["windows"][0]["focus"] for w in st["workspaces"]}

    # vera: tab deploy (claude, claimed by main), tab logs, tab chat
    r.rook("run", str(first_pane["vera"]), "exec claude -c 'while :; do echo \"› Reading migrations/0042_session_audit.sql\"; sleep 1; done'")
    r.settle(2.5)
    r.enter("vera")
    r.rook("rename", "deploy")
    claude = r.pane_running("claude")
    r.rook("own", str(claude), "main")
    logs = json.loads(r.rook("window", str(claude)))["pane"]
    r.settle(0.3)
    r.keys("`2", settle=0.3); r.rook("rename", "logs"); r.keys("`1", settle=0.3)
    r.rook("run", str(logs), "echo 14:20:11 GET /health 200")
    chat = json.loads(r.rook("window", str(claude)))["pane"]
    r.settle(0.3)
    r.keys("`3", settle=0.3); r.rook("rename", "chat"); r.keys("`1", settle=0.2)
    r.rook("run", str(chat), "exec $ROOK_FIXTURE_LIB/vera -c 'sleep 600; :'")
    r.settle(2.0)
    r.home()

    # api: tab tests (codex, claimed by codex), tab server with a bell
    r.rook("run", str(first_pane["api"]), "exec codex -c 'while :; do echo \"✗ revoked session rejected — flaky\"; sleep 1; done'")
    r.settle(2.5)
    r.enter("api")
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
    r.home()
    # a bell rings in api's server tab while nobody looks: unread
    r.rook("send", str(server), "printf '\\a'\r")
    r.settle(0.8)
    # a producer says what the work is: the rail's own wire, with the
    # fields a work item may carry
    frame = json.dumps({"v": 1, "op": "items.push", "params": {"surface": "agents", "items": [
        {"id": "t1", "title": "Deploy plan", "subtitle": "3 approvals", "state": "waiting", "workspace": "vera", "actor": "main", "event": "asked which region first"},
        {"id": "t2", "title": "Fix flaky auth", "subtitle": "attempt 2", "state": "working", "workspace": "api", "actor": "codex", "event": "re-running the revoked-session test"},
        {"id": "t3", "title": "Rotate the signing key", "state": "done", "workspace": "api", "result": "PR #212 merged"},
    ]}})
    r.rook("side", "-", stdin=frame + "\n")
    r.settle(0.6)
    return {"claude": claude, "codex": codex, "server": server, "logs": logs, "chat": chat}


ACCENT, RAISED, CHROME = "cba6f7", "313244", "181825"


def chip_bg(r, top, word, row=0):
    x = top.index(word) if word in top else -1
    if x < 0:
        return None
    return r.screen.buffer[row][x].bg


def selected_tab_cells(r, top, label):
    """The cells of a tab, index through mark, as pyte holds them."""
    x = top.index(label)
    return [r.screen.buffer[0][i] for i in range(x - 3, x + len(label) + 3)]


def no_sidebar(lines):
    return not any(len(l) > 30 and l[30] == "│" for l in lines[1:-1])


def slot_of(top):
    return top.split("┃")[-1]  # past the global pin dock


HEADERS = ("needs you", "running", "recent", "spaces", "pinned everywhere", "proposed")


def section(lines, name):
    """The rows under a home section header, up to the next header,
    past the global pin dock when one is on the glass."""
    out, on = [], False
    for l in lines[1:-1]:
        l = slot_of(l)
        s = l.strip()
        is_header = l.startswith("  ") and not l.startswith("   ") and any(s.startswith(h) for h in HEADERS)
        if on and is_header:
            break
        if is_header and s.startswith(name):
            on = True
            continue
        if on and s:
            out.append(s)
    return out


def main():
    if not os.path.exists(ENGINE):
        sys.stderr.write("altitude-fixture: build the engine first (make -C mux build)\n")
        sys.exit(2)

    # ---- the representative state, from home
    # 140 columns: the global pin dock keeps its 40% at home (it never
    # resizes), and the rows should still read whole beside it
    r = Rook(cols=140, rows=32)
    try:
        ids = build_fixture(r)
        st = r.state()
        sizes_before = {p["id"]: (p["cols"], p["rows"]) for p in st["panes"]}
        r.settle(0.3)

        # 01: home
        r.snap("01-home")
        lines = r.lines()
        top, bar = lines[0], lines[-1]
        slot = slot_of(top)
        body = "\n".join(lines)
        check("plain rook lands at home: scope root, view home", st["scope"] == "root" and st["root"]["view"] == "home" and st["focus"]["mode"] == "root", str(st.get("root")))
        check("the scope slot is the system's chip, then the separator", slot.startswith("  rook  │ "), repr(slot[:40]))
        check("the system's chip is the accent fill", chip_bg(r, top, "rook") == ACCENT, chip_bg(r, top, "rook"))
        check("the world is summarised where the tabs were", "4 spaces · 2 agents working · 2 need you" in slot, repr(slot[:60]))
        check("home has no corner: nothing is above it", "esc" not in top and "↩" not in top, repr(top[-30:]))
        check("no sidebar at home", no_sidebar(lines))
        check("the input says the grammar", "› Ask vera…    / find    : command" in body)
        needs = section(lines, "needs you")
        check("needs you comes first, with the bell and the producer's ask", any("api › server" in l and "rang the bell" in l for l in needs) and any("Deploy plan" in l and "needs you · asked which region first" in l for l in needs), needs)
        running = section(lines, "running")
        check("running work is the producer's task, by goal, with its space, actor and event",
              any("Fix flaky auth" in l and "working · api · codex · re-running" in l for l in running), running)
        check("an agent a producer claims is not listed twice", not any("claude in vera" in l or "codex in api" in l for l in running), running)
        recent = section(lines, "recent")
        check("recent work is the producer's finished task, with its result", any("Rotate the signing key" in l and "PR #212 merged" in l for l in recent), recent)
        spaces = section(lines, "spaces")
        check("every space is a row, the one named rook plain", len(spaces) == 4 and spaces[0].startswith("rook ") and not any("↵ back" in l for l in spaces), spaces)
        check("the space rows carry the tabs with actors and marks", any("deploy · main ◐" in l for l in spaces) and any("tests · codex ◐" in l for l in spaces), spaces)
        check("the global pin is listed with its origin", "pinned everywhere" in body and "from api" in body)
        check("nothing was resized to paint home", {p["id"]: (p["cols"], p["rows"]) for p in r.state()["panes"]} == sizes_before)
        check("the calm bar says rook · home, and counts the world", bar.startswith(" rook · home") and "◐ 2" in bar and "!2" in bar and "⊕g 1" in bar, repr(bar))
        r.keys("\x1b", settle=0.3)
        check("esc at home stays at home", r.state()["scope"] == "root")

        # 02: a request, and a reflection
        r.keys("deploy the api\r", settle=0.3)
        st2 = r.state()
        check("bare text goes to vera: the request is running", st2["root"]["ask"] in ("running", "replied"), st2["root"]["ask"])
        r.settle(1.2)
        r.snap("02-ask")
        lines = r.lines()
        body = "\n".join(lines)
        check("the request is quoted back, and the reflection shows intent, space and plan",
              '✦ "deploy the api"' in body and "deploy the api from its current branch" in body and "1. run the tests in api" in body and "3. roll it out to staging" in body)
        chip_rows = [i for i, l in enumerate(lines) if slot_of(l).strip().startswith("in ") and slot_of(l).strip().endswith("api")]
        chip_cell = r.screen.buffer[chip_rows[0]][lines[chip_rows[0]].rindex("api")] if chip_rows else None
        check("the space it is about wears the space chip", bool(chip_rows) and chip_cell.bg == RAISED, (chip_rows, chip_cell.bg if chip_cell else None))
        proposed = section(lines, "proposed")
        check("proposed actions are rows with the command they would run, unrun", any("start an agent on the deploy" in l and "$ echo started deploy-agent in api" in l for l in proposed), proposed)
        check("the bar says vera answered", "vera answered" in lines[-1], repr(lines[-1]))
        # the cursor is on the first action: ↵ confirms it, by hand
        r.keys("\r", settle=1.0)
        r.snap("02-ask-confirmed")
        proposed = section(r.lines(), "proposed")
        check("a confirmed action ran, and its receipt is on the row", any("start an agent on the deploy" in l and "ran (0) · started deploy-agent in api" in l for l in proposed), proposed)
        check("the other action is still a proposal", any("open the runbook" in l and "$ echo runbook" in l for l in proposed), proposed)
        r.keys("\x1b", settle=0.3)
        check("esc dismisses the receipt", "proposed" not in "\n".join(r.lines()) and r.state()["root"]["ask"] == "none")

        # 03: words
        r.keys("what is running\r", settle=1.5)
        r.snap("03-ask-words")
        body = "\n".join(r.lines())
        check("a reply in words is shown as words, under the request", '✦ "what is running"' in body and "Two things are running" in body and "waiting on you" in body)
        r.keys("\x1b", settle=0.3)

        # 04: find
        r.keys("/serv", settle=0.4)
        r.snap("04-find")
        lines = r.lines()
        body = "\n".join(lines)
        check("/ finds: the tab by name, and nothing else is a door", "api › server" in body and "✦" not in body, "")
        check("the bar says find", " rook · find" in lines[-1], repr(lines[-1][:30]))
        r.keys("\x1b", settle=0.3)
        check("esc clears the query and stays home", r.state()["scope"] == "root" and "serv" not in "\n".join(r.lines()[1:3]))

        # 05: command
        r.keys(":", settle=0.4)
        r.snap("05-command")
        body = "\n".join(r.lines())
        check(": completes every command, home and orbit among them", ":go " in body and ":home" in body and ":orbit" in body and ":ledger" in body)
        r.keys("go v", settle=0.3)
        check(":go completes the space", ":go vera" in "\n".join(r.lines()))
        r.keys("\x1b", settle=0.3)

        # 06: drill from a work item into its exact pane
        r.keys("`a", settle=0.4)
        lines = r.lines()
        check("prefix-a lands the cursor on the first running item", any(slot_of(l).startswith("  ▸") and "Fix flaky auth" in l for l in lines), [l for l in lines if "▸" in l])
        r.keys("\r", settle=0.5)
        r.snap("06-drill")
        st6 = r.state()
        top = r.lines()[0]
        check("↵ on the work item enters api at the agent's pane", st6["scope"] == "space" and st6["focus"]["pane"] == ids["codex"] and slot_of(top).startswith("  api  │"), (st6["scope"], st6["focus"], repr(top[:30])))
        check("the tab is the one the agent works in", "tests · codex" in top, repr(top))

        # 07: return
        r.keys("`o", settle=0.5)
        r.snap("07-return")
        st7 = r.state()
        check("prefix-o is home again", st7["scope"] == "root" and st7["root"]["view"] == "home")
        check("the space kept running, unresized", {p["id"]: (p["cols"], p["rows"]) for p in st7["panes"]}[ids["codex"]] == sizes_before[ids["codex"]])
        r.keys("`o", settle=0.3)
        check("a second prefix-o is still home", r.state()["scope"] == "root")
        r.keys("\x1b", settle=0.3)
        check("esc at home does not go back into api", r.state()["scope"] == "root")

        # 08: orbit, a subview
        r.keys("`s", settle=0.8)
        r.snap("08-orbit")
        lines = r.lines()
        slot = slot_of(lines[0])
        check("orbit is named in the scope bar as a tab of the root", slot.startswith("  rook  │  orbit ") and "4 spaces" in slot, repr(slot[:50]))
        check("orbit's corner is the way home", "esc rook" in lines[0], repr(lines[0][-20:]))
        check("orbit draws figures, and the bar agrees", "┌┤" in "\n".join(lines) and lines[-1].startswith(" rook · orbit"), repr(lines[-1][:30]))
        check("the figures name actors on tabs, never tools", "deploy · main" in "\n".join(lines) and "tests · codex" in "\n".join(lines))
        check("no figure offers a way back in", "back in" not in "\n".join(lines))
        r.keys("\x1b", settle=0.4)
        st8 = r.state()
        check("esc from orbit is home, not a space", st8["scope"] == "root" and st8["root"]["view"] == "home", str(st8["root"]))
        check("home again: the corner is gone", "esc" not in r.lines()[0])

        # 09: inside a space
        r.enter("vera")
        r.snap("09-space")
        lines = r.lines()
        top, bar = lines[0], lines[-1]
        slot = slot_of(top)
        check("in a space the scope slot is the space's chip, then the separator", slot.startswith("  vera  │ "), repr(slot[:40]))
        check("a space's chip is raised chrome, never the accent", chip_bg(r, top, "vera") == RAISED, chip_bg(r, top, "vera"))
        cells = selected_tab_cells(r, top, "deploy")
        check("the selected tab's index, label and mark share one fill and one underline", all(c.bg == RAISED and c.underscore for c in cells), [(c.data, c.bg, c.underscore) for c in cells[:4]])
        check("the corner says the way out to rook, in the prefix's own key", "`o rook" in top, repr(top[-20:]))
        check("no sidebar in a space", no_sidebar(lines))
        check("the tab reads name · actor, never the tool", "deploy · main" in top and "claude" not in top, repr(top[:60]))
        check("the calm bar names actor ▸ tool", "main ▸ claude" in bar and "owns input" in bar, repr(bar[:70]))
        check("global attention rides the bar while inside a space", "◐ 2" in bar and "!2" in bar and "⊕g 1" in bar, repr(bar[-40:]))
        st9 = r.state()
        vera_pane = [p for p in st9["panes"] if p["id"] == st9["focus"]["pane"]][0]
        dock = len(top.split("┃")[0]) + 1 if "┃" in top else 0
        check("the work has every column the dock left", vera_pane["cols"] == 140 - dock, "%d of %d" % (vera_pane["cols"], 140 - dock))
        r.keys("`\x0f", settle=0.4)
        check("prefix-C-o returns to the space before the hop", slot_of(r.lines()[0]).startswith("  api  │"), repr(r.lines()[0][:30]))
        r.home()

        # 10: narrow
        r.resize(58, 24)
        r.snap("10-narrow-home")
        lines = r.lines()
        check("narrow home keeps the sections and the grammar", "needs you" in "\n".join(lines) and "running" in "\n".join(lines) and "/ find" in "\n".join(lines))
        r.keys("`s", settle=0.8)
        r.snap("10-narrow-orbit")
        lines = r.lines()
        check("narrow orbit is the ledger, and says so", "ledger" in lines[-1] and "ledger" in lines[0] and "┌" not in "\n".join(lines), repr(lines[-1]) + repr(lines[0]))
        r.keys("\x1b", settle=0.3)

        # 11: wide
        r.resize(160, 40)
        r.snap("11-wide")
        lines = r.lines()
        check("wide home is the same rows, not a wider box", "Fix flaky auth" in "\n".join(lines) and len(lines[0].rstrip()) < 120)
    finally:
        r.close()

    # ---- 12: quiet — one space with history
    r2 = Rook(cols=100, rows=28, tag="quiet")
    try:
        r2.keys(":go main\r", settle=0.4)
        r2.keys("echo hello from earlier\r", settle=0.4)
        r2.home()
        r2.settle(0.4)
        r2.snap("12-quiet")
        lines = r2.lines()
        body = "\n".join(lines)
        check("quiet home: the intent field, honest empty sections, the one space with its age", "1 space · all quiet" in lines[0] and "needs you nothing" in body and "running nothing" in body and "recent nothing finished yet" in body and any(l.strip().lstrip("▸ ").startswith("main") and "quiet ·" in l for l in lines), "")
        check("a calm tab wears no glyph", "bash •" not in body and "bash !" not in body and "bash ◐" not in body)
        check("nothing is invented to look alive", "◐" not in body and "!" not in body, "")
    finally:
        r2.close()

    # ---- 13: cold start, vera available
    r3 = Rook(cols=100, rows=24, tag="cold")
    try:
        r3.snap("13-cold")
        st = r3.state()
        body = "\n".join(r3.lines())
        check("cold start lands at home with vera available", st["scope"] == "root" and "Ask vera…" in body and "is not on PATH" not in body)
        check("cold start has one space, main, made quietly", "1 space" in r3.lines()[0] and any(l.strip().lstrip("▸ ").startswith("main") for l in r3.lines()))
    finally:
        r3.close()

    # ---- 14: cold start, vera unavailable
    r4 = Rook(cols=100, rows=24, tag="offline", vera=False)
    try:
        r4.snap("14-offline")
        body = "\n".join(r4.lines())
        check("without vera the field says so and keeps the grammar", "vera is not on PATH    / find    : command" in body)
        r4.keys("hello there\r", settle=0.5)
        r4.snap("14-offline-asked")
        body = "\n".join(r4.lines())
        check("a request with nobody to send it to says so, and nothing was sent", "nothing was sent" in body and r4.state()["root"]["ask"] == "offline")
        r4.keys("\x1b", settle=0.3)
        r4.keys("/ma", settle=0.4)
        check("find still works offline", "main" in "\n".join(r4.lines()[3:8]))
        r4.keys("\x1b", settle=0.3)
        r4.keys(":go main\r", settle=0.4)
        check("commands still work offline: :go enters the space", r4.state()["scope"] == "space")
        r4.keys("`o", settle=0.3)
    finally:
        r4.close()

    # ---- 15: rook . — the space for the directory
    proj = tempfile.mkdtemp(prefix="/tmp/rk-proj-")
    name = os.path.basename(proj).replace(".", "_")
    r5 = Rook(cols=100, rows=24, tag="dot", attach=["attach", "--space", name, "--cwd", proj])
    try:
        r5.snap("15-start-dot")
        st = r5.state()
        top = r5.lines()[0]
        check("rook . lands in the space for the directory, made there", st["scope"] == "space" and any(w["name"] == name and w["current"] for w in st["workspaces"]), (st["scope"], [w["name"] for w in st["workspaces"]]))
        cwd = [p for p in st["panes"] if p["id"] == st["focus"]["pane"]][0].get("cwd", "")
        check("its first pane starts in that directory", cwd.rstrip("/").endswith(os.path.basename(proj)), cwd)
        check("the chip is the space's", chip_bg(r5, top, name[:20]) == RAISED, chip_bg(r5, top, name[:20]))
    finally:
        r5.close()

    # ---- 16: startup = "last-space"
    r6 = Rook(cols=100, rows=24, tag="last", extra_conf='startup = "last-space"')
    try:
        r6.snap("16-start-last")
        st = r6.state()
        check("startup = last-space lands in the space, by choice", st["scope"] == "space" and slot_of(r6.lines()[0]).startswith("  main  │"), (st["scope"], repr(r6.lines()[0][:20])))
        r6.keys("`o", settle=0.4)
        check("prefix-o from there is still home", r6.state()["scope"] == "root")
    finally:
        r6.close()

    # ---- 17: a space literally named rook
    r7 = Rook(cols=100, rows=24, tag="rookspace", attach=["attach", "--space", "rook"])
    try:
        r7.snap("17-space-rook")
        top = r7.lines()[0]
        check("in the space named rook, the chip is a space's chip", top.startswith("  rook  │") and chip_bg(r7, top, "rook") == RAISED, chip_bg(r7, top, "rook"))
        r7.keys("`o", settle=0.6)
        r7.snap("17-home-from-rook")
        lines = r7.lines()
        check("home from it: the system's chip is the accent, and the space is listed plain", chip_bg(r7, lines[0], "rook") == ACCENT and any(l.strip().startswith("rook ") for l in lines[3:]) and "esc" not in lines[0], repr(lines[0]))
    finally:
        r7.close()

    # ---- 18: the tab component's states, the ladder, global attention inside a space
    r8 = Rook(cols=120, rows=24, tag="tabs", attach=["attach", "--space", "main"])
    try:
        first = r8.state()["focus"]["pane"]
        r8.rook("rename", "a long user-given tab name")           # 1: user-named, long
        w2 = json.loads(r8.rook("window", str(first)))["pane"]   # 2: zsh fallback, will be unread
        w3 = json.loads(r8.rook("window", str(first)))["pane"]   # 3: claude, working, selected
        w4 = json.loads(r8.rook("window", str(first)))["pane"]   # 4: claude·2, attention
        w5 = json.loads(r8.rook("window", str(first)))["pane"]   # 5: zsh, calm
        r8.settle(0.4)
        r8.rook("run", str(w3), "exec claude -c 'while :; do echo tick; sleep 1; done'")
        r8.rook("run", str(w4), "exec claude -c 'printf \"\\a\"; sleep 600; :'")   # the program asked: attention
        r8.settle(2.6)
        r8.rook("run", str(w2), "echo unseen")                    # output nobody looked at: unread
        r8.settle(0.8)
        r8.keys("`3", settle=0.6)
        r8.snap("18-tabs")
        top, bar = r8.lines()[0], r8.lines()[-1]
        check("five states on one bar: long name, unread, working selected, attention, calm",
              "1 a long user-given tab" in top and "2 bash •" in top and "3 claude ◐" in top and "4 claude·2 !" in top and "5 bash   +" in top, repr(top))
        check("inside a space the bar still counts the attention owed elsewhere", "!1" in bar and "•1" in bar, repr(bar[-30:]))
        r8.resize(84, 24)
        r8.snap("18-tabs-narrow")
        top = r8.lines()[0]
        check("narrow: the selected tab keeps its label, the attention mark survives, the scope stays",
              "3 claude" in top and "!" in top and top.startswith("  main  │"), repr(top))
        r8.resize(44, 24)
        r8.snap("18-tabs-tiny")
        top = r8.lines()[0]
        check("tiny: indices and marks only, the selected label kept, an overflow tail when it must", "3 claude" in top and top.startswith("  main  │"), repr(top))
    finally:
        r8.close()

    # ---- 19: ascii glyphs
    r9 = Rook(cols=100, rows=24, extra_conf='glyphs = "ascii"', tag="ascii")
    try:
        r9.snap("19-ascii-home")
        body = "\n".join(r9.lines())
        check("ascii: home draws with ascii glyphs", "> Ask vera" in body and "◐" not in body and "↵" not in body and "↑" not in body, "")
        r9.keys(":go main\r", settle=0.4)
        first = r9.state()["focus"]["pane"]
        w2 = json.loads(r9.rook("window", str(first)))["pane"]
        r9.settle(0.5)
        r9.rook("run", str(w2), "exec claude -c 'while :; do echo tick; sleep 1; done'")
        r9.settle(2.6)
        r9.snap("19-ascii-space")
        top, bar = r9.lines()[0], r9.lines()[-1]
        check("ascii: the marks have letters, the separator a bar, the hierarchy the same", "|" in top and "2 claude *" in top and "* 1" in bar, repr(top) + repr(bar[-20:]))
    finally:
        r9.close()

    # ---- 20: overlays over dense output — the inspector and the gate
    r10 = Rook(cols=100, rows=26, tag="over", attach=["attach", "--space", "main"])
    try:
        r10.keys("seq 1 400\r", settle=0.8)
        r10.keys("`i", settle=0.5)
        r10.snap("20-inspector")
        body = "\n".join(r10.lines())
        check("the inspector is a bounded elevated box over the output", "┤ inspector" in body and "you — nobody claims this pane" in body)
        r10.keys("x", settle=0.3)
        pid = r10.state()["focus"]["pane"]
        r10.rook("own", str(pid), "main"); r10.keys("z", settle=0.5)
        r10.snap("20-gate")
        check("the gate is one elevated row with the attention mark, the actor, the moves", "! main owns input" in "\n".join(r10.lines()) and "request handoff" in "\n".join(r10.lines()))
        r10.keys("T", settle=0.3)
    finally:
        r10.close()

    # ---- 21: a split, human focus left, a background agent right
    r11 = Rook(cols=110, rows=24, tag="split", attach=["attach", "--space", "main"])
    try:
        r11.keys("`v", settle=0.4)
        r11.keys("exec claude -c 'while :; do echo working; sleep 1; done'\r", settle=2.6)
        r11.keys("`h", settle=0.4)
        r11.keys("echo mine\r", settle=0.4)
        r11.snap("21-split")
        top, bar = r11.lines()[0], r11.lines()[-1]
        check("split: the bar says you drive the shell, the tab says the agent works", "you ▸ bash" in bar and "◐" in top, repr(bar[:30]) + repr(top[:40]))
        seam = [l[54:57] for l in r11.lines()[1:5]]
        check("split: one seam between the panes", any("│" in s for s in seam), repr(seam))
        # and from here, home lists the agent rook found, goal unknown
        r11.keys("`o", settle=0.5)
        r11.snap("21-split-home")
        running = section(r11.lines(), "running")
        check("home lists an agent rook found with no producer behind it, and says its goal is unknown", any("claude in main" in l and "goal unknown" in l for l in running), running)
    finally:
        r11.close()

    print("frames in", OUT)
    if fails:
        print("FAILED:", ", ".join(fails))
        sys.exit(1)
    print("all good")


if __name__ == "__main__":
    main()
