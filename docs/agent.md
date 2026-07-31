# The Rook Agent: developer, not coder

> **Status, 2026-07-31: the drafter half of this document is code that no
> longer exists.** `rook-agent`, the decisions ledger, and the
> draft/approve/reject flow were removed in the strip — they were one
> instance of "something proposes, a human disposes", and that belongs to
> a plugin rather than to core. The **sensor** half survives and is still
> live code: `agentwatch.go`, `transcriptwatch.go`, `internal/transcript`,
> and the `/attention` list all work as described here.
>
> The mechanism the deletion leaves behind is `attention.raise` — any
> plugin may declare that something needs a human, and core ranks and
> renders what it collects. See `docs/plugins/VOCABULARY.md`. This file is
> kept as the design record the sensor layer still cites.

The goal of the built-in agent, distilled from the design conversation on
2026-07-11. This extends README decisions 3, 4, and 6; nothing here starts
until rook is the daily driver.

## The split

The agent is not the thing that writes code. Coding sessions are `claude`
CLI processes (README decision 6) — expensive, deep-context, subscription
billed. The Rook Agent sits **above** them and works like the human
developer who drives those sessions:

- decides which claude sessions to spawn, where, and with what task
- watches every session and notices state changes
- replies to sessions that are blocked waiting on input
- learns the user's preferences over time and applies them

That work is classification and routing over small, structured context —
which is why it runs on a **nano-tier model** (currently GPT-5.4 nano,
$0.20/M input, $1.25/M output, cached input at 10%). The watcher loop is
high-frequency with a stable prompt prefix, exactly the shape prompt
caching makes nearly free. Order-of-magnitude: a moderate multi-step task
costs ~$0.03 with caching; registry-dispatch calls cost hundredths of a
cent. The current ~$31 of OpenAI credit is months of development fuel.

Two tiers, two billing models: nano orchestrates on API credit, claude
codes on subscription. A bad nano decision must never be able to silently
burn claude-session time — see the escalation gate.

## Why rook's architecture already fits

- **Command registry (decision 3).** The agent's tool surface IS the
  registry. Spawning a session, switching a workspace, killing a window —
  the agent dispatches the same named commands as clicks and keybindings.
  No agent-only side doors.
- **Host API.** The agent is just another client of rook-host, like the
  webview. Sessions it spawns survive UI restarts for free.
- **Semantic blocks (decision 4).** The agent reads OSC 133 blocks —
  command, cwd, exit code, output — never raw VT scrollback. A small model
  over structured blocks is viable; a small model over text soup is not.
