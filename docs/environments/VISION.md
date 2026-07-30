# Environments — the direction

> 2026-07-30, from Seth's notes plus the design discussion. This is the
> candidate resolution of the "what is rook" question: not an AI IDE,
> not a review tool — a **native-performance substrate that materializes
> development environments**. "AI-native" and "review-first" are
> configurations of it. The immediate slices are at the bottom; IR.md
> is the part that exists.

## The idea

Configuration is not a startup script that mutates an editor. It is a
declarative description of a development environment, written in a real
language (Go first), compiled to a language-neutral graph (the IR),
materialized and reconciled by rook. Pulumi's authoring model; React's
runtime model; kubectl's state model.

- **Authoring (Pulumi):** the user's program emits a graph. It runs at
  apply time, never at launch — launch reads the materialized graph
  (measured budget: the TOML parse it replaces is ~50µs; see
  app/PERF.md "Startup").
- **Runtime (React):** no Pulumi-style state file recording "actual".
  The live object tree is enumerable and is the only truth; desired
  diffs against live, and long-lived state (PTYs, editors, scroll,
  agent sessions) survives every apply.
- **State (kubectl):** what IS persisted is the **last-applied desired
  graph** (last-applied-configuration in spirit). That yields three
  distinct diffs, each a command:
  - candidate vs last-applied = **preview** — the trust surface: what
    adopting this config changes, which plugins it adds, what
    capabilities they request, before anything runs.
  - last-applied vs live = **drift** — what you changed by hand;
    offered back as config amendments, never silently clobbered.
  - candidate vs live = the **apply plan**, respecting ownership.

## Ownership (the hard problem)

Config-declared nodes are config-owned; reconcile enforces them.
Everything the user creates or mutates live — splits, resizes, cwd —
is user-owned; reconcile never touches it ("the workspace is an
annotation, not a container; cd is sacred", generalized). Apply only
what changed in the graph diff, never what drifted. This needs a paper
design before the reconciler is built; layout drift has no established
right answer anywhere.

## Provenance

Every node records which package produced it and what overrode it, so
preview can PROVE an override won: compose a stranger's setup, neuter
the plugin you don't trust, and see `REMOVED by my.Overrides` in the
preview rather than hoping composition worked. Capability deltas
surface at preview, are granted at apply, and are never inherited
silently from a composed package.

## Why this is rook's and not just a nice idea

An agent can emit a candidate graph — "three diff panes, the failing
test, this checklist" — and the preview diff is the reviewable
artifact: semantic, small, verdictable in seconds, capability-gated.
That is the verdict ledger applied to configuration, and it requires
the workspace to BE a diffable value, which editors-with-config-files
don't have. Environments are also the composition story: official
contracts (`official.Neovim()`, tmux's detach — rook-host already
outlives the app) instead of dotfiles; work modes (`rook review`,
`rook infra-incident`) instead of layouts; repos and teams shipping
"how we work" as a package.

Two lines held on purpose:

- **Contracts, not ecosystems.** Muscle memory, bindings, chrome,
  layout grammar are winnable at native perf. Extension marketplaces
  are not; never promise "your VS Code extensions run here". Plugins
  provide data, commands, structure — never frames.
- **The substrate is the moat, not the pitch.** The wedge stays
  specific (terminal for Claude Code; `rook review`); composability is
  the retention story. Emacs is the cautionary tale of composability
  without opinion.

The honest test of the whole thesis: express `official.Rook()` — deck,
threads, review gate, current chrome — against the same public IR a
stranger would use. Where it can't be written, the platform is still
fiction.

## Sequencing

1. ✅ Startup baseline measured (app/PERF.md) — config is 50µs of 72ms.
2. ✅ IR v1 + app loads `environment.json` (IR.md) + Go SDK (sdk/rook)
   with Seth's config as the example; emit-time measured per language.
3. TOML → IR inside the app (one loader; TOML becomes a front end) and
   a TOML renderer for the host's half of the file.
4. `rook env apply` / `preview` verbs; last-applied graph; ownership
   design doc BEFORE any reconciler code.
5. ~~TypeScript SDK~~ (sdk/ts/rook.ts, 07-30 — Seth's vscode persona
   runs on it; preset goldens in rook.test.ts). Python SDK when
   demand arrives (the parity probe under sdk/rook/example stands in).
6. First work mode: `rook review`, converging with the RookTask design.

Deferred until dogfood demands: multi-language beyond the three,
`official.VSCode()`, package registry/sharing, CI parity, roles.
