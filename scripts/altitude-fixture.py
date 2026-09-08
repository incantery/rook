#!/usr/bin/env python3
"""The root fixture: a deterministic rook, looked at from home.

A sandboxed engine — its own socket, HOME, config, state, a fake
`vera` on PATH and a `rook` shim for her actions, never the live one
— is driven through the front door into a representative state, then
read back through a real glass (a pty, decoded with pyte) in the
frames the design is judged on:

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

  01-home           the cockpit over the representative state
  02-ask            a request; her reflection as a plan block; the same
                    actions as approval cards; one confirmed, its receipt,
                    and the card its action pushed; the card and the turn
                    about the same task, linked
  24-completed      the rail says it finished: recent, once, and the outcome
  03-conversation   a reply in words, in a thread of turns
  22-focus          the thread focused, the dashboard focused, typing
  04-find           `/` takes the canvas over as one list
  05-command        `:` with completions
  06-drill          ↵ on a card lands in its exact pane
  07-return         prefix-o brings the cockpit back as it was
  08-orbit          prefix-s: orbit as a subview, esc back to the cockpit
  09-space          inside a space: chip, tabs, the corner, the bar's counts
  10-narrow         one view at a time: vera, now, the switcher, the badge
  11-wide           a large glass
  26-one-task       two spaces, one task, two idle claude panes: one card
  23-needs-you      an approval, a blocked task, a failed task, prioritised
  27-breakpoint     the split just above and below its threshold
  12-quiet          nothing running, one finished thing, some history
  25-long           long titles, a long reply, many cards, scrolling
  13-cold           a fresh rook with vera on PATH
  14-offline        a fresh rook without vera: the grammar still works
  15-start-dot      `rook .`: the space for the directory, entered
  16-start-last     `startup = "last-space"`: the space, not home
  17-space-rook     a space literally named rook, and home from it
  18-tabs           five tab states, and the ladder at 84 and 44 columns
  19-ascii          home and a space with `glyphs = "ascii"`
  20-inspector      the inspector and the gate over dense output
  21-split          a split, and the agent home finds in it

The frames are asserted on — cells, attributes, and the feed's
`scope`/`root` — so this doubles as the rendering test. Exit status 1
when an assertion fails. Nothing here touches a running rook: the
socket is /tmp/rk-<tag>-<pid>.sock. Needs `pip install pyte` (and
`pillow` for the PNGs).
"""
import fcntl, json, os, pty, re, select, shutil, signal, struct, subprocess, sys, tempfile, termios, time

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
%s
'''

# The fake companion: `vera say -c rook <text>` answers — a reflection
# (ask.zig's shape) when the text mentions deploying, words otherwise —
# and anything else runs the bash copy named vera, so a pane can hold
# her. `vera say` is the one verb rook assumes of her.
FAKE_VERA = r"""#!/bin/sh
if [ "$1" = "say" ]; then
  shift
  while [ $# -gt 0 ]; do case "$1" in -c) shift 2;; *) break;; esac; done
  echo "· thinking" >&2
  if [ -n "$ROOK_ABOUT_TASK" ]; then printf 'about %s: it is the one in %s; ask me to pause it if you like.\n' "$ROOK_ABOUT_TASK" "$ROOK_ABOUT_SPACE"; exit 0; fi
  case "$*" in
    *deploy*) printf '%s\n' '{"intent":"deploy the api from its current branch","plan":["run the tests in api","tag the release","roll it out to staging"],"space":"api","task":"t4","actions":[{"label":"start an agent on the deploy","run":"push-t4 && echo started deploy-agent in api"},{"label":"open the runbook","run":"echo runbook: docs/deploy.md"}]}' ;;
    *long*) printf 'This is a long answer to a long question, and it keeps going so that the thread has to wrap it across several lines of the conversation region without losing a word of it, because a reply that is cut short is a reply that was not given; the second sentence is here so that there are two, and the third is short.\n' ;;
    *) printf 'Two things are running: the auth fix in api and the deploy plan in vera.\nThe deploy plan is waiting on you.\n' ;;
  esac
  exit 0
fi
if [ "$1" = "chat" ]; then
  exec "$ROOK_FIXTURE_LIB/vera" "$ROOK_FIXTURE_LIB/vera-chat"
fi
exec "$ROOK_FIXTURE_LIB/vera" "$@"
"""

# Her own terminal, standing in for mote's: a real program on a real
# pty that says what size it was given, what keys reached it, and what
# is in its box — the three things rook is responsible for and mote is
# not. It redraws on SIGWINCH, so a frame after a resize is proof the
# pty was resized and not merely painted smaller. Run as the bash copy
# named `vera`, so rook's companion scan sees her the way it sees the
# real one.
FAKE_CHAT = r"""
box=""
keys=""
draw() {
  sz=$(stty size)
  rows=${sz%% *}
  cols=${sz##* }
  printf '\033[2J\033[Hvera chat %sx%s\r\n' "$cols" "$rows"
  printf 'you  what is running\r\n'
  printf 'vera two things: the auth fix, and the deploy plan\r\n'
  printf 'keys%s\r\n' "$keys"
  printf '\033[%s;1H> %s' "$rows" "$box"
}
note() {
  keys="$keys $1"
  while [ ${#keys} -gt 20 ]; do keys="${keys#?}"; done
  draw
}
trap draw WINCH
stty raw -echo
draw
while :; do
  IFS= read -r -n1 c
  st=$?
  # a trapped SIGWINCH interrupts the read; that is the redraw, not an end
  if [ $st -gt 128 ]; then continue; fi
  if [ $st -ne 0 ]; then break; fi
  case "$c" in
    "") note 0a ;;
    $'\r') box=""; note 0d ;;
    $'\b') note 08 ;;
    $'\177') box="${box%?}"; note 7f ;;
    [[:print:]]) box="$box$c"; note pr ;;
    *) note ct ;;
  esac
done
"""

# The rail as the fixture pushes it, and as the fake vera's confirmed
# action pushes it back with one more task: the card the conversation
# is about, sharing its id (`t4`) with the plan turn.
NOW_MS = int(time.time() * 1000)
RAIL = [
    {"id": "t1", "title": "Deploy plan", "subtitle": "3 approvals", "state": "waiting", "workspace": "vera", "actor": "main", "event": "asked which region first",
     "goal": "Plan the 1.4.2 rollout across the three regions and get the approvals lined up.",
     "question": "Which region goes first?", "options": [{"label": "us-east first", "run": "push-t1-answered && echo answered us-east", "kind": "answer"}, {"label": "eu-west first", "run": "echo answered eu-west", "kind": "answer"}],
     "events": [{"ms": NOW_MS - 400000, "text": "drafted the plan"}, {"ms": NOW_MS - 120000, "text": "asked which region first"}]},
    {"id": "t2", "title": "Fix flaky auth", "subtitle": "attempt 2", "state": "working", "workspace": "api", "actor": "codex", "event": "re-running the revoked-session test", "started": NOW_MS - 900000,
     "goal": "Make the revoked-session test pass reliably by fixing the retry window in the auth middleware.",
     "plan": [{"text": "read the failing test", "done": True}, {"text": "patch the retry window", "done": True}, {"text": "re-run the suite", "done": False}],
     "events": [{"ms": NOW_MS - 900000, "text": "started in api › tests"}, {"ms": NOW_MS - 300000, "text": "patched middleware/retry.go"}, {"ms": NOW_MS - 60000, "text": "suite run 1: 1 failure"}],
     "files": ["middleware/retry.go", "middleware/retry_test.go"], "commits": ["a1b2c3d fix the retry window"], "tests": "212 passed · 1 failed", "usage": {"tokens": 41200, "cost": 0.31},
     "actions": [{"label": "pause", "run": "echo paused t2", "kind": "pause"}, {"label": "stop", "run": "echo stopped t2", "kind": "stop"}]},
    {"id": "t3", "title": "Rotate the signing key", "state": "done", "workspace": "api", "result": "PR #212 merged", "commits": ["9f8e7d6 rotate the signing key"], "artifacts": [{"label": "PR #212", "url": "https://example.test/pr/212"}], "files": ["auth/keys.go"], "tests": "212 passed", "usage": {"tokens": 18000, "cost": 0.12}},
]
T1_ANSWERED = dict(RAIL[0], state="working", event="rolling out to us-east", question="", options=[])
T4_WORKING = {"id": "t4", "title": "Deploy api to staging", "state": "working", "workspace": "api", "actor": "claude", "event": "running the tests", "started": NOW_MS}
T4_DONE = {"id": "t4", "title": "Deploy api to staging", "state": "done", "workspace": "api", "actor": "claude", "result": "staging is on 1.4.2", "artifacts": [{"label": "staging", "url": "https://staging.example.test"}]}
SESSION = {"tokens": 812000, "cost": 4.18}


def rail_frame(items, session=None):
    params = {"surface": "agents", "items": items}
    if session:
        params["session"] = session
    return json.dumps({"v": 1, "op": "items.push", "params": params})


fails = []


def check(name, ok, extra=""):
    print(("PASS  " if ok else "FAIL  ") + name + ("  " + str(extra) if extra else ""))
    if not ok:
        fails.append(name)


class Rook:
    """A sandboxed engine behind a pyte glass."""

    def __init__(self, cols=120, rows=32, extra_conf="", tag="fixture", vera=True, attach=None, chat=False):
        self.root = tempfile.mkdtemp(prefix="/tmp/rk-%s-" % tag)
        self.cols, self.rows = cols, rows
        os.makedirs(self.root + "/.config/rook")
        with open(self.root + "/.config/rook/rook.toml", "w") as f:
            # `chat = ""` is the opt-out: the panel draws rook's own
            # surface instead of hosting her terminal. The frames that
            # judge that surface ask for it; the chat frames ask for
            # the default.
            f.write(CONFIG % (extra_conf, {True: "", False: 'chat = ""'}.get(chat, 'chat = "%s"' % chat)))
        os.makedirs(self.root + "/bin")
        os.makedirs(self.root + "/lib")
        # real processes with the names the fixture needs: an agent
        # is a program by name, so a shell under another name is one —
        # and one that keeps talking is one that is working
        for name in ("claude", "codex"):
            shutil.copy("/bin/bash", self.root + "/bin/" + name)  # /bin/sh re-execs bash and loses the name
        shutil.copy("/bin/bash", self.root + "/lib/vera")
        with open(self.root + "/lib/vera-chat", "w") as f:
            f.write(FAKE_CHAT)
        os.chmod(self.root + "/lib/vera-chat", 0o755)
        # a chat command that fails the moment it starts, the way a
        # verad that is not there fails
        with open(self.root + "/bin/vera-broken", "w") as f:
            f.write('#!/bin/sh\necho "cannot reach verad" >&2\nexit 1\n')
        os.chmod(self.root + "/bin/vera-broken", 0o755)
        if vera:
            with open(self.root + "/bin/vera", "w") as f:
                f.write(FAKE_VERA)
            os.chmod(self.root + "/bin/vera", 0o755)
        # `rook` for the fake vera's actions: the engine, verbatim
        with open(self.root + "/bin/rook", "w") as f:
            f.write('#!/bin/sh\nexec "%s" "$@"\n' % ENGINE)
        os.chmod(self.root + "/bin/rook", 0o755)
        # what the fake vera's first action runs, and what answering
        # t1's question runs: the rail again, changed
        for name, items in (("t4", RAIL + [T4_WORKING]), ("t1-answered", [T1_ANSWERED] + RAIL[1:])):
            with open(self.root + "/lib/with-%s.json" % name, "w") as f:
                f.write(rail_frame(items, SESSION) + "\n")
            with open(self.root + "/bin/push-" + name, "w") as f:
                f.write('#!/bin/sh\nexec "%s" side - < "%s/lib/with-%s.json" >/dev/null\n' % (ENGINE, self.root, name))
            os.chmod(self.root + "/bin/push-" + name, 0o755)
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
    r.rook("side", "-", stdin=rail_frame(RAIL, SESSION) + "\n")
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


GROUPS = ("needs you", "in progress", "recent", "spaces")


def dividers(lines):
    """The columns of the region dividers, read off the header row,
    which no content shares."""
    row = lines[1]
    return [i for i, ch in enumerate(row) if ch == "│"]


def nav(lines):
    """The navigator's rows, past the dock, before the first divider."""
    d = dividers(lines)
    x = d[0] if d else len(lines[1])
    return [slot_of(l[:x]).rstrip() for l in lines]


def insp(lines):
    """The inspector's rows: between the first and second divider, or
    to the edge."""
    d = dividers(lines)
    if not d:
        return [slot_of(l).rstrip() for l in lines]
    x0 = d[0] + 1
    x1 = d[1] if len(d) > 1 else None
    return [(l[x0:x1] if len(l) > x0 else "").rstrip() for l in lines]


def vera(lines):
    """The rightmost region past the last divider (vera's pane)."""
    d = dividers(lines)
    x = d[-1] + 1 if d else 0
    return [(l[x:] if len(l) > x else "").rstrip() for l in lines]


def group(rows, name):
    """The rows under a navigator group header, up to the next, with
    the edge, the marker and the edge word taken off."""
    out, on = [], False
    for l in rows[1:-1]:
        s = l.strip()
        is_header = any(s.startswith(h + " ") or s == h for h in GROUPS) and not l.startswith("     ")
        if on and is_header:
            break
        if is_header and s.startswith(name):
            on = True
            continue
        if on and s:
            s = s.lstrip("▎▸| ").strip()
            s = re.sub(r"\s{2,}\S+$", "", s)
            out.append(s)
    return out


def flat(rows):
    return re.sub(r"\s+", " ", " ".join(re.sub(r"\s+\d+[smhd]$", "", l.rstrip()) for l in rows))


def cell(r, y, x):
    return r.screen.buffer[y][x]


def selected_nav(lines):
    return [l.strip().lstrip("▸ ").strip() for l in nav(lines) if l.strip().startswith("▸")]


def main():
    if not os.path.exists(ENGINE):
        sys.stderr.write("altitude-fixture: build the engine first (make -C mux build)\n")
        sys.exit(2)

    # ---- the representative state, from home. 200 columns: the global
    # pin dock keeps its 40% at home (it never resizes), and the
    # navigator and the inspector should still read whole beside it
    r = Rook(cols=200, rows=44)
    try:
        ids = build_fixture(r)
        st = r.state()
        sizes_before = {p["id"]: (p["cols"], p["rows"]) for p in st["panes"]}
        r.settle(0.4)

        # 01: home — the navigator left, the inspector right, the first
        # thing that needs you selected and inspected
        r.snap("01-home")
        lines = r.lines()
        top, bar = lines[0], lines[-1]
        N, I = nav(lines), insp(lines)
        slot = slot_of(top)
        check("plain rook lands at home: scope root, view home, the navigator focused, wide", st["scope"] == "root" and st["root"]["view"] == "home" and st["root"]["region"] == "nav" and st["root"]["wide"], str(st.get("root")))
        check("the top bar is identity, the view and the selection — no counts", slot.startswith("  rook  │  home ") and "rang the bell" in slot and "spaces" not in slot and "agents" not in slot, repr(slot[:70]))
        check("the navigator is the left third, the inspector the rest, one quiet divider", len(dividers(lines)) == 1 and 0.3 < (dividers(lines)[0] - top.index("┃")) / (200 - top.index("┃")) < 0.4, (dividers(lines), top.index("┃")))
        needs = group(N, "needs you")
        check("needs you: the bell and the producer's ask, as rows, the strongest first", needs[0].startswith("! rang the bell") and any(l.startswith("! Deploy plan") for l in needs), needs)
        active = group(N, "in progress")
        check("in progress: one row per task, by goal, nothing about its pane", active[0].startswith("◐ Fix flaky auth") and len(active) == 1 and "re-running" not in "\n".join(N), active)
        check("no idle agent, no agent a producer claims, is a row of its own", not any("at work" in l for l in N))
        recent = group(N, "recent")
        check("recent: one row, the title only", recent[0].startswith("✓ Rotate the signing key") and "PR #212" not in recent[0], recent)
        spaces = group(N, "spaces")
        check("spaces: compact rows with tab counts and marks, never a task's title", len(spaces) == 4 and spaces[0].startswith("rook") and any(l.startswith("vera") and "tab" in l for l in spaces) and "Deploy plan" not in "\n".join(spaces), spaces)
        check("the first row is selected, and the selection is unmistakable", selected_nav(lines) and selected_nav(lines)[0].startswith("! rang the bell"), selected_nav(lines))
        check("the inspector shows the selected signal: what happened, its pane, and what to do", I[1].strip().startswith("! rang the bell") and any("what happened" in l for l in I) and any("bash rang the bell in api › server" in l for l in I) and any("its pane" in l for l in I) and any("go see it" in l for l in I) and any("ask vera about this" in l for l in I), [l for l in I if l.strip()][:8])
        check("the bar is ambient health: agents, attention, the session's spend with its period, vera", "agents ◐ 2 active" in bar and "! 2 need you" in bar and "session $4.18 · 812k tokens" in bar and "vera ready" in bar and "stale" not in bar, repr(bar))
        check("nothing was resized to paint home", {p["id"]: (p["cols"], p["rows"]) for p in r.state()["panes"]} == sizes_before)
        r.keys("\x1b", settle=0.3)
        check("esc at home stays at home", r.state()["scope"] == "root")

        # 02: the active task inspected: goal, step, plan, timeline,
        # files, tests, usage, its pane, the producer's controls
        r.keys("j", settle=0.3)
        r.keys("j", settle=0.4)
        r.snap("02-active")
        lines = r.lines()
        I = insp(lines)
        body = "\n".join(I)
        check("j walks the navigator; the selection is the active task", selected_nav(lines)[0].startswith("◐ Fix flaky auth"), selected_nav(lines))
        check("active detail: title, state · space · actor · age; the goal; now; the plan with progress", I[1].strip() == "◐ Fix flaky auth" and "working · in api · codex · 15m since it started" in I[2] and "Make the revoked-session test pass reliably" in body and "\n  now" in body and "plan 2 of 3" in body and "✓ read the failing test" in body and "◌ re-run the suite" in body, [l for l in I if l.strip()][:9])
        check("active detail: the timeline with ages, files, commits, tests, usage", "timeline" in body and "suite run 1: 1 failure" in body and "files 2" in body and "middleware/retry.go" in body and "a1b2c3d" in body and "tests      212 passed · 1 failed" in body and "usage      41k tokens · $0.31" in body, [l for l in I if "tests" in l or "usage" in l])
        check("active detail: the last lines of its pane, as output", "its pane codex" in body and "revoked session rejected" in body)
        check("active detail: the producer's controls, then rook's own", any("◌ pause  $ echo paused t2" in l for l in I) and any("✕ stop" in l for l in I) and any("open its pane" in l for l in I) and any("ask vera about this" in l for l in I), [l for l in I if "$" in l or "open" in l])
        r.keys("l", settle=0.3)
        st2 = r.state()
        lines = r.lines()
        I = insp(lines)
        check("l moves focus into the inspector, on its first control", st2["root"]["region"] == "insp" and any(l.strip().startswith("▸") and "pause" in l for l in I), [l for l in I if "▸" in l])
        r.keys("j", settle=0.3)
        I = insp(r.lines())
        check("j walks the controls; the selected one says enter", any(l.strip().startswith("▸") and "stop" in l and "↵" in l for l in I), [l for l in I if "▸" in l])
        check("the top bar names the view and the selection", "  home " in slot_of(r.lines()[0]) and "Fix flaky auth" in r.lines()[0])
        r.keys("h", settle=0.3)
        check("h is the navigator again", r.state()["root"]["region"] == "nav")

        # 03: an approval answered from home — the blocked task's options
        r.keys("k", settle=0.3)
        r.snap("03-blocked")
        lines = r.lines()
        I = insp(lines)
        body = "\n".join(I)
        check("blocked detail: the question, what produced it, the options as controls", I[1].strip() == "! Deploy plan" and "waiting on you" in body and "Which region goes first?" in body and "timeline" in body and any("◌ us-east first" in l for l in I) and any("◌ eu-west first" in l for l in I), [l for l in I if l.strip()][:12])
        r.keys("l", settle=0.3)
        r.keys("\r", settle=1.2)
        r.snap("03-answered")
        lines = r.lines()
        N = nav(lines)
        check("answering from the inspector ran the option, the rail moved the task to in progress, and it stayed selected", any(l.startswith("◐ Deploy plan") for l in group(N, "in progress")) and not any("Deploy plan" in l for l in group(N, "needs you")) and r.state()["root"]["selected"] == "t:t1", (group(N, "in progress"), r.state()["root"]["selected"]))
        check("the inspector followed: now it is rolling out", any("rolling out to us-east" in l for l in insp(lines)), [l for l in insp(lines) if "rolling" in l])
        r.keys("\x1b", settle=0.3)

        # 04: vera, summoned and dismissed, with her state kept
        r.keys("`t", settle=0.5)
        r.snap("04-vera-open")
        lines = r.lines()
        st4 = r.state()
        V = vera(lines)
        check("prefix-t summons vera over the inspector's side, focused, the navigator untouched", st4["root"]["vera"]["open"] and st4["root"]["region"] == "vera" and len(dividers(lines)) == 2 and any("✦ vera · ready" in l for l in V) and any("› Ask vera" in l for l in V) and nav(lines)[1].strip().startswith("needs you"), (st4["root"]["vera"], V[1]))
        r.keys("half a thought", settle=0.3)
        r.keys("`t", settle=0.4)
        st4b = r.state()
        check("prefix-t again dismisses her; the draft is kept; focus is the navigator's", not st4b["root"]["vera"]["open"] and st4b["root"]["draft"] and st4b["root"]["region"] == "nav", str(st4b["root"]))
        r.keys("`t", settle=0.4)
        check("summoned again, the draft is still in the composer", "half a thought" in "\n".join(vera(r.lines())[-4:]))
        r.keys("\x15", settle=0.2)
        r.keys("deploy the api\r", settle=1.6)
        r.snap("04-vera-plan")
        lines = r.lines()
        V = vera(lines)
        N = nav(lines)
        check("her reflection is a block in her pane, and its actions are approvals in the navigator", "deploy the api from its current branch" in flat(V) and "1. run the tests in api" in flat(V) and any(l.startswith("◌ start an agent on the deploy") for l in group(N, "needs you")), (group(N, "needs you"), flat(V)[-200:]))
        check("her status says she is waiting for you, and so does the bar", any("waiting for you" in l for l in V[:2]) and "vera waiting for you" in lines[-1], repr(lines[-1]))
        r.keys("\x1b", settle=0.3)
        check("esc closes her pane; the approvals stay in the navigator", not r.state()["root"]["vera"]["open"] and any("start an agent" in l for l in group(nav(r.lines()), "needs you")))
        r.keys("g", settle=0.3)
        r.snap("04-approval")
        lines = r.lines()
        I = insp(lines)
        check("the approval inspected: what she proposed, what it runs, why, her plan, and run it", I[1].strip().startswith("◌ start an agent on the deploy") and any("what vera proposed" in l for l in I) and any("runs       push-t4" in l for l in I) and any("because you asked for" in l for l in I) and any("her plan" in l for l in I) and any("run it" in l for l in I), [l for l in I if l.strip()][:10])
        r.keys("l", settle=0.3)
        r.keys("\r", settle=1.4)
        r.snap("04-ran")
        lines = r.lines()
        N = nav(lines)
        check("run it ran: the card its action pushed is in progress, the approval is gone", any(l.startswith("◐ Deploy api to staging") for l in group(N, "in progress")) and not any("start an agent" in l for l in group(N, "needs you")), group(N, "in progress"))
        r.keys("\x1b", settle=0.3)

        # 05: ask vera about this — the reference rides the request
        r.keys("g", settle=0.2)
        for _ in range(6):
            if selected_nav(r.lines()) and selected_nav(r.lines())[0].startswith("◐ Fix flaky auth"):
                break
            r.keys("j", settle=0.2)
        r.keys("l", settle=0.3)
        for _ in range(6):
            I = insp(r.lines())
            if any(l.strip().startswith("▸") and "ask vera about this" in l for l in I):
                break
            r.keys("j", settle=0.2)
        r.keys("\r", settle=0.5)
        r.snap("05-about")
        lines = r.lines()
        st5 = r.state()
        V = vera(lines)
        check("ask vera about this opens her pane with the task attached as a reference", st5["root"]["vera"]["open"] and st5["root"]["vera"]["about"] == "t2" and any("about" in l and "Fix flaky auth" in l for l in V[:3]), (st5["root"]["vera"], V[:3]))
        r.keys("why is it slow\r", settle=1.6)
        lines = r.lines()
        V = vera(lines)
        check("the request carried the reference, and she answered about it", "about t2: it is the one in api" in flat(V), flat(V)[-200:])
        r.keys("\x1b", settle=0.3)
        r.keys("\x1b", settle=0.3)
        check("esc clears the attachment, then closes the pane", not r.state()["root"]["vera"]["open"] and r.state()["root"]["vera"]["about"] == "")

        # 06: the lifecycle transition keeps the selection
        for _ in range(8):
            if selected_nav(r.lines()) and selected_nav(r.lines())[0].startswith("◐ Deploy api to staging"):
                break
            r.keys("j", settle=0.2)
        check("the new task is selected", selected_nav(r.lines())[0].startswith("◐ Deploy api to staging"), selected_nav(r.lines()))
        r.rook("side", "-", stdin=rail_frame([T1_ANSWERED] + RAIL[1:] + [T4_DONE], SESSION) + "\n")
        r.settle(0.7)
        r.snap("06-completed")
        lines = r.lines()
        N, I = nav(lines), insp(lines)
        check("it finished: moved to recent, still selected, the inspector showing the outcome and the artifact", any(l.startswith("✓ Deploy api to staging") for l in group(N, "recent")) and r.state()["root"]["selected"] == "t:t4" and any("outcome" in l for l in I) and any("staging is on 1.4.2" in l for l in I) and any("https://staging.example.test" in l for l in I), (group(N, "recent"), r.state()["root"]["selected"]))

        # 07: open the workspace, and back with everything kept
        for _ in range(8):
            if selected_nav(r.lines()) and selected_nav(r.lines())[0].startswith("◐ Fix flaky auth"):
                break
            r.keys("k", settle=0.2)
        r.keys("l", settle=0.2)
        r.keys("o", settle=0.5)
        r.snap("07-drill")
        st7 = r.state()
        top = r.lines()[0]
        check("o opens the exact pane: api, the agent's pane", st7["scope"] == "space" and st7["focus"]["pane"] == ids["codex"] and slot_of(top).startswith("  api  │"), (st7["scope"], st7["focus"]))
        check("in a space the bar is local: who holds the keys, and one global attention count", "codex ▸ codex owns input" in r.lines()[-1] and "! 1 needs you" in r.lines()[-1] and "session" not in r.lines()[-1], repr(r.lines()[-1]))

        # 08: vera from the workspace, without perturbing it
        r.keys("`t", settle=0.5)
        r.snap("08-vera-space")
        st8 = r.state()
        lines = r.lines()
        check("prefix-t in a space opens her pane over the panes, holding the keys, resizing nothing", st8["root"]["vera"]["open"] and st8["root"]["vera"]["keys"] and st8["focus"]["mode"] == "pane" and any("✦ vera" in l for l in lines[1:3]) and {p["id"]: (p["cols"], p["rows"]) for p in st8["panes"]}[ids["codex"]] == sizes_before[ids["codex"]] and "you ▸ vera" in lines[-1], (st8["root"]["vera"], repr(lines[-1][:30])))
        r.keys("note to self", settle=0.3)
        r.keys("`t", settle=0.4)
        st8b = r.state()
        check("prefix-t dismisses her; the keys are the pane's again; the draft is kept", not st8b["root"]["vera"]["open"] and not st8b["root"]["vera"]["keys"] and st8b["root"]["draft"] and st8b["focus"]["pane"] == ids["codex"], str(st8b["root"]["vera"]))
        r.keys("`o", settle=0.5)
        r.snap("07-return")
        st7b = r.state()
        check("prefix-o is home again, the same task selected, the inspector focused, the draft kept", st7b["scope"] == "root" and st7b["root"]["selected"] == "t:t2" and st7b["root"]["region"] == "insp" and st7b["root"]["draft"], str(st7b["root"]))
        r.keys("\x15", settle=0.2)
        r.keys("\x1b", settle=0.3)

        # 09: orbit, and back to the same home
        r.keys("`s", settle=0.8)
        r.snap("09-orbit")
        lines = r.lines()
        check("orbit is named in the scope bar, esc rook in the corner, figures on the canvas", slot_of(lines[0]).startswith("  rook  │  orbit ") and "esc rook" in lines[0] and "┌┤" in "\n".join(lines), repr(slot_of(lines[0])[:50]))
        r.keys("\x1b", settle=0.4)
        st9 = r.state()
        check("esc from orbit is home again, the selection kept", st9["root"]["view"] == "home" and st9["root"]["selected"] == "t:t2", str(st9["root"]))

        # 10: narrow — the list-to-detail stack
        r.resize(100, 30)
        r.snap("10-narrow-list")
        lines = r.lines()
        st10 = r.state()
        check("narrow glass is the list alone, the selection kept", not st10["root"]["wide"] and len(dividers(lines)) == 0 and any("needs you" in l for l in lines) and selected_nav(lines), str(st10["root"]))
        r.keys("l", settle=0.4)
        r.snap("10-narrow-detail")
        lines = r.lines()
        check("l is the detail, full width, with the way back", r.state()["root"]["detail"] and any("h ‹ list" in l for l in lines[1:3]) and "◐ Fix flaky auth" in "\n".join(lines[1:4]), lines[1:4])
        r.keys("h", settle=0.3)
        check("h is the list again", not r.state()["root"]["detail"] and r.state()["root"]["region"] == "nav")
        r.keys("`t", settle=0.4)
        r.snap("10-narrow-vera")
        check("narrow: vera is a full-width view, and the bar keeps the attention count", any("✦ vera" in l for l in r.lines()[1:3]) and "need" in r.lines()[-1], repr(r.lines()[-1]))
        r.keys("\x1b", settle=0.3)

        # 11: wide, pinned: three columns when all three fit
        r.resize(240, 50)
        r.keys("`T", settle=0.5)
        r.snap("11-wide-pinned")
        lines = r.lines()
        st11 = r.state()
        check("pinned on a wide glass, vera is a third column, every region at its floor or above", st11["root"]["vera"]["pinned"] and len(dividers(lines)) == 2 and dividers(lines)[1] - dividers(lines)[0] >= 50 and 240 - dividers(lines)[1] >= 40 and any("pinned" in l for l in vera(lines)[:2]), dividers(lines))
        r.keys("`t", settle=0.3)
        to_vera = r.state()["root"]["region"]
        r.keys("`t", settle=0.3)
        check("pinned, prefix-t only moves focus, there and back", r.state()["root"]["vera"]["pinned"] and to_vera == "vera" and r.state()["root"]["region"] == "nav", (to_vera, r.state()["root"]["region"]))
        r.resize(180, 40)
        r.snap("11-pinned-fallback")
        lines = r.lines()
        check("pinned without room for three, she overlays instead of crushing the regions", len(dividers(lines)) == 2 and dividers(lines)[0] - lines[0].index("┃") >= 30 and any("pinned" in l for l in vera(lines)[:2]), dividers(lines))
        r.keys("`T", settle=0.3)
        r.keys("\x1b", settle=0.3)
        r.keys("\x1b", settle=0.3)
    finally:
        r.close()

    # ---- 26: the current-state equivalent — two spaces, one task, idle
    # claude panes, a short conversation
    r0 = Rook(cols=160, rows=42, tag="base")
    try:
        r0.rook("new", "-q", "api"); r0.settle(0.4)
        st = r0.state()
        first = {w["name"]: w["windows"][0]["focus"] for w in st["workspaces"]}
        r0.rook("run", str(first["main"]), "exec claude -c 'sleep 600; :'")
        w2 = json.loads(r0.rook("window", str(first["api"])))["pane"]; r0.settle(0.3)
        r0.rook("run", str(w2), "exec claude -c 'sleep 600; :'")
        r0.rook("run", str(first["api"]), "exec codex -c 'while :; do echo \"✗ revoked session rejected\"; sleep 1; done'")
        r0.settle(2.6)
        r0.rook("side", "-", stdin=rail_frame([RAIL[1]]) + "\n"); r0.settle(0.6)
        r0.keys("what is running\r", settle=1.6)
        r0.keys("\x1b", settle=0.4)
        r0.snap("26-one-task")
        lines = r0.lines()
        N, I = nav(lines), insp(lines)
        check("one task, two idle claude panes, a conversation: one row in progress, no phantom tasks, the detail beside it, vera dismissed", group(N, "in progress")[0].startswith("◐ Fix flaky auth") and len(group(N, "in progress")) == 1 and "needs you" not in "\n".join(N) and not any("at work" in l for l in N) and "Make the revoked-session test" in "\n".join(I) and r0.state()["root"]["turns"] == 2 and not r0.state()["root"]["vera"]["open"], (group(N, "in progress"), r0.state()["root"]))
        check("the bar reports what it can: one active agent, the one task's usage as the session's, no attention", "agents ◐ 1 active" in lines[-1] and "session $0.31 · 41k tokens" in lines[-1] and "need" not in lines[-1], repr(lines[-1]))
    finally:
        r0.close()

    # ---- 23: needs you — an approval, a blocked task, a failed task
    r1 = Rook(cols=160, rows=40, tag="needs")
    try:
        r1.rook("new", "-q", "api"); r1.settle(0.4)
        r1.rook("side", "-", stdin=rail_frame([
            {"id": "b1", "title": "Migrate the sessions table", "state": "waiting", "workspace": "api", "actor": "claude", "question": "Drop the old index before the backfill, or after?", "options": [{"label": "before", "run": "echo before"}, {"label": "after", "run": "echo after"}], "event": "needs a go-ahead before it drops the old index"},
            {"id": "f1", "title": "Backfill the audit log", "state": "failed", "workspace": "api", "actor": "codex", "event": "exit 1 · disk full on the runner", "events": [{"ms": NOW_MS - 30000, "text": "runner out of disk at 93%"}], "actions": [{"label": "retry", "run": "echo retried f1", "kind": "retry"}, {"label": "redirect to the big runner", "run": "echo redirected", "kind": "redirect"}]},
            {"id": "w1", "title": "Write the release notes", "state": "working", "workspace": "main", "actor": "claude", "event": "reading the last twenty commits"},
        ], {"tokens": 12345678, "cost": 123.45}) + "\n"); r1.settle(0.5)
        r1.keys("deploy it\r", settle=1.6)
        r1.keys("\x1b", settle=0.3)
        r1.snap("23-needs-you")
        lines = r1.lines()
        N = nav(lines)
        needs = group(N, "needs you")
        check("needs you: the approvals first, then the blocked and the failed", needs[0].startswith("◌ start an agent") and any(l.startswith("! Migrate the sessions table") for l in needs) and any(l.startswith("✕ Backfill the audit log") for l in needs), needs)
        check("the bar: attention, failed, a high spend with its period", "! 4 need you" in lines[-1] and "✕ 1 failed" in lines[-1] and "session $123.45 · 12.3M tokens" in lines[-1], repr(lines[-1]))
        for _ in range(6):
            if selected_nav(r1.lines()) and selected_nav(r1.lines())[0].startswith("✕ Backfill"):
                break
            r1.keys("j", settle=0.2)
        r1.snap("23-failed")
        I = insp(r1.lines())
        body = "\n".join(I)
        check("failed detail: what went wrong, the last event, retry and redirect as controls, the space to open", "what went wrong" in body and "disk full on the runner" in body and "runner out of disk" in body and any("◐ retry" in l for l in I) and any("redirect to the big runner" in l for l in I) and any("open the space" in l for l in I), [l for l in I if l.strip()][:12])
    finally:
        r1.close()

    # ---- 27: the breakpoint, just above and just below
    for cols, wide in ((81, True), (80, False)):
        r2 = Rook(cols=cols, rows=30, tag="bp%d" % cols)
        try:
            r2.rook("side", "-", stdin=rail_frame([RAIL[1]]) + "\n"); r2.settle(0.4)
            r2.snap("27-breakpoint-%d" % cols)
            st = r2.state()
            lines = r2.lines()
            check("at %d columns the layout is %s" % (cols, "navigator and inspector" if wide else "the list"), st["root"]["wide"] == wide and ((len(dividers(lines)) == 1) == wide), (st["root"]["wide"], dividers(lines)))
        finally:
            r2.close()

    # ---- 12: quiet — nothing running, one finished thing
    r3 = Rook(cols=120, rows=30, tag="quiet")
    try:
        r3.keys(":go main\r", settle=0.4)
        r3.keys("echo hello from earlier\r", settle=0.4)
        r3.home()
        r3.rook("side", "-", stdin=rail_frame([{"id": "d1", "title": "Tidy the changelog", "state": "done", "workspace": "main", "result": "3 entries"}]) + "\n")
        r3.settle(0.5)
        r3.snap("12-quiet")
        lines = r3.lines()
        N, I = nav(lines), insp(lines)
        check("quiet home: no needs-you or in-progress group, one recent row selected, its outcome inspected", "needs you" not in "\n".join(N) and "in progress" not in "\n".join(N) and group(N, "recent") == ["✓ Tidy the changelog"] and any("outcome" in l for l in I) and any("3 entries" in l for l in I), (group(N, "recent"), [l for l in I if l.strip()][:5]))
        check("the bar at rest collapses its warnings: no attention, no failed, no agents, vera ready", "need" not in lines[-1] and "failed" not in lines[-1] and "agents" not in lines[-1] and "vera ready" in lines[-1], repr(lines[-1]))
        check("nothing is invented to look alive", "◐" not in "\n".join(N) and "!" not in "\n".join(N))
    finally:
        r3.close()

    # ---- 25: long content — long titles, many rows, a long inspector
    r4 = Rook(cols=130, rows=18, tag="long")
    try:
        items = [{"id": "l%d" % i, "title": "A task with a deliberately long goal that says exactly what it means to do number %d" % i, "state": "working", "workspace": "main", "actor": "claude", "event": "step %d of a long plan whose current step is also described at some length" % i, "events": [{"ms": NOW_MS - 1000 * k, "text": "event %d of task %d with a long description" % (k, i)} for k in range(12)], "files": ["dir/file%d.go" % k for k in range(12)]} for i in range(14)]
        r4.rook("side", "-", stdin=rail_frame(items) + "\n"); r4.settle(0.5)
        r4.snap("25-long")
        lines = r4.lines()
        N, I = nav(lines), insp(lines)
        check("long titles are cut, the navigator says how many more, the inspector wraps and says how many more", any("A task with a deliberately long" in l for l in N) and any("more" in l for l in N[-3:]) and any("more · j k" in l for l in I[-2:]), (N[-2:], I[-2:]))
        r4.keys("G", settle=0.3)
        r4.snap("25-long-end")
        check("G is the last row, scrolled into view, its detail beside it", selected_nav(r4.lines()) and r4.state()["root"]["selected"].startswith("t:") or r4.state()["root"]["selected"].startswith("s:"), r4.state()["root"]["selected"])
        r4.keys("g", settle=0.2)
        r4.keys("l", settle=0.2)
        r4.keys("\x1b[6~", settle=0.3)
        r4.snap("25-long-scrolled")
        check("page down scrolls the inspector on its own", insp(r4.lines())[1].strip() != "◐ A task with a deliberately long goal that says exactly what it means to do number 0", insp(r4.lines())[1])
    finally:
        r4.close()

    # ---- 13: cold start, vera available
    r5 = Rook(cols=100, rows=24, tag="cold")
    try:
        r5.snap("13-cold")
        st = r5.state()
        lines = r5.lines()
        I = insp(lines)
        check("cold start lands at home: the one space inspected, honest, and what there is to do", st["scope"] == "root" and "all quiet" in "\n".join(nav(lines)) and "no task the rail knows runs here" in flat(I) and "to do something" in flat(I) and "ask vera" in flat(I) and "vera ready" in lines[-1], [l for l in I if l.strip()][:8])
    finally:
        r5.close()

    # ---- 14: cold start, vera unavailable
    r6 = Rook(cols=100, rows=24, tag="offline", vera=False)
    try:
        r6.snap("14-offline")
        lines = r6.lines()
        check("without vera the bar says so and the navigator and the inspector are whole", "vera offline" in lines[-1] and any("spaces" in l for l in nav(lines)) and any("to do something" in l for l in insp(lines)), repr(lines[-1]))
        r6.keys("say hello\r", settle=0.5)
        r6.snap("14-offline-asked")
        V = vera(r6.lines())
        check("typing summons her pane, which says she is not on PATH, and nothing was sent", r6.state()["root"]["vera"]["open"] and "✕ offline" in flat(V) and "not on PATH" in flat(V) and "nothing was sent" in flat(V) and r6.state()["root"]["ask"] == "offline", flat(V)[:200])
        r6.keys("\x1b", settle=0.3)
        r6.keys("/ma", settle=0.4)
        check("find still works offline", "main" in "\n".join(r6.lines()[3:8]))
        r6.keys("\x1b", settle=0.3)
        r6.keys(":go main\r", settle=0.4)
        check("commands still work offline: :go enters the space", r6.state()["scope"] == "space")
        r6.keys("`o", settle=0.3)
        r6.keys("l", settle=0.3)
        check("the inspector still works offline", r6.state()["root"]["region"] == "insp")
    finally:
        r6.close()

    # ---- 15: rook . — the space for the directory
    proj = tempfile.mkdtemp(prefix="/tmp/rk-proj-")
    name = os.path.basename(proj).replace(".", "_")
    r7 = Rook(cols=100, rows=24, tag="dot", attach=["attach", "--space", name, "--cwd", proj])
    try:
        r7.snap("15-start-dot")
        st = r7.state()
        top = r7.lines()[0]
        check("rook . lands in the space for the directory, made there", st["scope"] == "space" and any(w["name"] == name and w["current"] for w in st["workspaces"]), (st["scope"], [w["name"] for w in st["workspaces"]]))
        check("the chip is the space's", chip_bg(r7, top, name[:20]) == RAISED, chip_bg(r7, top, name[:20]))
    finally:
        r7.close()

    # ---- 16: startup = "last-space"
    r8 = Rook(cols=100, rows=24, tag="last", extra_conf='startup = "last-space"')
    try:
        r8.snap("16-start-last")
        st = r8.state()
        check("startup = last-space lands in the space, by choice", st["scope"] == "space" and slot_of(r8.lines()[0]).startswith("  main  │"), (st["scope"], repr(r8.lines()[0][:20])))
        r8.keys("`o", settle=0.4)
        check("prefix-o from there is still home", r8.state()["scope"] == "root")
    finally:
        r8.close()

    # ---- 17: a space literally named rook
    r9 = Rook(cols=100, rows=24, tag="rookspace", attach=["attach", "--space", "rook"])
    try:
        r9.snap("17-space-rook")
        top = r9.lines()[0]
        check("in the space named rook, the chip is a space's chip", top.startswith("  rook  │") and chip_bg(r9, top, "rook") == RAISED, chip_bg(r9, top, "rook"))
        r9.keys("`o", settle=0.6)
        r9.snap("17-home-from-rook")
        lines = r9.lines()
        check("home from it: the system's chip is the accent, and the space is a plain row", chip_bg(r9, lines[0], "rook") == ACCENT and any(l.strip().startswith("rook") for l in nav(lines)[3:]) and "esc" not in lines[0], repr(lines[0]))
    finally:
        r9.close()

    # ---- 18: the tab component's states, the ladder, the local bar
    r10 = Rook(cols=120, rows=24, tag="tabs", attach=["attach", "--space", "main"])
    try:
        first = r10.state()["focus"]["pane"]
        r10.rook("rename", "a long user-given tab name")
        w2 = json.loads(r10.rook("window", str(first)))["pane"]
        w3 = json.loads(r10.rook("window", str(first)))["pane"]
        w4 = json.loads(r10.rook("window", str(first)))["pane"]
        w5 = json.loads(r10.rook("window", str(first)))["pane"]
        r10.settle(0.4)
        r10.rook("run", str(w3), "exec claude -c 'while :; do echo tick; sleep 1; done'")
        r10.rook("run", str(w4), "exec claude -c 'printf \"\\a\"; sleep 600; :'")
        r10.settle(2.6)
        r10.rook("run", str(w2), "echo unseen")
        r10.settle(0.8)
        r10.keys("`3", settle=0.6)
        r10.snap("18-tabs")
        top, bar = r10.lines()[0], r10.lines()[-1]
        check("five states on one bar: long name, unread, working selected, attention, calm",
              "1 a long user-given tab" in top and "2 bash •" in top and "3 claude ◐" in top and "4 claude·2 !" in top and "5 bash   +" in top, repr(top))
        check("inside a space the bar is local, with the one global attention count", bar.startswith(" you ▸ claude") and "◐ 1" in bar and "! 1 needs you" in bar and "•1" in bar and "session" not in bar, repr(bar))
        r10.resize(84, 24)
        r10.snap("18-tabs-narrow")
        top = r10.lines()[0]
        check("narrow: the selected tab keeps its label, the attention mark survives, the scope stays", "3 claude" in top and "!" in top and top.startswith("  main  │"), repr(top))
        r10.resize(44, 24)
        r10.snap("18-tabs-tiny")
        top = r10.lines()[0]
        check("tiny: indices and marks only, the selected label kept, an overflow tail when it must", "3 claude" in top and top.startswith("  main  │"), repr(top))
    finally:
        r10.close()

    # ---- 19: ascii glyphs
    r11 = Rook(cols=100, rows=24, extra_conf='glyphs = "ascii"', tag="ascii")
    try:
        r11.snap("19-ascii-home")
        body = "\n".join(r11.lines())
        check("ascii: home draws with ascii glyphs", "|" in r11.lines()[1] and "◐" not in body and "↵" not in body and "⇥" not in body and "✦" not in body and "▎" not in body, "")
        r11.keys(":go main\r", settle=0.4)
        first = r11.state()["focus"]["pane"]
        w2 = json.loads(r11.rook("window", str(first)))["pane"]
        r11.settle(0.5)
        r11.rook("run", str(w2), "exec claude -c 'while :; do echo tick; sleep 1; done'")
        r11.settle(2.6)
        r11.snap("19-ascii-space")
        top, bar = r11.lines()[0], r11.lines()[-1]
        check("ascii: the marks have letters, the separator a bar, the hierarchy the same", "|" in top and "2 claude *" in top and "* 1" in bar, repr(top) + repr(bar[-20:]))
    finally:
        r11.close()

    # ---- 20: overlays over dense output — the inspector and the gate
    r12 = Rook(cols=100, rows=26, tag="over", attach=["attach", "--space", "main"])
    try:
        r12.keys("seq 1 400\r", settle=0.8)
        r12.keys("`i", settle=0.5)
        r12.snap("20-inspector")
        body = "\n".join(r12.lines())
        check("the pane inspector is a bounded elevated box over the output", "┤ inspector" in body and "you — nobody claims this pane" in body)
        r12.keys("x", settle=0.3)
        pid = r12.state()["focus"]["pane"]
        r12.rook("own", str(pid), "main"); r12.keys("z", settle=0.5)
        r12.snap("20-gate")
        check("the gate is one elevated row with the attention mark, the actor, the moves", "! main owns input" in "\n".join(r12.lines()) and "request handoff" in "\n".join(r12.lines()))
        r12.keys("T", settle=0.3)
    finally:
        r12.close()

    # ---- 21: a split, human focus left, a background agent right, and what home makes of it
    r13 = Rook(cols=110, rows=24, tag="split", attach=["attach", "--space", "main"])
    try:
        r13.keys("`v", settle=0.4)
        r13.keys("exec claude -c 'while :; do echo working; sleep 1; done'\r", settle=2.6)
        r13.keys("`h", settle=0.4)
        r13.keys("echo mine\r", settle=0.4)
        r13.snap("21-split")
        top, bar = r13.lines()[0], r13.lines()[-1]
        check("split: the bar says you drive the shell, the tab says the agent works", "you ▸ bash" in bar and "◐" in top, repr(bar[:30]) + repr(top[:40]))
        r13.keys("`o", settle=0.5)
        r13.snap("21-split-home")
        lines = r13.lines()
        N, I = nav(lines), insp(lines)
        check("home lists the agent rook found producing as one quiet row, and the inspector says what it can and cannot know", group(N, "in progress")[0].startswith("◐ claude at work") and "rook can say only what it sees" in flat(I) and "its pane claude" in flat(I) and "goal unknown" not in flat(I), (group(N, "in progress"), [l for l in I if l.strip()][:5]))
    finally:
        r13.close()

    # ---- 28: the companion's own terminal, hosted in her panel
    #
    # The default arrangement now: rook draws one header row and hands
    # the rest to `[companion] chat`. What is checked here is only what
    # is rook's — the geometry the program was given, who has the
    # keyboard, which of the four motions rook spends and which fall
    # through — because everything inside those rows is mote's and
    # rook has no business having an opinion about it.
    r14 = Rook(cols=140, rows=32, tag="chat", chat=True)
    try:
        build_fixture(r14)
        r14.home()
        r14.keys("`t", settle=1.6)
        r14.snap("28-chat")
        lines = r14.lines()
        V = vera(lines)
        st = r14.state()
        pid = st["root"]["vera"]["pane"]
        pane = [p for p in st["panes"] if p["id"] == pid]
        check("prefix-t hosts her terminal in the panel: rook's header, then the program",
              st["root"]["vera"]["open"] and any("✦ vera" in l for l in V[:2]) and any("vera chat" in l for l in V), V[:4])
        check("the state feed names the pane it runs in, and the companion reads as open and in front of you",
              pid is not None and len(pane) == 1 and pane[0]["rect"] is None
              and st["companion"]["open"] and st["companion"]["visible"] and st["companion"]["focused"]
              and any(c["pane"] == pid and c["place"] == "vera" and c["window"] is None and c["workspace"] == ""
                      for c in st["companion"]["panes"]),
              (pid, st["companion"]))
        said = [l for l in V if l.strip().startswith("vera chat ")]
        check("the program was given exactly the rows rook drew it into, and says so itself",
              said and said[0].split()[2] == "%dx%d" % (pane[0]["cols"], pane[0]["rows"]), (said[:1], pane[0]["cols"], pane[0]["rows"]))

        # keys: the box is the program's, and rook keeps no draft
        r14.keys("hi", settle=0.4)
        r14.snap("28-chat-typing")
        V = vera(r14.lines())
        check("typing goes into the program's box, and rook holds no draft of its own",
              any(l.strip().startswith("> hi") for l in V) and not r14.state()["root"]["draft"], [l for l in V if l.strip()][-3:])

        # Ctrl-j is mote's newline and has nowhere to walk: it falls through
        r14.keys("\x0a", settle=0.4)
        V = vera(r14.lines())
        check("Ctrl-j has no region below it, so the byte is the program's — its newline",
              any("0a" in l for l in V if l.strip().startswith("keys")), [l for l in V if l.strip().startswith("keys")])

        # Ctrl-h has a region to the left: rook spends it
        r14.keys("\x08", settle=0.4)
        check("Ctrl-h walks out of her panel into the inspector, and does not reach the program",
              r14.state()["root"]["region"] == "insp" and not any("08" in l for l in vera(r14.lines()) if l.strip().startswith("keys")),
              (r14.state()["root"]["region"], [l for l in vera(r14.lines()) if l.strip().startswith("keys")]))

        # dismissed and summoned again: the same program, still holding it
        r14.keys("`t`t", settle=0.8)
        V = vera(r14.lines())
        check("dismissed and summoned again it is the same program, with what was typed still in the box",
              any(l.strip().startswith("> hi") for l in V) and r14.state()["root"]["vera"]["pane"] == pid,
              [l for l in V if l.strip()][-3:])

        # pinned on a glass wide enough for three columns, and the pty
        # follows the panel: a resize the program hears is proof rook
        # sized the pty and did not merely paint it smaller.
        was = (pane[0]["cols"], pane[0]["rows"])
        r14.keys("`T", settle=0.6)
        r14.resize(200, 40)
        r14.snap("28-chat-pinned")
        lines = r14.lines()
        V = vera(lines)
        pinned = [p for p in r14.state()["panes"] if p["id"] == pid][0]
        said = [l for l in V if l.strip().startswith("vera chat ")]
        check("pinned and widened, the pty follows the panel — the program says the new size itself",
              r14.state()["root"]["vera"]["pinned"] and len(dividers(lines)) == 2
              and (pinned["cols"], pinned["rows"]) != was
              and said and said[0].split()[2] == "%dx%d" % (pinned["cols"], pinned["rows"]),
              (said[:1], was, (pinned["cols"], pinned["rows"])))

        # from a space: the same pane, over the panes, holding the keys.
        # Ctrl-h first: while she has the keyboard, `:go` would be typed
        # into her box — which is the point of the whole change.
        r14.keys("\x08", settle=0.3)
        r14.enter("api")
        r14.keys("`t", settle=0.8)
        r14.snap("28-chat-space")
        V = vera(r14.lines())
        st = r14.state()
        check("in a space it is the same terminal over the panes, holding the keys",
              st["root"]["vera"]["keys"] and any("vera chat" in l for l in V)
              and st["root"]["vera"]["pane"] == pid, V[:3])
        r14.keys("\x08", settle=0.5)
        check("and Ctrl-h gives the keys back to the panes", not r14.state()["root"]["vera"]["keys"])
    finally:
        r14.close()

    # ---- 29: a chat that will not start
    r15 = Rook(cols=110, rows=26, tag="broken", chat="vera-broken")
    try:
        r15.keys("`t", settle=1.2)
        panes_a = len(r15.state()["panes"])
        r15.settle(1.2)
        st = r15.state()
        r15.snap("29-chat-broken")
        V = vera(r15.lines())
        check("a chat that quits is not started again on every frame, and the panel is rook's own surface",
              st["root"]["vera"]["pane"] is None and len(st["panes"]) == panes_a
              and any("Ask vera" in l for l in V), (st["root"]["vera"], len(st["panes"]), panes_a))
        check("and what it managed to say is in the thread, so the reason is not lost",
              "cannot reach verad" in flat(V), flat(V)[:200])
        # asking again is a person asking, and starts one: it dies
        # again, and says so again — a second turn, not a hundred
        turns = r15.state()["root"]["turns"]
        r15.keys("`t", settle=0.4)
        r15.keys("`t", settle=1.6)
        after = r15.state()
        check("prefix-t at her is the retry, and one asking is one attempt",
              after["root"]["turns"] == turns + 1 and after["root"]["vera"]["pane"] is None,
              (turns, after["root"]["turns"], after["root"]["vera"]["pane"]))
    finally:
        r15.close()

    print("frames in", OUT)
    if fails:
        print("FAILED:", ", ".join(fails))
        sys.exit(1)
    print("all good")


if __name__ == "__main__":
    main()
