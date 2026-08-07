# rook vs Zed — competitive deep-dive

**2026-08-06.** Fifteen subsystem analyses, each reading Zed's implementation
(`zed-industries/zed`, 245 crates) against rook's counterpart and mining Zed's
git history for the bugs they already paid for. This page is the distillation;
every claim below cites a file or a commit.

The through-line, stated once so the sections don't have to repeat it:
**don't adopt Zed's architectures — adopt its scar tissue.** Zed's big
machinery (the CRDT text crate, the scene graph, worktree snapshots, the
multibuffer's legacy ExcerptId design) exists to serve collaboration and
proportional-font GUI constraints rook deliberately does not have. What
transfers is the bug history: hundreds of fix commits that are executable
specs for edge cases rook will otherwise rediscover one user at a time.

## Executive summary

### Where rook stands

**Ahead, and by design:** terminal emulation and throughput (ghostty-vt vs
Zed's alacritty fork; 0.90s vs their glue overhead on the same corpus),
rendering latency (37µs cell fill, true key-to-photon instrumentation —
Zed's scene graph cannot reach rook's numbers), buffer-core simplicity
(1.5k lines vs 14k, with disk-conflict safety and deterministic undo
grouping Zed's text crate doesn't own), config authoring/apply
(preview-as-diff, provenance — Zed has nothing there), and machine-wide
agent session visibility plus the attention/phone layer.

**Behind, and it compounds:** every hot path that flattens the whole buffer
(LSP sync, reparse, format), display features with no seam to grow through
(no soft wrap, folds, multi-cursor, inlay hints), no editable multi-excerpt
surface despite a review-first thesis, no push-based file-change detection
despite an agent-first thesis, and the entire shipping story: no
self-update, no crash capture, no session restore, no log file. A crash
today kills every shell and leaves no evidence.

**The strategic asymmetry worth naming:** Zed and rook are converging on
the same agent future from opposite ends. Zed owns in-editor review
(action_log, ~2000 lines of tests); rook owns orchestration, attention,
and the phone. Zed can add notifications more easily than rook can add
review. The multibuffer section and the agent section are both really
about closing that gap.

### Live bugs this analysis found in rook

Each of these is a today-bug with a Zed commit as prior art, ordered
roughly by severity:

1. **Two panes on one file corrupt syntax trees** — per-pane Highlighters
   drain Buffer's single-consumer edit log (`macos.zig:3398`,
   `buffer.zig:338-347`); the loser reparses against a stale tree.
2. **Formatting applies against the current rope with no version guard**
   (`macos.zig:3792`) — type during a slow format and the reply corrupts
   text. Rename already has the exact check needed (`macos.zig:4197`).
3. **`install.sh` nukes the live install before copying** (rm -rf then
   copy, `install.sh:45-46`) — a failed download bricks the app. Zed
   shipped the same class (6a38d699dc).
4. **Completion races:** `cpl_asked` dedup never clears (the menu silently
   stops asking the server) and the stale-answer guard checks no position
   (wrong-receiver members can fold into the ring).
5. **LSP shutdown sends `exit` immediately after the `shutdown` request**
   (`lsp.zig:955-960`) — rust-analyzer/clangd lose persisted caches. Zed
   fixed this race twice.
6. **Pane close / quit is SIGHUP-only** — a SIGHUP-trapping or
   job-controlled foreground process is orphaned. Zed fixed twice
   (#47412, #61467); the tcgetpgrp fix is ~30 lines.
7. **An externally deleted file becomes an empty pane, and `:w` resurrects
   it** (`buffer.zig:169` ENOENT path).
8. **Search-panel jumps use scan-time line numbers** — wrong target after
   any edit (`macos.zig:3280-3307`). Same class: ⌘⇧F searches stale disk
   under dirty buffers.
9. **Four confirmed vim divergences**, each with a Zed commit as spec:
   `3d2w` deletes 32 words, `2daw` drops the count, `cw` at word-end eats
   the next word, `d}` stops short at EOF.
10. **Palette key hints lie after a rebind** — they read the static
    `Command.keys` string (`registry.zig:100`).
11. **Renderer carries three of Zed's paid-for bugs live:** the
    `cells_buf` GPU-read race, stale scale on screen change, and ProMotion
    downclock — the last likely explains PERF.md's unexplained quiet-key
    p50 wobble.

### The priority list

If only six things come out of this analysis, these — ordered by
leverage-per-effort, mixing fixes and features:

1. **Fix the version-guard class now** (format replies, search jumps,
   completion races) — copy-paste-sized fixes to text corruption.
2. **One Highlighter per document**, plus a two-panes e2e scenario.
3. **Crash capture v1 + transactional install** (~a day): panic override +
   signal handlers, JSON sidecar, archive the unstripped binary per
   release — the one step that cannot be retrofitted.
4. **Incremental LSP `didChange` from the already-recorded TreeEdits**,
   and tree-sitter read-callback over rope leaves — kills the
   flatten-everything tax; the data structures already exist.
5. **The automated vim oracle harness** (`vim -Nu NONE` golden sessions,
   Zed runs 310 against neovim) — before adding more vim surface, because
   it would have caught all four divergences mechanically.
6. **`didChangeWatchedFiles`** — rook IS a terminal; `go get` in the next
   pane silently desyncs gopls today. This is the gap a Zed switcher hits
   in their first hour.

Behind those, the big product arcs in order: session restore (cheap —
Zed respawns shells in saved cwds too, rook has both halves already),
markdown + code-fence injections (a terminal whose thesis is agent
transcripts renders markdown plain), accept-time completion behavior
(auto-import via resolve-before-accept), the ACP client plugin
(structured tool calls + answer-from-phone), per-prompt git checkpoints,
and the PathKey-model multibuffer as the review surface.

### Cheap armor to install before the next big features

Zed's history is unambiguous about where the panics live. Before soft
wrap, folds, or inlays land: coordinate-space newtypes (mixed spaces are
Zed's top panic class even WITH newtypes), the marked-text test DSL
(`ˇ` cursor, `«»` selection — makes porting Zed's paid-for tests
mechanical), seeded randomized round-trip tests, CRLF normalization,
rope char-boundary guards (Zed fixed that class five-plus times in
production), and append-only config migrations versioned from row one.

---

## The text engine

Three subsystems: buffer core, display pipeline, syntax. One live bug found (shared-buffer highlighter corruption), one dominant theme: rook's 10x-smaller core is the right call, but every hot path that flattens the whole buffer — LSP sync, reparse, formatting — is the gap that compounds, and zed's commit history is a pre-paid map of the bugs waiting in rook's next three features (wrap, folds, injections).

### Text storage & buffer core

**VERDICT: differently positioned, honestly — rook's 1.5k-line single-replica core beats zed's 14k-line CRDT for rook's thesis, but rook is behind on coordinate math and flattens the whole buffer where zed never does.**

Zed's core (crates/sum_tree/src/sum_tree.rs, crates/rope/src/rope.rs, crates/text/src/text.rs) is a persistent B+tree where every node caches multiple monoid metrics — bytes, UTF-16 units, lines, longest row — so any coordinate converts to any other in one O(log n) seek (rope.rs:397-455), chunks are ≤128 bytes with u128 bitmaps counted by popcount, and clone-a-snapshot is O(1) via Arc sharing, feeding background syntax/search/diff. On top sits a full CRDT: fragments, tombstone ropes, Lamport clocks, anchors that survive concurrent edits.

rook (app/src/rope.zig, 427 lines; app/src/buffer.zig; app/src/docs.zig) tracks two metrics (bytes, newlines), rebuilds instead of rotating, and is oracle-tested against an array reference — same method as zed's randomized tests. rook does **not** need the CRDT: agents edit through the filesystem and the DiskState/reload seam, not shared replicas. And rook is genuinely ahead in three places zed's text crate doesn't play: disk-conflict safety in the buffer itself (DiskState mtime+size+inode, atomic rename preserving permissions, buffer.zig:263-329 — the agent-workspace thesis made concrete), deterministic command-boundary undo grouping (zed's 300ms wall-clock heuristic is a self-admitted test footgun, text.rs:226), and a comprehensible core.

The real gaps: every LSP sync sends the full buffer text (macos.zig:3632, lsp.zig:1063 admits "incremental sync is the next step"); every reparse flattens up to a 4MB cap (editor.zig:7935); UTF-16 conversion is an O(line) scan over flattened copies; zero CRLF handling anywhere (grep confirms); and mark-shifting depends on a 16-slot watcher registration array (buffer.zig:79-81) whose own comment states the principle the cap violates — the 17th view's marks silently rot.

**Steal:**
- Incremental LSP didChange from the already-recorded TreeEdits [medium] — Buffer.recordEdit (buffer.zig:349-405) already captures exactly what LSP incremental sync wants. zed: text.rs edits_since/Patch; rook: app/src/lsp.zig:1067 + macos.zig:3632.
- Tree-sitter via read-callback over rope leaves, not flatten [medium] — kills the per-reparse O(n) memcpy and the 4MB highlighting ceiling. zed: rope.rs:357-367 chunks_in_range; rook: editor.zig ~7935 + a leafSliceAt(off) on rope.zig.
- UTF-16 unit sum on rope nodes [medium] — one more field in refreshInner makes every LSP position conversion O(log n). zed: rope.rs:1282-1330 TextSummary; rook: app/src/rope.zig Leaf/Inner.
- Buffer-owned position table with Left/Right bias, replacing the 16-slot watcher fan-out for marks [medium] — zed's Bias doc (sum_tree.rs:167-204) is the spec. rook: buffer.zig watchers + editor.zig:5877 shiftAnchor.
- CRLF: normalize on load, restore on save, LSP sees \n [small] — zed shipped "preserve line endings over LSP" and reverted it a week later (435eab6896 → 1b6cde7032). rook: buffer.zig initFromFile/save.
- Char-boundary guards: debug assert in rope insert/delete, clamp at untrusted entry points [small] — zed fixed this bug class five+ times in production, once in the guard itself (376e958569). rook: rope.zig + lsp.zig resolveEdits.
- Skip no-op splices before applyEdit [small] — zed's 2b888e1d30: a no-op format cleared redo. rook's applyEdit (buffer.zig:417) clears redo unconditionally AND dirties the buffer.

**Bug lessons rook is exposed to:** non-boundary offsets from an LSP server splitting a codepoint (rope.zig validates nothing — EXPOSED); the UTF-16 relative-vs-absolute clipping trap on multi-line chunks (zed 4ed2b3d041 — fuzz it when incremental sync lands); no-op format killing redo (2b888e1d30 — EXPOSED); CRLF files getting \r counted in vim columns and UTF-16 offsets (EXPOSED); registration-dependent positions (buffer.zig's own comment vs its 16-slot cap). GUARDED by design: deterministic undo grouping, grapheme-cluster motion (ghostty tables + neovim oracle), tombstone-anchor pathology (plain offsets + eager adjustment sidestep it entirely — keep this strategy for folds/hints too).

**Priorities:** (1) incremental didChange, (2) read-callback reparse, (3) char-boundary guards, (4) CRLF, (5) no-op splice guard, (6) position table, (7) UTF-16 rope sums. Keep: DiskState, deterministic grouping, seq-based modified flag, oracle tests.

### Editor architecture & display pipeline

**VERDICT: rook ahead on latency and simplicity, structurally behind on display features — no soft wrap, folds, multi-cursor, or inlay hints, and critically no seam to add them without replaying zed's 50-commit interaction-bug history.**

Zed's one big idea: every display feature is a transform layer (InlayMap → FoldMap → TabMap → WrapMap → BlockMap, crates/editor/src/display_map.rs) with its own coordinate newtype and edits translated between spaces — interactions are contained at layer boundaries, and each layer has a seeded randomized invariant test (`SEED=113 ITERATIONS=1` reproduces shipped bugs, commit 6d0e7ff18c). rook (app/src/editor.zig, 532KB, one flat model) has exactly two coordinate spaces — (line, byte-col) and render column — both bare `usize`, and one display pass: fillGrid (line 7138), O(visible rows), with a long-line clamp that makes a 2MB minified line free. That flat model is a real advantage: no entity graph, no snapshot cloning, and — because rook is a fixed-width cell grid — soft wrap can be synchronous, deterministic arithmetic; zed's whole interpolate/invert/compose WrapMap machinery (wrap_map.rs:146-360, with its own panic tail) exists only because proportional fonts need off-thread measurement. rook also independently paid-forward two of zed's lessons: visual block anchored in render columns per row (DrawBlock, editor.zig:7058 — zed's 992f395c3d), and eager plain-offset anchoring immune to zed's tombstone-anchor class.

Do **not** chase the multibuffer: zed's excerpt-anchor machinery serves project-search/diff-review stitching and carries its own bug tail (3b9c38a320, f8965317c3); rook's decorated-document + arranged-workspace direction delivers the same user value as N panes over N documents.

**Steal:**
- Distinct coordinate-space types [small] — `enum(usize)` newtypes for RenderCol/ByteCol, conversion confined to renderColAt/bcolForRenderCol. Mixed spaces are zed's top panic class even WITH newtypes (90d024b88a). Do it BEFORE wrap adds a third space. rook: editor.zig 1548/7851/7122/7058.
- Marked-text test DSL (`ˇ` cursor, `«»` selection) [small] — makes cursor position a first-class assertion and porting zed's paid-for edge-case tests mechanical. zed: crates/util/src/test/marked_text.rs; rook: editor.zig test helpers ~11400.
- Seeded randomized round-trip tests [medium] — renderColAt↔bcolForRenderCol identity, shiftAnchor vs recompute-from-scratch, fillGrid(incremental)==fillGrid(fresh); SEED env replay. Build before wrap lands.
- Soft wrap as ONE seam [large] — per-line wrap-segment index + prefix-sum row mapping, exactly two converters, everything (fillGrid, ensureVisible, scroll, mouseCell, goal) routed through them. Synchronous is fine on a cell grid. Every zed wrap bug (blocks 6d0e7ff18c, mouse fa1d0362b4, autoscroll 6e1e050738) is a checklist item.
- Folds on the existing anchor seam [medium] — ranges registered like marks via Buffer.watch, merged on insert, type-tagged (manual|lsp|diff), `⋯` placeholder with LSP collapsedText, auto-open on cursor edit. zed: fold_map.rs:26-64; rook: editor.zig folds beside marks (626) + lsp.zig foldingRange.
- Inlay hints as display-only splices owning zero buffer coordinates [medium] — zed's empty-input-summary rule; their entire inlay bug tail (aa5e2aef46, 78c0f2522a, 5a40e687e5) is cursor/selection touching injected text. rook: fillGrid column walk ~7225 + renderColAt.
- Autoscroll polish [small] — scrolloff margin, center-on-jump for gd/search, zz/zt/zb cycling; pinned chrome height inside the scroll math (zed 1e6e44874e). rook: ensureVisible (7122).

**Bug lessons rook is exposed to:** subscribe-after-snapshot double-application (d6fe14b3cc) — no bug today because edits apply synchronously before watchers fire, but any deferred/batched edit path (LSP workspace edits, plugin edits) hits it; worth a comment on Buffer.watch now. Coordinate-space mixups (90d024b88a) — currently correct, verified, but nothing stops the next contributor. Zero-width-chunk-inside-a-tab-expansion (9e87fefe3f) arrives with folds. Config values reaching arithmetic uncapped (fbdf5d4df4) arrives when tab_width becomes a config key. Mouse-through-display-space (fa1d0362b4): keep mouseCell the SINGLE click path when wrap lands.

**Priorities:** (1) coordinate newtypes now, (2) marked-text DSL, (3) seeded fuzz harness, (4) soft wrap as the next big slice, (5) folds, (6) inlay hints, (7) autoscroll polish anytime, (8) defer multi-cursor (sorted-disjoint + normalize-in-the-mutator, 8ab52f3491, when it comes). Feature order for the Claude Code wedge: wrap → folds → inlays → multi-cursor.

### Syntax highlighting & tree-sitter

**VERDICT: rook at parity on incremental reparse and ahead on grammar provenance; behind five years on injections — and carrying one live correctness bug: two panes on one file corrupt each other's trees.**

Zed's syntax_map.rs (2220 lines) is hard-won: snapshot-immutable layer trees, interpolation keeping stale trees positionally honest during background parses, pending-language layers, combined-injection splicing. rook's three files (grammar.zig 637 lines, syntax.zig 324, queries/*.scm) already do incremental ts_tree_edit reparse — 12.6k-line file, 42ms full → 0.30ms incremental (STATUS.md:170) — ahead of most terminal editors. And grammar.zig's provenance story (sha256-pinned dylibs declared in the environment graph, ABI checked before load, typed Faults with actionable sentences via `rook syntax`) answers "why is this file plain text" with a sentence where zed answers with silence.

Behind, in ways users feel: **no markdown highlighting at all** — a terminal whose thesis is agent transcripts renders its most important format plain; no code-fence injections; copy-previous-line autoindent; bracket matching by raw byte scan that pairs a `(` inside a string against real code (editor.zig:5607-5694); and a synchronous parse inside the frame fill with a blunt 4MB cap as the only budget.

**The live bug:** docs.zig shares one Buffer across N panes, but a Highlighter attaches per pane (macos.zig:3398) while Buffer's edit log is single-consumer (takeEdits/clearEdits, buffer.zig:338-347). Pane A's reparse drains the edits pane B needed; pane B hands tree-sitter a stale tree as old_tree for new text — subtree reuse at wrong offsets, silently garbage highlights. syntax.zig:244-245's own comment names the invariant being violated. Fix: one Highlighter per document (spans per pane), or per-consumer edit cursors keyed by buffer version — zed precludes the class with version vectors (syntax_map.rs:36-38).

**Steal:**
- Budgeted parse via tree-sitter's progress callback [medium] — ~1ms sync attempt, then background against a snapshot while the old ts_tree_edit-shifted tree keeps rendering; recheck buffer version on completion. Skip zed's wrapper-timeout mistake — their first version silently never timed out (ccce05d25c). Replaces the 4MB cap. zed: buffer.rs:1847-1922; rook: syntax.zig reparse + editor.zig refreshHighlights.
- Randomized incremental-vs-scratch oracle test [small] — random edits + undos, assert incremental tree s-exp == fresh-parse s-exp; tree-sitter as its own oracle, matching rook's vim-oracle culture. Do BEFORE injections. zed: syntax_map_tests.rs:1159.
- Markdown + code-fence injections, single (non-combined) only [large] — flat layer array, injection query over changed ranges ±1 byte, k-way capture merge by (start, Reverse(end), depth). Combined injections (ERB/PHP/HEEx) are where 8+ of zed's bugs lived; rook has no template-language demand — defer that whole class. Encode zed's edge cases as day-one tests: boundary edits use <=/>= (ee66adbb49), empty included_ranges needs one zero-width range, pending layers for grammars still materializing (14c72cac58 — rook's lazy fetch makes this the COMMON path), ±1-row invalidation expansion (797ad8cf44).
- Query-driven autoindent with ERROR-node suppression [medium] — ~20 lines of scm per language; the suppression rule (56080771e6) is the paid-for part. rook: queries/<lang>-indents.scm → editor.zig newline/o/} paths (2352, 5050).
- Syntax-aware brackets, cheap first [medium] — matchBracket skips bytes whose hl_styles entry is string/comment; graduate to a brackets query with error-recovery repair (bracket_ranges.rs) later.
- Outline queries feeding the Finder [medium] — instant offline symbol nav that beats waiting for gopls/zls, and doubles as the agent-legible compressed file view for the membrane. zed: buffer.rs:4458, 43ad470e58.
- Highlighter hygiene pass [small] — on null parse KEEP the old edited tree (today rook deletes it first, syntax.zig:265-267 — zed's 8e925bf58f is exactly rook's dlopen'd-third-party-grammar scenario); ts_query_cursor_set_match_limit(64); free replaced trees off the render path (zed measured 10s of ms, 18532995ec — rook ts_tree_delete's inline in the frame fill); set_containing_byte_range on the highlight cursor — safe while queries are single-capture, with a comment citing zed's revert b38e8f17d8 so a future two-node pattern doesn't silently stop matching; retry .unavailable grammar faults on next ask instead of caching an offline-launch failure until config reload (grammar.zig).

**Bug lessons rook is exposed to:** the shared edit-log drain (LIVE, above); byte-range limits bound what's returned, not traversed — a large broken file's ERROR subtree is walked every frame (rook sets only set_byte_range, syntax.zig:277); null-parse deleting the incremental baseline; permanent fault caching on lazy grammars. Future landmines already mapped for injections: boundary-inequality invalidation, empty included_ranges, marker-outside-content invalidation, "deepest layer wins" being the wrong ownership rule (a40ee74a1f). Track the vendored tree-sitter runtime deliberately — zed upgraded purely for parser crashes (1c62abbf79) and rook dlopens third-party dylibs against it.

**Priorities:** (1) FIX the two-panes-one-file corruption now, with an e2e scenario typing in pane A and asserting pane B's dump; (2) oracle test; (3) hygiene pass; (4) parse budget; (5) markdown + fences; (6) query indent; (7) syntax-aware brackets; (8) outline.

### Bottom line

zed's text engine is ~18k lines of collaboration-grade machinery with a decade of bug history; rook's is ~2.5k lines that already converged on the right semantics (save-point modified flag, deterministic undo, incremental reparse, oracle testing) for a single-replica, agent-through-the-filesystem editor. Keep the small core — it is a velocity asset, not a deficit. Spend the stolen patterns where rook's daily-driver workload actually binds: stop flattening (LSP sync, reparse), fix the shared-buffer highlighter, put coordinate types and fuzz harnesses in place BEFORE wrap/folds/injections add the coordinate spaces where zed's 50 worst bugs lived, and ship markdown highlighting — the most visible gap in a terminal whose thesis is agent transcripts.

## Editing: vim, completion, LSP

### Vim emulation — `zed/crates/vim` vs `app/src/editor.zig`

**VERDICT: rook is architecturally ahead and behavior-behind — the pure keystroke-model dodges zed's whole GUI-mount bug tail, but four confirmed divergences from real vim are live today, and zed's automated neovim oracle is a process advantage rook must copy before adding more surface.**

Zed's vim mode is ~34k lines / 1134 commits (356 fix-labeled) layered over the GUI editor's selection/display-map machinery: a 40+ variant `Operator` enum, ~70 motions with a single `Motion::range()` chokepoint implementing vim's exclusive/inclusive/linewise promotion table verbatim (crates/vim/src/motion.rs:1334-1469, citing neovim's ops.c by URL), ~20 text-object families including tree-sitter Method/Class/Comment, and action-level dot-repeat with a years-long bug tail. Rook's vim core is 13.6k lines inside app/src/editor.zig, a pure bytes-in/styled-grid-out model over its own rope, grapheme-cluster-native everywhere — zed's entire multibyte-panic and display-map crash classes (most of their 88 panic commits) are structurally impossible in rook. Rook's keystroke-level dot-repeat recorded by result (recordStep, editor.zig:2107-2141) is vim's actual redo-buffer architecture and gets for free what cost zed six fix commits: `"add .` keeps the register, dot-after-macro works.

But reading rook against zed's fix history found **four confirmed bugs**, each with zed's commit as an executable spec:

1. **`3d2w` deletes 32 words, not 6** — one `count` field concatenates digits across the operator (editor.zig:4574-4577); vim multiplies pre×post counts (zed state.rs:256-259, vim.rs:1369-1380).
2. **`2daw`/`d2aw` drop the count** — applyTextObject (editor.zig:5779) zeroes count; textObject() takes none (zed 4dd54c6742).
3. **`cw` is three special cases, not one remap** — editor.zig:5417 remaps cw→ce unconditionally; on whitespace it must act as dw, and on a word's last char scanWordFwd (6027-6049) advances into the next word (zed 5c2f27a501, 4b9334b910).
4. **`d}` with no trailing blank line stops one line short of EOD**, and the col-0 linewise promotion stores a charwise register (editor.zig:6128-6159; zed f2813f60ed / #29490 + motion.rs:1429-1447).

Patterns to steal:
- **Automated vim-oracle harness with recorded goldens + at-each-offset sweep** [medium] — zed's `NeovimBackedTestContext` drives zed and embedded `nvim --embed` with identical keystrokes, asserts text+mode+registers, records 310 golden JSONs for CI replay; `simulate_at_each_offset` sweeps one test across every cursor position. Rook already trusts `vim -Nu NONE` as oracle (editor.zig:9232) but transcribes by hand — all four bugs above would have been caught mechanically. zed: crates/vim/src/test/neovim_backed_test_context.rs → rook: editor.zig tests + new app/src/testdata/vim/*.golden.
- **One (range, MotionKind) seam** [medium] — implement vim's promotion table once instead of per-motion-family; prerequisite for dv/dV forced motions. zed: motion.rs:1334-1469 → rook: make motionCharwise/motionPara return (range, kind) into one applyOp instead of calling opRange/opLines (6478-6552) directly.
- **Register shape through the macOS pasteboard** [medium] — zed serializes ClipboardSelection JSON alongside the text so linewise yanks survive ⌘C/⌘V across apps. zed: state.rs:215-247, normal/paste.rs:104-125 → rook: paste.zig + macos.zig pasteboard glue (RegKind exists at editor.zig:297).
- **Marks persistence + A-Z global marks** [medium] — rook already did the hard part (edit-anchored marks via onBufferEdit, editor.zig:5878-5893); persist to workspace state on close like zed's SQLite vim_marks (state.rs:1811). Change list g;/g, [small] is the jumplist template (editor.zig:5827-5871) plus ~200 lines.
- **Surrounds ys/cs/ds** [large] — most-installed vim plugin; zed's 1856-line surrounds.rs plus four fix commits is a prepaid edge-case map; rook's objBracket/objQuote already give the ranges.
- **Close the `d.` recording leak** [small] — rook's dot can record `d.`; replay leaves a dangling armed operator (zed's `d . .` freeze, 4a36f67f94). Suppress `.` from recordStep while op != 0.

Recommendations: (1) fix the four divergences now, each landing with an oracle-verified test; (2) build the automated oracle **before** adding more vim surface; (3) refactor to the MotionKind seam; (4) add plugin-tier features in demand order — ip/ap + sentence objects, gn/cgn, change list, surrounds; (5) skip Helix mode, subword motions, digraphs — 71 commits of churn for a different product bet.

### Completion — zed `crates/editor` completions vs rook's ring (editor.zig:2435-3130)

**VERDICT: rook shipped at zed's 2025 polish level on menu stability by reading zed's endgame, but is at their ~2023 baseline on capability — everything at ACCEPT time (auto-import, snippets, resolve-before-accept) is the gap daily drivers will feel first, and two real race holes are open today.**

Rook's ring (commits 7df3bb6..2634edb) already encodes the geometry lessons zed paid ~6 fixes for, with comments citing zed: side latched per (line, col) so the box can't flip as candidates stream (editor.zig:7553-7563), grow-only width (zed's #30598 fixed-width lesson), cursor-anchored left edge, doc card beside the list, and "no completions" only announced after the server answers (a test rook wrote independently, editor.zig:12488-12502). Its race policy — late answers dropped unless live+same-prefix+selection-untouched, resolve keyed by word not index — is simpler than zed's CompletionId+position machinery and sound for a single-buffer single-cursor editor. The packed-store ring is allocation-light where zed re-collects Vecs, and the sans-io wire (lsp.zig:1699-1822) tests both reply shapes in-process where zed needs a full TestAppContext.

Two live holes:
- **cpl_asked dedup never clears** (editor.zig:2824-2831) — complete after `foo.`, ESC, later type `bar().` — the `.` compares ""=="" and silently never asks the server. Clear it when cpl_live drops.
- **Stale check has no position** (takeCompletions, editor.zig:2954-2958) — a slow answer for prefix "a" asked at line 10 folds into a ring for prefix "a" at line 500, showing members of the wrong receiver. Zed guards every install with initial_position + monotonic id (completions.rs:380-389).

Where zed is decisively ahead: `additionalTextEdits` with resolve-before-accept (auto-import — the mechanism gopls/tsserver/rust-analyzer use), the overlap-skip rule (skip extra edits overlapping the primary except zero-width boundary insertions, #26136/#56973), snippets with tabstops/choices (crates/snippet, ~360 lines), insert-vs-replace intents, and a sort-tier table pinned by ~10 regression tests (word-start demotion, exact-match first, sortText only after fuzzy score — each test a shipped fix).

Patterns to steal:
- **additionalTextEdits + resolve-before-accept** [large] — zed: lsp_store.rs:7409-7556 → rook: cplAccept/cplPlace + lsp.zig onCompletion. Biggest capability gap.
- **filterText split from insert text and label** [small] — rook fuzzy-matches insert text; servers routinely differ (tailwind/vtsls — zed 76e3136369). One more blob in the ring. Do textEdit-range-aware placement at the same time — the range is parsed at lsp.zig:1745-1751 and dropped at the macos.zig seam.
- **isIncomplete plumb-through + skip-the-wire** [small] — parsed at lsp.zig:1721, dropped at lspmgr; carrying it deletes a request per keystroke (zed 17cf865d1e).
- **Resolved-doc cache surviving ring rebuilds** [small] — cplReset destroys doc+raw every keystroke, re-firing resolve for the row you're resting on (zed's preserve_markdown_cache, 506beafe10).
- **Sort-tier table + zed's test corpus** [medium] — port code_completion_tests.rs as Zig tests; free already-paid-for regressions.
- **Reverse row order when latched above** [small] — best candidate adjacent to the cursor (zed #23446); rook's latch + zed's reversal beats either alone.
- **Defensive snippet strip** [small] — insertTextFormat==2 text (`${1:arg}`) currently goes into the buffer literally via cplPlace; strip placeholders to defaults until a real snippet engine (port crates/snippet [large]) lands.
- **Signature help auto-shown after accept** [medium] — hoverdoc.zig and float machinery are already the hard parts.

Bug lesson worth flagging: the prefix copy truncates at 256 bytes (editor.zig:2792) and can split a UTF-8 sequence mid-cluster — truncate at the previous cluster start. Zed's multibyte panics clustered exactly at completion confirm (448db20eaa, da82eec4cb).

Recommendations, in order: fix cpl_asked clearing and add position to the ask/answer tuple (both small, both live races); ship additionalTextEdits/auto-import; parse filterText + textEdit range; plumb isIncomplete; doc cache; sort tiers with ported tests; snippet strip now, snippet engine later.

### LSP — zed `crates/lsp` + `lsp_store.rs` vs `app/src/lsp.zig` + `lspmgr.zig`

**VERDICT: rook's sans-io core is better-shaped than zed's transport at 1/3.5 the code (~4.9k vs ~17.6k lines), but zed is structurally ahead at everything ACROSS TIME — versioned payloads, lifecycle, cancellation — and rook has one live corruption bug plus a product-shaped watched-files gap that hits rook harder than it would hit zed.**

Rook's Session (bytes in via feed(), bytes out via outbound()) makes handshake/crash/hostile-payload tests trivial where zed needs a FakeLanguageServer; the single ordered outbound buffer eliminates a request/notification reorder seam zed actually has; hard caps everywhere (max_pending=64, max_events=256) are protections zed partially lacks — their unbounded outbound channel is a named leak suspect in their own commit 3f16f7b908. Rook already owns scars zed paid for: gopls's semanticTokens.requests requirement, tsgo's lowercased URIs, dotted settings paths, refusing file_ops renames honestly. Both are UTF-16-only by declaration; rook converts at the boundary with correct surrogate handling — fine at its scale.

Zed's crown jewel is versioning: every didChange pushes a {version, snapshot} pair (lsp_store.rs:331, retain 10), and every versioned server payload — diagnostics, formatting — is interpreted against the snapshot of the version it names (buffer_snapshot_for_lsp_version, lsp_store.rs:3176, including the "version 0 means current" server quirk at :3193). Rook parses the diagnostics version (lsp.zig:1495) and throws it away, converting against the live rope with clamping — squiggles sit on wrong lines in the type→publish window.

Live bugs and gaps, ranked:
1. **Formatting has no version guard** (macos.zig:3792) — typing during the format round trip garbles the file. Rename already refuses on `ed.buf.version != ed.buf.lsp_version` (macos.zig:4197); formatting needs the identical check. **Live text-corruption bug, small fix.**
2. **Shutdown sends `exit` immediately after the `shutdown` request** (lsp.zig:955-960) — the exact race zed shipped and fixed twice (629b8cd872, 5f3e7a5f91, 2658b2801e); servers that persist caches on graceful shutdown (rust-analyzer, clangd) lose them.
3. **No didChangeWatchedFiles** — client/registerCapability is acked null. Rook IS a terminal: `go get`, `git checkout`, codegen in the next pane are its bread and butter, and today they all silently desync gopls. The gap a Zed/VS Code switcher hits in their first hour.
4. **No restart path** — a crashed server's Entry stays in Manager.servers forever (lspmgr.zig:357-365), leaking its Session and permanently blocking the (lang,root) slot; one gopls OOM = no LSP until relaunch.
5. **workspace/applyEdit answered null and discarded** (lsp.zig:1421) — command-backed code actions (gopls commands, eslint fixes) silently no-op; spec reply is `{applied:bool}`.
6. **$/progress dropped** (lsp.zig:1453) — gopls indexing a big repo for 30s looks like "LSP broken"; also server stderr goes to /dev/null (lsp.zig:2169), so init failures say nothing.
7. **No CRLF normalization** of incoming edits — zed's one-line d87dfaa4b3 killed "cursor jumps to EOF" for every CRLF-emitting formatter.
8. **No timeouts or $/cancelRequest** — every keystroke's superseded completion keeps computing on the server; a hung-but-alive server strands asks until the max_pending overflow evicts them (zed: cancel-on-drop lsp.rs:1500-1510, 120s reap).

Patterns to steal (beyond the fixes above): versioned sent-text ring for diagnostics conversion [medium] — rook sends full text anyway, so the snapshot is literally the didChange payload; keep the last ~4 per (doc, server); zero-width diagnostic expansion + swap-inverted-inbound/refuse-outbound [small] (zed lsp_store.rs:2819-2828, language.rs:1583-1596 — and their #36223 lesson: don't warn-log per occurrence on the hot path); per-server RPC trace ring behind `ctl lsp trace` [small] — pays for itself with the next server added to the catalog; crash restart with an explicit-stop suppression set [medium] (zed shipped the auto-respawn bug e77b18bad8; rook's legend-in-Session design makes a fresh Session clean by construction — keep it that way).

What NOT to copy: half of zed's 15k-line lsp_store is collab/remote proto plumbing, dynamic-registration bookkeeping, and multi-worktree modeling rook's single-root Manager doesn't need. Rook doesn't need zed's architecture — it needs about six of zed's scars: shutdown ordering, version guards, CRLF, watched files, applyEdit, progress. Each is separable and small-to-medium in rook's codebase.

Recommendations, in order: (1) formatting version guard — now, it's corruption; (2) shutdown ordering — now, small; (3) CRLF normalize — cheap insurance; (4) didChangeWatchedFiles — highest product leverage; (5) diagnostics versioning off the parsed-and-dropped version; (6) cancel/reap request hygiene; (7) restart + `ctl lsp restart`; (8) real applyEdit; (9) $/progress in the status row + stderr capture; (10) diagnostics display polish + RPC trace ring.

## Platform: rendering, terminal, navigation, fs

Four subsystems where rook and Zed both have real code. Pattern across all four: rook's architectures are leaner and often faster; Zed's value is six years of fleet-scale scar tissue — shipped crashes, numbered issues, regression tests. The strategy everywhere is the same: **don't adopt Zed's architecture; adopt its bug history.**

### GPU rendering & frame loop

**VERDICT: rook ahead where it counts for a terminal — but carrying three live exposures Zed already paid for.**

Zed renders through gpui: a retained-view scene graph (crates/gpui/src/scene.rs) with per-frame BoundsTree z-ordering, 8-way sort+merge batching, pooled instance buffers recycled from GPU completed handlers, per-display CVDisplayLink registry, occlusion gating, and presentsWithTransaction synchronous resize frames (crates/gpui_macos/src/window.rs:2818). Rook (app/src/render.zig, 838 lines + the frame loop in app/src/macos.zig) is a cell grid: 16 bytes/cell, two instanced draws per pane, fill p50 37–56µs, encode ~35µs, `cat` 150MB in 0.89s vs installed Ghostty's 1.61s (app/PERF.md). Zed's architecture cannot reach those numbers and doesn't try. Rook is also ahead on latency honesty: maximumDrawableCount=2 (Zed ships 3), opaque-layer direct scan-out measured (present_lag 13.8→7.0ms), and true key-to-photon instrumentation (NSEvent.timestamp → presentedTime, echo-gated) that Zed has no equivalent of.

Zed is ahead on multi-display correctness, frame-resource lifetime, and pacing — and rook has live exposure to three of its paid-for bugs:

- **cells_buf lifetime race** — rook rewrites one shared MTLBuffer every frame with no completion fence (render.zig:356); frame N+1's CPU fill can race the GPU's read of frame N. Zed's pool exists for exactly this (commit 3d76ed96f5: "the GPU is actively reading from it"). Symptom: rare transient garbled cells under firehose/resize.
- **ProMotion downclock** — rook's zero-idle-frames dirty-skip lets the panel drop refresh between keystrokes, inflating the next key's latency. Zed holds presentation ~1s after high-rate input (commit 15edc46827). PERF.md's unexplained quiet-key p50 wobble (16.6→21.4ms, p95 stable, 120Hz M3 Max) matches this diagnosis exactly. **TESTED 2026-08-06, REJECTED**: the hold cost +8.6ms p50 — with two drawables, continuous presenting queues every echo frame behind a hold frame (PERF.md's dated entry has the table). Zed can afford it at drawable depth 3 with no photon instrument; rook cannot. The wobble's stronger suspect is now bench-window occlusion variance.
- **Stale scale on screen change** — rook reads backingScaleFactor only in viewResized (macos.zig:1411), which fires on frame changes, not screen changes; and the one immortal display link paces off the main display forever (wrong cadence on a 60Hz external). Zed's #38269/#38524.

One thing rook got right by accident: it never stops or releases its CVDisplayLink — Zed's display_link.rs header documents two segfault classes in link teardown (#32116, Sentry ZED-7XR). Keep the immortal link; gate with flags, never CVDisplayLinkStop.

Patterns to steal:
- Ring of 2–3 cell buffers recycled via addCompletedHandler [small] — zed metal_renderer.rs:57-110 → app/src/render.zig cells_buf + macos.zig drawFrame (CompletedBlock plumbing already exists at macos.zig:5336)
- ~~ProMotion hold: keep presenting ~1s after input_mark~~ — tried and reverted (see above; PERF.md 2026-08-06). The dirty-skip IS the latency strategy at drawable depth 2.
- windowDidChangeScreen handler: re-read scale + CVDisplayLinkSetCurrentCGDisplay, guard NSWindow.screen==nil [medium] — zed commit 46eb9e5223 → macos.zig next to the resize observer (~line 1318)
- Occlusion gating: early-return in displayLinkCallback while hidden, one forced frame on reveal — do NOT stop the link [small] — zed window.rs:2552 → macos.zig:9286
- Atlas: grow by adding a texture instead of resetting the world [medium] — rook's reset (render.zig:583-590) invalidates uvs already written into the cells buffer mid-frame; zed's list-of-textures never moves a uv (metal_atlas.rs:95-191; clamp 16384², bigger crashes validateWithDevice)
- presentsWithTransaction + synchronous draw during live resize [medium] — zed window.rs:2818 → macos.zig viewResized; draw_lock already serializes the cross-thread part
- Comptime layout asserts on CellData and Uniforms matching the RRUniforms ones (render.zig:225-229) [small] — rook already paid this class once ("rect landed 8 bytes early")

Skip: scene sort/batching, BoundsTree, subpixel variants, path MSAA — rook's grid makes them unnecessary, and adopting them trades away the 37µs fill that is the moat.

### Terminal emulation

**VERDICT: rook outclasses Zed as a terminal, and it is not close — but Zed owns the terminal-as-IDE-surface glue, and rook is uniquely cheap to build it.**

Zed wraps a pinned alacritty_terminal fork behind ~17.5k lines of glue (crates/terminal/src/terminal.rs, 5,469 lines), copying the ENTIRE visible grid into a fresh Vec<IndexedCell> on every wakeup (alacritty.rs:809) and re-shaping text through gpui each frame. Its own commit log concedes "scrolling is slow, proportional to line length" (#44714). Rook is the emulator's host (app/src/session.zig): ghostty-vt gives grapheme-correct wide text, kitty keyboard, page-based scrollback — all things alacritty lacks — rendered straight off the emulator's pages under a brief lock. Security posture favors rook too: OSC 52 write-only by construction (session.zig:450-458) where Zed answers clipboard reads; paste stripping xterm-complete even unbracketed. And answering DA1/DSR in-band on the parse thread (session.zig:388-519) structurally guarantees the response-ordering property Zed had to document as a hazard (terminal.rs:1653). Do not move those responses to the main thread later.

Zed's one winning axis is glue: cmd-click any path/URL with per-line-cwd-correct resolution into the editor at line:col, semantic double-click, task integration, shell-readiness handshake. Rook already owns both sides of the seam Zed spends the most glue on — the editor is in-process, ghostty-vt already parses OSC 8 into cells (rook just never reads them), regex engine and libproc cwd exist — so the flagship features cost rook less than they cost Zed.

Live bugs and exposures:
- **Process teardown orphans jobs (HAS THE BUG)**: ⌘W is `kill(shell_pid, SIGHUP)` (macos.zig:2356) and terminateCallback is empty (macos.zig:9307). A SIGHUP-trapping foreground job or a job in its own process group survives pane close. Zed paid twice (#47412, #61467): capture shell + foreground pgids via tcgetpgrp BEFORE the master closes, SIGTERM both groups, 100ms grace, SIGKILL; never killpg(0). ~30 lines — tcgetpgrp plumbing already in session.zig:24.
- **Alt-screen wheel (small bug)**: macos.zig:1968-1974 sends arrows whenever alt screen is active, ignoring DECSET 1007 (ghostty-vt tracks it), and reads screens.active_key without the session mutex — a data race with the reader thread.
- **SHLVL leaks through** (session.zig:356 sets only TERM/COLORTERM): rook relaunched from a terminal reports SHLVL=2 in its shells (zed #44835).
- **Grandchild holding the slave fd**: readLoop exits on EOF only; a pane whose shell dies while a background grandchild keeps the slave open never collapses.

Patterns to steal:
- Cmd-click hyperlink + path detection: OSC 8 cell-id walk → scheme-anchored URL regex → path regexes with path/line/column named captures, wall-clock timeout, trailing-punctuation/unbalanced-paren sanitization, wide-char offset mapping [large] — zed hyperlinks.rs (whole edge-case inventory) → new app/src/hyperlink.zig + mouseCallback + the existing editor open path. Gate on ⌘-held + mouse-delta throttle; Zed needed two perf rescues here (#44407, #44721 — hover was O(line²))
- Per-line cwd history: stamp scrollback position when paneInput sees '\r', record (position, cwd) pairs, resolve clicked relative paths against cwd_at_line [small] — zed terminal.rs:2848-2897, commit 184e124bba → session.zig + the existing HUD-tick cwd poller
- Double-click word / triple-click line selection, semantic-break set including '─' (box-drawing, #62076), 2px drag threshold before selection starts (#58970) [medium] — mouseCallback never reads clickCount today
- Init-command startup marker handshake (echo marker, scan output, then inject) [medium] — zed terminal.rs:2100-2154 → session.send plugin ops when the agent layer returns; their vacuity-trap test matches rook's own testing philosophy
- Off-thread incremental search via ghostty-vt tick/feed + all-match highlight + invalidate on resize [medium] — rook's own comment flags the frozen-window risk (session.zig:228-236); reflow moves matches (zed #43507)
- DisplayOnly terminal (emulator, no pty, OSC 52 ignored) for agent tool output with full ANSI fidelity [medium]

### Fuzzy matching & navigation surfaces

**VERDICT: rook covers the same surfaces in ~2,150 lines that Zed spends tens of thousands on, with a cleaner matcher story — but everything runs synchronously on the event thread, and three daily-driver features are missing.**

Zed runs THREE fuzzy scorers mid-migration (crates/fuzzy, crates/fuzzy_nucleo over the nucleo library, plus an ad-hoc inline matcher at file_finder.rs:1164) — the same query can rank differently in different pickers. Rook has one matcher with two integer weight profiles (app/src/fuzzy.zig, ident/path) and cannot have that bug. Rook's determinism contract (filelist.zig sorts by path; results agree across machines), shared index+ignore policy between ⌘P and ⌘⇧F, and top-K insertion sort during scoring are all positions Zed had to approximate with tiebreak layers. Rook's ASCII-only byte folding also makes it structurally immune to Zed's İ-expansion panic family (fixed three separate times: #30546, #52989, #22032) — if unicode folding ever lands via unicase.zig, it MUST keep 1:1 unit mapping.

Where rook is materially behind: ⌘P walks the repo synchronously UNDER draw_lock and re-scores all ≤20k paths per keystroke on the event thread (macos.zig:2624-2680) — the only place rook can visibly stall input; no MRU/history ranking, no proximity tiebreak, no order-independent multi-word queries (the single feature Zed built its entire second fuzzy crate for, #14428), no path:line:col; ⌘⇧F is literal-only and **searches stale disk under dirty buffers** — for a product whose premise is agents editing files while you watch, that's the visible-wrongness case; and rook has no symbol/outline picker at all.

Patterns to steal, roughly in order:
- Buffer-aware ⌘⇧F: scanFile consults the docs.zig registry and searches live Buffer content for dirty files; keep buffer-sourced results in path-sorted order (zed's #44135 ordering trap) [medium] — search.zig scanFile
- Background matching contract: per-keystroke cancel flag checked per candidate + monotonic search_id guard on publish + extend_old_matches (keep old sorted results when cancelled and query unchanged — no flicker on fast typing) [medium] — zed file_finder.rs:1081-1124 → move filelist.load + scoring off the event thread, reusing the sr_pending swap pattern macos.zig already has
- CharBag prefilter: one u64 per path (2 bits/letter, 1/digit), superset mask test before the DP [small] — zed char_bag.rs → filelist.Index; turns 20k DP runs per keystroke into 20k mask tests
- Multi-atom queries: split needle on spaces, all atoms must match, sum scores, union positions — a wrapper loop, no nucleo needed [medium] — fuzzy.zig matchAtoms
- MRU with Zed's guardrails baked in day one: empty query = recents; non-empty matches history on FILENAME only, requires a matched position in the basename; current file bubbles to top (file_finder.rs:686-783 — three PRs of pre-paid design) [medium]
- path:line:col parsing in ⌘P (agents and compilers emit exactly this) [small]; proximity tiebreak (component distance from focused file) in palInsertScored [small]; reuse one 2MB scan buffer instead of alloc/free per file (search.zig:143) [small]; per-command hit counts for the ⌘K palette [small]
- Symbol picker via documentSymbol through lspmgr, ranked with fuzzy.ident in the existing palette chrome — rook has no outline navigation at all [medium]

Bug lessons that transfer: min-one-worker + remainder-split when candidates < CPUs (zed #54371, #48798 — silent zero results on 1-CPU) the day any worker pool lands; the shared-matcher blast radius (a "perf improvement" to Zed's matcher crashed a different picker and was wholesale reverted, #22543 — fuzzy.zig serves both ⌘P and completion, run both profiles' suites when tuning); zero-width/multibyte progress test for regex.zig before a ⌘⇧F regex toggle ships (zed's replace-all hang, #54422).

### Worktree scanning, file watching & git

**VERDICT: different games honestly played — rook's "trust the filesystem, read it when asked" is ahead on several points Zed patched after shipping, but the gap sits exactly on rook's review-first roadmap, and there are two live bugs today.**

Zed's stack (crates/worktree, ~15k lines + ~30 race-fix commits) is a persistently-snapshotted live project model: SumTree snapshots, background scanner, FSEvents with overflow-as-first-class-event, .git noise filtering, git status via the git binary, diff hunks as CRDT anchor ranges. It exists to serve push-driven panels at monorepo scale. Rook deliberately doesn't play: 1Hz buffer polls, per-open ⌘P walks, branch from .git/HEAD with zero subprocesses (git.zig). Within that scope rook independently pre-fixed several Zed bugs: three-field DiskState (mtime+size+inode — Zed added size only after shipping #49436's "buffer permanently stuck empty" race), error-tolerant libc dir walking (Zed's closedir panic was a crash-loop-on-launch, #59953), nested-.gitignore in every dir (rook's own 26k-vendored-files bug, paid and documented at filelist.zig:154).

Live bugs:
- **Deleted-file silent data shredder (EXPOSED TODAY)**: buffer.zig:169 counts a failed stat as "changed on disk"; pollBuffersLocked reloads, initFromFile maps FileNotFound to an empty buffer with disk=null. A branch switch that removes an open unmodified file silently empties the pane, and a later :w resurrects the deleted file with no warning. Fix: treat ENOENT as its own "deleted" state — keep contents, badge the pane, keep the save guard armed.
- **Reftable branch display (PLAUSIBLY EXPOSED)**: git.zig parseHead trusts `ref: refs/heads/<name>` verbatim; on a reftable repo (git 2.45+ `--ref-format=reftable`) .git/HEAD is a compat stub naming an invalid ref — the status bar (rook's most-seen surface) would display a lie. Gate on `.git/reftable` existing (zed 300fde7b70).
- Smaller: no binary sniff on Editor.reload (an agent redirecting binary into a watched file feeds NUL-laden megabyte lines to the grid at 1Hz — zed 109c2238aa added a first-8KB NUL check); docs.zig registry keyed by path string without canonicalizing, so case-variant/symlinked paths on APFS create two Buffers racing each other via one inode (save already canonicalizes; open should too).

The strategic gap: no push-based change detection — agent-created files are invisible to ⌘P and the tree until reopen, which contradicts rook's own premise ("things are editing your files while you look at them", buffer.zig:12) — and no git status or diff-vs-HEAD gutter, which the review-first roadmap (RookTask review, verdict artifacts) needs. Zed's history is a free map of every race in that territory.

Patterns to steal (for when those features land — design the failure modes out, don't patch them out):
- The .git filename-based skip list (index.lock, COMMIT_MESSAGE, FETCH_HEAD, objects/, hooks/, *.lock, logs/ except logs/refs/stash…) matched by FILENAME so linked worktrees inherit it — the bare-.git + index.lock combination is a proven infinite-loop generator because `git status` itself takes index.lock [small] — zed worktree.rs:4753-4848, fixed three times (4129fc87d8, 0ba60d8a44, 2408640e5f). rook's whole workspace model runs on linked worktrees, so it meets this event shape on day one
- Git status by shelling `git status --porcelain=v1 -z --no-renames --untracked-files=all`, debounced per repo, never writing inside .git to configure it; commondir changes fan out to ALL worktrees sharing it (zed 11d216d8bf) [medium] — rook's "never spawn git" rule is right for the 2Hz branch read and wrong for status
- Diff hunks as position-watched ranges over Buffer.watch(): async diff vs HEAD on a worker, hunks stored as offset ranges registered through the existing EditFn seam (buffer.zig:69 exists precisely so "anything holding a POSITION can move it"), old-vs-new hunk compare for minimal gutter invalidation [large] — zed buffer_diff.rs:117/1351 translated to rook's architecture; editor.zig's diff_add/del/hunk styles are already there
- Generation-versioned background ⌘P index: scan_id/completed_scan_id two-counter pattern, serve the previous index instantly, atomic swap; convert filelist's per-directory ignore-set copies to a parent-pointer chain (zed IgnoreStack) while in there [medium]
- FSEvents, when it lands: MustScanSubDirs as a first-class Rescan kind, ancestor-coalesced, max one rescan per drained batch, git caches invalidated under the rescanned path, cooldown on watch-registration failure (zed fs_watcher.rs — a `git pull` or `pnpm install` overflow pegging CPU is the first production failure) [medium]
- Randomized incremental-vs-rescan oracle testing for any incremental index: random fs mutations, incremental update, assert equality with a from-scratch walk (zed test_random_worktree_changes) — this is rook's vim-oracle method applied to filesystems; build the harness before the first incremental refresh ships [medium]

### Priority order across the section

1. **Live bugs, this week**: deleted-file→empty-buffer (buffer.zig:169), process-teardown escalation (macos.zig:2356/9307), cells_buf ring (render.zig:356), reftable branch check, alt-screen wheel mode-1007 + mutex.
2. **Measured experiments**: ProMotion hold, then re-measure PERF.md's quiet-key wobble; CPUCacheModeWriteCombined only via interleaved e2e A/B (Zed reverted it twice before it stuck).
3. **The flagship build**: cmd-click path/URL detection + per-line cwd history + buffer-aware ⌘⇧F — the three features a daily driver feels every hour, all cheaper for rook than they were for Zed.
4. **Roadmap-gated**: git status + anchored diff-hunk gutter with the skip-list/commondir discipline baked in; background ⌘P + MRU + multi-atom; FSEvents with the overflow story written first.

## Product: agents, config, multibuffer

### Agent integration: Zed's ACP + action_log vs rook's plugin vocabulary

**VERDICT: differently positioned — Zed owns in-editor review and structured agent data; rook owns machine-wide supervision, attention, and distance. The overlap is coming, and rook should meet it by speaking ACP as a client, not by chasing hunk review.**

Zed's agent stack has one organizing insight: external agents and the native agent are the same type. Everything — Claude Code (via the `claude-code-acp` npm adapter), Gemini, opencode — speaks ACP as newline-JSON-RPC child processes (`crates/agent_servers/src/acp.rs`, ~185KB), behind one `AgentConnection` trait so the panel, review flow, and persistence are agent-agnostic. Above it: `AcpThread` models turns as typed entries (tool calls with buffer-anchored locations, permission requests with the reply channel embedded in the state machine), per-prompt **git checkpoints** shown only when the tree actually changed, and the crown jewel — `crates/action_log/src/action_log.rs` (130KB, ~2000 lines of tests): per touched buffer, a `diff_base` of "what the user has accepted" plus row-range unreviewed edits, with **user edits rebased into the base** when they don't conflict, so review shows only agent work even while the human edits around it. Keep = splice into base; reject = revert with undo capture; created/deleted/resurrected files all have defined semantics.

rook has almost none of this **by strip** (STATUS.md, docs/OWED.md), and what it has is a different shape: the plugin protocol (`app/src/plugins.zig`, docs/plugins/VOCABULARY.md) is newline-JSON like ACP with roles inverted; `plugins/claude` reads Claude Code's own jsonl transcripts read-only; actuation is keystrokes into the PTY (`session.send`). That transcript path is provider-neutral today and — crucially — **machine-wide**: rook sees every Claude Code session on the box, including ones it didn't spawn. Zed cannot supervise what it didn't launch, has no attention/ranking layer for "which of my nine agents needs me," no membrane, and no phone story. The dangerous asymmetry: Zed can add notifications more easily than rook can add review — so rook's window is speed on the supervision stack while adopting ACP's structured data.

One place rook is already ahead of a Zed bug class: `transcript.Snip` clamps truncation to rune starts (plugins/internal/transcript/transcript.go:496) — the UTF-8 boundary bug Zed paid for twice (#57100, #58432).

**Patterns to steal**

- **ACP client plugin** [large] — spawn `claude-code-acp` from a plugin; map session updates → items, tool calls → children, `session/request_permission` → `attention.raise` with typed option actions. Upgrades transcript-scraping to structured tool calls and lets asks be answered from the phone — the exact rung-3 payload. Keep PTY as fallback. zed: `crates/agent_servers/src/acp.rs`, `crates/acp_thread/src/acp_thread.rs:860-1345` → rook: new `plugins/acp`, answers VOCABULARY.md detail-ref open question #1.
- **Per-prompt git checkpoint, shown only if the tree changed** [medium] — checkpoint on send, diff after turn, attach "restore" to the digest row only when something changed. Highest-value phone-safety feature per line of code. zed: `acp_thread.rs:3688-3700, 4062-4124`, `git_store.rs:9049` → rook: `app/src/git.zig` + digest actions in `plugins/agent`.
- **The reviewed-base rebase** [large] — when review returns, adopt action_log's model: `diff_base` + row-range agent edits, user edits rebased in; the ~2000-line test list (overlapping edits, reject-created-file-with-user-edits, commit-during-review) is the spec. zed: `action_log.rs:322-368, 634-887` → rook: a core `reviewlog.zig` beside buffer.zig.
- **Handshake raced against child exit + stderr tail** [small] — plugins.zig currently dup2s plugin stderr to /dev/null (plugins.zig:590-594); a plugin that panics on spawn costs a timeout plus a debugging session instead of one glance. zed: `acp.rs:910-963` → rook: the fork block in `app/src/plugins.zig:585-610`.
- **Generation counters on async turn completion** [small] — plugins/agent's async summarize can attach a slow digest to a session whose state already flipped. zed hit this twice (commit 5c90b0664f; acp_thread.rs:3768-3780) → rook: `plugins/agent/main.go` pipeline.
- **`InterruptedByFollowUp` ≠ declined** [small] — an ask dismissed by a follow-up message is not a rejection. The verdict ledger (VISION.md:156) trains the autonomy ladder; polluting it with false rejections is unrecoverable later. zed: `acp_thread.rs:1230-1245` → rook: ask/verdict schema on the mailbox rails.
- **Persistence split for the digest journal** [medium] — versioned rows, every field defaulting on read, hot metadata separate from compressed cold bodies. Zed shipped "threads vanished after upgrade" (#54723) as tuition. zed: `crates/agent/src/db.rs:29-141` → rook: the digestlog jsonl seam (VISION roadmap #2).
- **Rung-4 security invariants, verbatim** [small] — hardcoded deny list no config overrides; refuse to even offer approval for commands containing shell substitutions (approved text ≠ executed text); bind path grants to the canonical resolved target at approval time (symlink TOCTOU). zed: `tool_permissions.rs:12-65`, `terminal.rs:36-50` → rook: session.send gates when "act within policy" lands.

**Bug lessons rook is exposed to**

- Byte-windowed UTF-8 slices landing mid-character (zed 14befe2151, 19b7625a67): guarded in transcript.Snip, but the old agentmon 2KB-cap bug was this class — repeat the clamp in any future jsonl windowing or Zig `[]u8` truncation.
- Stale async completions clobbering newer state (zed 5c90b0664f): live in miniature in plugins/agent's watch/summarize loop today.
- Child death re-entering the host mid-mutation (zed a5e78b02de, RefCell double-borrow): plugins.zig's pump-thread ownership mostly guards this, but audit who may remove a plugin handle and from which thread.
- Auto-accept-on-commit must gate on the new base *content* loading, not "something changed" (zed dae1b20289): rook's git reads are filesystem-snapshot based, so the ordering hazard is real the day review lands.

**Recommendations (priority order)**: (1) prototype `plugins/acp` before designing more transcript heuristics; (2) ship per-prompt git checkpoints now — no protocol dependency; (3) put a version field in digest-journal row one; (4) add InterruptedByFollowUp to the ask schema before the ledger exists; (5) the small plugins.zig spawn-hardening pass; (6) write the review design doc against action_log's test list before writing review code; (7) do **not** chase in-editor hunk review near-term — exploit machine-wide visibility and the attention layer, where rook is uncontested.

### Config, keymaps, themes, extensibility

**VERDICT: rook ahead on the authoring/apply pipeline (preview-as-diff, canonical bytes, grants on the user's side of the trust boundary); Zed years ahead on runtime resolution (layered settings, context-predicate keymaps, migrations) — steal the semantics, not the five-layer file model.**

Zed resolves settings through an explicit precedence lattice (Default < Global < User < Server < Project, `crates/settings/src/settings_store.rs:187-208`) over exactly **one** all-Option `SettingsContent` merged by one `MergeFrom` path — so a "two decoders drift" bug is structurally impossible. Its keymap is a real context-predicate language (`gpui/src/keymap/context.rs`: idents, `==`, `!`, `&&`, descendant `>`, evaluated by deepest-depth-of-match with later-added-wins), with source-precedence unbinding. Its migrator (`crates/migrator/src/migrator.rs:1-15`) is a 35-deep append-only dated chain of text-preserving edits with a vacuity self-check — the paid-in-full tuition for three years of renames.

rook's `app/src/config.zig` is deliberately flat — one file, two readers, no layering ("layering is what provenance is for, later"), 1Hz digest poll instead of fs-watch. The environments pipeline is where rook is genuinely ahead and Zed has nothing: config-as-program with typed SDKs, canonical-bytes emit, preview = diff-by-node-id before an explicit apply (`envapply.zig:25-31`), plugin grants declared in the *user's* environment rather than the extension's manifest — Zed's manifest capabilities put the declaration on the wrong side of the trust boundary. But rook's weak spots are self-inflicted: **two parallel option decoders** (`loadToml` vs `applyEnvOption`) that must agree by hand — the file itself documents the format_on_save drift bug this already shipped (config.zig:878-883) — plus a single-leader fixed-array keymap and 3 builtin themes with no overrides.

**Patterns to steal**

- **One comptime option table driving both decoders** [medium] — name, aliases, bounds, setter once; TOML-string and json.Value coercion become two thin adapters. Kills the drift class the format_on_save bug proves is live. zed: `settings_content/src/merge_from.rs` → rook: `app/src/config.zig` twin if/else chains.
- **Per-node tolerant graph parse** [small] — parse nodes as `std.json.Value`, coerce field-by-field, so no future kind-dependent field type fails the whole document (rook already paid once: the plugin argv-array collision silently dropped fonts/theme/leader, config.zig:757-770, test :1482). zed: `keymap_file.rs:93-99` → rook: `loadEnv`/`loadKeybindsEnv`.
- **Unbind with source precedence** [small] — `'<leader>x' = 'none'`, tagged default < preset < user; a preset's disable must not eat the user's rebind (zed got it wrong first: `gpui/keymap.rs:196-226`). → rook: Keybinds.bind path.
- **Theme refinement overlay** [small] — comptime-generate an all-optional mirror of Theme via `@typeInfo`, merge over the builtin, expose as graph nodes. Cheapest visible win here, and the natural first per-node provenance demo. zed: `theme_settings.rs:182-239` → rook: `app/src/theme.zig`.
- **Append-only migrations** [medium] — dated chain, text-preserving line edits for TOML / node-id rewrites through the canonical emitter, idempotent-by-detection (migrated == emitted is a byte check). Retire the permanent lsp→editor-lsp stderr notice as migration #1. zed: `migrator.rs:1-118` → rook: new `app/src/migrate.zig`, run on load and on envapply candidates before diffing.
- **Schema emitted from the comptime tables** [medium] — a `rook ctl schema` verb the SDKs and editors consume; restores typo rigor lost to silent-unknown-keys without breaking fail-open, and collapses the hand-kept preset goldens. zed: `keymap_file.rs` schema generation → rook: registry.zig + config.zig.
- **Context-predicate keymatcher** [large, when configurable editor maps land] — contexts as interned-id stacks, predicate AST at config load, depth-then-insertion-order precedence; port zed's edge-case tests verbatim (`gpui/context.rs:736-812` — the NOT-against-all-prefixes semantics are the expensive knowledge). → rook: new `app/src/keymatch.zig`.

**Bug lessons rook is exposed to**

- Stale key-hint display strings lie after a rebind (zed d801b7b12e): **present today in mild form** — `registry.zig` `Command.keys` is documented display-only; which-key routes truthfully via `byAction` but the palette still shows static strings. Route all hint display through live Keybinds.
- A parse failure must never become a base for a write (zed b48dd02d5a deleted users' settings by diffing against a defaulted parse): guarded today only because rook never rewrites config programmatically; exposure opens with any future "set option" verb.
- Sorted per-directory scan with break-on-first-non-match skips valid ancestors (zed b951bd3d6f): rook already met this bug's cousin in filelist.zig's .gitignore handling; use the stack walk when per-workspace scopes land.
- Layers that exist but silently do nothing (zed 8334374398): rook's editor.visual/editor.insert keybind nodes "ride along unconsumed" (config.zig:960-961) — when those scopes gain meaning, an e2e must prove they fire.
- EXDEV on the apply rename (zed 6bd235c1a3): verify envapply's candidate temp file is created inside the config directory, same mount.

**Recommendations (priority order)**: (1) per-node tolerant loadEnv now, with an e2e that one unknown-shaped node loses only itself; (2) one comptime option table on the next config touch; (3) unbind + truthful key hints; (4) theme overrides; (5) schema emission; (6) migration discipline before v1 graph freeze; (7) keymatch.zig only when configurable editor maps arrive.

### Multibuffer: the excerpt surface rook's review thesis needs

**VERDICT: rook behind — no multibuffer at all against Zed's signature surface (8.3k lines + 6.3k-line test file underpinning search, diagnostics, project diff, and agent review) — but well-positioned: Zed's converged design maps directly onto docs.zig/buffer.zig, and rook can adopt the endpoint for maybe a fifth of the code by skipping the abandoned ExcerptId legacy.**

Zed's MultiBuffer (`crates/multi_buffer/src/multi_buffer.rs`) is a stitched, **editable** document over N live buffers. The critical fact: the ExcerptId/locator scheme in older writeups is **gone** — it generated years of ordering panics (0f84a366d9 → revert 667b43083c → 248a3c6c95). The current design orders excerpts globally by PathKey `{sort_prefix: u64, path}` (`path_key.rs:18-23`), one buffer per path, per-file ranges sorted and merged; anchors are (append-only path index, buffer-local position) with **defined** out-of-bounds semantics; refresh reuses excerpts whose range is unchanged so cursor and scroll survive; edits spanning excerpts degrade per-region (insertion to the first buffer, deletions elsewhere, read-only skipped); cross-buffer undo is a transaction map `{buffer → transaction-id}` (`transaction.rs`, 546 lines).

rook's counterparts are three separate mechanisms: `app/src/search.zig` find-in-files (worker-thread scan, hits are **clipped disk snapshots** with (line,col) frozen at scan time), gr-references through the same read-only jump-only panel (macos.zig sr_*), and multi-file editing only as `applyWorkspaceEditLocked` (macos.zig:4140-4305) — which is genuinely good: two-phase validate-then-apply, version guard against stale server answers, per-file undo groups, open-unsaved/unseen-written asymmetry. The substrate is half-built: docs.zig's one-file-one-Buffer registry, buffer.zig's 16-watcher edit-adjustment seam (:69-81), Buffer.version. What's missing is anchors, cross-buffer undo (rename = N per-pane `u`s), live sync between results and buffers, and any stitched renderer. NEXT.md's hunk-first review thesis names exactly the surface Zed has and rook lacks.

**Patterns to steal**

- **PathKey-ordered excerpt table** [large] — the converged design, not the abandoned one: sorted excerpt list above docs.zig, append-only path table so stale anchors stay resolvable, no IDs, no locators. zed: `path_key.rs` (update_path_excerpts :361-615), `anchor.rs` → rook: new `app/src/excerpts.zig`.
- **Randomized reference-model test in the same commit** [small] — naive string rebuild as oracle, random excerpt/buffer mutations, deliberately stale and out-of-bounds anchors. This test style caught nearly every panic in zed's multibuffer history (3b9c38a320) and is rook's vim-oracle method applied to a data structure. zed: `multi_buffer_tests.rs:3629, 2435` → rook: excerpts.zig test block, day one.
- **Excerpt reuse on refresh** [medium] — keep excerpts whose anchor range is identical; the difference between a durable document and the "ground shifts under you" friction rook already logged. Small version applies today: drainSearchLocked resets sr_sel/sr_top to 0 on every search (macos.zig:3214). zed: `path_key.rs:424-449` → rook: excerpts refresh + today's panel.
- **Cross-buffer undo as a transaction map** [medium] — `{doc → group-id-before}` recorded per action; one `u` reverts a rename or a replace-all everywhere. zed: `transaction.rs:457-488` → rook: thin layer over buffer.zig group/seq, first consumer `applyWorkspaceEditLocked`.
- **Replace-all staleness discipline** [small] — store the searched query with results, defer/re-run on stale, and verify each hit's stored text before splicing (two shipped zed bugs: #34897, #50848); keep literal replacement literal, never through regex.zig. zed: `project_search.rs:935-1012` → rook: future replace mode of the sr panel.
- **Context/primary ranges + synthetic-newline invariant** [small] — context clamped to whole lines, adjacent ranges merged (row+1 rule), the joining `\n` owned by the *preceding* excerpt. Three decisions and the fiddliest arithmetic, pre-paid. zed: `multi_buffer.rs:3133-3151, 1809-1827`, `path_key.rs:432-517` → rook: excerpts.zig range builder and render mapping.
- **Diagnostics-view policy triple** [medium, when the aggregate view comes] — 50ms debounce, diff-before-update, retain-excerpts-when-focused/dirty and evict only on blur/save. Each rule was a shipped zed bug (#30494, #42416, #52937). zed: `diagnostics.rs:93, 471-486, 296-339` → rook: excerpt surface over lsp.zig diagnostics.

Explicitly rule **out** cloning zed's diff_transforms (inline expandable hunks — a third of the file's complexity and its worst panic source); rook's readonly diff-Buffer concept already covers excerpts-of-diffs.

**Bug lessons rook is exposed to**

- Stale jump targets **exist today**: hits capture (line,col) at scan time and Enter uses the raw numbers (macos.zig:3280-3307) — edit any buffer after searching and the jump lands on the wrong line. Cheap fix now: verify the stored hit text at the target line, fall back to in-file search.
- Non-ASCII smartcase: search.zig uses `std.ascii.toLower` (:100-105), so case-insensitive search silently fails on non-ASCII — make the promise explicit before replace lands on top of it.
- Strong buffer references resurrecting deleted files (zed 0238d2d180): rook is immune today because it re-reads disk and docs.zig deliberately isn't a cache — an excerpt surface acquiring doc refs per result inherits the class; the eviction hook must exist.
- Over-invalidation (zed cfb4cefb37): sync by comparing stored Buffer.version per doc, the same way lsp_version already gates rename.

**Recommendations (priority order)**: (1) write the excerpt-surface design note before code, citing zed's endpoint (`path_key.rs`), not its 306KB history; (2) ship excerpts.zig + the reference-model test in one commit; (3) first consumer: make find-in-files results editable over shared Buffers (success criterion: edit a hit line in the panel, see it in the pane, `u` in either place); (4) replace-in-files with the staleness discipline and one cross-buffer transaction; (5) backport the two small policies into today's panel now (selection identity across re-search, verify-hit-text-on-jump); (6) when the agent review surface comes, project hunks as excerpts with `sort_prefix` carrying the attention-compression ordering NEXT.md describes.

## Operations: shipping and durability

The two subsystems here are the operational floor under a daily driver: how the app updates itself and reports its deaths, and whether quitting (or crashing) costs you your arrangement. Zed is years ahead on both — and both are places where rook's smaller model means it can inherit Zed's invariants as design rules instead of re-living its incident history.

### Auto-update, crash reporting, and release engineering

**VERDICT: rook behind — badly.** This is the single biggest operational risk in rook's daily-driver posture: no self-update, no crash capture, no channels, not even a log file for a Dock-launched instance.

Zed's updater (`crates/auto_update/src/auto_update.rs`, 1846 lines) is one `AutoUpdater` state machine (Idle → Checking → Downloading → Installing → Updated | Errored) hardened by at least six distinct shipped-bug classes: version-compare loops, redownload loops, temp-dir leaks, sleep hangs, install-nuking, vanishing "restart to update" prompts. The macOS install path downloads a DMG to a prefixed temp dir, `rsync`s onto the *running* bundle (safe — new inodes), and relaunches via a detached `while kill -0 $pid; do sleep 0.1; done; open "$app"` one-liner (`crates/gpui_macos/src/platform.rs:540`). Crash capture (`crates/crashes/src/crashes.rs`, 775 lines) is out-of-process: Zed spawns *itself* with `--crash-handler <socket>` as a minidump server; the app's signal handlers request the dump, a first-crash `compare_exchange` guard prevents duplicates, and uploads happen on the *next* launch — never from the dying process. Release channels are compile-time identity (`crates/release_channel/src/lib.rs:216–235`): distinct bundle ids so stable/preview/nightly install side-by-side, and the Dev channel never polls.

Rook today: `install.sh` is the whole upgrade path (checksum-verified, signature-preserving `ditto -c -k` — genuinely good bootstrap), and nothing after it. `app/src/main.zig:106–110` prints a version nothing consumes; there is no panic handler, no signal handler, no log file — a crash destroys every shell (accepted regression, STATUS.md) *and* leaves no evidence, the worst possible combination. But rook is structurally well-positioned: one binary means the crash-handler-is-the-same-executable trick and ctl verbs (`rook crashes`, `rook update`) come for free; the attention system is the notification surface; and `--config=DIR` isolation (`main.zig:39–92`) is already 80% of a dev/stable channel — missing only a distinct bundle id and a distinct default socket (two channels colliding on `/tmp/rook.sock` would answer the wrong instance's `quit`). One rook-specific constraint: because shells die with the app, update-apply must be download+stage+notify with the swap at user-chosen restart — Zed's Windows finalize-on-quit shape, never its macOS hot-rsync.

**Patterns to steal:**
- Crash capture v1: root-module `pub const panic` override + `sigaction` for SEGV/BUS/ILL/FPE writing {version, build_id, panic msg, return addresses, image slide} as JSON to `~/.local/state/rook/crashes/` via a pre-opened fd, cmpxchg first-crash guard, gated on build != "dev" [medium] — zed `crates/crashes/src/crashes.rs:104–135, 483–536` → rook `app/src/main.zig` + new `app/src/crash.zig`
- Sweep-on-next-launch crash collection: startup scans the crash dir, raises an attention item, prefills a GitHub issue — the solo-dev QA loop [small] — zed `crates/zed/src/reliability.rs:232–271` → rook startup path + ctl verb table
- Archive debug info per release: `make release-stage` keeps the unstripped binary/dSYM per tag; symbolicate offline with `atos` [small, one Makefile line, impossible to retrofit] — zed `reliability.rs:279–282` → rook `Makefile` release-stage
- Self-update as download+verify+stage+swap-on-restart, with the detached relauncher one-liner and mv-transactional swap [large] — zed `auto_update.rs:1158–1212, 1296–1318`, `auto_update_helper/src/updater.rs:366–435` → new `app/src/selfupdate.zig` + status-bar "update ready" segment
- Updater comparator invariants as a zed-style test table: strip pre-release/build metadata, Updated-state as baseline, quiet automatic failures / loud manual ones, `build == "dev"` never updates [small] — zed `auto_update.rs:829–929` + its 13-test matrix at 1580–1846 → `selfupdate.zig`
- Channels as identity: `-Dchannel` bakes bundle id AND default ctl socket, giving Seth a self-hosted stable-fallback canary [medium] — zed `release_channel/src/lib.rs:216–235` → `app/build.zig`, `app/bundle/Info.plist`, `main.zig`
- Crash-loop safe mode: launch-started/launch-completed marker; if the previous launch never completed, start with the config program and plugins disabled and say so [medium] — zed `session.rs:14–38` + crash sidecars → `app/src/macos.zig` App.create
- Watchdog + memory heartbeat on a dedicated OS thread: render-loop stalls >100ms, resident-set deltas ≥10% [medium, ~100 lines of Zig; needs a log file first] — zed `reliability/hang_detection.rs:78–123` → new watchdog thread
- Real signing + notarization: `script/bundle-mac:120–277` verbatim (hardened runtime, nested binaries first, `notarytool submit --wait`, staple), ad-hoc fallback kept — closes STATUS.md §4 [medium]

**Bug lessons rook is exposed to:**
- **Version-format asymmetry → infinite update loop.** Zed shipped it twice (c366627642 preview, c2281779af nightly). Rook's tags are `vX.Y.Z` while dev builds carry `version="dev"` + `build=sha.timestamp` (`Makefile:24`, `app/build.zig:49`) — the exact two-format trap. Write the comparator test table first; hard-refuse to update a dev build.
- **install.sh nukes before it copies.** `rm -rf /Applications/rook.app` precedes the new `ditto` (`install.sh:45–46`); a failed copy leaves zero rook. Zed's Windows updater destroyed user installs the same way (6a38d699dc). Fix available today: stage sibling, mv old aside, mv new in, delete old last.
- **argv lies about the bundle path.** Rook is always launched via `~/.local/bin` symlinks; Zed's fix was `[NSBundle bundlePath]` (e566a8335f) and rook's own `docs/OWED.md` §3 records the identical lesson from the deleted Go updater. Currently guarded by documentation only.
- **The crash path must be async-signal-safe from commit one.** Zed spent five commits retrofitting it (88c4a5ca49 → c5ee3f3e2e: suspending the panicking thread turned a crash into a hang; ce696c18ed: an unwrap inside the handler is a crash inside the crash). Rook has render, pty-pump, and ctl threads — the lesson is free only if taken now.
- **Dev-build reports are noise.** Zed refuses to generate on Dev and upload without a sha (021681d456, 07e57bb488). Rook's `make dev` builds would dominate crash volume — gate capture.
- **Absent config key must mean default, never zero-value.** Zed silently disabled auto-update for everyone for a week (b60e705782); rook already paid a cousin with the lsp bool/table collision (fixed 2631764). Every updater/crash toggle needs an absent-means-default test.
- **Panic messages leak user content** (Rust slice panics embed the sliced string; f0e301cea0). `editor.zig` works on user file content — any GitHub-issue prefill or upload must redact; build the seam from day one.

**Recommendations, in order:** (1) crash capture v1, ~a day, worth more per line than any feature; (2) archive debug info per release — one `cp`, unretrofittable; (3) make install.sh transactional, no updater needed to hit the bug; (4) a real log file for Dock launches (`stderr → ~/.local/state/rook/rook.log`) — every reliability feature presumes it; (5) self-update, staged, swap only on explicit restart; (6) crash-loop safe mode with it; (7) stable+edge channels; (8) signing + notarization in parallel; (9) watchdog + memory heartbeat.

### Workspace, session persistence, and restore

**VERDICT: rook behind — zero persistence today — but structurally much closer than Zed's 6,000-line subsystem suggests; slice one is a few hundred lines of Zig writing one JSON file.**

Zed's stack: a per-channel SQLite substrate with fail-open corruption recovery (`crates/db/src/db.rs:170–225` — a bad DB is moved aside, never blocks launch), a relational pane-tree serializer (`crates/workspace/src/persistence.rs`, 5980 lines) throttled to one write per 200ms with a quit-time flush, and a session layer (`crates/session/src/session.rs`, 147 lines) whose one great idea is the **session-generation stamp**: read the previous boot's session id, immediately write a fresh one, stamp every snapshot with the current id during the run. Restore = "everything stamped with the previous id" — so a crash restores identically to a clean quit, with no separate crash path. The other quiet concession: Zed's terminals do **not** survive as ptys either — it persists each terminal's `working_directory` and respawns a fresh shell there (`crates/terminal_view/src/persistence.rs:378–470`). Layout+cwd restore requires no pty survival.

Rook persists nothing: no layout, no window frame (every launch is a centered fixed-size window, `macos.zig:1064–1074`), no reopened files, no unsaved-content protection, quit is a bare `terminate:` with no flush. But the hard primitives already exist: `paneCwd` reads live shell cwds from the kernel via `proc_pidinfo` (`app/src/macos.zig:1986–2007`), `Session.start` accepts a spawn cwd (`app/src/session.zig:336`), the live model (`app/src/panes.zig`: Space → Tab → binary `Split{horiz, ratio, a, b}` → Pane) maps 1:1 onto Zed's SerializedPaneGroup but simpler, `docs.zig` enumerates dirty Buffers, and `editor.zig:339–346` carries exactly the per-view state Zed persists (`top`/`left`, `cline`/`ccol`). Rook also dodges Zed's worst bug family outright: workspace identity is a declared *name* in the environment graph, not a path set — the path-order/path-set identity bugs Zed fixed four times (398d0396b6, 237474a889) don't apply. And the 08-03 sqlite deletion stands: the vehicle is an atomically-renamed JSON snapshot (the env hot-swap pattern), not a database.

**Patterns to steal:**
- Session-generation stamp = crash recovery for free: continuous throttled snapshot tagged with a boot id; restore loads the previous boot's snapshot [medium] — zed `session.rs:15–38`, `workspace.rs:173, 7058–7073` → new `app/src/persist.zig` + the existing periodic tick
- Terminal restore without pty survival: persist per-Term cwd, respawn there [small — rook has both halves already, only the snapshot format connects `paneCwd` to `Session.start`] — zed `terminal_view/src/persistence.rs:378–470` → `persist.zig` + restore path in `macos.zig`
- Defensive restore walk: drop dead leaves (missing file, gone cwd → `$HOME`), collapse a split whose sibling died via sibling promotion (`panes.zig` `removeAt`, lines 228–246), never abort a Space for one bad leaf [medium] — zed `persistence.rs:2241–2314`, `model.rs:254–335` → `persist.zig` restore
- Unsaved-buffer hot-exit with mtime conflict detection: dump dirty Buffers + saved mtime; on restore mark CONFLICTED if disk moved, and strip the restore edit from the undo stack [medium] — zed `items.rs:1444–1526, 2274–2293` → `docs.zig` enumeration + `buffer.zig` restore entry point
- Window frame + display-UUID persistence with fallback to today's centered default [small, independently shippable first win] — zed `persistence.rs:113–231` → `macos.zig` frame-change notifications (view already posts them, line 1095)
- Quit-time flush: cancel the debounce, serialize synchronously, block exit on the write — plus immediate write on tab/space close so closed things don't resurrect as zombies (zed e90cf0b941) [small] — zed `workspace.rs:6988–7003` → an `applicationShouldTerminate` hook rook currently lacks
- Fail-open on corrupt snapshot: rename to `.corrupt-<ts>`, launch fresh — rook's own `workspaces.zig` rule ("garbage and absence are an empty list") extended [small] — zed `db.rs:170–225`, commit 39fb89e031 → `persist.zig` load

**Bug lessons rook is exposed to:**
- **Restore-over-changed-file must surface as CONFLICT** (7146087b44) — rook's planned unsaved-restore ships this bug by default without the stored mtime; a restore would silently mask a `git checkout`.
- **One failing item must not abort the whole restore** (4e21e753ec: a `?` silently abandoned every remaining workspace) — design log-and-continue per leaf in.
- **Raw offsets restore wrong after external edits** (e04d044271: folds captured wrong lines after git ops) — restored `cline`/`ccol`/`top` must at minimum clamp to the loaded buffer, or rook's editor indexes out of range; better, store a line-prefix sample and relocate.
- **Debounced serializer + flushless quit loses the final 200ms** — the exact state the user quit with. Rook's quit path has no hook at all today.
- **Two instances, one snapshot path.** Seth runs `make dev` and the daily driver simultaneously (cf5a113751: Zed panicked with two instances open); temp+atomic-rename, last writer wins, and a version field + ignore-unknown-fields so dev and release builds can share the file — rook's own host-protocol fail-open lesson.

**Recommendations, in order:** (1) the snapshot — `persist.zig`, one JSON file under `$XDG_DATA_HOME/rook/session/`, throttled from the periodic tick + close-time writes + a new quit flush; (2) restore on launch with sibling-promotion pruning and fail-open; (3) the boot-id stamp (crash recovery falls out free); (4) unsaved-buffer hot-exit with mtime conflict; (5) window frame + display identity; (6) a `make e2e` "relaunch" scenario asserting quit-then-relaunch fidelity — Zed encodes every persistence regression as a test and rook's harness is built for exactly this; (7) do NOT re-add sqlite; (8) keep the tmux-style pty detach as a separate future project — after slices 1–2 the visible relaunch experience matches Zed's (which also respawns shells), and detach becomes a differentiator Zed doesn't have.
