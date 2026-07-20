# Comments over LSP — the shareable half of the review workspace

*Rook's threads are anchored, agent-answerable comments on code. Today they
are visible only inside rook's own Monaco pane. This spec exposes the part of
that model every editor already knows how to render — diagnostics and code
actions — over a real LSP server, so nvim, VS Code and Cursor can see and act
on rook comments. Rook's own editor deliberately does NOT consume it.*

## Thesis

The review workspace's thesis (NEXT.md) is that reviewing, not writing, is
becoming the primary engineering activity, and that rook is where you figure
out what you think before GitHub becomes the public record. Threads are the
substrate for that: a scratch note anchored to a blob, answerable by an agent,
never published until you say so.

That substrate is currently trapped in one editor. A comment you left in rook
is invisible the moment you drop into nvim on the same file — which is exactly
where a lot of the actual reading happens.

LSP is the obvious carrier, and the interesting question is not *whether* to
speak it but **how much of the model to put on the wire**. The answer this
spec commits to:

> **The LSP server carries what every editor renders the same way. Rook's own
> editor keeps everything else.**

This is a deliberate asymmetry, not a staging plan. It is not the case that
rook's Monaco should eventually consume its own LSP server "for consistency" —
doing so would cap rook's review surface at the lowest common denominator of
every other editor, which is the opposite of the product bet.

## The boundary

**On the wire (shared):**

| LSP surface | Carries |
|---|---|
| `textDocument/publishDiagnostics` | every unresolved thread on the file, at its **re-anchored** range |
| `textDocument/codeAction` | resolve / reopen / ask-the-agent, for threads overlapping the cursor |
| `workspace/executeCommand` | the verbs those actions invoke |

**Native to rook only:**

the composer (`,c` / `,?` / ⌘⇧M), the thread panel with its per-comment
avatars and reply box, glyph-margin bands with stacked-thread cycling, the
pending→submit batch model, outdated-anchor rendering, review-task integration,
and anything that comes later (proposed revisions, conditional approval).

### Why not `textDocument/hover`

Hover is the tempting one — a thread reads like hover content. It is the wrong
channel, for a reason that is a property of clients rather than of taste:

**Diagnostics merge across servers; hover competes.** nvim renders the union
of every attached client's diagnostics, so rook's comments sit alongside
gopls's errors with no arbitration. Hover, by contrast, resolves to one widget:
attaching a second server that answers `textDocument/hover` means every `K` on
a symbol now races rook's answer against gopls's, and the language server —
the one you actually need mid-edit — is what degrades.

A comment is also not the answer to "what is this symbol", which is the
question `K` asks. Putting it there is a category error that happens to be
technically expressible.

Rook's own editor has no such constraint: it owns its hover provider and can
merge thread content into it directly, since it knows both sources. That is
precisely the kind of thing the "more integrated" half is for.

### What the wire cannot carry

**Creating a comment.** LSP has no "annotate this range" verb, and a code
action cannot prompt for free text — it returns a command, not a dialog. So
comment *creation* from nvim stays `rookctl comment path:a-b <text…>`, which
already exists. Likewise free-text *reply* stays `rookctl reply <id> <text…>`.

This is an honest limitation and it is worth stating in the diagnostic message
itself: each published diagnostic carries its thread id, so the command you
need is always on screen. Same posture as the self-contained nudge — spell the
verb out rather than assume a skill, plugin, or memorized flag.

The one-click verbs (resolve, reopen, ask) need no input, so those are code
actions.

## Transport: `rookctl lsp-server`

A new rookctl verb that speaks LSP on stdio and proxies to the running
rook-host over its existing authenticated HTTP API.

```lua
-- nvim
vim.lsp.start({
  name = "rook",
  cmd = {"rookctl", "lsp-server"},
  root_dir = vim.fs.root(0, ".git"),
})
```

Why a bridge rather than a port on rook-host:

- stdio-per-client is what every editor's LSP plumbing already does; a TCP
  LSP endpoint is the unusual path in all of them.
- The daemon stays the single owner of the registry, threads and anchoring.
  The bridge is stateless — it holds open documents and a workspace name, and
  every fact comes from the host.
- It inherits `connect()` / `host.ReadState()` (cmd/rookctl/main.go:71), so
  discovery and the bearer token are already solved.
- rook-host outlives app installs, so protocol skew between a new client and
  an older daemon is a standing constraint: a bridge that fails open on an
  unknown host response is far easier to reason about than a protocol surface
  welded into the daemon.

Workspace resolution reuses the existing ladder: `-w`, else `$ROOK_WORKSPACE`,
else the registry entry whose root contains the client's `rootUri`. The last
one is new and necessary — an editor launched outside a rook window has no
`ROOK_WORKSPACE`.

## Protocol implementation

`internal/lsp/conn.go` already has direction-agnostic framing: `readMsg` is a
stateless package-level function, `newConn` takes plain `io.Reader`/`io.Writer`
(so `os.Stdin`/`os.Stdout` drop straight in), and the `handle` callback already
covers inbound *requests*. Two changes are needed:

1. **`readLoop` drops every inbound notification** (conn.go:154, commented
   "diagnostics are a deferred seam"). A server that ignores `didOpen` /
   `didChange` / `didClose` is a non-starter. The loop needs a notification
   sink alongside the request handler.
2. Everything is unexported. Either export the transport or put the server in
   `internal/lsp`. Prefer the latter for slice one — fewer public surfaces to
   regret, and the two directions genuinely share the framing.

