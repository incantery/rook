#!/usr/bin/env python3
"""Seth's config as a Python environment — the parity probe.

Same environment as main.go, and the output must be byte-identical to
it (docs/environments/IR.md, "Canonical bytes"): compact JSON, fields
in canonical order, entries sorted, integral floats as integers, raw
UTF-8. `diff <(go run ./sdk/rook/example) <(python3 sdk/rook/example/main.py)`
is the whole test. A real Python SDK arrives when demand does; this
exists to measure emit time per language and to keep the canon honest.
"""

import json
import sys

nodes = []


def put(n):
    for i, e in enumerate(nodes):
        if e["id"] == n["id"]:
            nodes[i] = n
            return
    nodes.append(n)


def option(scope, key, value):
    put({"id": f"option:{scope}:{key}", "kind": "option", "scope": scope,
         "key": key, "value": value})


def set_app(key, value):
    option("app", key, value)


def host(key, value):
    option("host", key, value)


def table(name, entries):
    put({"id": f"table:host:{name}", "kind": "table", "scope": "host",
         "name": name, "entries": dict(sorted(entries.items()))})


def leader(key):
    put({"id": "leader:app", "kind": "leader", "scope": "app", "key": key})


def editor_leader(key):
    put({"id": "leader:editor", "kind": "leader", "scope": "editor", "key": key})


def bind(chord, command):
    put({"id": f"keybind:app:{chord}", "kind": "keybind", "scope": "app",
         "chord": chord, "command": command})


def editor_bind(mode, chord, command):
    scope = f"editor.{mode}"
    put({"id": f"keybind:{scope}:{chord}", "kind": "keybind", "scope": scope,
         "chord": chord, "command": command})


def canon(v):
    """Integral floats emit as integers — Go's 1, Python's 1.0, TS's 1
    must be the same byte."""
    if isinstance(v, float) and v.is_integer():
        return int(v)
    if isinstance(v, list):
        return [canon(x) for x in v]
    if isinstance(v, dict):
        return {k: canon(x) for k, x in v.items()}
    return v


# ---- the environment (mirror of main.go) ----

set_app("font-family", "Hack Nerd Font Mono")
set_app("font-size", 18.0)
set_app("background-opacity", 1.0)
set_app("window-padding", 4.0)
set_app("theme", "Nocturne")

leader("`")
editor_leader(",")

bind('<leader>"', "app.split.horizontal")
bind("<leader>v", "app.split.vertical")
bind("<leader>c", "tab.new")
bind("<leader>m", "workspace.manager")

editor_bind("normal", "<leader>TAB", "explorer.toggle")
editor_bind("normal", "<leader>o", "explorer.reveal")

host("coder", "claude")
host("workspace-allow", ["rook", "rook-cloud", "rook-site", "presentation"])
table("agent", {"enabled": True, "engine": "auto", "model": "",
                "daily-cap-usd": 1.0})
table("lsp", {"enable": ["go", "typescript", "svelte"]})
table("cloud", {"url": "https://api.rookide.com"})

graph = canon({"rookEnvironment": 1, "nodes": nodes})
out = json.dumps(graph, separators=(",", ":"), ensure_ascii=False) + "\n"
sys.stdout.write(out)
