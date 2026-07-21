#!/usr/bin/env python3
"""Cell-by-cell diff of a Go-emulator grid against the xterm.js reference.

Both grids come from the extractors in this dir (same normalized schema), so a
difference here is a difference in what the emulators DID with identical bytes
at identical geometry — the fidelity question, made concrete.

    python3 diff.py <xterm.json> <vt.json>

Buckets each differing cell by which field diverged (char / width / fg / bg /
attrs) and prints counts, a verdict (% of cells identical), and a sample of
each bucket with location + both values. "char" and "width" divergences are
the corrupting kind; fg/bg palette-vs-rgb mismatches are usually cosmetic.
"""
import json
import sys
from collections import defaultdict


def load(p):
    with open(p) as f:
        return json.load(f)


def main():
    xt, vt = load(sys.argv[1]), load(sys.argv[2])
    assert xt["cols"] == vt["cols"] and xt["rows"] == vt["rows"], "geometry mismatch"
    cols, rows = xt["cols"], xt["rows"]

    buckets = defaultdict(list)  # field -> [(y,x, xtval, vtval)]
    total = cols * rows
    diff_cells = 0

    for y in range(rows):
        for x in range(cols):
            a, b = xt["cells"][y][x], vt["cells"][y][x]
            fields = [k for k in ("c", "w", "fg", "bg", "a") if a[k] != b[k]]
            if fields:
                diff_cells += 1
            for k in fields:
                buckets[k].append((y, x, a[k], b[k]))

    name = xt["name"]
    match = 100 * (total - diff_cells) / total
    print(f"\n=== {name}  ({cols}x{rows}, {total} cells) ===")
    print(f"  identical cells: {total - diff_cells}/{total}  ({match:.2f}%)")
    label = {"c": "char", "w": "width", "fg": "fg", "bg": "bg", "a": "attrs"}
    for k in ("c", "w", "fg", "bg", "a"):
        if buckets[k]:
            corrupting = " ⚠ CORRUPTING" if k in ("c", "w") else ""
            print(f"  {label[k]:>6} differs: {len(buckets[k])} cells{corrupting}")
    # samples of the corrupting kinds, which are the ones that decide go/no-go
    for k in ("c", "w"):
        if buckets[k]:
            print(f"  — sample {label[k]} diffs (y,x: xterm | vt):")
            for y, x, av, bv in buckets[k][:6]:
                print(f"      ({y:2},{x:3}): {av!r} | {bv!r}")
    return diff_cells


if __name__ == "__main__":
    main()