- **stream-json for claude sessions.** Claude sessions are spawned in
  stream-json mode, so the agent consumes structured events ("tool use
  requested", "awaiting permission", "result") instead of scraping the
  terminal. Reliability of a nano-tier model goes way up when the input is
  events.

## Amendment (2026-07-11): agentmon covers interactive sessions

stream-json only helps sessions the agent spawns. The sessions that
actually need watching are the interactive ones the user runs — and
agentmon (github.com/incantery/agentmon) already derives structured events
from their transcripts (`~/.claude/projects/**/*.jsonl`): session
lifecycle, prompts, tool calls, turn completions, idle detection, cost.

So rook-host consumes `agentmon watch --dry-run` (NDJSON over stdout,
nothing written to disk) and reduces it to one state per claude session —
`internal/host/agentwatch.go`:

- `turn_completed` → **needs_input** (claude finished; the last assistant
  text is the question waiting for an answer)
- any transcript event → **working**
- `session_idle` mid-turn → **quiet** (long tool run or a permission
  prompt; the transcript can't distinguish them, so rook reports the tool
  and the silence, not a guess)

Correlation to rook windows is mechanical: fg process == "claude" (the
host already senses it) + working-directory match. Consequences:

- **Milestone 1 (attention router) ships with zero LLM calls.** Classify
  is a state machine over events; surface is the dashboard, the pulsing
  window number, and the workspace cards. Nano's first real job is step
  2+ (drafting replies), not classification.
- **OSC 133 blocks drop off the agent's critical path.** Still wanted —
  command history, non-claude awareness — but the agent doesn't wait on
  them.
- The division of labor is permanent: agentmon stays a dumb, reusable
  sensor (no LLM, no rook knowledge); rook owns correlation, state, and
  everything that acts. *(Overturned 2026-07-15 — see the amendment below.
  The sensor half was right until the surface changed.)*

### Shipped (2026-07-14): two engines, and the drafter stops needing setup

The drafter's model backend is now an interface (`internal/agent/engine.go`)
with two implementations, and `agent-engine = auto` picks one:

- **claude** — shells out to `claude -p` (haiku by default). The argument is
  dependency arithmetic, not model quality: rook-agent *already* requires
  claude, because agentmon reads its transcripts and without claude sessions
  there is nothing to draft against. So this adds no dependency and removes
  one — no API key, no keychain entry, no config edit. If claude is on PATH
  the drafter works.
- **openai** — an API key, as before. Kept deliberately, and not only as a
  fallback: it is the only way to keep the drafter's spend *off* the
  subscription's rate limit. "Two tiers, two billing models" (above) was
  written about a bad reply wasting session time; sharing a quota is a second
  route to the same harm — hit your limit and you lose the coder *and* the
  drafter at once, exactly when you have the most sessions running.

**The output contract is a tool.** `claude -p` has no strict `json_schema`, so
the judgment arrives as a tool call instead: a one-tool MCP server
(`internal/agent/mcp.go`, served by `rook-agent mcp <pass>`) declares the
shape, and `--output-format stream-json` carries the payload. MCP declares,
the stream delivers. The failure mode is the safe one — no tool call means no
judgment, and no judgment leaves the ask surfaced draft-less, which is what
escalate already looks like. The schema-violation path and the safe path are
the same path, so this needs no enforcement to be correct. We never
synthesize a judgment: a fabricated row is worse than no row, because the
ledger is the thing that earns autonomy.

Three findings worth keeping, each paid for once:

1. **`claude -p` writes a transcript into `~/.claude/projects` by default** —
   the exact tree agentmon watches. Left alone, the drafter manufactures the
   events rook-host reduces to session state: the agent watching itself.
   `--no-session-persistence` is the fix and is guarded by a test.
2. **A tool is an offer, not an obligation.** The shared rubric says what to
   decide, not how to answer, because json_schema made "how" a property of
   the OpenAI request. Given only the rubric, the model reasons well and calls
   nothing. The ClaudeCode engine appends its own output-contract paragraph —
   appended, so the cached prefix stays byte-stable.
3. **The drafter must stay a classifier.** With tools it will use them, and a
   $0.0005 classify becomes an agentic run — holding a shell — against a
   session that is already blocked. `--strict-mcp-config` plus an
   `--allowed-tools` allowlist of exactly one tool is what prevents it.

The cost is honest rather than good: ~$0.0146 and ~15s per judgment versus
nano's ~$0.0005 and ~1s, roughly 30x. Almost none of it is rook's — an empty
`claude -p` already carries ~19k tokens and 31 tools before our prompt. It is
the price of inheriting the user's global claude config, it scales with what
they have installed, and `--bare` removes it but only with an
`ANTHROPIC_API_KEY` (never OAuth, never the keychain). Cheap and clean, or
free and inherited — the user's credential decides. At ~35 calls/day it is
cents either way.

Not yet done, and it gates what comes next: the verdict ledger still cannot
tell "the draft was wrong" from "the draft was never seen", so swapping the
engine cannot be *shown* to have improved drafting. This change is justified
on setup cost alone. See the sequence below — step 3 stays blocked until
`manual` splits.

## Amendment (2026-07-15): rook reads the transcripts; agentmon is the wrong sensor

The 2026-07-11 amendment above is not being corrected — it was right for the
job it was written for. The job changed.

The attention router needs a state chip, an ask string, and a cost number. A
lossy metrics reduction serves that perfectly, and everything agentmon's parser
discards, it discards *correctly* for Loki and Grafana. What we want next is
different: **the agent session rendered in Svelte as the 90% case**, with the
pty kept exactly as it is so `jump` into the live interactive claude stays the
10% escape hatch. Not stream-json, not headless — attach is worth more than the
correlation layer it would delete. The read path is what changes.

A renderer needs what a dashboard doesn't: whole content, call/result identity,
and low latency. agentmon can give none of the three, and the reasons are
structural rather than tuneable.

Three findings, each paid for once:

- **The transcript already shows the block.** The `tool_use` record is written
  when the model emits it and resolves only when the human answers, so the gap
  between them *is* the block, with the full tool input sitting there for the
  duration. Measured in one session: two `AskUserQuestion` calls pended 2m32s
  and 17.7s, while auto-approved `Read`/`Bash` calls resolved in under half a
  second. So "the transcript can't distinguish them" (above) is too pessimistic.
  It holds for `Bash` — compiling and waiting look alike — and fails for
  `AskUserQuestion`, which has no long-running variant. An aged unresolved
  `tool_use` is the signal, and rook's reducer never looks for it.
- **agentmon's parser structurally cannot carry it.** `ToolCallPayload{Name,
  Input}` and `ToolResultPayload{OK, Content}` (`internal/transcript/event.go`)
  carry no `tool_use_id`, so calls can never be paired to results downstream.
  `MaxContentBytes = 2048` is applied at *parse* time, and `--level full` —
  which rook already passes — means "don't clear the field", not "don't truncate
  it": `redact.go` clears content at Metadata and returns 2KB at Full. A picker
  with four options and descriptions is clipped, and no flag recovers it.
  Finally `internal/transcript` is under `internal/`, so rook cannot import it.
  The subprocess is not a design choice; it is a workaround for a package path.
- **The hooks are not installed.** Neither `~/.claude/settings.json` nor
  `settings.local.json` has a `hooks` key, so `claim` — tier-0 evidence in
  `correlate()` — and `notify-hook`, the only mechanical permission-block
  sensor, are both inert. Correlation is running on ring-content matching and
  recency. Unrelated to this amendment, and worth chasing on its own.

The tell we had already: rook's live data plane is `agentmon watch --dry-run`,
the exhaust of a telemetry daemon told not to ship. Its README says
`node_exporter` for agent sessions, and that is accurate.

**So rook grows `internal/transcript` and reads `~/.claude/projects/**/*.jsonl`
directly.** This overturns "the division of labor is permanent" above. agentmon
keeps its own job — cross-machine telemetry, Loki, cost dashboards, ntfy
step-away alerts — which rook does not do and should not grow. Both read the
same files; neither knows the other exists.

This is *less* abstraction, not more. Rook does not depend on agentmon the way
composable tools depend on each other — it depends on an event vocabulary
designed for Grafana, with a truncation constant baked in. Deleting that moves
the composition point from `ToolCallPayload` to the jsonl Claude Code writes: a
file neither tool owns and both can read. agentmon has no privileged claim to
it. Two readers of a third party's file is the simplest arrangement available,
and it is what the suite's plain-file substrate rule already says to do.
`node_exporter` and your application both read `/proc`.

Scope is a package, not a project. Rook needs discovery (the slug is cwd with
`/`→`-`), a tail, a permissive parser, and the pricing table (~67 lines, ported
because `AgentStatus.CostUSD` comes from agentmon's stamping today). It needs
none of the spool, loki, or drain — that is shipping — and no `redact` at all,
since content levels exist because bytes leave the machine and here nothing
crosses a wire. No TOML config. No subagent globbing: rook already discards
events with a non-empty `agent_id`. No `(machine, session_id, offset, seq)`
identity: that is Loki dedupe and resume.

Four deliberate divergences, each a thing agentmon got right for itself and
wrong for us: poll becomes fsnotify (poll is correct for a shipper; latency is
the point for a UI); the 2KB truncate goes; `tool_use_id` is kept; and the
parser stops reducing to nine event types, yielding whole records with the
reduction as a separate layer. agentmon's `parser.go` is the spec — the
expensive part was reverse-engineering the format, and that survives being read
rather than imported.

`AgentStatus` is the migration seam and it already exists. Every consumer —
`correlate()`, `/attention`, the Inbox, the Dashboard — reads that type and
nothing else. Keep it, swap the source underneath, run both readers and diff
before cutting over. Rook is the daily driver; the sensor should not change out
from under it on a single commit.

The honest cost: rook owns a parser for an undocumented format that changes
without notice. We already carry that risk transitively — agentmon breaking
breaks rook today — and the mitigation is the one `apply()` already implements
and the host taught us the hard way: unknown record types are skipped, never
fatal.

Sequence: `internal/transcript` first, because a renderer cannot be built on a
truncated stream that cannot pair a call to its result — it is step zero of the
surface, not a cleanup task. Then the Svelte session view over whole records.
Then whether pickers can be *answered* rather than only shown: rendering one is
implementation, but answering it still means synthesising keystrokes into a TUI
widget whose layout we infer, so `attention.go`'s server-side refusal to type
into pickers stands until that is proven. Showing the full question so the user
can decide whether jumping is worth it captures most of the value with none of
the risk.

One incidental find: agentmon parses `PermissionModePayload{Mode}` and rook's
`apply()` does not handle `permission_mode`. We are dropping a signal we are
already handed.

### Shipped (2026-07-15): rook reads its own transcripts

`internal/transcript` (parser, tailer, fsnotify watcher, ported pricing) and
`internal/host/transcriptwatch.go` (the reducer) replaced the agentmon
dependency outright. `findAgentmon`, the `watch --dry-run` pump, the
`agentmonEvent` envelope and `apply()` are gone; `AgentStatus` never moved, so
`correlate()`, `/attention`, the Inbox and the Dashboard did not change. Net
−328 lines, one new dependency (fsnotify).

The shadow-diff this doc called for was **not** built, and should not be. The
oracle was worse than the thing it would have tested: the installed agentmon is
a 2026-07-10 build that silently skips six record types the format has since
grown, so most disagreements would have been the new path being right. What the
diff was really guarding was that the reducer had only ever seen fixtures its
author wrote from a reading of the format — a reading that could be wrong in
exactly the way its own tests would agree with. That is answered by replaying
real sessions through it, not by a second implementation:
`TestReducerAgainstRealSessions` puts every transcript on the machine through
the reducer (115 sessions, 64k lines, 0 malformed) and asserts the beliefs the
unit tests merely assume. It is also where the next format change surfaces.

Two things the build settled that argument could not:

- **`system`/`turn_duration` really is the turn end.** The whole `needs_input`
  state hangs on that reading. In the corpus, 89 of 115 sessions end there, and
  one real session shows 7 `turn_duration` records against 8 typed prompts —
  1:1, the missing one being the turn still open. Had this been wrong, every
  unit test would still have passed and the Inbox would simply have gone quiet.
- **Backlog must not fire hooks.** The watcher replays a discovered file from
  offset 0 to rebuild state, which is correct for state and catastrophic for
  side effects: every historical `turn_duration` would have fired
  `onTurnFinished`, the workflow engine's stage-completion sensor. A restart
  would have advanced every stage for turns that ended hours ago. Records now
  carry `Live`; state reduces from everything, hooks fire only on appends we
  watched land.

The picker fix shipped with the cutover and needed no UI work. `pickerAsk` was
always able to render the question and its numbered options — it was being fed
input capped at 2KB, which is smaller than a real picker, so it had been
degrading to "Claude is asking a question (interactive prompt)". Whole input,
real question.

Also fixed in passing: `permission_mode` is parsed but still unconsumed (the
gap above stands), and rook-host's 300ms shutdown beat — written for agentmon's
asynchronous kill — turns out to be load-bearing for the usage prober's
`claude -p /usage`, which is killed the same way. The sleep stayed; its comment
was the thing that was wrong.

### Shipped (2026-07-15): the session view

`` ` v`` opens a claude session as a rendered conversation. It is a **pane** —
it splits, it sits beside the pty it is a view of, and it retargets in place to
another session, because a session is a document too. The pty is untouched:
`terminal ↗` jumps to it, and everything rook has not reimplemented still works
there. `GET /agents/{id}/transcript` over `transcript.FindSession`/
`ReadSession`; `agentview.ts` holds every decision with its spec and the
`.svelte` stays dumb (the `term/threadview.ts` split); `AgentPane` is the first
Svelte mounted outside `main.ts`, behind the same narrow `PaneContent` seam
that keeps the manager Monaco-free.

