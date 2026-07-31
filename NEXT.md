# Rook Review Workspace — Design Notes

> **Status, 2026-07-31: this is a THESIS, and its implementation was
> stripped.** rook had a review workspace — hunk-level review tasks, a
> gate, anchored threads, Haiku triage — and all of it was removed along
> with the rest of the Go layer. See [`docs/OWED.md`](docs/OWED.md).
>
> The removal was not a verdict on the argument below. It was a verdict on
> the shape: every feature here had grown its own endpoints and its own
> storage, and none of it could have been written by anyone outside the
> repo. If this thesis is right, it should be expressible as plugins over
> the item model in
> [`docs/plugins/VOCABULARY.md`](docs/plugins/VOCABULARY.md) — and the
> exercise that produced that vocabulary took the review queue as one of
> its ten test cases, so the fit is at least plausible.
>
> Read this as the product argument, still open, not as a description of
> anything that runs.

## Core Thesis

The future bottleneck in software engineering is no longer writing code.

It's reviewing, understanding, and validating code that was written by AI agents.

Rook should not try to be "another AI code reviewer."

It should become the best environment to **think through** code changes.

---

# The Mental Model

There are two ways to understand a code change:

1. Mountain → Pebbles
2. Pebbles → Mountain

Most existing tools are mountain-first.

They summarize the PR and ask you to trust that summary while drilling into details.

I think Rook should deliberately go the opposite direction.

Review the smallest meaningful pieces first, build confidence quickly, then step back and decide whether the overall solution actually makes sense.

The goal is not to summarize a PR.

The goal is to let a human rapidly eliminate everything that doesn't deserve significant attention.

---

# Attention Compression

Imagine a PR containing:

- 3,000 lines of internal documentation
- 1,500 lines of tests
- 500 lines of production code

Today every line feels like "part of the PR."

Instead Rook should classify them into different review workflows.

Example:

```
5,000 changed lines

✓ 3,000 documentation
  Claude verified docs match implementation.
  1 possible inconsistency.

✓ 1,500 tests
  Tests validated separately.
  1 suspicious assertion.

✓ 300 mechanical changes
  Auto-approved.

→ 200 production lines
  Human review recommended.

→ 60 production lines
  Human attention strongly recommended.
```

The reviewer should feel like they're reviewing a small PR rather than drowning in a massive one.

---

# Hunks Are The Atomic Unit

I don't think Rook should primarily merge things into large semantic review items.

The atomic unit should still be the git hunk.

Claude can absolutely use wider context while reasoning.

It can inspect:

- neighboring code
- other files
- tests
- call sites
- issue descriptions
- agent transcripts

But the output should come back attached to individual hunks.

Each hunk becomes a tiny review task.

---

# Different Categories Need Different Review Strategies

Documentation != Tests != Production Code

Each category has different risk.

Examples:

## Internal Documentation

Low risk.

Claude can verify consistency against implementation.

Human probably skims.

---

## Tests

Different review questions:

- Does this actually prove the behavior?
- Is it flaky?
- Are edge cases missing?
- Can Claude mutate the implementation and verify the tests fail?

---

## Production Code

Requires actual understanding.

This is where human attention belongs.

---

# Local vs Global Review

This feels like an important distinction.

Example:

We add:

```
skipCache: boolean
```

Locally this makes perfect sense.

If this is the architecture we've chosen, then:

- field name makes sense
- implementation is correct
- propagation is correct

I should be able to approve that.

Separately...

I might still question whether exposing cache bypass is the correct architectural decision.

Those are different review questions.

Local:

"Given the current design, this implementation is good."

Global:

"Is this actually the design we want?"

Those shouldn't block each other.

---

# Conditional Approval

A review state isn't just:

- approve
- reject

There is also:

"I approve this assuming the overall design remains correct."

That lets me unload that decision from working memory.

If the overall design changes later, Rook can invalidate that approval.

---

# Whiteboard vs Typewriter

This might actually be the biggest differentiator.

GitHub review comments are public.

Every comment feels like something another engineer will read.

That changes behavior.

Rook should be a whiteboard.

While reviewing I should be able to dump every thought into the diff.

Examples:

- Why is this named skipCache?
- This feels weird.
- Could this race?
- Isn't there already a helper?
- Why not make this configurable?
- I don't understand this.

These are NOT GitHub comments.

They're thinking.

Scratch notes.

Questions.

Half-formed ideas.

Gut reactions.

---

# Claude Reviews My Thoughts

After I finish reviewing, Claude should process my annotations.

For each note it can:

- answer the question
- propose code
- explain intent
- find evidence
- point to related code
- challenge my assumption
- identify that the concern is already addressed
- recommend changes

This becomes an iterative conversation.

Not just AI reviewing code.

AI helping me think.

---

# Rook Is A Review Workspace

GitHub is where I publish review comments.

Rook is where I figure out what I actually think.

Those are different activities.

Rook should optimize for:

- exploration
- uncertainty
- questions
- conversations
- experimentation
- private notes

Not publication.

---

# The Development Loop

Instead of:

Write Code
↓

Open PR
↓

Review

The future loop becomes:

Agent writes code
↓

Human reviews
↓

Human leaves notes
↓

Claude investigates
↓

Claude revises implementation
↓

Human reviews only changed hunks
↓

Repeat

The review itself becomes the primary engineering activity.

---

# Long-Term Vision

Rook is not trying to replace GitHub.

GitHub remains the public record.

Rook becomes the private workspace where developers:

- understand changes
- ask questions
- leave scratch notes
- work with Claude
- gradually build confidence
- only publish the conclusions worth sharing

The IDE/editor becomes a supporting tool.

The primary workflow is reviewing, understanding, and directing AI-generated work.

---

# Open Questions

- What should the review data model look like?
- What is the smallest useful hunk-level object?
- How should annotations be stored?
- How should Claude respond to annotations?
- How do review sessions evolve as Claude changes the code?
- How should "conditional approval" work?
- How do we preserve review state across iterations?
- How should CLI and GUI experiences differ?
- How do we make spending 6+ hours/day reviewing code genuinely comfortable?
