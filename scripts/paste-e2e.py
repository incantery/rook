#!/usr/bin/env python3
"""Paste, end to end, through a real glass.

The unit tests in server.zig cover the byte routing; this covers the
two things only a running engine can show: that a paste arriving on a
glass's stdin reaches the pane's program byte for byte, and that a
glass is told mode 2004 when it attaches — without which the terminal
never wraps Cmd-V in ESC[200~ … ESC[201~ and the paste comes in as
keystrokes.

    make -C mux build && python3 scripts/paste-e2e.py

Everything runs in a temp HOME with its own socket, config and state,
with `prefix = "`"` — the prefix that made pasted backticks into
commands. The live rook is never touched.
"""
import fcntl, os, pty, select, struct, subprocess, sys, tempfile, termios, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENGINE = os.path.join(REPO, "mux", "zig-out", "bin", "engine")

# In the pane: raw mode, ask for bracketed paste, append every byte
# read to a file the test can compare against what it sent.
PROBE = r'''
import sys, os, tty, termios
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd); tty.setraw(fd)
sys.stdout.write("\x1b[?2004hREADY\r\n"); sys.stdout.flush()
try:
    while True:
        b = os.read(fd, 4096)
        if not b or b"\x03" in b: break
        f = open(GOT, "ab"); f.write(b); f.close()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
'''

fails = []


def check(name, ok, extra=""):
    print(("PASS  " if ok else "FAIL  ") + name + ("  " + extra if extra else ""))
    if not ok:
        fails.append(name)


class Rook:
    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="/tmp/rook-paste")
        self.got = os.path.join(self.root, "got.bin")
        self.probe = os.path.join(self.root, "probe.py")
        with open(self.probe, "w") as f:
            f.write("GOT = %r\n" % self.got + PROBE)
        self.env = dict(os.environ)
        for k in ("ROOK_MUX_PANE", "TMUX", "TMUX_PANE"):
            self.env.pop(k, None)
        self.env.update({
            "ROOK_MUX_SOCK": "/tmp/rook-paste-%d.sock" % os.getpid(),
            "SHELL": "/bin/sh", "HOME": self.root,
            "XDG_STATE_HOME": self.root + "/state",
            "XDG_CONFIG_HOME": self.root + "/config",
            "XDG_DATA_HOME": self.root + "/data",
        })
        for k in ("XDG_STATE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME"):
            os.makedirs(self.env[k], exist_ok=True)
        os.makedirs(self.root + "/.config/rook", exist_ok=True)
        with open(self.root + "/.config/rook/rook.toml", "w") as f:
            f.write('[tmux]\nprefix = "`"\n')
        self.srv = subprocess.Popen([ENGINE, "server"], env=self.env, cwd=self.root,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
        time.sleep(1.0)

    def glass(self):
        mfd, sfd = pty.openpty()
        fcntl.ioctl(sfd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        g = subprocess.Popen([ENGINE], env=self.env, cwd=self.root, stdin=sfd,
                             stdout=sfd, stderr=subprocess.DEVNULL)
        os.close(sfd)
        time.sleep(1.5)
        return mfd, g

    def drain(self, mfd, budget=2.5):
        out, dead = b"", time.time() + budget
        while time.time() < dead:
            r, _, _ = select.select([mfd], [], [], 0.3)
            if not r:
                break
            try:
                out += os.read(mfd, 65536)
            except OSError:
                break
        return out

    def arm(self):
        open(self.got, "wb").close()

    def read(self):
        try:
            with open(self.got, "rb") as f:
                return f.read()
        except FileNotFoundError:
            return b""

    def kill(self):
        subprocess.run([ENGINE, "kill"], env=self.env, capture_output=True, timeout=5)
        try:
            self.srv.wait(timeout=5)
        except Exception:
            self.srv.kill()


def main():
    if not os.path.exists(ENGINE):
        sys.exit("no engine at %s — run `make -C mux build` first" % ENGINE)
    r = Rook()
    try:
        mfd, g = r.glass()
        r.drain(mfd)
        os.write(mfd, ("python3 -u %s\r" % r.probe).encode())
        time.sleep(2.0)
        first = r.drain(mfd)
        check("a glass is told mode 2004 when the pane asks for it",
              b"\x1b[?2004h" in first)

        def paste(name, payload):
            r.arm()
            wrapped = b"\x1b[200~" + payload + b"\x1b[201~"
            os.write(mfd, wrapped)
            time.sleep(1.5)
            r.drain(mfd)
            got = r.read()
            check(name, got == wrapped, "" if got == wrapped else repr(got[:120]))

        paste("a plain paste arrives whole", b"hello world")
        # the bug: the backticks armed the prefix, `b` was spent on a
        # command, and the ESC of the closing marker went the same way
        paste("backticks in a paste are text", b"```bash\nls\n```")
        paste("newlines in a paste are text", b"line one\nline two\n")
        paste("a paste is not read for keys",
              b"\x1b[<0;9;9M a ` and a \x02 and \x1b[200~")
        paste("a paste longer than one read arrives whole", b"x" * 9000)

        def typed(name, keys, want):
            r.arm()
            os.write(mfd, keys)
            time.sleep(1.0)
            r.drain(mfd)
            got = r.read()
            check(name, got == want, "" if got == want else repr(got[:60]))

        typed("plain typing still arrives", b"hello", b"hello")
        typed("arrow keys still pass through", b"\x1b[A\x1bOB", b"\x1b[A\x1bOB")
        typed("a double-tapped prefix still types one backtick", b"``", b"`")
        typed("a mouse report is still the server's, not the pane's",
              b"\x1b[<0;5;5M\x1b[<0;5;5m", b"")

        # detach, reattach: the pane still wants brackets, so the new
        # glass has to be told, or Cmd-V stops being a paste
        os.write(mfd, b"`d")
        time.sleep(1.2)
        r.drain(mfd)
        try:
            g.wait(timeout=3)
        except Exception:
            g.kill()
        os.close(mfd)
        mfd2, g2 = r.glass()
        second = r.drain(mfd2)
        check("a reattached glass is told mode 2004 too",
              b"\x1b[?2004h" in second, repr(second[:60]))
        g2.kill()
        os.close(mfd2)
    finally:
        r.kill()
    print("%d failed" % len(fails) if fails else "all good")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