No JSON-RPC dependency is added. The repo hand-rolls the protocol on purpose
(conn.go:1-5, "~200 lines of protocol instead of a dependency") and the server
side is smaller than the client side; matching that convention is cheaper than
introducing `go.lsp.dev`.

## The push problem

`publishDiagnostics` is a server→client push, and **rook has no event stream**.
Thread mutations write SQLite and return; nothing broadcasts. The only push
surface in the host is the per-session PTY WebSocket.

The same gap is already a live dogfood bug on the rook side: the frontend
refetches threads only on pane focus (`editor.ts:372`, `STALE_MS = 2000`), so
**an agent's reply is invisible until you click back into the editor.** You
ask, claude answers, and rook shows you nothing until you happen to refocus.

So this is one fix with two consumers, and it should be built as such:

> **`GET /workspaces/{ws}/threads/watch` — SSE, emitting a small envelope
> whenever a thread in that workspace is created, commented on, resolved,
> reopened or submitted.**

The bridge subscribes and republishes diagnostics for open documents; the
frontend subscribes and drops the focus-only staleness dance. Mutation sites
are already funnelled (`createThread`, `addThreadComment`, `resolveThread`,
`reopenThread`, `submitThread(s)`), so the broadcast is a handful of call
sites behind one registry-level notifier.

Polling from the bridge is the obvious de-risk, and it is tempting because it
touches nothing. It is rejected as the *destination* because it leaves the
frontend bug unfixed and puts a permanent timer against SQLite for a signal
the host already knows exactly when to emit. If slice one needs to ship before
the SSE lands, poll — but the SSE is the design.

## Thread → diagnostic mapping

One diagnostic per unresolved thread, at the **re-anchored** range
(`currentStart`/`currentEnd`), not the stored one — the whole point of
`anchorNow` is that a comment follows its code.

| Field | Value |
|---|---|
| `range` | re-anchored, 0-based, converted at the edge like every other LSP surface |
| `severity` | open → `Information`; pending → `Hint` |
| `source` | `rook` |
| `code` | the thread id (the handle `rookctl reply` needs) |
| `message` | first comment, then reply count, then the outdated marker if the anchor drifted |
| `tags` | — |

Resolved threads are not published. They are, by definition, the ones you have
stopped thinking about, and a review workspace that accumulates permanent
gutter noise stops being usable.

Severity is a mapping choice with real ergonomic consequence — `Error` would
put comments in the same visual channel as compile failures, which is wrong
even when a comment is important. `Information`/`Hint` keeps them legible
without competing with the language server. Both are worth revisiting after a
week of use; neither should be configurable before then.

The mapping itself is a pure Go function over `ThreadInfo`, unit-testable
without a protocol, and the one piece genuinely shared between the LSP server
and (eventually) any other export.

## Document sync

`didOpen`/`didChange`/`didClose`, full-text sync (incremental is not worth it
at this scale). The bridge keeps the current text per URI for one reason:
**anchoring**. A thread's range is re-anchored against current content, and
while a buffer is dirty the file on disk is stale. The host's thread endpoints
re-anchor from the working tree, so slice one accepts a small lag on unsaved
buffers rather than teaching the anchor path to take client text.

That is a real, boring limitation and it should be written down rather than
discovered: **comments re-anchor on save, not on keystroke.** The existing
`lspQueryRequest.Text` field is the precedent for fixing it later if the lag
turns out to matter.

## What slice one ships

1. `readLoop` learns notifications; server-side scaffolding in `internal/lsp`.
2. `rookctl lsp-server`: initialize/shutdown, document sync, workspace
   resolution.
3. `threadDiagnostics(ThreadInfo) Diagnostic` mapping + unit tests.
4. `publishDiagnostics` on open/change and on the change signal.
5. `GET /workspaces/{ws}/threads/watch` (SSE) + registry notifier.
6. Frontend subscribes to the same stream — kills the focus-only refresh, so
   agent replies appear as they land.
7. Code actions: resolve / reopen / ask, via `executeCommand`.
8. `docs/nvim.md`: the ten lines of Lua above, and the `rookctl` verbs for
   what the wire can't carry.

## Deferred (seams, not built)

- **Inlay hints** for reply counts. Plausibly nicer than diagnostics for
  answered threads; needs the diagnostic version in real use first.
- **`textDocument/documentLink`** or a custom command to open a thread in
  rook from the foreign editor.
- **Dirty-buffer anchoring** (pass client text into the anchor path).
- **A VS Code extension.** The LSP server is editor-agnostic by construction,
  but VS Code's comment API is much richer than diagnostics and would be the
  better target *if* Cursor/VS Code becomes a real review surface.
- **Publishing rook comments to GitHub.** Out of scope by thesis: GitHub is
  the public record, rook is where you decide what deserves to go there.

## Decisions

- **Diagnostics + code actions only; never hover.** Clients merge the first,
  arbitrate the second. Rook's own hover can merge threads because it owns
  both sides.
- **Rook's Monaco does not consume this server.** The shared piece is the
  mapping function in Go, not the transport. Divergence is the product bet.
- **The bridge is stateless.** The daemon owns threads and anchoring; the
  bridge holds open documents and nothing else.
- **SSE, not polling** — because it fixes the frontend's invisible-reply bug
  with the same channel.
- **Creation and free-text reply stay on rookctl**, and every diagnostic
  carries the thread id so the command is always to hand.
- **Resolved threads are not published.**
