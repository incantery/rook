# Developing rook using rook:
#   make install  — production .app into /Applications; the daily driver
#   make dev      — hot-reload dev instance in a fully isolated sandbox
#                   (its own XDG_STATE_HOME + XDG_CONFIG_HOME + XDG_DATA_HOME
#                   → own host daemon, sessions, config, and database; never
#                   touches the daily driver — see dev for why it matters)
#   make start    — quick foreground run of a production build
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

.PHONY: build start dev dev-web package install clean agent release e2e e2e-clean

build:
	wails3 task build

start: build
	./bin/rook

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
# On this branch (rook/zig), dev is the NATIVE experiment: build and run
# rookz, the Zig app in native/. The webview dev instance survives as
# dev-web for side-by-side comparisons (the latency A/B needs both).
dev:
	cd native && zig build && ./zig-out/bin/rookz win

dev-web:
	XDG_STATE_HOME=$(HOME)/.local/state/rook-dev \
	XDG_CONFIG_HOME=$(HOME)/.config/rook-dev \
	XDG_DATA_HOME=$(HOME)/.local/share/rook-dev \
	wails3 dev

package:
	@# The bundle task only adds files into an existing .app — a stale
	@# bundle keeps files the build no longer produces (e.g. Assets.car).
	rm -rf bin/rook.app
	wails3 task package BUILD=$(BUILD)

LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

install: package
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

# Browser-driven tests against the REAL app: Wails server mode runs rook as an
# HTTP server, so Playwright gets the actual Go services and a real host
# daemon — sandboxed in bin/e2e, never your daily driver. See docs/e2e.md.
#   make e2e                     — all specs
#   make e2e ARGS="--headed"     — watch it happen
#   make e2e ARGS=theme          — one file
e2e:
	cd frontend && pnpm exec playwright test $(ARGS)

# The sandbox daemon is setsid'd to outlive the app (same as the real one), so
# it survives the run by design. This is how you stop it.
e2e-clean:
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

clean: e2e-clean
	rm -rf bin frontend/dist

# Publish a release: make release VERSION=v0.1.0
# Builds arm64 on this machine (no CI), zips rook.app + rookctl, tags the
# current commit, and publishes via gh. Users install with install.sh
# (curl → no quarantine → no Gatekeeper prompt on our ad-hoc signature)
# and upgrade with `rookctl update`. rook-agent is not shipped yet — the
# drafter stays a from-source feature until it settles.
DIST := bin/dist
RELEASE_ZIP = rook-$(VERSION)-darwin-arm64.zip
VERSION_FLAG = -X github.com/incantery/rook/internal/version.Version=$(VERSION)

release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=v0.1.0"; exit 1; }
	@test -z "$$(git status --porcelain)" || { echo "working tree dirty — commit first (the tag must match the build)"; exit 1; }
	rm -rf bin/rook.app $(DIST)
	wails3 task package VERSION=$(VERSION) BUILD=$(BUILD)
	mkdir -p $(DIST)/stage
	cp -R bin/rook.app $(DIST)/stage/
	go build -tags production -trimpath -ldflags "-w -s $(VERSION_FLAG) $(BUILD_FLAG)" -o $(DIST)/stage/rookctl ./cmd/rookctl
	@# `re` is rookctl by another name (argv[0] dispatch → edit); ditto -c -k
	@# preserves the symlink through the zip
	ln -sf rookctl $(DIST)/stage/re
	@# ditto -c -k, not zip: preserves xattrs and the ad-hoc signature exactly
	ditto -c -k $(DIST)/stage $(DIST)/$(RELEASE_ZIP)
	cd $(DIST) && shasum -a 256 $(RELEASE_ZIP) > checksums.txt
	git tag -a $(VERSION) -m "rook $(VERSION)"
	git push origin main $(VERSION)
	gh release create $(VERSION) $(DIST)/$(RELEASE_ZIP) $(DIST)/checksums.txt --title "rook $(VERSION)" --generate-notes

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
