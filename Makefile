# Developing rook using rook:
#   make install  — production .app into /Applications; the daily driver
#   make dev      — hot-reload dev instance in a fully isolated sandbox
#                   (its own XDG_STATE_HOME + XDG_CONFIG_HOME + XDG_DATA_HOME
#                   → own host daemon, sessions, config, and database; never
#                   touches the daily driver — see dev for why it matters)
#   make prod     — the same sandbox at ReleaseFast; the binary the
#                   scoreboard measures (app/PERF.md)
#   make build    — compile the app without running it: the "does it still
#                   build" check, and what CI runs
#
# The retired webview app keeps the -web suffix — build-web, dev-web,
# package-web, install-web, e2e-web. Nothing in the shipped app depends
# on it; it is the way back, not a live surface.
# Promote: make install, then quit+relaunch the installed app. Every
# install gets a fresh BUILD id stamped into ALL binaries, and the app
# replaces a daemon whose build differs — so relaunch is guaranteed to
# run the latest everything, at the cost of that daemon's shells (the
# tmux server-upgrade reality; rook-agent respawns via mtime, no cost).

APP := /Applications/rook.app

# One build identity per make run, stamped into every binary it produces.
# Host↔client compatibility is equality of this id — see internal/version.
BUILD := $(shell git rev-parse --short HEAD 2>/dev/null || echo nogit).$(shell date +%Y%m%d%H%M%S)
BUILD_FLAG := -X github.com/incantery/rook/internal/version.Build=$(BUILD)

.PHONY: build build-web dev prod dev-web package-web install install-web clean agent release release-stage e2e-web e2e-clean-web

# Compile only, and deliberately so: there is no run target that skips
# DEV_ENV, because an instance on the default socket unlinks-then-binds
# and would steal /tmp/rook.sock out from under the installed app (see
# dev). Want to run it? make dev, make prod, or make install.
build:
	cd app && zig build

# The retired webview app. The only target left that needs the wails3
# CLI — `make install` has not since the cutover.
build-web:
	wails3 task build

# Isolated sandbox. The dev instance gets its own state (host daemon +
# sessions), config, and data (database + worktrees) dirs, so it never rides
# the daily driver's daemon or writes its records.
# That mattered: the host is one-client-per-session — when a shared-daemon
# dev instance background-attached the daily driver's sessions, its attach
# EVICTED the daily driver's (host closes the old socket "replaced"), and
# the frontend doesn't reconnect a replaced session — freezing the pane you
# launched from until you opened a new window. Own daemon = no contact.
# Config is sandboxed too, so re-enter Jira/OpenAI keys in the dev instance;
# writes stay in rook-dev and never clobber your real ~/.config/rook.
# XDG_DATA_HOME sandboxes DataDir (internal/host: registry.go rook.db +
# worktree.go checkouts) — else dev shares the daily driver's rook.db, so
# its workspaces, verdict ledger, threads, and cost totals would pollute the
# real ones, and worktrees would land in the shared tree.
# dev builds and runs the Zig app in app/ — which IS rook now. The
# webview dev instance survives as dev-web for side-by-side comparisons
# (the latency A/B needs both).
#
# dev  = Debug: fast compiles, slow binary (ghostty-vt parses ~100x
#        slower — fine for typing, do NOT judge firehose/cat here).
# prod = ReleaseFast: the binary the scoreboard measures (app/PERF.md,
#        same mode bench.sh builds). Zig caches per optimize mode, so
#        alternating dev/prod doesn't rebuild ghostty-vt each time.
# Both use their own ctl socket: the server unlinks-then-binds, so a
# second default-socket instance would STEAL the installed app's
# /tmp/rook.sock out from under it. They also get their own XDG_STATE_HOME,
# so the daemon a dev instance spawns — and kills on quit — is never the
# installed app's.
DEV_ENV = ROOK_SOCK=/tmp/rook-dev.sock XDG_STATE_HOME=$(HOME)/.local/state/rook-dev
dev:
	cd app && zig build && $(DEV_ENV) ./zig-out/bin/rook win

prod:
	cd app && zig build -Doptimize=ReleaseFast && $(DEV_ENV) ./zig-out/bin/rook win

