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
  case "$*" in
    *deploy*) printf '%s\n' '{"intent":"deploy the api from its current branch","plan":["run the tests in api","tag the release","roll it out to staging"],"space":"api","task":"t4","actions":[{"label":"start an agent on the deploy","run":"push-t4 && echo started deploy-agent in api"},{"label":"open the runbook","run":"echo runbook: docs/deploy.md"}]}' ;;
    *long*) printf 'This is a long answer to a long question, and it keeps going so that the thread has to wrap it across several lines of the conversation region without losing a word of it, because a reply that is cut short is a reply that was not given; the second sentence is here so that there are two, and the third is short.\n' ;;
    *) printf 'Two things are running: the auth fix in api and the deploy plan in vera.\nThe deploy plan is waiting on you.\n' ;;
  esac
  exit 0
fi
exec "$ROOK_FIXTURE_LIB/vera" "$@"
"""

# The rail as the fixture pushes it, and as the fake vera's confirmed
# action pushes it back with one more task: the card the conversation
# is about, sharing its id (`t4`) with the plan turn.
RAIL = [
    {"id": "t1", "title": "Deploy plan", "subtitle": "3 approvals", "state": "waiting", "workspace": "vera", "actor": "main", "event": "asked which region first"},
    {"id": "t2", "title": "Fix flaky auth", "subtitle": "attempt 2", "state": "working", "workspace": "api", "actor": "codex", "event": "re-running the revoked-session test"},
    {"id": "t3", "title": "Rotate the signing key", "state": "done", "workspace": "api", "result": "PR #212 merged"},
]
T4_WORKING = {"id": "t4", "title": "Deploy api to staging", "state": "working", "workspace": "api", "actor": "claude", "event": "running the tests"}
T4_DONE = {"id": "t4", "title": "Deploy api to staging", "state": "done", "workspace": "api", "actor": "claude", "result": "staging is on 1.4.2"}


def rail_frame(items):
    return json.dumps({"v": 1, "op": "items.push", "params": {"surface": "agents", "items": items}})


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
        # `rook` for the fake vera's actions: the engine, verbatim
        with open(self.root + "/bin/rook", "w") as f:
            f.write('#!/bin/sh\nexec "%s" "$@"\n' % ENGINE)
        os.chmod(self.root + "/bin/rook", 0o755)
        with open(self.root + "/lib/with-t4.json", "w") as f:
            f.write(rail_frame(RAIL + [T4_WORKING]) + "\n")
        # what the fake vera's first action runs: one more task on the rail
        with open(self.root + "/bin/push-t4", "w") as f:
            f.write('#!/bin/sh\nexec "%s" side - < "%s/lib/with-t4.json" >/dev/null\n' % (ENGINE, self.root))
        os.chmod(self.root + "/bin/push-t4", 0o755)
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
    r.rook("side", "-", stdin=rail_frame(RAIL) + "\n")
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


MODULES = ("needs you", "in progress", "recent", "spaces")


def right(lines, top):
    """The dashboard's rows, past the divider."""
    x = top.rindex("│") if "│" in top else None
    return [l[x + 1:].rstrip() if x is not None and len(l) > x else "" for l in lines]


def left(lines, top):
    """The conversation's rows, before the divider, past the dock."""
    x = top.rindex("│") if "│" in top else len(top)
    return [slot_of(l[:x]).rstrip() for l in lines]


def module(rows, name):
    """The rows under a dashboard module header, up to the next, with
    the edge, the marker and the age taken off, so a check reads the
    words."""
    out, on = [], False
    for l in rows[1:-1]:
        s = l.strip()
        is_header = any(s.startswith(h + " ") or s == h for h in MODULES) and not l.startswith("     ")
        if on and is_header:
            break
        if is_header and s.startswith(name):
            on = True
            continue
        if on and s:
            s = s.lstrip("▎▸| ").strip()
            s = re.sub(r"\s{2,}\d+[smhd]$", "", s)
            out.append(s)
    return out


def cell(r, y, x):
    return r.screen.buffer[y][x]


