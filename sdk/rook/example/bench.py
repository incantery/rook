#!/usr/bin/env python3
"""Emit-time bench: how long each SDK language takes to run the example
environment and emit the graph.

This is the EDIT-APPLY loop's cost, not launch cost — the app never
runs these programs at startup (it reads the materialized
environment.json, ~100µs; app/PERF.md "Startup"). What's measured here
is what `rook env apply` will pay per config change, per language.

Usage: python3 sdk/rook/example/bench.py   (from the repo root or anywhere)
"""

import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))


def which_node():
    node = shutil.which("node")
    if node:
        return node
    nvm = os.path.expanduser("~/.nvm/versions/node")
    if os.path.isdir(nvm):
        versions = sorted(os.listdir(nvm))
        for v in reversed(versions):
            cand = os.path.join(nvm, v, "bin", "node")
            if os.access(cand, os.X_OK):
                return cand
    return None


def bench(label, cmd, runs=15, warmup=2):
    for _ in range(warmup):
        subprocess.run(cmd, cwd=REPO, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=True)
    times = []
    for _ in range(runs):
        t0 = time.perf_counter()
        subprocess.run(cmd, cwd=REPO, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=True)
        times.append((time.perf_counter() - t0) * 1000)
    print(f"  {label:<34} min {min(times):7.1f} ms   median {statistics.median(times):7.1f} ms")


def main():
    print("emit-time per language (wall, warm caches):")

    tmp = tempfile.mkdtemp(prefix="rook-env-bench-")
    gobin = os.path.join(tmp, "example")
    subprocess.run(["go", "build", "-o", gobin, "./sdk/rook/example"],
                   cwd=REPO, check=True)
    bench("go (prebuilt binary)", [gobin])
    bench("go run (warm build cache)", ["go", "run", "./sdk/rook/example"])
    bench("python3", [sys.executable, os.path.join(HERE, "main.py")])

    node = which_node()
    if node:
        bench("node (.ts, type stripping)", [node, os.path.join(HERE, "main.ts")])
    else:
        print("  node: not found, skipped")

    bun = shutil.which("bun")
    if bun:
        bench("bun (.ts)", [bun, os.path.join(HERE, "main.ts")])

    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