# The daily driver: the ZIG app as /Applications/rook.app. ReleaseFast,
# minimal hand-rolled bundle, ad-hoc signed, ctl socket on the default
# /tmp/rook.sock (the agent-visibility surface rides along on purpose).
#
# It REPLACES the wails app at the same path, by design — `make
# install-web` puts that one back, and is the escape hatch if this one
# misbehaves. The two Go binaries ship INSIDE the bundle because that is
# how they are found: the app resolves rook-host and rookctl beside its
# own executable first (hostc.siblingBinary), so a bundle without them
# is an app that cannot start a daemon or answer a CLI verb.
#
# TWO version strings, because they answer different questions.
#
# REL_VERSION is the newest tag, dotted: Info.plist's CFBundleVersion has
# to be a number, so this is always one.
#
# VERSION_STAMP is what `rookctl update` compares, and it is the exact
# tag ONLY when this tree is clean and sitting on one. Anything else —
# ahead of the tag, or dirty — stamps "dev", which is the string that
# makes `rookctl update` refuse rather than "upgrade" a source build
# backwards into the last release. NewerThan is string inequality, so a
# `git describe` suffix like v0.38.1-3-gabc would read as "not the
# latest" and roll the daily driver back; "dev" is the guard.
REL_VERSION := $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)
VERSION_STAMP := $(shell test -z "$$(git status --porcelain)" && git describe --tags --exact-match 2>/dev/null || echo dev)
STAMP_FLAGS = $(BUILD_FLAG) -X github.com/incantery/rook/internal/version.Version=$(VERSION_STAMP)
install:
	cd app && zig build -Doptimize=ReleaseFast -Dbuild=$(BUILD) -Dversion=$(REL_VERSION)
	go build -ldflags "$(STAMP_FLAGS)" -o app/zig-out/bin/rook-host ./cmd/rook-host
	go build -ldflags "$(STAMP_FLAGS)" -o app/zig-out/bin/rookctl ./cmd/rookctl
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	sed 's/__VERSION__/$(REL_VERSION)/g' app/bundle/Info.plist > $(APP)/Contents/Info.plist
	cp app/zig-out/bin/rook $(APP)/Contents/MacOS/rook
	cp app/zig-out/bin/rook-host $(APP)/Contents/MacOS/rook-host
	cp app/zig-out/bin/rookctl $(APP)/Contents/MacOS/rookctl
	codesign -s - --force $(APP)
	$(LSREGISTER) -f $(APP)
	mdimport $(APP)
	@# The CLI face of the same binary. ~/.local/bin is on PATH; symlinks
	@# keep the CLI in lockstep with the installed app.
	mkdir -p $(HOME)/.local/bin
	ln -sf $(APP)/Contents/MacOS/rook $(HOME)/.local/bin/rook
	@# `re` = rook edit (argv[0] dispatch). CLAIMED from rookctl, which
	@# used the same trick — the zig editor is the editor now.
	ln -sf $(APP)/Contents/MacOS/rook $(HOME)/.local/bin/re
	@# rookctl stays on PATH under its own name too: claude-plugin invokes
	@# `rookctl mcp` and `rookctl claim` BY NAME, and an installed plugin
	@# breaking mid-session is not an acceptable cutover cost. It goes
	@# when the plugin has moved to `rook`.
	@# A COPY, not a symlink: selfupdate.Apply EvalSymlinks's the running
	@# rookctl and writes over what it resolves to, so a link into the
	@# bundle would make `rookctl update` rewrite a sealed binary and
	@# invalidate the app's signature.
	install -m 0755 app/zig-out/bin/rookctl $(HOME)/.local/bin/rookctl
	@echo "installed $(APP) (v$(REL_VERSION), build $(BUILD)) + ~/.local/bin/{rook,re,rookctl}"
	@echo "quit + relaunch rook to pick it up"

dev-web:
	XDG_STATE_HOME=$(HOME)/.local/state/rook-dev \
	XDG_CONFIG_HOME=$(HOME)/.config/rook-dev \
	XDG_DATA_HOME=$(HOME)/.local/share/rook-dev \
	wails3 dev

