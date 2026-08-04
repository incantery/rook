# The rook agent — what it wants to be

> Status: vision, 2026-08-04. Grounded in what is landed in rook
> (`bb73637`: digests, draft/expand/copy, the panel) and what is landed
> or accepted in rook-cloud (the Temporal control plane, the
> supervisor, ADRs 0001–0004). This is the document to design against;
> the current-state inventory and playground live in the appendix.
> Supersedes the panel-polish brief that briefly lived at
> `docs/plugins/DESIGN.md`.

## The identity, in one sentence

**The rook agent is the membrane between you and every agent you run:
it makes agent work legible coming in, makes your intent potent going
out, and — as it earns it — holds the fort when you are away.**

It is not another agent that does the work. Claude Code writes the
code. The rook agent is the layer that means you can *supervise* that
work from wherever you are, at whatever attention level you have to
give — a glance at the panel, a tap on your phone, a sentence spoken
on a walk.

One identity, everywhere. Users do not install a watcher and a
summarizer and a supervisor; they get **the rook agent**, baked into
the prebundled rook core config. That it is implemented as plugins and
services is packaging, not product.

## The membrane, and why it runs on a different model

Every interaction with a coding agent crosses an impedance gap.
Agents emit eight paragraphs where the decision is three bullets;
humans emit "yeah but keep the test" where the agent needs a
paragraph. The rook agent sits in that gap, facing both ways:

- **Inbound — compression.** A finished turn becomes an STE digest: a
  headline you scan, bullets you read, the full text one hop away.
  Never lossy at the source: the membrane compresses the *reading*,
  the session keeps every word.
