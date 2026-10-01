#!/usr/bin/env python3
"""`rook play`, end to end: a curses program tested the way an agent would.

    make -C mux build && python3 scripts/play-fixture.py

A play session is a rook server of its own with the program under test
in its pane (docs/play.md). This starts one around a small to-do list
and drives it with the verbs a test is made of:

  01-start     a session comes up with its own config — not the
               person's, whatever the environment says — and the program
  02-expect    expect holds or fails with the reason and the screen;
               it retries until the program has caught up
  03-find      text is found at its cell, with how it is drawn
  04-keys      key, then expect, with no sleep between
  05-click     a click lands, in the encoding the program asked for
  06-env       $ROOK_PLAY makes plain `rook` the session's
  07-trace     every acting step is in the trace, with its screen
  08-stop      stop ends it and leaves the trace; a name starts clean

Stdlib only. Exit status 1 when an assertion fails.
"""
import json, os, subprocess, sys, tempfile, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENGINE = os.path.join(REPO, "mux", "zig-out", "bin", "engine")
FRONT = os.path.join(tempfile.mkdtemp(prefix="/tmp/rk-front-"), "rook")
subprocess.run(["go", "build", "-o", FRONT, "./cmd/rook"], cwd=REPO, check=True)

fails = []


def check(name, ok, extra=""):
    print(("PASS  " if ok else "FAIL  ") + name + ("  " + str(extra) if extra and not ok else ""))
    if not ok:
        fails.append(name)


work = tempfile.mkdtemp(prefix="/tmp/rk-play-")
APP = os.path.join(work, "todo.py")
open(APP, "w").write('''import curses, time
ITEMS = ["buy milk", "write tests", "ship it", "\\u65e5\\u672c\\u8a9e item"]
def main(s):
    curses.curs_set(0); s.keypad(True)
    curses.mousemask(curses.ALL_MOUSE_EVENTS)
    curses.start_color(); curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_WHITE, curses.COLOR_BLUE)
    curses.init_pair(2, curses.COLOR_BLACK, curses.COLOR_YELLOW)
    sel, done = 0, set()
    while True:
        h, w = s.getmaxyx()
        s.erase()
        s.addstr(0, 0, (" todo  %d/%d done" % (len(done), len(ITEMS))).ljust(w - 1), curses.color_pair(1) | curses.A_BOLD)
        for i, it in enumerate(ITEMS):
            s.addstr(2 + i, 1, "%s %s" % ("[x]" if i in done else "[ ]", it), curses.color_pair(2) if i == sel else 0)
        s.refresh()
        k = s.getch()
        time.sleep(0.05)   # a program that takes a moment
        if k == ord("q"): break
        if k in (ord("j"), curses.KEY_DOWN): sel = min(sel + 1, len(ITEMS) - 1)
        if k in (ord("k"), curses.KEY_UP): sel = max(sel - 1, 0)
        if k == ord(" "): done ^= {sel}
        if k == curses.KEY_MOUSE:
            try:
                _, mx, my, _, _ = curses.getmouse()
                if 2 <= my < 2 + len(ITEMS): sel = my - 2; done ^= {sel}
            except curses.error: pass
curses.wrapper(main)
''')

# A hostile environment: the person's config seeds a home that runs a
# program, and $ROOK_FRONT_DOOR names some other rook. A session must
# take neither — this once typed a test into somebody's to-do list.
MARK = os.path.join(work, "HOME-RAN")
conf = os.path.join(work, "config", "rook")
os.makedirs(conf)
open(os.path.join(conf, "rook.toml"), "w").write(
    '[home]\n[[home.window]]\nname = "me"\npanes = ["touch %s"]\n' % MARK)
env = dict(os.environ)
for k in ("ROOK_MUX_PANE", "ROOK_MUX_SOCK", "ROOK_PLAY", "ROOK_CONFIG", "TMUX", "TMUX_PANE"):
    env.pop(k, None)
env.update({"ROOK_ENGINE": ENGINE, "XDG_CONFIG_HOME": os.path.join(work, "config"), "ROOK_FRONT_DOOR": "/usr/bin/false"})
NAME = "fx%d" % os.getpid()


def rook(*args, session=True, extra=None):
    e = dict(env)
    if extra:
        e.update(extra)
    argv = [FRONT] + (["play", "-s", NAME] if session else []) + list(args)
    p = subprocess.run(argv, env=e, cwd=work, capture_output=True, text=True, timeout=60)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


