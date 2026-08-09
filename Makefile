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
# tmux server-upgrade reality).

APP := /Applications/rook.app

# One build identity per make run, stamped into the app.
BUILD := $(shell git rev-parse --short HEAD 2>/dev/null || echo nogit).$(shell date +%Y%m%d%H%M%S)

# Providers: separate processes rook spawns to reach one external system
# each (sdk/provider). DISCOVERED, not listed — one directory under
# providers/ is one provider, so adding one is never an edit to core's
# build. The deliberate, reviewed act is a USER declaring a provider in
# their config and granting it what it asks for; a name in this file
# would only mean somebody could compile it.
# Keyed on main.go, not on "is a directory": providers/ also holds
# doc.go and boundary_test.go (the import-boundary guard), and macOS
# ships GNU Make 3.81, whose $(wildcard providers/*/) IGNORES the
# trailing slash and matches those files too.
PROVIDER_DIRS := $(patsubst %/main.go,%,$(wildcard providers/*/main.go))

# First-party plugins (plugins/*): separate processes speaking the plugin
# protocol of rook-plugin(7), discovered the same way providers are. They
# ship inside the bundle at Contents/MacOS/rook-plugin-<name>, so a config
# declares them by that stable path and they upgrade with the app.
PLUGIN_DIRS := $(patsubst %/main.go,%,$(wildcard plugins/*/main.go))

.PHONY: build dev prod install clean release release-stage e2e e2e-clean providers plugins

# Compile only, and deliberately so: there is no run target that skips
# DEV_ENV, because an instance on the default socket unlinks-then-binds
# and would steal /tmp/rook.sock out from under the installed app (see
# dev). Want to run it? make dev, make prod, or make install.
build:
	cd app && zig build

# Isolated sandbox. The dev instance gets its own state (host daemon +
# sessions), config, and data (database + worktrees) dirs, so it never rides
# the daily driver's daemon or writes its records.
# That mattered: the host is one-client-per-session — when a shared-daemon
# dev instance background-attached the daily driver's sessions, its attach
# EVICTED the daily driver's (host closes the old socket "replaced"), and
# the frontend doesn't reconnect a replaced session — freezing the pane you
# launched from until you opened a new window. Own daemon = no contact.
# Config is sandboxed too, so re-enter Linear/OpenAI keys in the dev instance;
# writes stay in rook-dev and never clobber your real ~/.config/rook.
# XDG_DATA_HOME sandboxes DataDir (internal/host: registry.go rook.db +
# worktree.go checkouts) — else dev shares the daily driver's rook.db, so
# its workspaces, verdict ledger, threads, and cost totals would pollute the
# real ones, and worktrees would land in the shared tree.
# dev builds and runs the Zig app in app/ — which IS rook.
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

# The providers rook SHIPS — the "official tier". They are built exactly
# the way a stranger's would be (sdk/provider and the standard library;
# sdk/provider's boundary test fails the build if one reaches outside the
# SDK), and they land beside the app because that is where
# provider.Client.resolve looks first — shipped providers upgrade with
# rook, so a stale copy elsewhere must never win. Everyone else's go to
# provider.InstallDir().
#
# Providers and plugins are the only Go this repo still builds. Core is Zig.
# sdk/rook/cmds.go is generated from the app's command registry, so the
# SDK's typed Cmd constants cannot drift from what the app dispatches.
# CI check: make gen-cmds && git diff --exit-code sdk/rook/cmds.go
gen-cmds:
	scripts/gen-cmds.sh

providers:
	@for d in $(PROVIDER_DIRS); do \
	  echo "  provider $$(basename $$d)"; \
	  go build -o app/zig-out/bin/rook-provider-$$(basename $$d) ./$$d || exit 1; \
	done

# A plugin with its own go.mod (plugins/link, which carries rook-host
# and a QR dependency the stdlib-only root module refuses) builds from
# inside its directory; the rest build from the root as always.
plugins:
	@for d in $(PLUGIN_DIRS); do \
	  echo "  plugin $$(basename $$d)"; \
	  if [ -f $$d/go.mod ]; then \
	    (cd $$d && go build -o $(CURDIR)/app/zig-out/bin/rook-plugin-$$(basename $$d) .) || exit 1; \
	  else \
	    go build -o app/zig-out/bin/rook-plugin-$$(basename $$d) ./$$d || exit 1; \
	  fi; \
	done

