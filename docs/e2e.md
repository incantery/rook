# End-to-end tests

`make e2e` drives the real rook in a headless browser. Not a mock, not the
frontend on its own: the actual Go services, the actual generated bindings,
the actual production bundle, and a real `rook-host` daemon.

```
make e2e                    # everything
make e2e ARGS="--headed"    # watch it happen in a real browser window
make e2e ARGS=theme         # one spec file
make e2e-clean              # stop the sandbox daemon, drop bin/e2e
```

## How it works

Wails v3 has a **server mode**: building with `-tags server` compiles the same
`cmd/rook` — same services, same bindings, same embedded `frontend/dist` — into
a plain HTTP server instead of a native window. The Wails JS runtime already
speaks plain `fetch` (`POST /wails/runtime`, see `@wailsio/runtime`'s
`runtime.js`), so a browser pointed at that server gets working bindings.
`Config.Get()` returns your real config struct; `Host.Info()` spawns and
discovers a real daemon.

`frontend/e2e/serve.sh` builds that binary plus `rook-host`, and runs them
against a **sandboxed XDG triple** in `bin/e2e` — its own daemon, sessions,
config, and database. It never touches the daily driver or `make dev`. The
`boot.spec.ts` assertion that mission control shows *"No workspaces yet"* is
the sandbox's canary: if it ever fails, the tests found your real database.

Playwright's `webServer` runs `serve.sh` automatically, so `make e2e` is the
only command you need.

### The fast loop

`webServer` has `reuseExistingServer`, so if a sandbox is already up on the
port, the test run skips the ~20s bundle+Go rebuild and attaches to it:

```sh
./frontend/e2e/serve.sh          # leave running in another terminal
make e2e                         # now ~3s
```

Just remember it serves the **embedded** bundle: after a frontend change,
restart `serve.sh` or the tests run the old markup.

## What this does and doesn't cover

It covers everything downstream of the DOM: boot, real service calls, keybinds,
the command palette, chrome rendering, theming, and the host daemon round trip.
The theme specs are the worked example — they assert what a unit test can't
reach (the palette really lands on `:root`, the picker rewrites it live with no
reload, the choice survives a restart through `config.Service`).

It does **not** cover the native shell, because there isn't one: no `WKWebView`,
no window chrome, no traffic lights, no `MacBackdropTransparent` translucency,
no `--wails-draggable`. Chromium is not WKWebView either — this is the wrong
tool for a WebKit-specific rendering bug. Those still need `make dev` and your
eyes.

Keep the tiers honest: **vitest** (`src/**/*.spec.ts`) owns pure view-model
units and stays the default; e2e is the slow tier, for things that only exist
once the whole app is running. Specs in `frontend/e2e/` sit outside `tsconfig`'s
`include`, so Playwright transpiles them but `svelte-check` doesn't type-check
them — deliberate, so `svelte-check` doesn't need node types.

## Writing specs

Prefer the ids the app already carries (`#home`, `#settings`, `#theme-select`)
and real user paths over internals. Note that the home screen gates chords down
to the two commands that work without a terminal (`App.svelte` `onKeydown`), so
`cmd+,` won't open Settings from mission control — the palette (`cmd+k`) is the
route that works.
