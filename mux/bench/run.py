#!/usr/bin/env python3
"""rook's engine vs tmux: throughput, memory, latency. Both muxes run inside
an outer tmux (the glass); payload is cat'd in a pane and the wall
clock stops when the sentinel renders. Usage: ./run.py [runs]"""
import subprocess, sys, time, os, pathlib, statistics

RUNS = int(sys.argv[1]) if len(sys.argv) > 1 else 3
HERE = pathlib.Path(__file__).resolve().parent
MUX = os.environ.get("ROOK_ENGINE") or os.path.expanduser("~/.local/libexec/rook/engine")
PAYLOAD = "/tmp/rmbench-payload.txt"
MB = 5

def sh(*a, check=True, out=False):
    r = subprocess.run(a, capture_output=True, text=True)
    if check and r.returncode != 0 and not out:
        raise RuntimeError(f"{a}: {r.stderr.strip()}")
    return r.stdout

def payload():
    if not pathlib.Path(PAYLOAD).exists() or pathlib.Path(PAYLOAD).stat().st_size < MB*1024*1024:
        with open(PAYLOAD, "w") as f:
            n = 0
            while n < MB * 1024 * 1024:
                line = f"line-{n:08d} " + "x" * 60 + "\n"
                f.write(line); n += len(line)
            f.write("BENCH-DONE\n")

def wait_for(session, needle, timeout=120):
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        if needle in sh("tmux", "capture-pane", "-t", session, "-p", check=False):
            return time.monotonic()
        time.sleep(0.02)
    raise TimeoutError(needle)

def outer(session, cmd, cols=100, rows=30):
    sh("tmux", "kill-session", "-t", session, check=False)
    sh("tmux", "new-session", "-d", "-s", session, "-x", str(cols), "-y", str(rows), cmd)

def wait_absent(session, needle, timeout=30):
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        if needle not in sh("tmux", "capture-pane", "-t", session, "-p", check=False):
            return
        time.sleep(0.02)
    raise TimeoutError(f"still visible: {needle}")

def drain(session):
    sh("tmux", "send-keys", "-t", session, "clear", "Enter")
    wait_absent(session, "BENCH-DONE")
    sh("tmux", "send-keys", "-t", session, f"cat {PAYLOAD}", "Enter")
    t0 = time.monotonic()
    t1 = wait_for(session, "BENCH-DONE")
    return t1 - t0

def rss_of(pattern):
    # newest match only: stray servers from other sessions must not
    # pollute the number
    pid = sh("pgrep", "-n", "-f", pattern, check=False).strip()
    if not pid: return 0
    v = sh("ps", "-o", "rss=", "-p", pid, check=False).strip()
    return int(v) if v else 0  # KB

def bench_rook():
    sock = "/tmp/rmbench-rook.sock"
    if pathlib.Path(sock).exists():
        sh(MUX, "kill", check=False); time.sleep(0.3)
        pathlib.Path(sock).unlink(missing_ok=True)
    for suffix in (".state", ".state.tmp"):
        pathlib.Path(sock + suffix).unlink(missing_ok=True)
    outer("rmb-rook", f"env ROOK_MUX_SOCK={sock} {MUX}")
    wait_for("rmb-rook", "♜")
    times = [drain("rmb-rook") for _ in range(RUNS)]
    rss = rss_of("engine server")
    stats = ""
    env = dict(os.environ, ROOK_MUX_SOCK=sock)
    r = subprocess.run([MUX, "stats"], capture_output=True, text=True, env=env)
    stats = r.stdout.strip().splitlines()[-1] if r.stdout else ""
    subprocess.run([MUX, "kill"], env=env, capture_output=True)
    sh("tmux", "kill-session", "-t", "rmb-rook", check=False)
    return times, rss, stats

def bench_tmux():
    sh("tmux", "-L", "rmbench", "kill-server", check=False)
    outer("rmb-tmux", f"tmux -L rmbench -f {HERE}/bench.conf new-session")
    time.sleep(2.0)  # shell prompt; prompt strings vary, a beat is enough
    times = [drain("rmb-tmux") for _ in range(RUNS)]
    rss = rss_of("tmux -L rmbench")
    sh("tmux", "-L", "rmbench", "kill-server", check=False)
    sh("tmux", "kill-session", "-t", "rmb-tmux", check=False)
    return times, rss

def fmt(times):
    return f"median {statistics.median(times):.3f}s  runs {' '.join(f'{t:.3f}' for t in times)}"

if __name__ == "__main__":
    payload()
    print(f"payload: {MB}MB, {RUNS} runs each\n")
    rt, rrss, rstats = bench_rook()
    tt, trss = bench_tmux()
    print(f"rook drain: {fmt(rt)}")
    print(f"tmux     drain: {fmt(tt)}")
    print(f"rook server RSS: {rrss/1024:.1f} MB")
    print(f"tmux     server RSS: {trss/1024:.1f} MB")
    if rstats: print(f"rook latency: {rstats}")
    print(f"\nratio drain rook/tmux: {statistics.median(rt)/statistics.median(tt):.2f}x")
