- [ ] The competitive-research roadmap (docs/zed-analysis.md 08-06,
      docs/ghostty-analysis.md + docs/agent-landscape.md +
      docs/agent/acp-brief.md 08-07 — zed's eleven live bugs are FIXED;
      this is what remains, re-ordered after the Ghostty/cmux/ACP
      findings)
    - [x] BUMP ghostty-vt (LANDED 08-07) to upstream main FIRST (security: the pin
          executes kitty-graphics commands — file reads, shared memory,
          PNG decode — from any stdout; upstream hardened it all
          2026-08-05, rook ships pre-hardening). Cheap: consumed symbol
          surface intact, the OSC 9/777 fork patch was absorbed
          upstream; adapt clipboard_write to multi-MIME. Inherits OSC
          9;4 progress (the Claude Code protocol rook drops today) and
          `vt.snapshot` — the session-restore serialization primitive,
          already written. docs/ghostty-analysis.md has the checklist;
          note Ghostty is leaving GitHub, re-point the pin.
          → OSC 9;4 WIRED 08-09 (a3c26da): session atomics → 2Hz tab
          aggregate → chip " 42%"/" …"; panes/tabs ctl mirrors; e2e
          `progress`.
    - [x] The IO loop (LANDED 08-07, cat 0.971→0.52s): drain-then-parse + gather thread (macOS caps pty
          reads at ~1KiB; rook pays a read+mutex cycle per KiB). With
          the idle-parser-delivers-immediately rule so key→photon holds.
          This is essentially the whole remaining cat gap vs Ghostty
          nightly — land it before Ghostty 1.4 ships so the A/B stays a
          win.
    - [x] Crash capture v1 (LANDED 08-09): panic override + signal handlers, JSON
          sidecar, first-crash cmpxchg guard, gated off dev builds — and
          archive the unstripped binary per release, the one step that
          cannot be retrofitted. ~A day. A crash today kills every shell
          and leaves no evidence.
    - [x] workspace/didChangeWatchedFiles (LANDED 08-09, d59bc2d): capability
          declared, registrations parsed (globs, RelativePatterns, kind
          masks), FSEvents stream per server root (fswatch.zig), batched
          notifications. Two macOS scars now in fswatch: events arrive
          symlink-RESOLVED (/tmp→/private/tmp) and flags are history —
          birthtime beats the created bit.
    - [ ] Kill the flatten tax: incremental didChange from the TreeEdits
          the buffer already records (lsp.zig:1063 names itself as the
          next step), and tree-sitter via read-callback over rope leaves
          instead of the 4MB flatten (editor.zig refreshHighlights).
    - [ ] The automated vim oracle: golden `vim -Nu NONE` sessions run in
          CI, zed-style (they keep 310 against neovim). The method just
          caught five divergences by hand; automate it BEFORE adding
          more vim surface.
    - [ ] Session restore, slice one: pane trees + cwds + editor
          positions, respawn shells in saved cwds — but the terminal
          CONTENT half should ride `vt.snapshot` from the bumped pin,
          not a JSON format of our own. Boot-id stamp makes crash
          restore identical to quit restore. Urgency upgraded: it's the
          top-reacted ask on cmux's own tracker, and cmux's version is
          replay theater (re-spawn + scrollback replay) — real state
          restore is a visible win. tmux-style detach stays a separate
          later project.
    - [ ] Markdown + code-fence injections, single (non-combined) only —
          the terminal whose thesis is agent transcripts renders
          markdown plain. Defer combined injections; that corner held
          8+ of zed's syntax bugs.
    - [ ] Accept-time completion: additionalTextEdits + resolve-before-
          accept (auto-import), filterText, isIncomplete plumb-through.
          Zed's overlap rule verbatim (lsp_store.rs:7503).
    - [ ] Cheap armor BEFORE wrap/folds/inlays land: coordinate-space
          newtypes, marked-text test DSL, seeded randomized round-trips,
          CRLF normalize-on-load, rope char-boundary guards.
    - [ ] The agent race, re-ordered by the ACP brief: per-prompt git
          checkpoints FIRST (higher phone-safety value per line, no
          protocol dependency), then plugins/acp per
          docs/agent/acp-brief.md (slice one needs zero new vocabulary
          verbs; one gap: attention.raise can't reference the
          answerable item — extend it). The review surface is the
          wedge now (docs/agent-landscape.md): cmux owns the 'terminal
          for Claude Code' label but chose not to build editor or
          review depth; beat their two best mechanisms natively
          (comment-pool→next-prompt, re-anchoring inline comments —
          threads/reanchor already points here) and add what nobody
          has: partial approve, classification, verdicts.
    - [ ] Notarization + signing. Funnel-killer before the thesis is
          ever seen — every category review checks it. (Self-update's
          transactional install half already shipped.)
    - [ ] PERF WATCH: rerun bench single-display on an idle machine; if
          present_lag still reads ~21ms without the external, the
          compositing path changed and the July rows need re-earning.

