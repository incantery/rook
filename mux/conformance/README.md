# conformance

`./run.sh` replays each `corpus/*.vt` byte stream into the engine and
into a reference tmux, then diffs the final screens. Both sides render
inside the same outer tmux (the reference runs nested) so capture
artifacts cancel out. `gen.py` regenerates the corpora: autowrap and
wide-char margins, CJK/emoji/ZWJ/combining, DECSTBM scroll regions,
cursor choreography, ICH/DCH/ECH/IRM, tab stops (HTS/TBC), alt screen,
origin mode, SGR, scrollback push.

Text content and cell positions are compared. Styled comparison is
future work: rook deliberately flattens palette colors to truecolor at
render time, so a byte-level SGR diff against tmux is meaningless
without a palette-aware normalizer.