# The daily driver: the ZIG app as /Applications/rook.app. ReleaseFast,
# minimal hand-rolled bundle, ad-hoc signed, ctl socket on the default
# /tmp/rook.sock (the agent-visibility surface rides along on purpose).
#
# Providers ship INSIDE the bundle because that is how they are found:
# provider.Client.resolve looks beside the executable first.
#
# REL_VERSION is the newest tag, dotted: Info.plist's CFBundleVersion has
# to be a number, so this is always one.
#
# --match 'v[0-9]*' so only RELEASE tags count. The repo also carries
# tags that are not releases — sdk/provider/vX.Y.Z for the plugin SDK,
# edge-v1 and pre-strip-v1 for stripped code kept recoverable — and an
# unfiltered describe would feed one of those into CFBundleVersion, which
# has to be a number.
REL_VERSION := $(shell git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || echo 0.0.0)
# A bare cp skips the registration Finder/installers do — without this,
# Spotlight won't offer the app.
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Man pages ride INSIDE the bundle (Contents/Resources/man): the release
# zip is just rook.app, so this is how they reach a curl install, and the
# codesign seal covers them like everything else. Installers copy them
# out onto a manpath from here. Must run before codesign.
define bundle-man
	mkdir -p $(1)/Contents/Resources/man/man1 $(1)/Contents/Resources/man/man5 $(1)/Contents/Resources/man/man7
	cp docs/man/rook.1 docs/man/re.1 $(1)/Contents/Resources/man/man1/
	cp docs/man/rook-config.5 $(1)/Contents/Resources/man/man5/
	cp docs/man/rook-ctl.7 docs/man/rook-plugin.7 $(1)/Contents/Resources/man/man7/
endef
install:
	cd app && zig build -Doptimize=ReleaseFast -Dbuild=$(BUILD) -Dversion=$(REL_VERSION)
	$(MAKE) providers
	$(MAKE) plugins
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	sed 's/__VERSION__/$(REL_VERSION)/g' app/bundle/Info.plist > $(APP)/Contents/Info.plist
	cp app/zig-out/bin/rook $(APP)/Contents/MacOS/rook
	cp app/zig-out/bin/rook-provider-* $(APP)/Contents/MacOS/
	cp app/zig-out/bin/rook-plugin-* $(APP)/Contents/MacOS/
	@# Before codesign: the seal covers Resources. Degrades to a
	@# fallback icon without Xcode rather than failing the build.
	scripts/build-icon.sh $(APP)/Contents
	$(call bundle-man,$(APP))
	codesign -s - --force $(APP)
	$(LSREGISTER) -f $(APP)
	mdimport $(APP)
	@# The CLI face of the same binary. ~/.local/bin is on PATH; symlinks
	@# keep the CLI in lockstep with the installed app.
	mkdir -p $(HOME)/.local/bin
	ln -sf $(APP)/Contents/MacOS/rook $(HOME)/.local/bin/rook
	@# `re` = rook edit (argv[0] dispatch).
	ln -sf $(APP)/Contents/MacOS/rook $(HOME)/.local/bin/re
	@# Man pages. ~/.local/share/man is on the default macOS manpath, so
	@# `man rook` works with no MANPATH ceremony — and an agent's first
	@# question about rook has a canonical answer.
	mkdir -p $(HOME)/.local/share/man/man1 $(HOME)/.local/share/man/man5 $(HOME)/.local/share/man/man7
	cp docs/man/rook.1 docs/man/re.1 $(HOME)/.local/share/man/man1/
	cp docs/man/rook-config.5 $(HOME)/.local/share/man/man5/
	cp docs/man/rook-ctl.7 docs/man/rook-plugin.7 $(HOME)/.local/share/man/man7/
	@echo "installed $(APP) (v$(REL_VERSION), build $(BUILD)) + ~/.local/bin/{rook,re} + man pages"
	@echo "quit + relaunch rook to pick it up"

# The real app, driven end to end: each scenario spawns a SANDBOXED rook
# (own ctl socket, own config, own state dir, /bin/sh) and
# asserts against both truths — `dump` for what the emulator holds and a
# decoded `shot` for what the renderer actually drew.
#
#   make e2e                 — all scenarios
#   make e2e ARGS=splits     — one (substring match on the name)
#
# Local only, never CI: it needs a window server, a Metal device, and
# real shells. See app/e2e/ and app/README.md.
e2e:
	cd app && zig build e2e -- $(ARGS)

# Sandboxes are /tmp/rook-e2e-<pid>-<n>; a scenario leaves its dir behind
# on failure so the app log and any shot are still there to read.
e2e-clean:
	-pkill -f 'rook-e2e' 2>/dev/null || true
	rm -rf /tmp/rook-e2e-*

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

clean:
	rm -rf bin app/zig-out app/.zig-cache

