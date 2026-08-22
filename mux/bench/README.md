# bench

`./run.py [runs]` — rook-mux vs tmux on the same outer glass:
throughput (wall time for a 5MB cat to reach the screen), server RSS,
and rook-mux's own input→frame latency histogram.

2026-08-22, M-series MacBook, ReleaseSafe:

    rook-mux drain: median 0.338s        tmux: 0.489s   (0.69x)
    rook-mux RSS:   6.9 MB               tmux: 11.1 MB
    rook-mux input→frame: p50 52µs · p99 81µs

The first run of each set is cold (page faults, ~2x); the median is
the honest number. tmux runs nested (status off, history 10000) so
both muxes pay the same outer-terminal serialization tax.
