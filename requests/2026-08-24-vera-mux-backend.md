# Requests from Vera: what its rook backend needs from the socket

Status: open. Written 2026-08-24 against rook `b8e356f` by the agent
that wrote `mux/rook.go` in the vera repo (`github.com/incantery/vera`,
commit `05e98e7`).

## Context

Vera now owns the fleet — worktrees, agents, supervision — and talks
to a multiplexer through a small interface (`vera/mux/mux.go`): find
the focused pane, spawn one, type into it, read its screen, bring it
forward, hear when something changed. `vera/mux/rook.go` implements
that over rook's socket (`$ROOK_MUX_SOCK`, `mux/src/proto.zig`).

Eight of the twelve verbs work today with no rook change. The four
that do not are all *observation*, not control — rook was built from
the glass outward, and Vera is the first client that wants to read
rather than draw. Each ask below is small, and each is something a
herdr-style rail author would want too, which is the test for whether
it belongs in rook (`docs/surfaces.md`: rook publishes, consumers
replicate).

Everything here is against the placeholder protocol. If the
structured cell protocol is close, these are the fields it needs to
carry; if it is not, they are a few lines each on the current wire.

## The asks

### 1. A focus event — which block has the person

**Why.** `terminal.focus` is the observation that makes Ghostty stop
being opaque to Vera's model ("inside it, rook shows Claude Code
session X"), and it drives the phone's home-screen ranking of where
the person has been. On the rook backend `Focus()` returns
`ErrNoFocus` today, so all of that is dark.

**Ask.** A new `s2c` kind, say `focus = 6`, payload `[block u32 LE]`,
sent to every client with `wants_blocks` whenever the focused pane
changes — `server.zig` already funnels every change through
`focusEvents(old, new)` at ~1567 (it writes `\x1b[I`/`\x1b[O` to the
panes); one `sendTo` loop beside it does it. Also send it once on
`blocks` subscribe so a fresh client knows the current answer.

**Vera side, ready:** `Rook.Focus` reads the last value; `Watch`
emits `FocusChanged`.

### 2. An activity column in the block table — a per-block pulse

**Why.** Liveness. The fleet classifies a task as running / quiet /
stale from "when did this pane last produce output" plus a
write-evidence scan of its worktree. Without the pulse it is
write-evidence only, which misses an agent that is thinking (no
files) and mis-reads a long test run as stale.

**Ask.** One more tab-separated column on each `blocks_text` row:
last-output time as epoch milliseconds (`0` if never). The reader
thread in `pane.zig` is the place that knows; a `last_output_ms`
atomic on `Pane`, stamped per read, costs nothing. The existing
"fg/cwd drift" re-check every couple of seconds will then push the
table on activity too — fine, but consider **not** pushing on the
activity column alone (only stamp it, push on the other columns), so a
busy pane does not push a table every two seconds to every
subscriber. Vera re-asks on its own ticker anyway.

**Vera side, ready:** `parseBlocks` takes an optional 6th column into
`Pane.Active`.

### 3. A plain-text snapshot flag on `attach_block`

**Why.** `Capture` is the phone's one eye into a pane. Today Vera
attaches, takes the arrival snapshot (`render.zig blockSnapshot`), and
decodes the VT frame back into rows itself — a small parser that
knows exactly the sequences that frame uses. It works, and it is
fragile in the way every "parse the other program's output" is.

**Ask.** `attach_block` flag `4`: reply with `s2c.text` (new kind)
whose payload is the viewport as `rows` lines joined by `\n`, no SGR,
no cursor — then close, or fall through to the raw tee as usual.
`Frame.drawPane` already walks the cells; a sibling that appends
codepoints and newlines is ~20 lines. Wide cells: one codepoint,
skip the spacer. This is also what a native phone/rail view of a pane
wants before the cell protocol exists.

**Vera side, ready:** `Capture` tries flag 4, falls back to decoding
`draw` if `exit`/timeout.

