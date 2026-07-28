#!/bin/sh
# rook bench — the scoreboard runs. ReleaseFast, own socket, four phases:
# idle, keystroke latency at a quiet prompt, firehose, 150MB cat.
# Numbers land in PERF.md; state the grid geometry with every number.
set -e
cd "$(dirname "$0")"

zig build -Doptimize=ReleaseFast

SOCK=/tmp/rook-bench.sock
CORPUS=/tmp/rook-cat-bench.txt

if [ ! -f "$CORPUS" ]; then
  echo "generating 150MB ascii corpus..."
  base64 < /dev/urandom | head -c 150000000 > "$CORPUS"
fi

# The scoreboard runs a PINNED config — the user's live config (theme,
# background-opacity) must not skew like-for-like runs. Font is pinned
# to what the 0.88–0.91s cat band was measured with (Hack 18pt → the
# 67×42 WM-tile grid); everything else is defaults, opacity included.
BENCHCFG=/tmp/rook-bench-config
mkdir -p $BENCHCFG/rook
printf 'font-family = "Hack Nerd Font Mono"\nfont-size = 18\n' > $BENCHCFG/rook/config.toml

# And no rook-host. The daemon is not under test: adopting the daily
# driver's would put its background work (prwatch, usagepush, relay) in
# the middle of a 150MB cat, and spawning our own would replace the
# daily driver's daemon and kill its shells. An unwritable state dir
# fails the spawn fast and leaves the renderer measured alone.
XDG_STATE_HOME=/dev/null/no-host \
XDG_CONFIG_HOME=$BENCHCFG ROOK_SOCK=$SOCK ./zig-out/bin/rook win --no-activate >/dev/null 2>&1 &
APP=$!
trap 'kill $APP 2>/dev/null' EXIT
sleep 2

c() { printf '%s\n' "$1" | nc -U $SOCK; }

echo "== geometry =="
c dump | head -1

echo ""
echo "== idle, 5s (frames should be ~0) =="
c 'stats reset' >/dev/null
sleep 5
c stats

echo ""
echo "== keystroke latency: 60 keys @ 80ms, quiet prompt =="
c 'stats reset' >/dev/null
i=0
while [ $i -lt 60 ]; do
  c 'key 6a' >/dev/null
  sleep 0.08
  i=$((i+1))
done
sleep 0.3
c ctrlc >/dev/null
c stats

echo ""
echo "== firehose: full-width yes, 5s =="
LINE=$(printf 'x%.0s' $(seq 1 180))
c "type yes $LINE" >/dev/null
c 'stats reset' >/dev/null
c enter >/dev/null
sleep 5
c ctrlc >/dev/null
sleep 0.3
c stats

echo ""
echo "== cat 150MB ascii =="
c "type time cat $CORPUS" >/dev/null
c enter >/dev/null
# Dump lines WRAP at the pane width — "total" can split into "t/otal".
# Trim row padding and join before matching (the 15-minute lesson).
joined() { c dump | sed -e 's/ *$//' | tr -d '\n'; }
t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt 120 ]; do
  if joined | grep -q 'total'; then break; fi
  sleep 0.5
done
joined | grep -oE 'cpu [0-9]+\.[0-9]+ total' | tail -1
c stats

echo ""
c quit >/dev/null 2>&1 || true
