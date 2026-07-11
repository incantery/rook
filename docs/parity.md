# Parity backlog

The MVP spec, per the README: the ghostty and tmux configs actually in daily
use, nothing more. Sources: `~/.config/ghostty/config`, `~/.tmux.conf`
(audited 2026-07-11). Checked = matched in rook.

## From the ghostty config

- [x] Font: Hack Nerd Font Mono, size 18
- [x] Theme: Material Ocean
- [x] Window padding: 4px
- [x] Hidden titlebar (traffic lights over content, top strip drags)
- [x] `background-opacity = 0.95` — plain alpha, no blur
- [ ] `shell-integration = none` — deliberately disabled in ghostty. Rook's
      OSC 133 plan (README decision 4) means rook must ship its own
      integration rather than assume the shell has one; nothing in daily
      muscle memory depends on prompt marks today.

## From the tmux config

Keybindings (all behind `` ` `` prefix — the leader key itself is muscle
memory):

- [ ] `` ` `` as prefix/leader for rook's command keybindings
- [ ] `c` — new tab/window, **inheriting current pane's cwd**
- [ ] `"` — split down, inheriting cwd
- [ ] `v` — split right, inheriting cwd
- [ ] `n` — rename tab (prompt)
- [ ] `r` — reload config equivalent (rook: reload keybindings/theme?)

Copy mode:

- [ ] vi keys; `v` begins selection, `y` yanks
- [ ] mouse drag selects **without leaving copy mode / scroll position**
- [ ] mouse on generally (scroll, click-through to apps that grab mouse)

Chrome:

- [ ] Tab bar at **top**, centered, minimal: bare window indexes, 1-based,
      dim inactive / white active, transparent background
- [ ] Windows numbered from 1

Cross-cutting (the big one):

- [ ] `vim-tmux-navigator`: `C-h/j/k/l` moves between panes *and* vim splits
      seamlessly. Rook's equivalent needs the same trick — know when the
      focused pane is vim and forward the key instead of switching panes.
      This is the deepest muscle-memory item in either config.

## Not in the configs (doesn't exist for MVP)

Remote/ssh session management, ghostty tabs (tmux owns multiplexing today),
themes beyond Material Ocean, blur, ligatures.
