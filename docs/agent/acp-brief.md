# Design brief: `plugins/acp` — rook as an ACP client

> Status: research brief, 2026-08-07. Sources: ACP schema v1
> (`schema/v1/schema.json` + `meta.json`, zed-industries/agent-client-protocol,
> fetched today; local copy in `../acp-spec/`), agentclientprotocol.com
> protocol docs, zed's client at
> `/Users/sethlowie/go/src/github.com/zed-industries/zed`
> (`crates/agent_servers`, `crates/acp_thread`), the `claude-code-acp`
> adapter (renamed: now `agentclientprotocol/claude-agent-acp` — both
> names appear below, they are the same thing), rook's `docs/plugins/VOCABULARY.md`, `docs/agent/VISION.md`,
> `plugins/claude/main.go`, `app/src/plugins.zig`, `app/src/macos.zig`,
> and `docs/zed-analysis.md` §"Agent integration" (which recommended this
> plugin as the highest-leverage steal).

The one-sentence pitch: `plugins/claude` reads what Claude Code already
*wrote*; `plugins/acp` talks to what rook itself *spawned* — structured
tool calls instead of transcript heuristics, and, decisively, the
permission request as a first-class question rook can put on your phone
and answer back. That is VISION.md's rung 3 ("act with approval") with a
real API under it instead of TUI keystroke actuation.

---

## 1. Protocol shape — what an ACP client must speak

### Transport and framing

