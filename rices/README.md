# Rices

Stylesheets to include from `rook.toml` — copy one, or point at it:

```toml
include = ["~/src/rook/rices/4-left-rail.toml", "~/.config/rook/rices/*.toml"]
```

`include` goes at the top of the file, above every `[table]`. A rice
holds `[style]`, `[[style.match]]`, `[[style.tab]]` and its own
`include`, nothing else:
it can recolour and reshape the chrome, never bind a key, float a
program or seed home, so one from anywhere is safe to try. Its rules
come before your file's, in the order included — your own file always
has the last word. Save a rice and rookd reloads it like `rook.toml`.
`rook style` names the file every rule came from.

| file | what it does |
|---|---|
| `1-prominent-home.toml` | home says `⌂ HOME` at both edges |
| `2-bracketed-tabs.toml` | powerline caps on the chip and the selected tab |
| `3-double-bar.toml` | a rule under home's tab bar and over its calm bar |
| `4-left-rail.toml` | a column of home's colour down the left |
| `5-corner-brackets.toml` | home's work marked at its four corners |
| `6-patterned-bar.toml` | home's bars fill their empty stretch with `╌` |
| `7-filled-header.toml` | home's tab bar a row and a half tall |
| `8-segmented-bar.toml` | slanted segments everywhere, home in blue |
| `9-minimal-separators.toml` | a heavier separator after a bracketed chip |
| `repo-colours.toml` | an accent and a `{repo}:{branch}` chip per repository; release branches framed |
| `tabs.toml` | each tab its own colour, by name, program or class |
| `signals.toml` | looks for `error` and `loop` classes, and the `working` state |

The caps in 2 and 8 are Nerd Font glyphs; on `glyphs = "ascii"` they
draw as brackets. Every file here is loaded by the test suite
(`TestShippedRicesLoad`), so none of them rots. The whole vocabulary is
`docs/style.md`.