package-web:
	@# The bundle task only adds files into an existing .app — a stale
	@# bundle keeps files the build no longer produces (e.g. Assets.car).
	rm -rf bin/rook.app
	wails3 task package BUILD=$(BUILD)

LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

install-web: package-web
	rm -rf $(APP)
	cp -R bin/rook.app $(APP)
	@# A bare cp skips the registration Finder/installers do — without this,
	@# Spotlight won't offer the app.
	$(LSREGISTER) -f $(APP)
	mdimport $(APP)
	@# The CLI (tmux's scripting surface): rookctl ls / agents, plus the
	@# claim hooks claude runs. Lives on PATH, not in the bundle.
	go build -ldflags "$(BUILD_FLAG)" -o $(shell go env GOPATH)/bin/rookctl ./cmd/rookctl
	go build -ldflags "$(BUILD_FLAG)" -o $(shell go env GOPATH)/bin/rook-agent ./cmd/rook-agent
	@echo "installed $(APP) + rookctl + rook-agent (build $(BUILD))"
	@echo "quit + relaunch rook to pick it up — the relaunch replaces the daemon (shells die with it)"

# The drafter's dev loop: rebuild, and the running host's supervisor
# notices the new mtime and respawns rook-agent — no daemon replacement,
# no shell deaths. Deliberately NOT bundled into the .app: next-to-binary
# would shadow this loop.
agent:
	go build -ldflags "$(BUILD_FLAG)" -o $(shell go env GOPATH)/bin/rook-agent ./cmd/rook-agent

# Browser-driven tests against the RETIRED app: Wails server mode runs it as
# an HTTP server, so Playwright gets the actual Go services and a real host
# daemon — sandboxed in bin/e2e, never your daily driver. See docs/e2e.md.
#   make e2e-web                     — all specs
#   make e2e-web ARGS="--headed"     — watch it happen
#   make e2e-web ARGS=theme          — one file
#
# There is no `make e2e` any more, and that is a real gap rather than a
# rename: this was how an agent could SEE rook and verify its own UI work
# instead of asking. The Zig app has no equivalent loop yet — app/PARITY.md.
e2e-web:
	cd frontend && pnpm exec playwright test $(ARGS)

# The sandbox daemon is setsid'd to outlive the app (same as the real one), so
# it survives the run by design. This is how you stop it.
e2e-clean-web:
	-pkill -f 'bin/e2e/rook-host'
	rm -rf bin/e2e

# libghostty-vt for the `ghostty` build tag (benchmarks + differential
# fuzzing — see internal/host/ghostty_term.go). Requires zig (brew install
# zig). The normal build never needs this.
#   make ghostty-lib
#   go test -tags ghostty ./internal/host/ -run Ghostty
#   go test -tags ghostty ./internal/host/ -bench 'Pipe|WriteOnly|RenderSnapshot' -run xxx
GHOSTTY_SRC ?= $(HOME)/go/src/github.com/ghostty-org/ghostty
ghostty-lib:
	@test -d $(GHOSTTY_SRC) || git clone --depth 1 https://github.com/ghostty-org/ghostty.git $(GHOSTTY_SRC)
	cd $(GHOSTTY_SRC) && zig build -Demit-lib-vt=true -Doptimize=ReleaseFast
	rm -rf bin/ghostty-vt && mkdir -p bin/ghostty-vt/lib
	cp -R $(GHOSTTY_SRC)/zig-out/include bin/ghostty-vt/
	cp $(GHOSTTY_SRC)/zig-out/lib/libghostty-vt.a bin/ghostty-vt/lib/

clean: e2e-clean-web
	rm -rf bin frontend/dist app/zig-out app/.zig-cache

# Publish a release: make release VERSION=v0.1.0
# Builds arm64 on this machine (no CI), zips rook.app + rookctl, tags the
# current commit, and publishes via gh. Users install with install.sh
# (curl → no quarantine → no Gatekeeper prompt on our ad-hoc signature)
# and upgrade with `rookctl update`. rook-agent is not shipped yet — the
# drafter stays a from-source feature until it settles.
#
# The bundle is the ZIG app: `rook` plus the two Go binaries it resolves
# beside its own executable (hostc.siblingBinary), assembled here rather
# than by wails3. The zip's SHAPE is unchanged — rook.app + a rookctl at
# the top level — because install.sh and internal/selfupdate both read
# it, and keeping their contract is what let the app underneath change
# without touching the upgrade path.
DIST := bin/dist
RELEASE_ZIP = rook-$(VERSION)-darwin-arm64.zip
VERSION_FLAG = -X github.com/incantery/rook/internal/version.Version=$(VERSION)
STAGE = $(DIST)/stage
STAGED_APP = $(STAGE)/rook.app
GO_RELEASE = go build -tags production -trimpath -ldflags "-w -s $(VERSION_FLAG) $(BUILD_FLAG)"