- [ ] Window chrome
    - [x] Drag to resize edges and CORNERS. The corner case was the broken
          one: mouseCallback returned nil for every mouse event inside the
          layer, so AppKit never saw the downs it needs. Edges appeared to
          work because the resize region also extends a pixel or two
          outside the frame, where the monitor never sees the event at all;
          at a corner that outside sliver is an L two pixels wide.
          `ui.appKitOwns` is the geometry (5pt edges, 16pt corners, in
          POINTS). NEEDS A HAND ON THE WINDOW to confirm — `ctl click`
          bypasses the monitor, so no test here reaches the decision.
    - [x] Double-click titlebar to zoom — same cause, same fix: the strip
          is AppKit's and now gets its events. Glass mode only ever had
          the problem; opaque mode's titlebar sits above the layer.
    - [ ] Drag-to-move in glass mode was broken by the same bug and should
          now work. Unverified, same reason as above.
- [ ] More vim motions
    - [x] WORD motions W B E gE — they existed only as text objects, so
          `dW` and `cB` did nothing at all.
    - [x] `|` `g_` `+` `_` `<CR>`
    - [x] ctrl-f ctrl-b ctrl-e ctrl-y, and z<CR> z. z-
    - [x] `:qa` `:wa` `:wqa` `:xa` (+ qall/wall/wqall/xall). Closes every
          EDITOR pane and leaves the terminals — vim-inside-tmux semantics.
    - [ ] Not done, each a feature rather than a keybind: folds, tags,
          `gq` format, `:r` / `!` filters, the changelist (`g;` `g,`), `gi`.
    - [ ] `-` stays rook's vim-vinegar climb to the parent listing, NOT
          vim's first-non-blank-of-previous-line. Decided, not pending.
- [ ] Action list plugin system.
	- [ ] Github: PR review requests, comments awaiting replies, etc
	      NOTE: no longer greenfield. diffsource.zig already makes rook
	      indifferent to who supplies a diff and substrate.zig has a
	      remote arm, so a PR is a DiffSource arm plus a thread importer.
	      `?base=` is a string so `?base=pr/1234` needs no new vocabulary.
	      Two catches: substrate writes are still host-remote on both arms,
	      so posting a reply crosses the undecided sole-writer question;
	      and "comments awaiting replies" is a thread importer, a different
	      shape from a diff source — they land as separate slices.
	- [ ] Github Issues
	- [ ] Jira
- [ ] Diff view follow-ups (from the viewer landing)
    - [ ] It does not refresh when files change underneath it. Rebuild is a
          keystroke, but it is a stale view until you press it — and
          staleness in a review surface is the failure mode that matters.
    - [ ] No `]h` / `[h` hunk motions. `/^@@` works and is not a binding.
- [x] Model states in the vim status bar should have different colors
      (mode_insert green, mode_visual type-gold; NORMAL keeps the accent)
- [ ] Create buffer "tab line" basically a vs code like visual representation of open buffers with:\
	- [x] x to close
	- [ ] drag to rearrange
	- [x] should be able to enable/disable via config (`buffer-line`)
	- [x] per-PANE line (rook-buffers: the pane is the window, its
	      documents are the chips; the top strip stays layouts); :b N,
	      :bn/:bp, chip click switches, parked cursor line restored
- [ ] TOML Syntax highlighting
- [ ] Markdown Syntax highlighting