The endpoint **retains nothing** — it reads the jsonl on demand. Live is a
stream, history is a file, and holding every session's records in memory to
serve a view nobody may open is paying for scrollback at all times. It is also
the read the tailer cannot do: `watch` follows appends forward, scrollback
pages backward from the end. Two reads of one artifact, which is why the parser
is stateless.

Three numbers decided the design, and none of them were guessable:

- **Transcripts average 1.6MB and reach 58MB.** Windowing is not a nicety. A
  200-record window of a real 1.3MB session is 96KB on the wire — 5x less than
  the 485KB it starts as, because bookkeeping records (`attachment`,
  `file-history-snapshot`, `queue-operation`, `mode`, `ai-title`,
  `last-prompt`) are not conversation. Nothing else is capped: tool input
  arrives whole, which is the entire reason agentmon had to go.
- **Thinking blocks are empty.** 7430 of them corpus-wide, 25MB of signature,
  and *zero renderable characters between them* — claude writes the reasoning
  encrypted. agentmon's `// dropped by design` was right, and nothing above
  should be read as saying otherwise. The signature is an attestation for
  replaying to the API, which rook never does, so it never reaches the wire.
  The block survives so a turn's shape does.
- **Every `tool_use` carries an id** — 38,807 of them, no exceptions. Pairing a
  call to its result is a two-line map in `agentview.ts`, and was structurally
  impossible through agentmon's events.

