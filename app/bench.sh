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
# Per-phase off-glass check. The window's visibility can CHANGE mid-run
# (the first real-world run had a throttled quiet-key phase and an
# on-glass cat — the operator switched Spaces to watch), so each latency
# phase vouches for itself. Here the discriminator is the throttle
# clock's quantization: on glass, intervals follow the ~80ms key
# cadence; occluded, they pin to exactly ~100ms. The 95ms threshold
# splits those two — it is NOT a generic slow-frame test, and it breaks
# if the key cadence above is ever raised to ~100ms.
pi=$(c stats | grep -o 'present_interval_us n=[0-9]* p50=[0-9]*' | grep -o 'p50=[0-9]*' | cut -d= -f2)
if [ -n "$pi" ] && [ "$pi" -ge 95000 ]; then
  echo ""
  echo "*** OFF-GLASS PHASE: present_interval p50=${pi}us pins to the 10Hz"
  echo "*** throttle clock — the window was occluded during the keystroke"
  echo "*** phase and its latency numbers are NOT scoreboard numbers."
fi

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
# Off-glass tripwire (PERF.md 2026-08-07): a fully-occluded window —
# behind a fullscreen Space, a locked screen — gets its presents
# throttled to a hard 10Hz, and every latency number in this run is
# garbage. Detected HERE because the firehose separates cleanly: on
# glass it presents at a locked 8.3ms; throttled it quantizes to
# ~100ms. The quiet-key phase cannot discriminate — its echo cadence
# (~80ms) sits too close to the throttle clock.
pi=$(c stats | grep -o 'present_interval_us n=[0-9]* p50=[0-9]*' | grep -o 'p50=[0-9]*' | cut -d= -f2)
if [ -n "$pi" ] && [ "$pi" -ge 50000 ]; then
  echo ""
  echo "*** OFF-GLASS RUN: firehose present_interval p50=${pi}us — the"
  echo "*** bench window is occluded (fullscreen Space in front? screen"
  echo "*** locked?) and its presents are 10Hz-throttled. Nothing from"
  echo "*** this run goes in the scoreboard. Re-run with the window"
  echo "*** visibly on glass."
fi

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