try:
    # ---- 01: start
    code, out, err = rook("play", "start", NAME, "--size", "80x20", "--", "python3", APP, session=False)
    check("start prints the session's name", code == 0 and out == NAME, (code, out, err))
    code, out, _ = rook("play", "ls", session=False)
    check("ls lists it", NAME in out and "80x20" in out, out)
    st = json.loads(rook("state")[1])
    check("it is a server of its own, in a space, at the size said", st["scope"] == "space" and st["geometry"] == {"cols": 80, "rows": 20} and len(st["workspaces"]) == 1, (st["scope"], st["geometry"]))
    time.sleep(0.5)
    check("the person's config was not read: their home never ran", not os.path.exists(MARK))
    code, out, err = rook("play", "start", NAME, session=False)
    check("a name that is running is not started twice", code == 1 and "already running" in err, err)

    # ---- 02: expect
    t0 = time.time()
    code, out, err = rook("expect", "0/4 done", "--row", "0")
    check("expect holds once the program is up", code == 0 and out == "" and err == "", (code, out, err))
    code, out, err = rook("expect", "9/4 done", "--timeout", "400")
    check("expect fails with the reason and the screen", code == 1 and "is not on the screen, after 400 ms" in err and "[ ] buy milk" in err, err)
    code, _, err = rook("expect", "0/4 done", "--row", "0", "--bold", "--bg", "#81a2be")
    check("a header is bold on its fill", code == 0, err)
    code, _, err = rook("expect", "buy milk", "--fg", "#ff0000", "--timeout", "300")
    check("drawn otherwise, it says how it is drawn", code == 1 and "not drawn as asked" in err and "bg=" in err, err)
    code, _, err = rook("expect", "--no-text", "Traceback")
    check("--no-text holds when it is absent", code == 0, err)

    # ---- 03: find
    code, out, _ = rook("find", "write tests", "--json")
    m = json.loads(out)
    check("find says the cell and the width", code == 0 and m[0]["x"] == 5 and m[0]["y"] == 3 and m[0]["w"] == 11, m)
    sel = json.loads(rook("find", "buy milk", "--json")[1])[0]
    check("and how it is drawn: the selected row has a fill", sel.get("bg") and not m[0].get("bg"), (sel, m[0]))
    code, out, _ = rook("find", "item", "--json")
    check("text after wide glyphs is at its cell", json.loads(out)[0]["x"] == 12, out)
    code, out, err = rook("find", "nowhere")
    check("find fails when it is nowhere", code == 1 and "not on the screen" in err, (code, err))

    # ---- 04: keys, no sleeps
    stale = 0
    for i in range(1, 4):
        rook("key", ".", "down")
        code, _, err = rook("expect", "[ ] " + ["write tests", "ship it", "日本語 item"][i - 1], "--bg", sel["bg"], "--timeout", "1500")
        stale += code
    check("three arrows, three highlights, each seen by the expect after it", stale == 0, err)
    rook("key", ".", "space")
    code, _, err = rook("expect", "1/4 done", "--row", "0")
    check("space toggles, and the header says so", code == 0, err)

    # ---- 05: click
    code, out, err = rook("click", "ship it")
    check("click finds its text and clicks it", code == 0 and json.loads(out)["y"] == 4, (code, out, err))
    code, _, err = rook("expect", "[x] ship it")
    check("the program took the click", code == 0 and rook("expect", "2/4 done")[0] == 0, err)
    code, _, err = rook("click", "[x]")
    check("text that is there twice is refused, with where", code == 1 and "2 times" in err, err)
    code, _, err = rook("click", "1,2")
    check("a cell clicks too", code == 0 and rook("expect", "[x] buy milk")[0] == 0, err)

    # ---- 06: $ROOK_PLAY
    code, out, err = rook("shot", ".", session=False, extra={"ROOK_PLAY": NAME})
    check("$ROOK_PLAY makes plain rook the session's, and . its pane", code == 0 and out.startswith("todo  3/4 done"), (code, out[:60], err))
    code, _, err = rook("kill", session=False, extra={"ROOK_PLAY": NAME})
    check("kill is not a verb to say inside a session", code == 1 and "play stop" in err, err)
    code, _, err = rook("expect", "x", session=False, extra={"ROOK_PLAY": "nosuch"})
    check("a session that is not there says so", code == 1 and "no session called nosuch" in err, err)

    # ---- the program ends: the shell is still there to read
    rook("key", ".", "q")
    code, _, err = rook("expect", "$", "--no-text", "todo  ")
    check("the program quits to a shell that is still there", code == 0, err)

    # ---- 07: trace
    code, out, err = rook("play", "trace", NAME, session=False)
    page = open(out).read() if code == 0 else ""
    steps = [json.loads(l) for l in open(os.path.join(os.path.dirname(out), "steps.jsonl"))] if code == 0 else []
    verbs = [s["argv"][0] for s in steps]
    check("the trace has every acting step, in order", verbs[:3] == ["start", "run", "expect"] and verbs.count("key") == 5 and verbs.count("click") == 3 and "find" not in verbs and "shot" not in verbs, verbs)
    check("failed steps are marked failed", [s["exit"] for s in steps if s["argv"][:2] == ["expect", "9/4 done"]] == [1] and "exit 1" in page, page[:200])
    check("the page has the screens inline, and says when nothing changed", page.count("data:image/png;base64,") >= 6 and "did not change" in page and "<title>rook play: %s" % NAME in page)

    # ---- 08: stop
    code, out, err = rook("play", "stop", NAME, session=False)
    info = json.loads(out) if code == 0 else {}
    check("stop ends it and says where the trace is", code == 0 and os.path.exists(info.get("trace", "/nonexistent")) and NAME not in rook("play", "ls", session=False)[1], (out, err))
    code, _, err = rook("expect", "x")
    check("a stopped session is gone", code == 1 and "no session called" in err, err)
    code, out, err = rook("play", "start", NAME, "--no-trace", session=False)
    code2, _, err2 = rook("play", "trace", NAME, session=False)
    check("a name starts clean: no trace left from the last run", code == 0 and code2 == 1, (err, err2))
finally:
    rook("play", "stop", NAME, session=False)

print("\n%d failed" % len(fails) if fails else "\nall passed")
sys.exit(1 if fails else 0)
