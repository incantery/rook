# Home

You are either home or at work. Home is one workspace outside the
list of spaces, a key away from any of them. It is not a dashboard:
it is a workspace like any other — panes, windows, splits — that rook
seeds from the config and keeps out of the way of the spaces. What is
in it is yours to say. With nothing said, it is one shell in `~`: a
scratch pad to check something in and close.

This replaced the root (`docs/altitude.md` at `8a9daf9`), a canvas
rook drew itself — a navigator, an inspector, an ask door, orbit. Every
round on that was rook guessing what you wanted to see. A home that is
a workspace makes that question the config's.

## The model

| | what it is | lives in |
|---|---|---|
| home | a `Session` with `home = true`; at most one | `Server.ensureHome`, `Server.homeIndex` |
| its seed | `[home]`: windows, each a name, a dir and panes; each pane a command, a dir and a split | `config.Home`, `config.parseHome` |
| the way there | the `home` verb, `o` by default: home from a space, back from home | `Server.toggleHome` |
| the way back | `home_back`, the space home was gone to from; else `last_sess`; else any space | `Server.awayFromHome` |

- **Plain `rook` lands at home**, seeded fresh at boot; the spaces are
  restored underneath it and the one the server was showing is where
  the home key goes back to. `startup = "last-space"` lands in that
  space instead, and home is not made until it is gone to. `rook home`
  and `rook attach --root` say home outright.
- **The home key toggles.** From a space it goes home, made if it is
  not there; from home it goes back to the space it was gone to from.
  Leaving home for another space (`rook switch`, the picker) makes the
  one it came from the space before, so C-o still works as a hop
  between spaces — C-o never lands on home.
- **Closing its last pane goes back** to that space, and home is gone
  until it is gone to again, when it is seeded fresh.
  `[home] on_empty = "stay"` seeds it again in place instead. With no
  other space to go back to it is seeded again either way: the server
  does not end because the scratch pad was cleared.
- **It is never saved.** The restore file holds the spaces; when home
  is the one showing, the star goes on the space it goes back to.
- **It is out of every list of spaces:** `rook ls`, the picker, the
  rail, name lookups (a space you name `home` is a space). The state
  feed lists it among `workspaces` with `"home": true` and says
  `"scope": "home"` while it is showing; `mux.Current()` reports no
  space from home.
- **It looks like another room.** The chrome wears home's colour —
  `[home] color`, a hex colour or an ANSI name, the accent when unset
  (`ui.Theme.home`): both bars stand on a ground pulled toward it, the
  seams and the focused edge are in it, and it is the accent while
  home is showing. The chip reads `⌂ home` in its fill, the calm bar
  leads with `⌂ home`, and the corner names where the home key goes:
  `` `o main `` at home, `` `o home `` in a space. Only colour changes:
  no row appears and no pane is resized on the way in or out. The
  panes keep the terminal's own background — rook does not know it,
  so it does not paint over it.

## The seed

```toml
[home]
on_empty = "return"   # or "stay"
color = "cyan"        # its accent and its chrome's tint; the accent unset
dir = "~"             # where its panes start unless they say

[[home.window]]
name = "me"
dir = "~/work"
panes = ["docket", ""]            # short form: side by side; "" is a shell

[[home.window]]
name = "notes"
dir = "~/notes"
[[home.window.pane]]
command = "nvim scratch.md"
[[home.window.pane]]
dir = "archive"                   # relative to $HOME, like every dir here
split = "down"                    # under the pane before it; "right" is the default
```

A pane's dir is its own, else its window's, else home's, else `~`;
`~`, `~/x` and a relative path are under `$HOME`. A pane's command is
typed into a login shell once its prompt is up (the boot restored
panes use), so a program that quits leaves the shell and does not
close the pane — or home with it. Up to eight windows of eight panes.
The Go loader refuses an `on_empty` or `split` it does not know, and a
key it has not heard of.

## Tests

`scripts/home-fixture.py` drives a sandboxed engine through a real
glass and asserts on it and on the feed: landing, the toggle, C-o,
returning on close and seeding fresh, `stay`, a seeded layout with its
commands and dirs, home alone, `last-space`, the restore file, and the
prefix table. `mux/src/config.zig` tests the parser.
