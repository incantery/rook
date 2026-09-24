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
| `tab_fill` | `all`: every tab a filled segment with `tabs`' caps — the selected lifted toward the accent, the others sunk toward the bar, a coloured tab in its colour dimmed; `selected` (rook's): only the selected one |

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

## Tabs, one by one

`[[style.tab]]` rules style individual tabs. Each asks about the tab —
its `name` (a glob), its `index` (from 1), and `program`, `class` and
`state` as the tab's own: the focused pane's program, the classes on its
panes, whether it is unread or an agent in it is producing — and about
the workspace (`home`, `workspace`, `dir`, `repo`, `branch`) the same way
`[[style.match]]` does. Rules apply in order, a later one winning
property by property, like everywhere here.

```toml
[[style.tab]]
home = true
name = "docker*"
color = "#89b4fa"

[[style.tab]]
program = "mongo*"
color = "green"
icon = ""
label = "{icon} {name}"          # {name} {index} {icon} {program}, and the workspace's

[[style.tab]]
class = "error"                  # a failing build in any tab turns it red
color = "#f38ba8"
```

| property | what it does |
|---|---|
| `color` | fills the tab when it is the selected one; toned down toward the bar, it inks the tab when it is not |
| `color_inactive` | the unselected ink outright |
| `text` | the selected tab's text; light or dark by the fill when unsaid |
| `icon`, `label` | the `{icon}` token and the tab's words |

A tab with a colour of its own drops the accent edge — its fill is the
edge — and keeps `tabs`' caps in its colour. Tab rules are colour and
words only, so any condition may set them; rices carry them too, and
`rook style` lists each tab with the rules that held for it.

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

## Rices: stylesheets to share

A stylesheet can live in a file of its own and be included:

```toml
include = ["~/.config/rook/rices/*.toml", "grafana.toml"]   # at the top
```

Paths are relative to the file that includes them; `~` and globs work
(a glob matching nothing is fine, a plain path that is not there is
not). A rice holds `[style]`, `[[style.match]]` and an `include` of its
own — anything else refuses to load, so a rice cannot bind a key, float
a program or seed home, and one from anywhere is safe to try. Includes
nest, eight deep, and a cycle is refused.

The order is the whole story, as everywhere here: every rice's
`[style]` and rules come first, depth first in the order included,
then `rook.toml`'s own — your file has the last word. rookd watches
the rices as it watches `rook.toml`: save one and it applies, or the
calm bar says why not. `rook style` names the file each rule came from
(`config:3  … (~/.config/rook/rices/grafana.toml #2)`).

The repository's `rices/` holds your nine sketches from the design
round and two more — per-repo colours, and looks for an error/loop
detector's classes — each loaded by the test suite.

## Geometry: what takes cells

Four properties shape the chrome rather than colour it. They take
cells from the work — the panes are laid out inside what they leave —
so they are held to one rule of their own.

| property | values | takes |
|---|---|---|
| `frame` | `none`, `rail` (a column down the left), `corners` (the four corners marked), `box` (a line all round) | rail 1 column; corners 2 columns; box 2 columns and 2 rows |
| `frame_color` | a colour, like the others; the accent when unsaid | nothing |
| `header_rule` | one character, drawn the width of the work under the tab bar: `▔` a double bar, `▀` in `frame_color = "bar"` a taller header | a row |
| `footer_rule` | the same over the calm bar: `▁`, `━`, `╌` | a row |
| `bar_height` | the tab bar's rows: `2` puts a half-block row under the tabs (segments a row and a half tall), `3` one above and one below with the words centred (two rows tall); caps follow in quarter blocks | 1 or 2 rows |

```toml
[[style.match]]
home = true
frame = "rail"                  # sketch 4

[[style.match]]
repo = "github.com/grafana/*"
frame = "corners"               # sketch 5
header_rule = "▔"               # sketch 3

[[style.match]]
class = "error"
frame_color = "red"             # a colour may follow a class
```

**Only a rule that cannot flicker may set `frame`, `header_rule`,
`footer_rule` or `bar_height`**: one on `home`, `workspace`, `dir`, `repo` or `branch`.
A rule that asks about `program`, `class` or `state` may not — a frame
that came and went with a flickering fact would resize every program in
the workspace each time it did, the one motion rook must never cause.
`rook config check` refuses such a rule and says why, and the engine
ignores the property if one arrives anyway. `frame_color` takes no
cells, so anything may colour the frame: an error class can turn a
repository's box red without moving a pane.

The static facts can still change at a person's pace — a `cd` into
another repository, a branch checked out — and then the workspace is
laid out again, once, at that moment. Too small a glass (under 10
columns or 3 rows of work) keeps its cells and draws no frame.