def main():
    if not os.path.exists(ENGINE):
        sys.stderr.write("altitude-fixture: build the engine first (make -C mux build)\n")
        sys.exit(2)

    # ---- the representative state, from home. 160 columns: the global
    # pin dock keeps its 40% at home (it never resizes), and both
    # regions should still read whole beside it
    r = Rook(cols=200, rows=44)
    try:
        ids = build_fixture(r)
        st = r.state()
        sizes_before = {p["id"]: (p["cols"], p["rows"]) for p in st["panes"]}
        r.settle(0.3)

        # 01: home, busy
        r.snap("01-home")
        lines = r.lines()
        top, bar = lines[0], lines[-1]
        L, R = left(lines, lines[1]), right(lines, lines[1])
        slot = slot_of(top)
        check("plain rook lands at home: scope root, view home, composer focused, wide", st["scope"] == "root" and st["root"]["view"] == "home" and st["root"]["region"] == "composer" and st["root"]["wide"], str(st.get("root")))
        check("the scope slot is the system's chip, then the summary, no corner", slot.startswith("  rook  │ ") and "4 spaces · 2 agents working · 2 need you" in slot and "esc" not in top, repr(slot[:60]))
        check("the system's chip is the accent fill", chip_bg(r, top, "rook") == ACCENT, chip_bg(r, top, "rook"))
        check("two regions: the conversation left, the dashboard right, one quiet divider", L[1].startswith("  ✦ vera · ready") and R[1].strip().startswith("now") and lines[10].count("│") == 1, (L[1], R[1]))
        check("the composer is at the foot of the conversation, above the calm bar", "› Ask vera…" in L[-3] and "↵ sends · / find · : command · ⇥ dashboard" in L[-2], (L[-3], L[-2]))
        check("no field at the top of the screen", "›" not in L[1] and "›" not in L[2] and "›" not in L[3])
        check("the thread holds rook's notes from the rail — what began, what needs you — and nothing invented", any("Deploy plan needs you · asked which region first" in l for l in L) and any("Fix flaky auth began in api · codex" in l for l in L) and not any("finished" in l for l in L), [l for l in L if "·" in l][:4])
        check("the dashboard header carries the attention count", "now · ! 2 need you" in R[1], R[1])
        needs = module(R, "needs you")
        check("needs you: the bell as a card, the producer's ask as a card, the strongest first", needs[0] == "! rang the bell" and "api · bash · unread" in needs[1] and "in server, nobody was" in needs[2] and any(l.startswith("! Deploy plan") for l in needs) and any("vera · main · needs you" in l for l in needs), needs)
        active = module(R, "in progress")
        check("in progress: one card per task, by goal, with space, actor, state and the current step", active[0] == "◐ Fix flaky auth" and "api · codex · working" in active[1] and "re-running the revoked-session test" in " ".join(active[2:]), active)
        check("no agent a producer claims is a card of its own, and no idle agent is", not any("at work" in l for l in R))
        recent = module(R, "recent")
        check("recent: one flat line with the result", recent == ["✓ Rotate the signing key · PR #212 merged"], recent)
        spaces = module(R, "spaces")
        check("spaces: compact rows with tabs and marks, never the task's title again", len(spaces) == 4 and spaces[0].startswith("rook") and any(l.startswith("vera") and "deploy · main ◐" in l and "Deploy plan" not in l for l in spaces), spaces)
        check("the attention edge marks every needs-you card row", all(cell(r, y, lines[1].rindex("│") + 3).data == "▎" for y, l in enumerate(lines) if "rang the bell" in l or "nobody was looking" in l), "")
        check("nothing was resized to paint home", {p["id"]: (p["cols"], p["rows"]) for p in r.state()["panes"]} == sizes_before)
        check("the calm bar says rook · home, and counts the world", bar.startswith(" rook · home") and "◐ 2" in bar and "!2" in bar and "⊕g 1" in bar, repr(bar))
        r.keys("\x1b", settle=0.3)
        check("esc at home stays at home", r.state()["scope"] == "root")

        # 02: a request, a reflection, an approval that becomes a card
        r.keys("deploy the api\r", settle=0.3)
        st2 = r.state()
        check("bare text goes to vera, and is a turn in the thread", st2["root"]["ask"] in ("running", "replied") and st2["root"]["turns"] >= 1, st2["root"])
        r.settle(1.4)
        r.snap("02-ask")
        lines = r.lines()
        L, R = left(lines, lines[1]), right(lines, lines[1])
        body = "\n".join(L)
        check("the thread: your turn, then her reflection as a block — intent, plan, and the actions with their state",
              any(l.strip().startswith("you deploy the api") for l in L) and "deploy the api from its current branch" in body and "1. run the tests in api" in body and "3. roll it out to staging" in body and "◌ start an agent on the deploy" in body and "needs you · ↵ on its card" in body, [l for l in L if l.strip()][:12])
        plan_y = [i for i, l in enumerate(lines) if "1. run the tests in api" in l][0]
        you_y = [i for i, l in enumerate(lines) if "you deploy the api" in l][0]
        check("the plan is a tinted block, the prose is not", cell(r, plan_y, lines[plan_y].index("1. run") - 1).bg == RAISED and cell(r, you_y, lines[you_y].index("you deploy") + 8).bg == CHROME, (cell(r, plan_y, lines[plan_y].index("1. run") - 1).bg, cell(r, you_y, lines[you_y].index("you deploy") + 8).bg))
        check("her status says she is waiting for you", "✦ vera · ! waiting for you" in L[1], L[1])
        needs = module(R, "needs you")
        check("the same actions are approval cards, first under needs you, with the command they would run", needs[0] == "◌ start an agent on the deploy" and needs[1].startswith("$ push-t4") and needs[2] == "◌ open the runbook", needs[:3])
        check("the bar says vera answered", "vera answered" in lines[-1], repr(lines[-1]))
        # ⇥ to the dashboard: the first card is the approval; ↵ runs it
        r.keys("\t", settle=0.3)
        st3 = r.state()
        r.snap("02-ask-dash")
        R = right(r.lines(), r.lines()[1])
        check("tab moves focus to the dashboard, on the first approval, which says what enter does", st3["root"]["region"] == "dash" and any("↵ runs" in l for l in R[:8]), R[:8])
        r.keys("\r", settle=1.5)
        r.snap("02-ask-confirmed")
        lines = r.lines()
        L, R = left(lines, lines[1]), right(lines, lines[1])
        body = "\n".join(L)
        check("the confirmed action ran: a receipt in the thread, the action marked in the plan", "✓ start an agent on the deploy · started deploy-agent in api" in body and any(l.strip().lstrip("▸").strip().startswith("✓") and "ran start an agent on the deploy" in l for l in L), [l for l in L if "start an agent" in l])
        active = module(R, "in progress")
        check("its work is a new card in progress, from the rail — not a second copy of anything", any("Deploy api to staging" in l for l in active) and sum(1 for l in R if "Deploy api to staging" in l) == 1 and any("api · claude · working" in l for l in active), active)
        needs = module(R, "needs you")
        check("the other action is still an approval; the ran one is gone from needs you", any("open the runbook" in l for l in needs) and not any("start an agent" in l for l in needs), needs)
        check("the note that it began is in the thread, about the same task", any("Deploy api to staging began in api · claude" in l for l in L), [l for l in L if "began" in l])
        # the card and the plan share t4: selecting the card lights the plan turn
        r.keys("\x1b[B", settle=0.2); r.keys("\x1b[B", settle=0.2); r.keys("\x1b[B", settle=0.3)
        lines = r.lines()
        R = right(lines, lines[1])
        selected = [l for l in R if l.strip().startswith("▸")]
        found_t4 = any("Deploy api to staging" in l for l in selected)
        if not found_t4:
            for _ in range(4):
                r.keys("\x1b[B", settle=0.2)
                R = right(r.lines(), r.lines()[1])
                if any("Deploy api to staging" in l for l in R if l.strip().startswith("▸")):
                    found_t4 = True
                    break
        r.snap("02-ask-linked")
        lines = r.lines()
        L = left(lines, lines[1])
        check("selecting the task's card highlights the turn about it in the thread", found_t4 and any(l.strip().startswith("▸") for l in L), [l for l in L if "▸" in l])

        # 24: completion — the rail says t4 finished
        r.rook("side", "-", stdin=rail_frame(RAIL + [T4_DONE]) + "\n")
        r.settle(0.6)
        r.snap("24-completed")
        lines = r.lines()
        L, R = left(lines, lines[1]), right(lines, lines[1])
        check("completion: the card moved to recent with its result, and only one card says so", any("✓ Deploy api to staging · staging is on 1" in l for l in module(R, "recent")) and not any("Deploy api to staging" in l for l in module(R, "in progress")) and sum(1 for l in R if "Deploy api to staging" in l) == 1, module(R, "recent"))
        check("…and the thread has the linked outcome, once", sum(1 for l in L if "Deploy api to staging finished · staging is on 1.4.2" in l) == 1, [l for l in L if "finished" in l])
        r.keys("\x1b", settle=0.3)
        check("esc from the dashboard returns focus to the composer", r.state()["root"]["region"] == "composer")

        # 03: words, and the thread as a conversation
        r.keys("what is running\r", settle=1.5)
        r.snap("03-conversation")
        lines = r.lines()
        L = left(lines, lines[1])
        body = "\n".join(L)
        check("a reply in words is her turn, under yours, oldest first", body.index("you deploy the api") < body.index("you what is running") < body.index("Two things are running"), "")
        check("every turn carries a quiet age at its edge", sum(1 for l in L if l.rstrip().endswith("s") and ("you" in l or "✦" in l)) >= 2, [l for l in L if "you" in l][:3])

        # 22: focus states — thread, composer, dashboard
        r.keys("\x1b[A", settle=0.3)
        st22 = r.state()
        r.snap("22-focus-thread")
        L = left(r.lines(), r.lines()[1])
        check("up from an empty composer walks into the thread, on the latest turn", st22["root"]["region"] == "thread" and any(l.strip().startswith("▸") for l in L), [l for l in L if "▸" in l])
        r.keys("\x1b[A", settle=0.2); r.keys("\x1b[A", settle=0.2)
        r.keys("\x1b[B", settle=0.2); r.keys("\x1b[B", settle=0.2); r.keys("\x1b[B", settle=0.3)
        check("down past the latest turn is the composer again", r.state()["root"]["region"] == "composer")
        r.keys("half a thought", settle=0.3)
        r.keys("\t", settle=0.3)
        r.snap("22-focus-dash")
        check("tab keeps the draft and moves to the dashboard", r.state()["root"]["region"] == "dash" and r.state()["root"]["draft"], str(r.state()["root"]))
        r.keys("x", settle=0.3)
        check("typing from the dashboard goes to the composer, never into a shortcut", r.state()["root"]["region"] == "composer" and "half a thoughtx" in "\n".join(left(r.lines(), r.lines()[1])[-4:]), left(r.lines(), r.lines()[1])[-3])
        r.keys("\x7f", settle=0.2)

        # 04: find
        r.keys("\x15", settle=0.2)
        r.keys("/serv", settle=0.4)
        r.snap("04-find")
        lines = r.lines()
        body = "\n".join(lines)
        check("/ takes the canvas over as one list: the tab by name", "api › server" in body and "matches" in body, "")
        check("the bar says find", " rook · find" in lines[-1], repr(lines[-1][:30]))
        r.keys("\x1b", settle=0.3)
        check("esc clears the query and is the cockpit again", r.state()["scope"] == "root" and "› Ask vera" in "\n".join(left(r.lines(), r.lines()[1])[-4:]))

        # 05: command
        r.keys(":", settle=0.4)
        r.snap("05-command")
        body = "\n".join(r.lines())
        check(": completes every command, now and vera among them", ":go " in body and ":home" in body and ":orbit" in body and ":now" in body and ":vera" in body)
        r.keys("\x1b", settle=0.3)

        # 06: drill from a card into its exact pane
        r.keys("`a", settle=0.4)
        R = right(r.lines(), r.lines()[1])
        check("prefix-a lands the cursor on the first card in progress", r.state()["root"]["region"] == "dash" and any(l.strip().startswith("▸ ◐ Fix flaky auth") for l in R), [l for l in R if "▸" in l])
        r.keys("\r", settle=0.5)
        r.snap("06-drill")
        st6 = r.state()
        top = r.lines()[0]
        check("↵ on the card enters api at the agent's pane", st6["scope"] == "space" and st6["focus"]["pane"] == ids["codex"] and slot_of(top).startswith("  api  │"), (st6["scope"], st6["focus"], repr(top[:30])))

        # 07: return, with the cockpit as it was
        r.keys("`o", settle=0.5)
        r.snap("07-return")
        st7 = r.state()
        check("prefix-o is home again, the dashboard still focused on its card, the thread intact", st7["scope"] == "root" and st7["root"]["region"] == "dash" and st7["root"]["turns"] >= 6, str(st7["root"]))
        check("the space kept running, unresized", {p["id"]: (p["cols"], p["rows"]) for p in st7["panes"]}[ids["codex"]] == sizes_before[ids["codex"]])
        r.keys("\x1b", settle=0.3)
        r.keys("half a thought", settle=0.3)
        r.keys("\t", settle=0.2)
        for _ in range(12):
            r.keys("\x1b[B", settle=0.1)
        R = right(r.lines(), r.lines()[1])
        on_space = any(l.strip().startswith("▸ vera") or l.strip().startswith("▸ infra") or l.strip().startswith("▸ rook") for l in R)
        r.keys("\r", settle=0.5)
        check("↵ on a space row enters it", r.state()["scope"] == "space", (on_space, r.state()["scope"]))
        r.keys("`o", settle=0.5)
        check("the draft survived the round trip", r.state()["root"]["draft"] and "half a thought" in "\n".join(left(r.lines(), r.lines()[1])[-4:]), str(r.state()["root"]))
        r.keys("\x15", settle=0.2)
        r.keys("\x1b", settle=0.3)

        # 08: orbit, a subview, and back to the same home
        r.keys("`s", settle=0.8)
        r.snap("08-orbit")
        lines = r.lines()
        slot = slot_of(lines[0])
        check("orbit is named in the scope bar, esc rook in the corner, figures on the canvas", slot.startswith("  rook  │  orbit ") and "esc rook" in lines[0] and "┌┤" in "\n".join(lines), repr(slot[:50]))
        r.keys("\x1b", settle=0.4)
        st8 = r.state()
        check("esc from orbit is the cockpit again, with its thread", st8["root"]["view"] == "home" and st8["root"]["turns"] >= 6 and "› Ask vera" in "\n".join(left(r.lines(), r.lines()[1])[-4:]), str(st8["root"]))

        # 09: inside a space
        r.enter("vera")
        r.snap("09-space")
        lines = r.lines()
        top, bar = lines[0], lines[-1]
        slot = slot_of(top)
        check("in a space the scope slot is the space's chip, then the tabs, then the way out", slot.startswith("  vera  │ ") and chip_bg(r, top, "vera") == RAISED and "`o rook" in top, repr(slot[:40]))
        cells = selected_tab_cells(r, top, "deploy")
        check("the selected tab's index, label and mark share one fill and one underline", all(c.bg == RAISED and c.underscore for c in cells), "")
        check("the calm bar names actor ▸ tool and counts the world", "main ▸ claude" in bar and "◐ 2" in bar and "!2" in bar, repr(bar))
        r.home()

        # 10: narrow — one view at a time, with the switcher
        r.resize(100, 30)
        r.snap("10-narrow-vera")
        lines = r.lines()
        L = [slot_of(l) for l in lines]
        st10 = r.state()
        check("narrow glass shows one view: vera first, with the switcher and the attention badge on now", not st10["root"]["wide"] and "vera" in L[1] and re.search(r"now !\s*\d", L[1]) and "│" not in "".join(lines[3:6]).replace("┃", ""), L[1])
        check("the composer is still at the foot", "› Ask vera" in "\n".join(L[-4:]))
        r.keys("\t", settle=0.4)
        r.snap("10-narrow-now")
        lines = r.lines()
        L = [slot_of(l) for l in lines]
        check("tab switches to now: the same modules, cards, selection", r.state()["root"]["region"] == "dash" and "needs you" in "\n".join(L) and "in progress" in "\n".join(L) and any("▸" in l for l in L), L[1])
        r.keys("\t", settle=0.3); r.keys("\t", settle=0.3)
        check("tab again is vera again, the thread scrolled to its foot", r.state()["root"]["region"] == "composer" and "› Ask vera" in "\n".join([slot_of(l) for l in r.lines()][-4:]))
        r.keys("\x1b", settle=0.3)
        r.keys("`s", settle=0.8)
        r.snap("10-narrow-orbit")
        lines = r.lines()
        check("narrow orbit is the ledger, and says so", "ledger" in lines[-1] and "ledger" in lines[0], repr(lines[-1]) + repr(lines[0]))
        r.keys("\x1b", settle=0.3)

        # 11: wide
        r.resize(220, 50)
        r.snap("11-wide")
        lines = r.lines()
        L, R = left(lines, lines[1]), right(lines, lines[1])
        region_w = 220 - lines[1].index("┃") - 1
        check("wide: the split holds its ratio, the cards do not stretch into boxes", abs((lines[1].rindex("│") - lines[1].index("┃") - 1) - region_w * 62 // 100) <= 1 and any(l.strip() == "◐ Fix flaky auth" for l in R), (lines[1].rindex("│"), lines[1].index("┃"), region_w))
    finally:
        r.close()

    # ---- 26: the current-state equivalent — two spaces, one task, two idle claude panes
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
        r0.snap("26-one-task")
        lines = r0.lines()
        R = right(lines, lines[1])
        check("one task, two idle claude panes: one card, no phantom tasks, no duplicate space row", module(R, "in progress")[0] == "◐ Fix flaky auth" and len(module(R, "in progress")) == 3 and "needs you" not in "\n".join(R) and not any("at work" in l or "goal unknown" in l for l in R) and any(l.startswith("api") and "codex ◐ · claude" in l for l in module(R, "spaces")), R[:14])
    finally:
        r0.close()

    # ---- 23: needs you — an approval, a failed task, a blocked task, prioritised
    r1 = Rook(cols=160, rows=40, tag="needs")
    try:
        r1.rook("new", "-q", "api"); r1.settle(0.4)
        r1.rook("side", "-", stdin=rail_frame([
            {"id": "b1", "title": "Migrate the sessions table", "state": "waiting", "workspace": "api", "actor": "claude", "event": "needs a go-ahead before it drops the old index"},
            {"id": "f1", "title": "Backfill the audit log", "state": "failed", "workspace": "api", "actor": "codex", "event": "exit 1 · disk full on the runner"},
            {"id": "w1", "title": "Write the release notes", "state": "working", "workspace": "main", "actor": "claude", "event": "reading the last twenty commits"},
        ]) + "\n"); r1.settle(0.5)
        r1.keys("deploy it\r", settle=1.5)
        r1.snap("23-needs-you")
        lines = r1.lines()
        L, R = left(lines, lines[1]), right(lines, lines[1])
        needs = module(R, "needs you")
        check("needs you: the approvals first, then the blocked and the failed, each with its reason", needs[0].startswith("◌ start an agent") and any(l.startswith("! Migrate the sessions table") for l in needs) and any(l.startswith("✕ Backfill the audit log") for l in needs) and any("disk full on the runner" in l for l in needs), needs)
        check("the header counts them", "now · ! 4 need you" in R[1], R[1])
        check("a failed task is a card with the failed mark, a blocked one with attention; neither looks like an idle pane", any(l.startswith("✕") for l in needs) and any(l.startswith("!") for l in needs))
    finally:
        r1.close()

    # ---- 27: the breakpoint, just above and just below
    for cols, wide in ((85, True), (84, False)):
        r2 = Rook(cols=cols, rows=30, tag="bp%d" % cols)
        try:
            r2.rook("side", "-", stdin=rail_frame([RAIL[1]]) + "\n"); r2.settle(0.4)
            r2.snap("27-breakpoint-%d" % cols)
            st = r2.state()
            lines = r2.lines()
            check("at %d columns the layout is %s" % (cols, "split" if wide else "one view"), st["root"]["wide"] == wide and (("│" in lines[5]) == wide), (st["root"]["wide"], lines[1]))
        finally:
            r2.close()

    # ---- 12: quiet — nothing running, one finished thing, some history
    r3 = Rook(cols=120, rows=30, tag="quiet")
    try:
        r3.keys(":go main\r", settle=0.4)
        r3.keys("echo hello from earlier\r", settle=0.4)
        r3.home()
        r3.rook("side", "-", stdin=rail_frame([{"id": "d1", "title": "Tidy the changelog", "state": "done", "workspace": "main", "result": "3 entries"}]) + "\n")
        r3.settle(0.5)
        r3.snap("12-quiet")
        lines = r3.lines()
        L, R = left(lines, lines[1]), right(lines, lines[1])
        body = "\n".join(R)
        check("quiet home: no needs-you or in-progress module reserved, one recent result, the space with its age", "needs you" not in body and "in progress" not in body and "✓ Tidy the changelog · 3 entries" in body and any(l.startswith("main") and "bash" in l for l in module(R, "spaces")), R[:10])
        check("the conversation side is honest and empty", "say what should happen" in "\n".join(L) and "1 space · all quiet" in lines[0])
        check("nothing is invented to look alive", "◐" not in body and "!" not in body)
    finally:
        r3.close()

    # ---- 25: long content — long titles, a long message, many cards
    r4 = Rook(cols=130, rows=26, tag="long")
    try:
        items = [{"id": "l%d" % i, "title": "A task with a deliberately long goal that says exactly what it means to do number %d" % i, "state": "working", "workspace": "main", "actor": "claude", "event": "step %d of a long plan whose current step is also described at some length" % i} for i in range(6)]
        r4.rook("side", "-", stdin=rail_frame(items) + "\n"); r4.settle(0.4)
        r4.keys("a long question about what is going on and whether the long plan is long\r", settle=1.6)
        r4.snap("25-long")
        lines = r4.lines()
        L, R = left(lines, lines[1]), right(lines, lines[1])
        body = "\n".join(L)
        flat = re.sub(r"\s+", " ", " ".join(re.sub(r"\s+\d+[smhd]$", "", l.rstrip()) for l in L))
        check("a long reply wraps inside the conversation, whole", "keeps going so that the thread has to wrap it" in flat and "the third is short." in flat and "whether the long plan is long" in flat and not any(len(l) > 130 for l in lines), flat[-160:])
        check("long titles are cut, not wrapped into boxes; the dashboard says how many more", any("A task with a deliberately long" in l for l in R) and any("more" in l for l in R), [l for l in R if "more" in l])
        r4.keys("\t", settle=0.3)
        for _ in range(8):
            r4.keys("\x1b[B", settle=0.1)
        r4.snap("25-long-scrolled")
        R = right(r4.lines(), r4.lines()[1])
        check("the dashboard scrolls to keep the selected card in view, independently of the thread", any(l.strip().startswith("▸") for l in R), [l for l in R if "▸" in l])
    finally:
        r4.close()

    # ---- 13: cold start, vera available
    r5 = Rook(cols=100, rows=24, tag="cold")
    try:
        r5.snap("13-cold")
        st = r5.state()
        body = "\n".join(r5.lines())
        check("cold start lands at home with vera ready", st["scope"] == "root" and "✦ vera · ready" in body and "Ask vera…" in body and "is not on PATH" not in body)
        check("cold start has one space, main, made quietly, and no phantom work", "1 space" in r5.lines()[0] and "nothing running, nothing needs you" in body)
    finally:
        r5.close()

    # ---- 14: cold start, vera unavailable
    r6 = Rook(cols=100, rows=24, tag="offline", vera=False)
    try:
        r6.snap("14-offline")
        body = "\n".join(r6.lines())
        check("without vera the header and the composer say so, and the grammar stays", "✦ vera · ✕ offline — not on PATH" in body and "vera is not on PATH — / find · : command" in body)
        r6.keys("hello there\r", settle=0.5)
        r6.snap("14-offline-asked")
        body = "\n".join(r6.lines())
        check("a request with nobody to send it to is a failed turn, and nothing was sent", "nothing was sent" in body and r6.state()["root"]["ask"] == "offline" and r6.state()["root"]["turns"] == 2)
        r6.keys("/ma", settle=0.4)
        check("find still works offline", "main" in "\n".join(r6.lines()[3:8]))
        r6.keys("\x1b", settle=0.3)
        r6.keys(":go main\r", settle=0.4)
        check("commands still work offline: :go enters the space", r6.state()["scope"] == "space")
        r6.keys("`o", settle=0.3)
        r6.keys("\t", settle=0.3)
        check("the dashboard still works offline", r6.state()["root"]["region"] == "dash")
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
        check("home from it: the system's chip is the accent, and the space is a plain row", chip_bg(r9, lines[0], "rook") == ACCENT and any(l.strip().startswith("rook") for l in right(lines, lines[1])[3:]) and "esc" not in lines[0], repr(lines[0]))
    finally:
        r9.close()

    # ---- 18: the tab component's states, the ladder, global attention inside a space
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
        check("inside a space the bar still counts the attention owed elsewhere", "!1" in bar and "•1" in bar, repr(bar[-30:]))
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
        check("ascii: home draws with ascii glyphs", "> Ask vera" in body and "◐" not in body and "↵" not in body and "⇥" not in body and "✦" not in body, "")
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
        check("the inspector is a bounded elevated box over the output", "┤ inspector" in body and "you — nobody claims this pane" in body)
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
        R = right(lines, lines[1])
        active = module(R, "in progress")
        check("home shows the agent rook found producing as one quiet card, without a goal it does not have", active[0] == "◐ claude at work" and "main · claude · producing" in active[1] and "no task was pushed for it" in " ".join(active[2:]) and "goal unknown" not in "\n".join(R), active)
    finally:
        r13.close()

    print("frames in", OUT)
    if fails:
        print("FAILED:", ", ".join(fails))
        sys.exit(1)
    print("all good")


if __name__ == "__main__":
    main()