release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=v0.1.0"; exit 1; }
	@test -z "$$(git status --porcelain)" || { echo "working tree dirty — commit first (the tag must match the build)"; exit 1; }
	$(MAKE) release-stage VERSION=$(VERSION)
	git tag -a $(VERSION) -m "rook $(VERSION)"
	git push origin main $(VERSION)
	gh release create $(VERSION) $(DIST)/$(RELEASE_ZIP) $(DIST)/checksums.txt --title "rook $(VERSION)" --generate-notes

# Everything up to the zip, with nothing irreversible in it — so the
# packaging can be exercised without tagging or publishing:
#   make release-stage VERSION=v0.38.0 && ditto -x -k bin/dist/*.zip /tmp/x
release-stage:
	@test -n "$(VERSION)" || { echo "usage: make release-stage VERSION=v0.1.0"; exit 1; }
	rm -rf bin/rook.app $(DIST)
	@# The app. -Dversion drops the leading v: CFBundleShortVersionString
	@# has to be a dotted number, and XTVERSION reports it too.
	cd app && zig build -Doptimize=ReleaseFast -Dbuild=$(BUILD) -Dversion=$(VERSION:v%=%)
	$(GO_RELEASE) -o app/zig-out/bin/rook-host ./cmd/rook-host
	$(GO_RELEASE) -o app/zig-out/bin/rookctl ./cmd/rookctl
	mkdir -p $(STAGED_APP)/Contents/MacOS
	sed 's/__VERSION__/$(VERSION:v%=%)/g' app/bundle/Info.plist > $(STAGED_APP)/Contents/Info.plist
	cp app/zig-out/bin/rook $(STAGED_APP)/Contents/MacOS/rook
	cp app/zig-out/bin/rook-host $(STAGED_APP)/Contents/MacOS/rook-host
	cp app/zig-out/bin/rookctl $(STAGED_APP)/Contents/MacOS/rookctl
	@# Sign the BUNDLE last — the seal covers the nested binaries, so
	@# anything that rewrites one afterwards invalidates it.
	codesign -s - --force $(STAGED_APP)
	@# rookctl at the top level is what install.sh copies to the user's
	@# PATH and what selfupdate swaps the running one with. Same build,
	@# a second copy on purpose: the bundle's is sealed.
	cp app/zig-out/bin/rookctl $(STAGE)/rookctl
	@# No `re` symlink here any more — `re` is `rook edit` now, and
	@# install.sh points it at the app binary inside the bundle.
	@# ditto -c -k, not zip: preserves xattrs and the ad-hoc signature exactly
	ditto -c -k $(STAGE) $(DIST)/$(RELEASE_ZIP)
	cd $(DIST) && shasum -a 256 $(RELEASE_ZIP) > checksums.txt
	@# No backticks in this message: the shell would run what is in them.
	@echo "staged $(DIST)/$(RELEASE_ZIP) — 'make release VERSION=$(VERSION)' tags and publishes"

# Regenerate the copied edge protocol (proto/rook/edge/v1 — rook-cloud
# is the source of truth; re-copy its proto first when the contract
# changes). Plugins are installed at the exact versions go.mod declares,
# so generated code and runtime library cannot drift; the gen/ tree is
# committed and this target is only needed when proto/ changes.
.PHONY: proto
proto:
	go install google.golang.org/protobuf/cmd/protoc-gen-go@$$(go list -m -f '{{.Version}}' google.golang.org/protobuf)
	go install connectrpc.com/connect/cmd/protoc-gen-connect-go@$$(go list -m -f '{{.Version}}' connectrpc.com/connect)
	buf lint
	buf generate
