# Up Next

- [x] Fix the attach replay gap: handleAttach copies the ring, replays, THEN sets s.attach — pty bytes arriving during replay never reach that client. Silent scrollback loss on reload today; constant loss once detach/reattach becomes routine (CHATGPTFEEDBACK.md). Step zero of the background-session detach work.

# Workspace Switcher

- [x] Vim key-binds (^j/^k + ^n/^p in switcher and palette — bare j/k would type into the filter; bare j/k in the inbox)
- [x] Focus currently always starts at the top and it should start on the active workspace

# Rook Agent

- [ ] The rook agent should have more agency. Right now it does a lot of just "yours to answer".
- [ ] Improve the agent recommendation and response setup. I'm thinking something like having something on the dashboard, or a way to have a more detailed view, where Rook can display a summary of what it's replying to and why. If we dial this in, it will/should let us just run most claude code sessions "in the background" and only attach when we specifically choose to directly attach even though it's running interactive the whole time.
- [ ] Markdown in the svelte session view. Claude writes markdown and the view renders it literally today — fences, lists, headings, bold all show their syntax. It's the difference between a view you'd use and one you'd tolerate, so it gates daily-driving the 90% case. Options: take a dep, reuse Monaco (already chunked, already themed), or write a small renderer for the subset claude actually emits.

# Rook App

- [x] Better total cost tracking in a sort of app wide status bar with more details on the main "workspace manager" screen
- [x] Baked in claude code usage. We still track total "cost" when using a claude subscription, but we want to also keep track of remaining usage for the period for subscription accounts

# Issue Tracking

- [ ] One of the next things we should probably setup is some kind of issue tracking integration. Then the rook agent can tie into the list of issues to determine what we should work on next
- [ ] The file tree should be based on CWD rather than workspace I think, but let's dicsuss.
- [ ] When dashboard or mission control is open, input keeps going into the most recently open terminal

# Emulator (internal/vt)

- [x] libghostty-vt differential oracle (2026-07-22): `make ghostty-lib` + `go test -tags ghostty ./internal/host/ -run Ghostty`; fixed 16 conformance bug classes on day one (charset/ACS, alt-screen cursor, tab stops, DECALN, REP, wide-pair tearing, combining-mark widths, pending-wrap semantics, …). Benchmarks: their parser 4–6× faster (SIMD — real headroom), our pipeline 4× faster (their per-cell FFI read path drowns it). PERF.md has the table.
- [ ] Parser rework (VT state machine proper): C0 controls EXECUTE inside escape sequences (we abort); C1 as raw bytes/codepoints should execute in 8-bit-tolerant mode (we drop, ghostty stores, xterm executes). Known-divergent classes documented in the fuzz filter.
- [ ] Replace go-runewidth classification with own width table (its zero-width table misses hundreds of combining ranges — patched via Mn/Me/Cf bitmap; a unified table would also reclaim the ~10% unicode parse cost of the patch and the fuzz-adjudicated margins like Hangul fillers).
- [ ] Ghostty upstream candidates (report when we engage): CSI 0a/0e (HPR/VPR) miss the zero-coercion CSI 0C/0B have.
- [ ] Adapter v2 (only if ever needed as a real backend): per-row dirty flags + bulk row read to fix the 17ms full-screen FFI snapshot; WRITE_PTY effect callback for query responses; scrollback paging parity.

# WebGL Renderer (beamterm) — adoption gaps

- [ ] Window transparency: the canvas paints opaque, so background-opacity doesn't show through. Beamterm's fragment shader already supports it (`u_bg_alpha`, core `set_bg_alpha()` since 0.16.0) — the JS/wasm wrapper just exposes no setter. Decision (2026-07-22): don't file upstream yet; once we're confident in beamterm, file the PR (thin wasm_bindgen delegation).
- [x] Scrollback view on canvas — shared SbStore (sbstore.ts) extracted from the DOM renderer; wheel + Shift+PageUp/Home; host paging works on canvas
- [ ] Mouse forwarding to tracking programs: wheel IS forwarded now (Claude Code scroll works); clicks/drags (vim mouse) still local-only
- [ ] A11y text mirror (canvas has no readable text; DOM renderer is the accessible fallback)
- [ ] Theme-change re-read of CSS vars (palette swap currently needs a reload)
- [ ] Key-to-pixel latency probe to settle the DOM-vs-WebGL headed measurement asymmetry