- **Outbound — amplification.** Your rough words ("sounds good, ship
  it, but log errno") become the reply you meant — decisions kept
  exactly, expanded with specifics drawn from what the agent actually
  said.

A principle our architecture stumbled into that should now be held on
purpose: **the membrane runs on a different model than the workers.**
A cheap, fast, uncorrelated intelligence (today gpt-5.6-luna at
fractions of a cent) reading your Claude sessions is structurally more
valuable than Claude summarizing itself — the overseer must not share
the worker's blind spots. It also keeps the economics legible: the
membrane spends pennies supervising dollars of work, and prints its
own bill on every row.

## One identity, two membranes

The rook agent already exists in two places with two different
authority models. This is not an accident to fix; it is the shape of
the thing.

| | presentation membrane | decision membrane |
|---|---|---|
| lives | rook, on your machine (`plugins/agent`) | rook-cloud (`internal/supervisor`) |
| does | digest, draft, expand — language work | picks ONE action from a runtime-generated list |
| output | prose a human reads and edits | a typed `SupervisorDecision`, validated before dispatch |
| authority | none — a human sends everything | constrained — policy filters, action digests, expiries |
| failure mode | a bad draft you edit | a bad decision the ledger records and the corpus learns from |
| record | the panel (and soon a persistent log) | the durable event history, evidence bundles |

The presentation membrane may say anything and do nothing. The
decision membrane may do things but only from a menu, under policy,
onto a ledger. Autonomy grows by moving specific action classes from
the first column toward the second — never by loosening the second.

Underneath both, one boundary rule inherited from rook-cloud ADR 0003
and never negotiated away: **cloud coordinates, the machine decides.**
The rook agent may request; only rook, on your machine, under your
local policy, executes. Local deny always wins. No generic shell ever
crosses the boundary.

## The phone is not a feature — it is the point

The goal, stated plainly: **run everything from your phone.**
Execution stays on your machine; presence goes wherever you are. The
membrane is what makes that sentence coherent — because what travels
to the phone is not a terminal, it is the membrane's artifacts:

- a **digest** is exactly what a push notification should carry;
- a **drafted reply** is exactly what an approval should offer —
  "yeah that looks good" is *tapping the draft*;
- **expand** is exactly how you write from a phone — you thumb-type or
  dictate rough words, the membrane writes the paragraph;
- an **ask** (rook's remote-asks rail: follows you, answer either
  place, both settle) is the same item, rendered smaller.

We built the phone's payload format first and happened to render it in
a side panel. The panel is one renderer of the membrane. The phone is
the second. Voice is the third.

## Three distances, one gradient

"Away from the keyboard" is not one state. The rook agent should model
distance as an attention gradient and change register accordingly:

| | **the other room** | **on a walk** | **out on errands** |
|---|---|---|---|
| you want | not to walk back for "looks good" | progress without screens | the fort held |
| surface | phone, full fidelity: digest + bullets + draft, tap to send, type rough words | notifications for needs-you only; voice out (spoken headline), voice in (dictated rough reply → expand) | silence, mostly |
| rook agent's job | presentation membrane, live | presentation membrane, terse register | decision membrane: act within policy, batch low-risk questions, escalate only judgment and authority |
| machinery | mailbox rails (stateless HTTP, zero idle traffic) + digests/drafts on the wire | the cloud `voice` surface; digest grammar is already speech-shaped (STE: short sentences, one idea each) | supervisor + DecisionFrames + policy filters + evidence; you return to a trail, not a backlog |
| exists today | rails yes, payloads not yet on them | route scaffolded | supervisor core landed cloud-side |

Two cloud rules carry over verbatim and matter more as distance grows:
approvals bind to an **exact action digest with an expiry** (you
approve *this* diff, not "whatever it ends up doing"), and **voice is
never an authentication factor** — it is an input/output surface,
nothing more.

## The autonomy ladder

The spine of the whole vision. Each rung names what the rook agent may
do, what substrate it needs, and — the part that makes it a ladder —
what *trust evidence* from the rung below unlocks it.

1. **Read.** Watch everything, compress everything, interrupt only
   with cause. *Substrate:* transcripts, `panes.activity`, attention.
   *Mostly built.* Remaining: fuse the watcher's banner with the
   digest so the interruption arrives already carrying the answer.
2. **Suggest.** Draft the reply; expand the rough one. *Substrate:*
   `items.act` payloads, `clipboard.set`. *Built.* The ⌘V hop is rung
   two's honest posture — and its tuition: every edit you make to a
   draft is a verdict on the drafter.
3. **Act with approval.** "Send it" as one tap/keystroke — the rook
   agent types the approved reply into the Claude pane itself.
   *Substrate:* `session.send`, which ADR 0004 tells us is not an API
   call but **TUI keystrokes** — rook owns the PTY and types the way
   you would, subscription-safe, visible in the pane as it happens.
   Approval binds to the exact text; the send lands on the ledger.
4. **Act and report.** For action classes with a strong verdict
   record (trivial acks, known-safe approvals), send on your behalf
   within a policy window; report rather than ask. *Substrate:* the
   verdict ledger + policy filters; the phone shows "sent for you"
   with one-tap undo-by-interrupt.
5. **Orchestrate.** "Take these three digests' follow-ups, spawn
   sessions, watch them, come back when one needs a human." This is
   rook-cloud's Rook Task machinery — Temporal-durable, evidence-
   gated, survives restarts and disconnects — with the rook agent as
   the supervisor it was built for. A task can be *born* in a Claude
   conversation and promoted to a durable Task when it firms up; the
   membrane, which already reads every conversation, is the natural
   promotion point.

The ladder's enforcement machinery is not hypothetical — rook-cloud
already built it: policy-as-filters, decisions constrained to
generated action lists, golden decision corpora, evidence bundles
gating "done", dual event histories. What the local rook agent
contributes upward is the **verdict ledger**: the accumulated record
of accepted digests, edited drafts, approved sends. Verdicts are the
most valuable and most personal data rook will ever hold; where they
live (local file, synced, cloud) is an open product decision — the
default should be the user's machine.

## Non-goals, so the identity stays sharp

- The rook agent **does not write code**. It supervises, translates,
  and dispatches; Claude Code and its peers do the work.
- rook does **not compete with Claude Code by spawning more agents**
  (rook-cloud NEXT.md's own non-goal). The defensible layer is
  durable, provider-neutral, cross-device supervision with local
  machine safety and an evidence-grade record.
- The membrane never becomes the source of truth. Transcripts, diffs,
  tests, and ledgers are truth; the membrane is a *view* with a good
  memory.
- No autonomy by loosening: a rung is never reached by weakening the
  constraints of the rung above it, only by evidence from below.

## What this reorders, concretely

The near-term roadmap, each item justified by the distance it serves:

1. **Attention fusion** (rung 1 completion; serves every distance).
   One banner, carrying the headline. Agent plugin raises with the
   digest; watcher keeps only its time-critical `blocked?` banners.
2. **Persistence** (prerequisite for distance > 0). A digest that
   dies with a relaunch cannot follow you to a walk. Append digests,
   drafts, and verdicts to a local log; load the recent window at
   spawn.
3. **Payloads on the rails** (the other room). Digests, drafts, and
   asks flow over the host↔relay mailbox; the phone renders them;
   answers settle both places. This is the moment "run it from your
   phone" becomes real for the simple cases — which are most cases.
4. **`session.send` as TUI typing, approval-bound** (rung 3). The
   clipboard hop gets a sibling: "send it," gated exactly like a
   confirm action, landing on the ledger.
5. **Identity fusion** (the two membranes learn they are one). Shared
   task/session references between the local plugin and the cloud
   supervisor; one agent in the user's mental model, one ledger of
   its conduct.
6. **Panel polish** — demoted, deliberately. Still worth doing, but
   as one of *three renderings* designed together.

## The design brief, restated

The design question is not "polish the panel." It is:

> **Design the membrane's three renderings — panel, phone, voice — as
> one system.** Same content types everywhere (digest, draft, ask,
> verdict, banner); register shifts with distance; trust is always
> visible (which rung authorized this, what evidence backs it, what
> it cost). The panel shows the most, the phone shows what matters,
> voice speaks only what needs you — but they are recognizably one
> agent.

Concrete surfaces to design: the digest card (panel row ↔ phone
notification ↔ spoken headline — one grammar, three registers); the
approval moment at each distance (Enter ↔ tap ↔ "yes, send it") with
its action-digest binding made visible; the rough-reply input (panel
one-liner ↔ phone keyboard ↔ dictation); the returning-home debrief
(what the fort did while you were out — the evidence trail as a
readable story); and the trust surface itself (the ladder made
glanceable: what may it do today, on what record).

## Appendix: current state and how to see it

The precise inventory of the panel renderer (rows, states, palette,
modes) is in git history at `docs/plugins/DESIGN.md@ba02254` — still
accurate about mechanics, superseded as a brief. The five-minute
sandboxed playground in that document still works and is the fastest
way to see the presentation membrane render real content; the traps
it names (104-byte socket paths, ~400ms geometry settle) are still
paid for. rook-cloud's half: `NEXT.md` (the architecture), ADRs
0001–0004, `internal/supervisor` (DecisionFrames, the golden corpus),
and the `chat`/`voice` routes in `web/`.
