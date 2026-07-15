# The Rook Agent: developer, not coder

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
  everything that acts.

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
