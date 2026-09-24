# Style

Rook's chrome — the two bars, the chip, the tabs, the seams — is a
stylesheet. There is one look everywhere, and rules over it that match
the workspace on the glass: home, a repository, a branch, a directory,
a name, the program in front. Everything a rule says is optional; what
it does not say, the rule before it decides.

```toml
[style]                          # everywhere, home included
chip = "round"
accent = "#89b4fa"

[[style.match]]                  # home: rook already has a rule for it,
home = true                      # this one comes later and wins
label = "{icon} HOME"

[[style.match]]
repo = "github.com/grafana/*"
accent = "#ff8833"
tint = "accent"
label = "{REPO}:{branch}"

[[style.match]]
branch = "release/*"
bar = "#3a1f24"
```

`rook style` explains it for the workspace you are in: the facts rook
sees, every rule with ✓ or ✗ and its conditions, and each computed
property with where it came from. `rook style --json` is the same for a
program. Save the file and it applies: rookd reloads the running
server (docs: README, "The config is live").

## The cascade

In order, a later one winning property by property:

1. **rook's own rules** (`style.builtin`): one, for home — its colour
   on the chip (`chip_bg = "accent"`), the chrome tinted toward it, and
   `⌂ home` at both edges. This is the only look rook brings.
2. **`[style]`**, everywhere.
3. **each `[[style.match]]` whose conditions all hold**, in file order.

`[home] color` is shorthand for a rule `home = true, accent = <it>`,
placed ahead of the file's rules. There is no specificity: order is
the whole story, as it reads.

## Matchers

Every condition a rule says must hold; one it does not say holds.
Globs: `*` is any run (across `/` too), `?` one character.

| key | the fact | for example |
|---|---|---|
| `home` | this is home | `true`, `false` |
| `workspace` | the workspace's name | `"rook--*"` |
| `dir` | the focused pane's directory; `~` is `$HOME` | `"~/work/*"` |
| `repo` | that directory's repository, as its origin remote's host/owner/name | `"github.com/grafana/*"` |
| `branch` | its checked-out branch (a detached HEAD is its short sha) | `"release/*"` |
| `program` | the focused pane's foreground program | `"nvim"` |
| `class` | a class on the workspace or any pane in it (below) | `"error"` |
| `state` | one of rook's own states of it (below) | `"working"` |

The repository is read from `.git` itself — worktrees included — when
the focused directory changes and every two seconds after, never by
running `git`. A directory outside any repository has none.

## Properties

**Colours** take a hex colour (`#rgb`, `#rrggbb`), an ANSI name
(`cyan`, `bright-black`), or a role by name, as it stands after the
colours said outright: `chip_bg = "accent"`.

| property | what it colours |
|---|---|
| `accent` | the one accent: focus, the selected tab's edge, the prompt; the focused seam unless `border_focused` says |
| `bar` | both bars' ground |
| `raised` | the selected tab, a chip, an overlay |
| `selection` | a selected row |
| `text` `subtext` `muted` | ink, strongest to weakest |
| `border` `border_focused` | seams, and the focused pane's |
| `attention` `working` `unread` `success` `error` | the states' inks |
| `chip_bg` `chip_fg` | the scope chip (raised and text unless said) |
| `tint`, `tint_amount` | pull `bar`, `raised`, `selection` and the seams toward a colour, 26% by default — the ones a rule did not set outright |

**Shape** — what a terminal can draw, in cells, with no row added and
no pane resized:

| property | values |
|---|---|
| `chip` | the scope chip's ends: `plain`, `bracket`, `powerline`, `round`, `slant` |
| `tabs` | the same, on the selected tab |
| `separator` | between the chip and the tabs, `│` by default; `""` for none |
| `fill` | what the bars' empty stretch is drawn with, e.g. `╌` or `▔` |

`powerline`, `round` and `slant` are Nerd Font glyphs; with `[mux]
glyphs = "ascii"` they draw as `bracket`.

**Words** are templates over the facts: `{name}` (the workspace, short
form), `{repo}` (the repository's last part), `{branch}`, `{dir}` (the
directory's last part), `{icon}`, and the same in capitals — `{NAME}`
— for the word upper-cased.

| property | where |
|---|---|
| `icon` | the `{icon}` token |
| `label` | the scope chip; `{name}` when unsaid |
| `bar_label` | the first thing on the calm bar, in the accent; nothing when unsaid |

## Classes: facts from outside

Rook has no idea what an error is, or a loop that will not stop, and
it should not. It lets anyone say so: a **class** is a name put on a
workspace or on a pane, and a rule matches it like any other fact.

```toml
[[style.match]]
class = "error"            # a glob: "err*" works too
bar = "#3a1f24"
bar_label = "! {name} is failing"

[[style.match]]
class = "loop"
tint = "red"
tint_amount = 40
```

From outside — a detector watching `rook watch`, a hook, a person:

```sh
rook class api +error              # on the workspace api
rook class api +loop --ttl 5m      # lapses on its own after five minutes
rook class 42 -error               # a pane, by id; -* takes them all off
rook class api                     # what is on it now
rook class +building               # inside rook: this pane
```

From inside a pane, by the program itself — no `rook` on PATH needed,
so it works over ssh too. It is the OSC 1337 `SetUserVar` convention
(WezTerm, iTerm2) with the name `rook_class` and the ops base64'd;
`ttl=30s` among the ops gives the ones after it a deadline:

```sh
printf '\e]1337;SetUserVar=rook_class=%s\a' "$(printf '+failing ttl=10m' | base64)"
```

A workspace **has** a class when it is on the workspace or on any pane
in it, so a build pane flagging itself colours its whole workspace
wherever the focus is. Classes are words — letters, digits, `- _ . :`,
31 at most, 16 to a set — and they are in the state feed
(`workspaces[].classes`, `panes[].classes`, each with `until`, the
epoch ms it lapses at or 0) and in `rook style`'s facts. They are not
saved: a restart starts without them, and whatever put them there says
them again.

**Rook's own states** are matched the same way, with `state`: facts
rook already has about a workspace, offered to the stylesheet with no
opinion about them.

| `state =` | when |
|---|---|
| `unread` | a pane in it has output nobody has seen |
| `working` | an agent in it is producing |
| `zoomed` | its current window is zoomed |
| `copy` | copy mode is up |
| `popup` | a popup is over it |

## What a rule cannot do, and why

A rule changes colour, glyphs and words — never geometry. The frame
around the work, a rail down its side, a taller bar: those take cells,
and a look that changed with a fact would resize every program running
in the workspace as the fact changed, the one thing rook must never
cause. They arrive as their own properties, resolved from static
facts only (docs, next).