`` ` v`` targets the session in front of you, read from `correlate()` at command
time — **not** from `app.attention`, which only lists sessions that need
something and would have made the command do nothing for a session that is
happily working, i.e. most of them.

The gap is the predicted one: **markdown renders literally.** The TUI renders
it and this does not. That is the first real instance of "every Claude Code
feature rook has not reimplemented is one you lose by not being in the TUI",
which is the standing risk of this entire surface and the reason the pty stays.
No markdown library is installed. A decision, not an oversight.

Fixed on the way, because it made the feature look broken rather than absent:
`make dev` could not load a host change at all. Every unstamped build reports
Build "dev", so the compatibility check compared `"dev" == "dev"`, matched, and
rode a daemon from hours earlier while `wails3` dutifully rebuilt the binary on
every save. The daemon now records a content hash of its own executable and
unstamped clients compare against it (`internal/hostclient`). Stamped builds
are untouched.

## The escalation gate (load-bearing)

"Reply to a claude session" spans two difficulty tiers:

- **Mechanical** — approve/deny against a learned preference, "yes,
  continue", picking from enumerated options. Nano handles these.
- **Judgment** — "should I refactor the session store or patch around
  it?". Nano will answer confidently and be wrong often enough to matter,
  and the cost lands on claude-session time and user trust, not on nano
  tokens.

So the agent's first decision on any "session needs a reply" event is
*whether this is mine to answer*. Templated/preference-matched → reply.
Judgment-shaped → surface to the user (later, maybe a bigger model). A
small model that knows what it can't answer is useful; one that answers
everything is a liability.

## Preference learning is a pipeline, not a model feature

Nano extracts candidate preferences from interactions ("user rejected
auto-commit twice"), writes them to a store, and the store is injected
into future prompts. The extraction is easy; the design work is the store:
a visible, user-editable file — nothing learned behind your back, in the
same spirit as "nothing respawns behind your back".

### Shipped (2026-07-12): the store and the extraction pass

The store is `~/.config/rook/preferences.md`. Everything above the
"## Learned by the drafter" header is the user's, never touched; the
extractor appends one-line bullets below it, and the whole file rides
into the drafter's SystemPrompt verbatim — editing the file IS editing
the agent. Every 15 minutes (and once shortly after start), rook-agent
reads the decided verdicts past its cursor from GET /decisions, asks
nano for durable preferences (≤3 per pass, empty is the normal outcome),
dedups against the file, and appends.

The load-bearing detail is where the cursor lives: NOT in the store.
The cursor (`~/.local/state/rook/prefs-cursor`) marks which ledger rows
were already considered, so deleting a learned line — or the whole
file — can never invite re-extraction of the rows the user just vetoed.
Deleted stays deleted.

## First milestone: the attention router

Parity-first applies to the agent too. The first shipped piece is not an
autonomous replier — it's the thing that removes the actual pain of
running several claude sessions at once:

> Nano watches all sessions and surfaces "session 3 needs you — Claude is
> asking whether to delete the old migration", with a **drafted** reply
> the user approves with one key.

Entirely within nano's competence, immediately valuable, and every
approve/edit/reject becomes training data for the preference store — which
is what eventually earns the autonomy tier.

## Sequence

1. Attention router: watch sessions, classify state, surface + draft.
2. Preference store: extract from approve/edit/reject, inject into drafts.
3. Mechanical autoreply behind the escalation gate, off by default.
4. Session spawning: task → workspace/cwd/command routing via the registry.
5. Judgment-tier escalation to a bigger model — only once the gate has
   proven it knows the difference.