Newline-delimited JSON-RPC 2.0 over the spawned agent's **stdio**: the
client spawns the agent server as a child process, writes requests to
its stdin, reads responses/notifications from its stdout. stderr is the
agent's log channel. This is exactly rook's own plugin protocol shape
with the roles inverted (`docs/zed-analysis.md:379` — "newline-JSON like
ACP with roles inverted"), which is why a Go plugin that already speaks
one side of such a wire (`plugins/claude/main.go` `conn`) can speak the
other with the same demux: one writer mutex, a pump goroutine per
direction, pending-call map keyed by id.

Both sides are both caller and callee — the agent calls *client* methods
(`session/request_permission`, `fs/*`, `terminal/*`) mid-turn while the
client's own `session/prompt` call is still outstanding. The plugin must
therefore run a full bidirectional JSON-RPC endpoint, not a
request/reply client. (Same lesson the rook plugin pump already paid
for: "a handler calling Host.Raise and waiting would otherwise be
waiting for itself", VOCABULARY.md landed-notes.)

### Version and capability negotiation

`initialize` (client → agent), first message:

```json
{ "protocolVersion": 1,
  "clientCapabilities": {
     "fs": {"readTextFile": false, "writeTextFile": false},
     "terminal": false },
  "clientInfo": {"name": "rook-acp", "version": "..."} }
```

- `protocolVersion` is an **integer** (uint16), bumped only for breaking
  changes; features arrive via capabilities (schema `ProtocolVersion`).
  v1 is current-stable; v2 exists in the repo but is `2.0.0-alpha.*`
  (schema/v2/CHANGELOG.md, latest alpha 2026-07-21) — target **v1** and
  record the negotiated integer. If the agent answers with a lower
  version, the client uses it or disconnects.
- Client capabilities rook should advertise in slice one: **none**
  (`fs` false/false, `terminal` false). Everything then executes inside
  the agent's own process against the real filesystem — correct for
  rook, whose buffers are documents over real files, not a virtual
  workspace. See §2 "deliberately not modeled".
- Agent capabilities to read back: `loadSession` (bool),
  `promptCapabilities` (`image`/`audio`/`embeddedContext`),
  `mcpCapabilities` (`http`/`sse`), `sessionCapabilities`
  (`list`/`delete`/`resume`/`close`/`additionalDirectories`), `auth`.
- `authenticate` follows only if the agent listed `authMethods` and
  rejects `session/new` with auth-required; claude-code-acp normally
  rides the user's existing Claude Code login (see §4).

### The method surface (schema/v1/meta.json, verbatim)

Agent-side methods the **client calls**:

| method | kind | notes |
|---|---|---|
| `initialize` | request | version + capabilities, above |
| `authenticate` | request | only if advertised |
| `session/new` | request | `{cwd (absolute), mcpServers[], additionalDirectories?}` → `{sessionId, modes?, configOptions?}` |
| `session/load` | request | replay an existing session (updates re-stream); gated on `loadSession` |
| `session/prompt` | request | `{sessionId, prompt: ContentBlock[]}` → `{stopReason}`; the call stays open for the whole turn |
| `session/cancel` | **notification** | interrupt the turn |
| `session/set_mode` | request | switch agent mode (e.g. claude-code-acp's permission modes) |
| `session/set_config_option`, `session/list`, `session/delete`, `session/resume`, `session/close`, `logout` | request | optional, capability-gated |

Client-side methods the **agent calls** (rook must implement):

| method | kind | slice one? |
|---|---|---|
| `session/update` | **notification** | yes — the firehose |
| `session/request_permission` | request | yes — the killer feature |
| `fs/read_text_file`, `fs/write_text_file` | request | no — capability off |
| `terminal/create|output|release|wait_for_exit|kill` | request | no — capability off |
| `elicitation/create` / `elicitation/complete` | request/notif | no |
| `$/cancel_request` | protocol-level notification | tolerate receiving |

### `session/update` variants (schema `SessionUpdate`, discriminator `sessionUpdate`)

- `user_message_chunk`, `agent_message_chunk`, `agent_thought_chunk` —
  streamed `ContentBlock`s (text | image | audio | resource_link |
  resource).
- `tool_call` — a new `ToolCall`: `toolCallId`, `title`,
  `kind` ∈ {read, edit, delete, move, search, execute, think, fetch,
  switch_mode, other}, `status` ∈ {pending, in_progress, completed,
  failed}, `content[]` (each: `content` block | `diff {path, oldText?,
  newText}` | `terminal {terminalId}`), `locations[] {path, line?}`
  (follow-along), `rawInput`/`rawOutput`.
- `tool_call_update` — same fields, all optional except `toolCallId`;
  merge into the existing call.
- `plan` — `entries[] {content, priority, status}`; each update replaces
  the whole plan.
- `available_commands_update` — the agent's slash commands
  (`{name, description, input?}`).
- `current_mode_update`, `config_option_update`, `session_info_update`,
  `usage_update` (token/cost telemetry — feeds MONEY fields directly).

### The prompt turn (agentclientprotocol.com/protocol/prompt-turn)

`session/prompt` → stream of `session/update` → (optionally)
`session/request_permission` → more updates → response
`{stopReason: end_turn | max_tokens | max_turn_requests | refusal |
cancelled}`. Cancellation: client sends `session/cancel` (notification),
must immediately answer **all pending permission requests** with
`{outcome: "cancelled"}` and mark unfinished tool calls cancelled; the
agent MUST still answer the open `session/prompt` with
`stopReason: "cancelled"` (schema `StopReason` doc-comment makes this a
MUST).

### `session/request_permission`

Request: `{sessionId, toolCall: ToolCallUpdate, options:
[{optionId, name, kind: allow_once | allow_always | reject_once |
reject_always}]}`. Response: `{outcome: {outcome: "selected", optionId}}`
or `{outcome: {outcome: "cancelled"}}`. The tool call rides along, so
the question arrives already carrying its diff/command — exactly the
"interruption that arrives already carrying the answer" VISION.md rung 1
asks for.

What claude-agent-acp concretely sends (its `canUseTool` translation,
`src/acp-agent.ts` ~4873–5100): three options — Deny/`reject_once`,
Allow Once/`allow_once`, Always Allow/`allow_always` (the last carrying
`updatedPermissions: [{type:"addRules", …, destination:"session"}]` or
SDK suggestions). It eagerly emits the referenced `tool_call` *before*
asking (`ensureToolCallEmitted`) because the permission check can race
ahead of the streamed tool_use block — rook's plugin must tolerate a
permission request naming a toolCallId it has already seen OR is seeing
for the first time in the request itself. `ExitPlanMode` arrives as a
permission request whose options are mode switches; in
`bypassPermissions` mode everything auto-allows except ask-rules.

---

## 2. The mapping — ACP ↔ rook's vocabulary

*(zed grounding: `crates/acp_thread/src/acp_thread.rs` models the same
data as typed entries; file:line cites in §zed-notes below.)*

### Clean fits

| ACP | rook vocabulary |
|---|---|
| session | **item** (id = `acp:<agent>:<sessionId>`; title = first prompt line, like `plugins/claude` titles from transcripts) |
| session state | item `state` — semantic: `working` (prompt open), `needs-you` (permission pending), `done` (end_turn), `failed` (refusal/error), `cancelled` |
| `tool_call` / `tool_call_update` | **children** of the session item — "the only structural difference between a list and a tree" (VOCABULARY.md). Child state = ToolCallStatus verbatim: pending/in_progress/completed/failed all already semantic, never a colour |
| `kind` (read/edit/execute/…) | child **badge** — semantic label, no value; core picks the glyph |
| `locations[] {path, line?}` | child **anchor** `{path, startLine}` — ACP hands rook exactly the field its vocabulary made first-class; core resolves drift (`anchor.zig`), ACP plugin never does |
| `usage_update` | item **fields**: `cost` MONEY, `tokens` NUMBER — same shape `plugins/agent/main.go:544` already emits (`{"cost","MONEY",…}`); typed so the deck can sum a column across nine agents |
| turn duration | field `elapsed` DURATION (hint: "elapsed") |
| `plan` | children under a `plan` group-child; entry status maps to child state. Defer past slice one |
| final `agent_message_chunk` text | item `detail` ref (transcript/conversation) + the digest seam: hand the finished turn's text to `plugins/agent`'s summarizer path so ACP sessions get STE digests like transcript sessions do |
| `session/prompt` | plugin action `prompt` with `Input: "INPUT_TEXT"` — the exact mechanism that landed 2026-08-03 for "expand my reply" (VOCABULARY open-question 3; `plugins/agent/main.go:507`) |
| `session/cancel` | item action `cancel` (`confirm: true`) |
| spawning the agent | **not** `session.spawn` — the ACP agent is a *child of the plugin*, not a pane. See "deliberately not modeled" |

### The killer feature: permission → attention → answer-from-anywhere

`session/request_permission` maps to **three vocabulary pieces at
once**, and needs *no new verb* for the local loop:

1. The pending request becomes a **child item** in state `needs-you`
   whose `actions[]` are generated 1:1 from `options[]`:
   `{id: optionId, label: name}`, with `confirm: true` added for any
   `*_always` kind (a remembered grant deserves one more keystroke).
   The tool-call payload renders as the child's fields (title, command,
   diff summary) — the question carries its evidence.
2. The plugin calls `attention.raise {title, body}` — today's banner
   (`app/src/macos.zig:7405` `raiseAttention`; params are title+body
   only, provenance stamped by the host, never by the plugin). The
   banner points at the panel; it does not carry the answer yet.
3. The answer rides the existing `items.act` path: human selects the
   option-action in the panel → plugin resolves the still-open JSON-RPC
   request with `{outcome: selected, optionId}`. The plugin holds the
   request open across polls — the panel's ~2s self-refresh
   (`macos.zig:5234`, tick%240) is the only latency.

The phone leg is VISION.md roadmap #3 ("payloads on the rails") applied
unchanged: the permission item is an **ask** — the remote-asks rail
already promises "follows you, answer either place, both settle". The
ACP plugin is the first producer of asks whose answer is a typed option
list rather than free text, which is precisely the phone's best input
form (tap one of three buttons).

**Where the vocabulary needs a new verb (post-slice-one):** attention
fusion. `attention.raise` today cannot reference an item or carry
actions, so the banner and the answerable item are two things the human
must connect. VISION.md roadmap #1 already owes this ("one banner,
carrying the headline"); the ACP plugin sharpens the requirement to:
`attention.raise {title, body, itemRef?}` so the banner can open the
panel *at* the permission child. Raise it as a vocabulary change, don't
smuggle it.

**Verdict ledger hooks (design in now, ship later):** every permission
answer is a verdict — record `{toolCall.kind, title-digest, optionId,
elapsed-to-answer}` to the digestlog-style journal. Two invariants from
`docs/zed-analysis.md:390-392`:
- `cancelled` outcome ≠ declined (zed's `InterruptedByFollowUp`,
  `acp_thread.rs:1230-1245`): a question mooted by a follow-up prompt
  must not be logged as a rejection, or the rung-4 policy corpus is
  poisoned unrecoverably.
- Rung-4 invariants land in the *plugin's* answer path the day
  auto-answer exists: hardcoded deny list no config can override;
  refuse to even offer `allow_always` — and never auto-answer — for
  commands containing shell substitutions (`$(…)`, backticks), because
  approved text ≠ executed text; bind any remembered path grant to the
  canonical resolved target at approval time (symlink TOCTOU). zed:
  `tool_permissions.rs:12-65`, `terminal.rs:36-50`. In slice one the
  human answers everything, so these reduce to one rule: `allow_always`
  options for shell-substituted commands are demoted to render as
  `allow_once`.

### Deliberately NOT modeled

- **`fs/read_text_file` / `fs/write_text_file`: capability off.** This
  is the biggest divergence from zed and it is on purpose. Zed routes
  agent edits through its buffers to power in-editor hunk review
  (action_log). rook's verdict (`docs/zed-analysis.md:401` rec 7) is to
  *not* chase in-editor review near-term; with the capability off, the
  agent writes files itself and rook's ordinary document/gutter
  machinery sees the changes on disk. Turning fs on without an
  action_log equivalent buys a proxy hop and nothing else. §4 lands
  the decisive fact: claude-agent-acp itself no longer routes edits
  through client fs (built-in tools since its #316) — the capability
  would sit unused for the very agent rook targets first.
- **`terminal/*`: capability off.** rook owns real PTYs; proxying the
  agent's command execution through the plugin protocol into a rook pane
  is a whole design (which pane? whose scrollback?) that slice one does
  not need. The agent runs commands internally and reports them as
  `execute` tool calls with rawOutput.
- **Plan rendering, session modes, slash commands, `session/load`,
  audio/image content**: parked. Modes matter for claude-code-acp
  (plan/acceptEdits) and should come early in slice two as an item
  action cycling `session/set_mode`.
- **A UI DSL for tool-call detail.** rawInput/rawOutput/diff render
  through existing detail refs (document/diff/transcript), never
  plugin-painted pixels (VOCABULARY.md "Deliberately not here").

---

## 3. Coexistence with `plugins/claude`

The two plugins are complementary by *how the session was born*:

| | `plugins/acp` | `plugins/claude` |
|---|---|---|
| sees | sessions rook spawned through ACP | every Claude Code session on the machine, however started (`~/.claude/projects` jsonl) |
| data | structured: typed tool calls, live permission requests, usage | inferred: transcript scan + pane-activity fusion, `blocked?` heuristics |
| can act | prompt, answer permissions, cancel — real API | `open` a pane, `peek`; actuation only via `session.send` keystrokes |
| latency | streamed (2s panel pull) | 2s transcript poll + fusion |

Machine-wide visibility is rook's uncontested asymmetry vs zed
(`docs/zed-analysis.md:379`) — the transcript scanner must therefore
**stay**, and stays the fallback story: any agent rook did not spawn, or
any ACP-less agent, is still supervised.

**Double-counting is real, not hypothetical**: claude-code-acp's
underlying Claude Code SDK writes the same `~/.claude/projects` jsonl
transcripts the scanner reads, so an ACP-spawned session would appear
twice — once structured, once inferred, with two banners for one event.
Options:

1. **Suppression by session id (recommended).** Claude Code's transcript
   filename/`sessionId` and the SDK session id are the same namespace.
   The ACP plugin exposes `acp.sessions` (or simply: the host passes
   each plugin the other's item ids is *wrong* — plugins must not know
   each other). Cleanest concrete shape: the ACP plugin writes the ids
   it owns to a tiny well-known file
   (`~/.local/state/rook/acp-owned.json`, mtime-guarded); the scanner's
   `Scan` drops matching ids. Shared-file coordination, no protocol
   change, fail-open (file missing → old behavior). Precedent: the
   shared transcript library already lives in `plugins/internal/`.
2. Item-namespace discipline only (`acp:` vs bare id prefixes) — stops
   id collisions but not double banners. Necessary, not sufficient.
3. Host-side dedup — rejected: the host would need to understand
   session identity, which the vocabulary deliberately keeps out of
   core.

Both plugins keep raising attention through the same verb; ranking
across sources is already attention's job (VOCABULARY open-question 2).

---

## 4. What claude-code-acp loses vs raw PTY Claude Code

First, the naming fact: the repo moved. `zed-industries/claude-code-acp`
now redirects to **`agentclientprotocol/claude-agent-acp`**, npm
`@agentclientprotocol/claude-agent-acp`, latest **v0.66.0
(2026-08-07)** — actively maintained, Apache-2.0, still authored by Zed
Industries. It is one Node ≥22 process (`bin: claude-agent-acp`),
ndjson-ACP on stdout/stdin, all logging redirected to stderr
(`src/index.ts`, `runAcp()` in `src/acp-agent.ts`). It wraps
`@anthropic-ai/claude-agent-sdk` 0.3.220 (exact pin) via one streaming
`query()` per ACP session; the SDK in turn spawns the Claude Code CLI
bundled inside the SDK package.

### Surprisingly NOT lost

The adapter passes `settingSources: ["user", "project", "local"]`, so a
wrapped session loads **CLAUDE.md, settings.json, user hooks, and
skills exactly as the CLI does** (it merges its own PostToolUse/
TaskCreated/TaskCompleted hooks with the user's rather than replacing
them). Also intact: **todo lists** (TodoWrite → ACP `plan`),
**subagents** (Task tool; nested transcripts via a non-standard
`_meta["subagent-transcript"]` capability, flattened text otherwise),
**images** (base64 + http), **custom slash commands** (from
`.claude/commands`, surfaced via `available_commands_update`), **MCP
passthrough** (`session/new` mcpServers → SDK config; http/sse/stdio),
**plan mode** (as a session mode; `ExitPlanMode` becomes a permission
request whose options ARE mode switches — "Yes, and auto-accept edits"
→ `acceptEdits` etc.), **session resume/load/fork**, and prompt
queueing/steering (`_session/steering` extension injects a message into
a running turn).

### Actually lost or degraded (the honest list)

- **The CLI's interactive UI itself**: vim-mode input, tab completion,
  ctrl-r history, the interactive plan-editing surface, output styles —
  inherently absent; the client must rebuild what it wants.
- **Hidden slash commands** (`getAvailableSlashCommands` filter, ~7073):
  `/clear`, `/cost`, `/keybindings-help`, `/login`, `/logout`,
  `/output-style:new`, `/release-notes`, `/todos` declared unsupported.
- **Many built-ins emit nothing over ACP**: `/usage /status /model
  /memory /permissions /agents /mcp` produce no output (#642),
  `/context` is unstructured markdown (#643), `/compact`'s summary is
  dropped (#873).
- **Checkpoint / rewind**: no `/rewind`; the adapter only maps ACP
  message ids to SDK uuids so a client *could* drive
  `rewindFiles`/`resumeSessionAt` (~686–701) — nothing exposed yet.
  This is exactly why the per-prompt **git checkpoint** steal
  (`docs/zed-analysis.md:386`) is worth shipping independent of ACP.
- **Background bash is rough**: background shells escape the turn-hold
  and fire out-of-turn permission requests (#876), background tasks
  can't be tracked to completion (#865), a background Agent can
  deadlock via permission-id desync (#851), notifications can block the
  queue (#603). Crons/ScheduleWakeup never fire (#838, #655).
- **AskUserQuestion** requires the client to support ACP **form
  elicitation** (unstable `elicitation/create`); for clients without
  it, the tool is added to `disallowedTools` — the agent simply loses
  the ability to ask structured questions. (rook note: rook *has* a
  Form surface in the vocabulary — supporting elicitation is a natural
  slice-two, and until then rook-through-ACP loses AskUserQuestion.)
- **Blob resources and audio prompt chunks silently ignored**
  (`promptToClaude` ~7161; PDF blobs requested in #935); session titles
  not generated (#861); stdio MCP servers passed via `session/new`
  sometimes never reach the model (#883).

### Two adapter facts that reshape rook's design

1. **Edits do NOT ride `fs/write_text_file`.** Since #316
   (`be618f5d`, "Switch over to built-in Claude Code tools") the SDK's
   Read/Write/Edit hit disk directly; the adapter renders them as
   `tool_call` diffs — optimistic diff from `tool_use` input, then the
   real `structuredPatch` from a PostToolUse hook
   (`toolUpdateFromDiffToolResponse`, `src/tools.ts`). So rook's
   "capabilities off" posture (§2) costs nothing with this agent: even
   zed's own adapter no longer uses the client fs proxy, and unsaved
   editor buffers are invisible to the agent either way.
2. **Terminal is not ACP's standard `terminal/*` either.** Bash output
   streams via a non-standard `_meta["terminal_output"]` capability
   (`src/tools.ts` ~100–110, 689–810), with plain code-block fallback.
   rook gets command output as tool-call content without implementing
   any terminal capability.

### The verdict for rook's fallback story

Running Claude Code through the adapter costs the *interactive-UI*
layer and some command surface, not the brain: config, hooks, MCP,
subagents, and plan mode survive. So the honest guidance is: spawn
through ACP when the session's purpose is **supervised work** (rook
prompts, watches, approves — possibly from a phone); keep a raw PTY
pane when the human is **driving** (slash-command-heavy, /rewind,
interactive plan editing). rook uniquely offers both at once — nothing
prevents an ACP-supervised session *and* raw PTY panes coexisting, and
the transcript scanner (§3) covers the PTY side.

---

## 5. Slice one

**Ship:** `plugins/acp` (Go, beside `plugins/claude`, reusing its conn
demux), spawning **one** configured agent server
(`@agentclientprotocol/claude-agent-acp`, version-pinned — npx-on-
demand is a supply-chain decision to make explicitly; the Supermaven
tmp-leak lesson says vet anything that downloads at runtime), one
session, and:

1. `initialize` (v1, all client capabilities false) → `session/new`
   with cwd = the workspace the panel is scoped to.
2. Item per session; `prompt` INPUT_TEXT action → `session/prompt`;
   state `working` while the call is open.
3. `session/update` pump → tool-call children with state/kind/anchor
   fields; agent_message text accumulated into the item detail.
4. `session/request_permission` → child in `needs-you` + option-actions
   + `attention.raise`; answer via `items.act` resolves the RPC.
   Cancel action → `session/cancel` + auto-answer pending permissions
   `cancelled`.
5. Crash/exit of the child → item state `failed`, banner, no respawn.

**Hardening in scope for slice one** (each one paid for by zed, cites
in §zed-notes): initialize raced against child exit with stderr tail;
unknown `sessionUpdate` variants ignored; `tool_call_update` for an
unseen id becomes a failed child, not an error; cancel resolves all
pending permission responders with `cancelled` *before* sending
`session/cancel`; permission answers carry only `optionId` back.

**Defer, explicitly:** fs/terminal capabilities; plan + modes + slash
commands; `session/load`/multi-session-per-agent; phone leg (arrives
with the rails, not with this plugin); digests for ACP turns; verdict
journal; auto-answer of any kind; a second agent (gemini etc. — the
plugin is agent-shaped config from day one, but one binary is the
proof).

### Reasons NOT to build it (stated so they can be rebutted)

1. **Node in the loop.** The only ACP path to Claude Code today is a
   Node ≥22 adapter wrapping a JS SDK wrapping the CLI — three layers
   of someone else's release cadence between rook and the model, for a
   product whose identity is "one Zig binary, no daemon". Rebuttal:
   the *plugin* seam contains it (out-of-process, separately
   accounted, killable), and PTY remains the substrate; ACP is an
   upgrade path, not a dependency.
2. **The adapter is young and churning** (v0.66.0, 60+ releases,
   background-bash issues #876/#865/#851 open; the repo itself just
   changed owners to the `agentclientprotocol` org). A rook feature
   built on it inherits its bug list. Rebuttal: slice one uses only
   the stable core (init / new / prompt / update / permission), which
   is the part v1 froze.
3. **Double supervision must be gotten right or the feature is a
   regression** — two banners per event teach the human to ignore
   banners, the exact failure `plugins/claude`'s `watch()` was
   designed against. The §3 suppression file is therefore *in* slice
   one's acceptance test, not after it.
4. **Opportunity cost vs the checkpoint steal**: per-prompt git
   checkpoints (`docs/zed-analysis.md:386`) are higher phone-safety
   value per line and have no protocol dependency. If only one lands
   this month, it should arguably be checkpoints. Rebuttal: they are
   independent; this brief exists so the ACP slice is scoped well
   enough to run second.

---

## zed implementation notes (grounding, zed @ 101ca00a1352, 2026-08-06)

What zed's client actually does, and which of its lessons transfer:

- **Pin situation**: zed pins crate `agent-client-protocol = "=2.0.0"`
  (Cargo.toml:521) but imports the **wire schema v1 module**
  (`use agent_client_protocol::schema::v1 as acp` everywhere, e.g.
  `agent_servers/src/acp.rs:6-9`). Confirms: v1 is the wire to target;
  v2 is future.
- **Spawn/handshake hardening** (`acp.rs:804-1103`): stdio ndjson
  child; initialize is **raced against child exit**
  (`futures::select`, :991-1010) with a 250ms grace to collect the exit
  status, and stderr is tailed on a background task so a crash reports
  as `Exited{status, stderr}` instead of an opaque RPC timeout. This is
  the `docs/zed-analysis.md:388` steal, confirmed at the exact site —
  rook's plugin should do the same from day one (Go makes it cheap).
- **Client caps zed sends** (`acp.rs:764-792`): fs true/true, terminal
  true, `elicitation {form, url}`, `_meta {terminal_output: true}`.
  rook slice one sends none of these; the consequence with
  claude-agent-acp is graceful (code-block output fallback, no
  AskUserQuestion).
- **Permission machinery** (`acp_thread.rs:3383-3478`, 1197-1245):
  pending request = a `WaitingForConfirmation` status wrapping the
  tool call's *underlying* status plus the responder channel — the
  permission is a state of the tool-call child, not a separate object.
  That is exactly the item-child mapping in §2. Outcomes: `Cancelled`
  and `InterruptedByFollowUp` are distinct in zed's model but **both
  serialize to wire `cancelled`** (:1237-1245) — the distinction exists
  only for the local ledger, which is why rook must record it locally
  too (§2 verdict hooks). Only `optionId` ever crosses the wire back.
- **Always-allow persistence**: for external ACP agents zed persists
  *nothing* — the agent owns the memory of an `allow_always`
  (claude-agent-acp scopes it to the session via
  `updatedPermissions destination:"session"`). rook should adopt the
  same posture: the plugin never stores grants in slice one; a
  remembered grant is the agent's, session-scoped, dying with it.
- **Tolerance patterns worth copying**: unknown `SessionUpdate`
  variants hit a `_ => {}` catch-all (`acp_thread.rs:2652`, enum is
  non_exhaustive); a `tool_call_update` for an id never seen
  synthesizes a `Failed` "Tool call not found" child rather than
  erroring (:3126-3152); unknown tool-call content variants are
  silently dropped (:1845). rook's own fail-open rule
  (rook-host-protocol-skew memory) says the same thing: never brick on
  a new signal.
- **`session/load` ordering trap**: history replays as `session/update`
  notifications **before** the `session/load` response arrives, so the
  session must be registered before awaiting the RPC (`acp.rs:1155-1290`,
  regression test :4110-4179). Applies the day rook implements load.
- **Cancel discipline** (`acp_thread.rs:3901-3966`, `acp.rs:1974-1996`):
  on user cancel, resolve every pending permission responder with
  `cancelled`, *then* send `session/cancel`, then tolerate the agent's
  abort-flavored errors (zed pattern-matches gemini's "operation was
  aborted" strings and converts to `stopReason: cancelled`).
- **Refusal handling**: on `stopReason: refusal` zed truncates the
  thread back to before the user message (`acp_thread.rs:3831-3865`)
  because the spec says the refused prompt won't be in context. rook
  slice one just marks the item `failed` with a `refused` badge — but
  must not pretend the refused prompt is still part of the session.
- **Follow-along**: zed resolves `locations[]` to buffer anchors and
  moves the editor to the *last* location (`acp_thread.rs:3325-3381`).
  rook's equivalent is the anchor field on children + Decoration
  surface — deferred, but the data is captured from slice one.