### 4. A reply to `session 'n'` with the new block id

**Why.** `Spawn` into a new workspace has no way to learn which block
it made. Vera diffs the table before/after and polls for a block in
that workspace that was not there. It is a race with anything else
creating panes, and it is a poll.

**Ask.** After `newSession` succeeds, `replyCreated(c, window.focused)`
— the same `block_created` reply `block_cmd 'c'` already sends
(`server.zig` ~1058). Two lines.

**Vera side, ready:** `Spawn` waits for `block_created`, diff as
fallback.

### 5. `session 'n'` that does not switch the view

**Why.** The one hard rule of the fleet's `Spawn` is that starting
work must never move the person. `newSession` sets `cur_sess` to the
new one, so opening a room for an agent pulls the desk to it. A new
window via `block_cmd 'c'` does not switch, so this only bites on the
first task per repo — and it bites every time.

**Ask.** A variant op — `'N'` (quiet new), or a flag byte after the
name — that creates the workspace without changing `cur_sess`. The
`old_focused` / `focusEvents` dance in `newSession` is then skipped
too.

**Vera side, ready:** `Spawn` uses the quiet form when the server
advertises it (see 6), else the current one.

### 6. (Optional) a protocol version in `stats_text`

So the Go client can pick the quiet spawn / text snapshot when they
exist and fall back when they do not, without probing. One line in
`sendStats`. If the cell protocol is arriving soon, skip this.

## Order

4 and 5 are two-line changes and make Spawn correct; 1 unblocks the
most user-visible thing (focus); 2 and 3 are quality. Suggested: 4 → 5
→ 1 → 2 → 3 → 6.

## How Vera will verify

`cd vera && VERA_ROOK_LIVE=1 go test ./mux -run TestRookLive -v` drives
the live engine: spawn into a new workspace, capture, send + enter
through `cat`, spawn as a new window, resize lease, kill. It cleans up
after itself but switches the view while it runs (which ask 5 fixes).
Each ask lands with a corresponding branch in that test.

## What is NOT being asked

- No agent state, no worktree knowledge, no fleet vocabulary in rook.
  Vera supplies those as an `items` surface later; rook paints.
- No change to the `rook` CLI verbs. Everything here is socket-level.
- Nothing that waits on a client: every reply is fire-and-forget from
  the server's side, per the "rook paints, plugins supply" rule.

## Addendum (2026-08-24, after the reply): `program` for Claude Code

`fgName` names a versioned binary by the directory above it, but
Claude Code's layout is `~/.local/share/claude/versions/2.1.241`, so
the answer is `versions`. One more step up when the parent is itself
a bare `versions`/`bin`-style word would give `claude`. Vera treats
`versions` as Claude Code in the meantime.

## Addendum (2026-08-24, evening): there is one command, and it is `rook`

Decided earlier today: the product is `rook` — one command people type,
one daemon (`rookd`). The Zig engine is an implementation detail. Two
places still say otherwise:

1. **The engine binary is on `$PATH` as `rook-mux`.** `make install`
   puts it in `~/.local/bin`, so it is typeable, and people (and
   agents, and Vera's author today) type it. Ask: install it off the
   path — `~/.local/libexec/rook/engine` or beside the `rook` binary
   under a name nobody would type — and have `rook` (execMux) and
   `rookd` (muxPath) find it there. `ROOK_MUX_SOCK` / `ROOK_MUX_PANE`
   are env names on the wire and can stay.
2. **`mux/README.md` and `docs/surfaces.md` call it `rook-mux`** in
   prose and examples (`rook-mux side -`). The `vera-eac97655` branch
   already moved the verbs to the umbrella (`rook side`, `rook state`,
   `rook watch`, `rook capture`); the docs should follow — "the
   engine" in prose, `rook <verb>` in examples.

Vera has no mention of `rook-mux` in code or docs and speaks only to
the socket, so nothing on its side changes.
