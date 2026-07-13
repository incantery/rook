# Key repeat (hold-to-repeat) — investigation & fix (#35)

**Status:** root cause found, fix landed. Spike for
[#35](https://github.com/incantery/rook/issues/35).

## Symptom

Holding a key to auto-repeat works for some keys and not others. Hold `j` or
an arrow and it repeats; hold `a`/`e`/`i`/`o`/`u`/`n` and you get a single
character, then nothing (or an accent popover). The split is **by key**, not
by pane.

## Root cause

macOS **press-and-hold** in WKWebView, driven by the system default
`ApplePressAndHoldEnabled`.

rook renders through Wails v3 (`cmd/rook/main.go`,
`github.com/wailsapp/wails/v3` — a WKWebView on macOS). WKWebView honours the
system `ApplePressAndHoldEnabled` default:

- When it resolves **truthy** (macOS's default when the key is *unset*),
  holding a letter that has accent variants (a e i o u n c …) shows the accent
  popover **instead of** repeating. Keys with no accent variant (j k, arrows,
  digits, most punctuation) repeat normally.
- When it resolves to **NO**, every key repeats — terminal behaviour.

That is exactly "may or may not repeat depending on which key."

### Why it's inconsistent across machines too

`NSUserDefaults` resolves a key through domains in priority order: argument →
application (the app's own plist) → global (`NSGlobalDomain`) → registration
(`registerDefaults`). Two facts combine:

1. **Wails v3 never sets `ApplePressAndHoldEnabled`.** Verified by grepping the
   pinned module (`v3.0.0-alpha2.117`): the only `NSUserDefaults` read is
   `AppleInterfaceStyle` for dark-mode detection
   (`pkg/application/application_darwin.go:74`). Nothing writes press-and-hold.
2. **rook never set it either** (before this fix), and the app domain
   `com.incantery.rook` has no value for it.

So rook inherited whatever `NSGlobalDomain` said. On a **stock** Mac that key
is unset → press-and-hold ON → accent letters don't repeat. On a machine where
someone once ran `defaults write -g ApplePressAndHoldEnabled -bool false`
(a common developer tweak / the old VS Code advice), it's OFF → everything
repeats. Same build, opposite behaviour — the inconsistency between machines.

> Note: on the dev machine used for this spike, `defaults read -g
> ApplePressAndHoldEnabled` returns `0`, which *masks* the bug locally.
> Relying on that global value is itself the bug.

## What was ruled out (frontend is not the culprit)

- **Capture-phase keydown** (`frontend/src/App.svelte:408`, registered
  `capture:true` at `:577`) never inspects `e.repeat` (confirmed: no `.repeat`
  reference anywhere under `frontend/src`). For a plain held key with no
  modifier it returns early at `App.svelte:489` (`if (!e.metaKey &&
  !e.ctrlKey && !e.altKey) return;`) on **every** repeat event, so repeats
  fall through to the shell untouched.
- **xterm input path** (`frontend/src/term/manager.ts:322`, `term.onData`):
  every keystroke, repeats included, is forwarded to the PTY. The replay gate
  (`:416`) only strips a specific `AUTO_REPLY` marker sequence, never repeated
  characters — no input latency, no swallowed repeats.
- **Monaco / thread-zone panes:** press-and-hold is an OS-level input-method
  behaviour tied to the *key*, not the pane. Every editable context in the
  webview (xterm's textarea, Monaco's textarea, thread-widget inputs, home
  inputs) is affected identically. `.thread-zone` is guarded at
  `App.svelte:424` only so the leader/backtick prefix doesn't eat backticks in
  review comments — it has no bearing on repeat.

### Repro matrix (before fix, stock `ApplePressAndHoldEnabled` = ON)

| Key held        | Terminal | Monaco | Thread input | Home input |
|-----------------|----------|--------|--------------|------------|
| `a e i o u n c` | popover, no repeat | popover | popover | popover |
| `j k l s` etc.  | repeats  | repeats| repeats      | repeats    |
| arrows, digits  | repeats  | repeats| repeats      | repeats    |

The pane column is uniform on purpose: the driver is the OS, keyed on the
character, not on which webview element has focus.

### Secondary observation (minor, not the reported bug)

Holding the **leader** key itself (backtick by default,
`internal/config/config.go:86`) is odd by design: each repeated keydown toggles
`app.prefixArmed` (arm → passthrough literal → arm …), so releasing can leave
the prefix armed depending on parity (`App.svelte:444-449, 461-486`). Backtick
has no accent variant, so this is the prefix state machine, not press-and-hold.
Cosmetic; call out here so it isn't re-investigated as part of #35.

## Fix (landed)

`cmd/rook/pressandhold_darwin.go` — a ~6-line CGO `init()` that registers an
app-level default before the webview builds its text-input context:

```objc
[[NSUserDefaults standardUserDefaults] registerDefaults:@{
    @"ApplePressAndHoldEnabled": @NO,
}];
```

This is the well-trodden Chromium/Electron/VS Code fix. It runs in `init()`,
before `application.New` / `app.Run` in `main.go`, so the value is in place
when WKWebView reads it.

Trade-offs of the chosen lever:

- **`registerDefaults` (registration domain)** — chosen. Non-persistent (nothing
  written to disk), process-wide (all panes repeat, which is what a terminal
  wants), and it still yields to a user who has *deliberately* set the global to
  YES. Fixes the common stock-Mac case.
- **`setBool:NO forKey:` on the application domain** — the alternative. Would
  force repeat even over an explicit global YES, but persists to rook's plist
  and removes the user's ability to opt back into the popover. Switch to this
  only if we decide rook should always win over an explicit global.
- **Pane-scoped (frontend) disable** — rejected. WKWebView gives no clean web
  API to turn off press-and-hold per element; you'd have to synthesise repeats
  from `keydown`, which is fragile and duplicates OS timing (`KeyRepeat` /
  `InitialKeyRepeat`). Global host-side is simpler and correct for a terminal.

Global (host-side) was chosen over pane-scoped because rook *is* a terminal:
repeat is the expected behaviour everywhere, not just in the shell pane.

## Verify (before / after)

```sh
# Force the buggy state (simulate a stock Mac), then relaunch rook:
defaults write -g ApplePressAndHoldEnabled -bool true
make dev
# BEFORE this fix: hold `a` in a shell → accent popover / single char.
#                  hold `j` → repeats. (the inconsistency)
# AFTER this fix:  hold `a` → repeats. hold `j` → repeats. All keys repeat.

# Restore your normal setting afterwards (or delete to return to OS default):
defaults delete -g ApplePressAndHoldEnabled    # or: -bool false
```

Build check used during the spike:

```sh
pnpm --dir frontend run build:dev   # produce frontend/dist for the go:embed
go build ./cmd/rook                 # cgo compiles + links (exit 0)
```