# Publish a release: make release VERSION=v0.1.0
# Builds arm64 on this machine (no CI), zips rook.app, tags the current
# commit, and publishes via gh. Users install with install.sh (curl → no
# quarantine → no Gatekeeper prompt on our ad-hoc signature).
#
# The bundle is assembled by hand, right here: `rook` plus its providers.
#
# The zip used to carry a rookctl at the top level, which install.sh and
# internal/selfupdate both keyed on. Both are gone with the Go — an
# in-app updater is one of the things owed back in Zig, and until it
# lands `install.sh` is the upgrade path.
DIST := bin/dist
RELEASE_ZIP = rook-$(VERSION)-darwin-arm64.zip
STAGE = $(DIST)/stage
STAGED_APP = $(STAGE)/rook.app
GO_RELEASE = go build -tags production -trimpath -ldflags "-w -s"

release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=v0.1.0"; exit 1; }
	@test -z "$$(git status --porcelain)" || { echo "working tree dirty — commit first (the tag must match the build)"; exit 1; }
	$(MAKE) release-stage VERSION=$(VERSION)
	git tag -a $(VERSION) -m "rook $(VERSION)"
	git push origin main $(VERSION)
	gh release create $(VERSION) $(DIST)/$(RELEASE_ZIP) $(DIST)/checksums.txt $(DIST)/rook-$(VERSION)-unstripped.gz --title "rook $(VERSION)" --generate-notes

# Everything up to the zip, with nothing irreversible in it — so the
# packaging can be exercised without tagging or publishing:
#   make release-stage VERSION=v0.38.0 && ditto -x -k bin/dist/*.zip /tmp/x
release-stage:
	@test -n "$(VERSION)" || { echo "usage: make release-stage VERSION=v0.1.0"; exit 1; }
	rm -rf bin/rook.app $(DIST)
	@# The app. -Dversion drops the leading v: CFBundleShortVersionString
	@# has to be a dotted number, and XTVERSION reports it too.
	cd app && zig build -Doptimize=ReleaseFast -Dbuild=$(BUILD) -Dversion=$(VERSION:v%=%)
	@for d in $(PROVIDER_DIRS); do \
	  $(GO_RELEASE) -o app/zig-out/bin/rook-provider-$$(basename $$d) ./$$d || exit 1; \
	done
	@for d in $(PLUGIN_DIRS); do \
	  if [ -f $$d/go.mod ]; then \
	    (cd $$d && $(GO_RELEASE) -o $(CURDIR)/app/zig-out/bin/rook-plugin-$$(basename $$d) .) || exit 1; \
	  else \
	    $(GO_RELEASE) -o app/zig-out/bin/rook-plugin-$$(basename $$d) ./$$d || exit 1; \
	  fi; \
	done
	mkdir -p $(STAGED_APP)/Contents/MacOS
	sed 's/__VERSION__/$(VERSION:v%=%)/g' app/bundle/Info.plist > $(STAGED_APP)/Contents/Info.plist
	cp app/zig-out/bin/rook $(STAGED_APP)/Contents/MacOS/rook
	cp app/zig-out/bin/rook-provider-* $(STAGED_APP)/Contents/MacOS/
	cp app/zig-out/bin/rook-plugin-* $(STAGED_APP)/Contents/MacOS/
	@# --strict: a release must carry the real icon, so a missing actool
	@# fails here rather than quietly shipping the fallback.
	scripts/build-icon.sh $(STAGED_APP)/Contents --strict
	$(call bundle-man,$(STAGED_APP))
	@# Sign the BUNDLE last — the seal covers the nested binaries and
	@# Resources, so anything that rewrites one afterwards invalidates it.
	codesign -s - --force $(STAGED_APP)
	@# No `re` symlink here any more — `re` is `rook edit` now, and
	@# install.sh points it at the app binary inside the bundle.
	@# ditto -c -k, not zip: preserves xattrs and the ad-hoc signature exactly
	ditto -c -k $(STAGE) $(DIST)/$(RELEASE_ZIP)
	@# The unstripped binary rides the release as its own artifact: a
	@# crash sidecar (crash.zig) is raw addresses plus a slide, readable
	@# only against the exact binary that made them —
	@#   atos -o rook-$(VERSION)-unstripped -s <slide> <addr ...>
	@# — and this is the one release step that cannot be done later.
	gzip -c app/zig-out/bin/rook > $(DIST)/rook-$(VERSION)-unstripped.gz
	cd $(DIST) && shasum -a 256 $(RELEASE_ZIP) > checksums.txt
	@# No backticks in this message: the shell would run what is in them.
	@echo "staged $(DIST)/$(RELEASE_ZIP) — 'make release VERSION=$(VERSION)' tags and publishes"

