#!/bin/sh
# Replay each corpus into rook-mux and plain tmux; diff final screens.
# Usage: ./run.sh [name...]   (default: every corpus/*.vt)
set -u
cd "$(dirname "$0")"
MUX="${MUX:-$HOME/.local/bin/rook-mux}"
OUT=out; rm -rf "$OUT"; mkdir -p "$OUT"
pass=0; fail=0
names="${*:-$(ls corpus/*.vt | xargs -n1 basename | sed 's/\.vt$//')}"

stable_capture() { # session rows outfile — capture until two identical reads
  prev=""; i=0
  while [ $i -lt 40 ]; do
    cur="$(tmux capture-pane -t "$1" -p | head -"$2")"
    [ -n "$cur" ] && [ "$cur" = "$prev" ] && break
    prev="$cur"; sleep 0.25; i=$((i+1))
  done
  printf '%s\n' "$cur" > "$3"
}

for name in $names; do
  f="$PWD/corpus/$name.vt"
  [ -f "$f" ] || { echo "?? $name (no corpus)"; continue; }

  # reference: tmux-in-tmux, so the ref rides the same outer glass as
  # rook-mux does (capture-pane re-emits \t for tab-written cells; a
  # nested renderer normalizes both sides to what was actually drawn)
  tmux -L rmvt-ref kill-server 2>/dev/null
  tmux kill-session -t vtref 2>/dev/null
  tmux new-session -d -s vtref -x 80 -y 24 \
    "tmux -L rmvt-ref -f $PWD/ref.conf new-session \"sh -c 'cat $f; sleep 60'\""
  stable_capture vtref 24 "$OUT/$name.tmux"
  tmux -L rmvt-ref kill-server 2>/dev/null
  tmux kill-session -t vtref 2>/dev/null

  # rook-mux: 80x25 outer (24 pane rows + status line)
  sock="/tmp/rmvt-$name.sock"; rm -f "$sock"
  tmux kill-session -t vtmux 2>/dev/null
  tmux new-session -d -s vtmux -x 80 -y 25 \
    "env ROOK_MUX_SOCK=$sock SHELL=$PWD/replay-shell.sh RMVT_FILE=$f $MUX"
  stable_capture vtmux 24 "$OUT/$name.rook"
  ROOK_MUX_SOCK=$sock "$MUX" kill >/dev/null 2>&1
  tmux kill-session -t vtmux 2>/dev/null; rm -f "$sock"

  # normalize trailing whitespace; diff
  sed 's/[[:space:]]*$//' "$OUT/$name.tmux" > "$OUT/$name.tmux.n"
  sed 's/[[:space:]]*$//' "$OUT/$name.rook" > "$OUT/$name.rook.n"
  if diff -q "$OUT/$name.tmux.n" "$OUT/$name.rook.n" >/dev/null; then
    echo "ok   $name"; pass=$((pass+1))
  else
    echo "FAIL $name  (diff $OUT/$name.tmux.n $OUT/$name.rook.n)"; fail=$((fail+1))
  fi
done
echo "----"; echo "pass $pass fail $fail"
[ $fail -eq 0 ]
