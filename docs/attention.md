# The attention feed

Rook renders attention; it does not manufacture it. Anything that wants
a say in rook's chrome — the status bar, the picker, the preview card —
writes items into the feed, and rook draws them without knowing who
wrote them. Vera is the first publisher; it must not be the last.

## The file

`$XDG_STATE_HOME/rook/attention.jsonl` (default
`~/.local/state/rook/attention.jsonl`), plus every `*.jsonl` in
`attention.d/` beside it. Each file **is** one publisher's current
set, not a log: that publisher rewrites its own file atomically
(write a temp file, `rename(2)` it into place; an empty set removes
the file). The single `attention.jsonl` is the original single-writer
seat (vera holds it); every other publisher owns a file of its own in
`attention.d/`, one file per publisher, so concurrent publishers never
share a file. One JSON object per line:

```json
{"session":"tmux","kind":"waiting","headline":"T-136 needs an answer","at":"2026-08-19T13:40:47-04:00","source":"vera"}
```

| field    | meaning                                                                |
|----------|------------------------------------------------------------------------|
| session  | tmux session name on the rook server this item points at (optional)    |
| dir      | absolute path; rook maps it to the session that dir would become (optional) |
| kind     | `waiting` = a human is needed, renders accent; anything else renders dim |
| headline | one line, required                                                     |
| at       | RFC3339, required; items older than 24h are ignored                    |
| source   | who wrote it, shown dim on the preview card (optional)                 |

Malformed lines are skipped, never fatal. A missing file is an empty
feed.

## Where items appear

- **status bar, right side**: `● N waiting` — only `waiting` items;
  the bar shows attention debt, not activity.
- **picker rows** (`prefix s`): a `waiting` item marks its row
  `● waiting`, merged with rook's own pane heuristics.
- **preview card**: every matching item, accent for waiting, dim
  otherwise, with its source.
- **window tabs**: independent of the feed, the same 5s sweep that
  draws the bar classifies each window's agent panes and stamps
  `@rook_agent` (waiting/working/done); tabs render ● (accent) for
  waiting and ✳ for working.

## Reading rook (the other direction)

Publishers that want rook's view of the world use
`rook ls --json [-t|-z]`: one JSON object per row —
`{"kind":"session","name":"tmux","agent":"working","attention":[…]}` or
`{"kind":"dir","path":"/…"}`. `agent` is `none|done|working|waiting`,
read from the panes.
