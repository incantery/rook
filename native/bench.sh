#!/bin/sh
# rookz bench — the scoreboard runs. ReleaseFast, own socket, four phases:
# idle, keystroke latency at a quiet prompt, firehose, 150MB cat.
# Numbers land in PERF.md; state the grid geometry with every number.
set -e
cd "$(dirname "$0")"

zig build -Doptimize=ReleaseFast

SOCK=/tmp/rookz-bench.sock
CORPUS=/tmp/rookz-cat-bench.txt

if [ ! -f "$CORPUS" ]; then
  echo "generating 150MB ascii corpus..."
  base64 < /dev/urandom | head -c 150000000 > "$CORPUS"
fi

ROOKZ_SOCK=$SOCK ./zig-out/bin/rookz win --no-activate >/dev/null 2>&1 &
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
t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt 120 ]; do
  if c dump | grep -q 'total$'; then break; fi
  sleep 0.5
done
c dump | grep 'total$' | tail -1
c stats

echo ""
c quit >/dev/null 2>&1 || true
