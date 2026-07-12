# Developing rook using rook:
#   make install  — production .app into /Applications; the daily driver
#   make dev      — hot-reload dev instance (own window, own PTYs); run it
#                   from inside installed rook, changes never touch your
#                   daily shells
#   make start    — quick foreground run of a production build
# Promote: make install, then quit+relaunch the installed app. (Relaunch
# kills its shells until the PTY host splits into its own process.)

APP := /Applications/rook.app

.PHONY: build start dev package install clean agent release

build:
	wails3 task build

start: build
	./bin/rook

dev:
	wails3 dev

package:
	@# The bundle task only adds files into an existing .app — a stale
	@# bundle keeps files the build no longer produces (e.g. Assets.car).
	rm -rf bin/rook.app
	wails3 task package

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
	go build -o $(shell go env GOPATH)/bin/rookctl ./cmd/rookctl
	go build -o $(shell go env GOPATH)/bin/rook-agent ./cmd/rook-agent
	@echo "installed $(APP) + rookctl + rook-agent — quit + relaunch rook to pick it up"

# The drafter's dev loop: rebuild, and the running host's supervisor
# notices the new mtime and respawns rook-agent — no daemon replacement,
# no shell deaths. Deliberately NOT bundled into the .app: next-to-binary
# would shadow this loop.
agent:
	go build -o $(shell go env GOPATH)/bin/rook-agent ./cmd/rook-agent

clean:
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
	wails3 task package VERSION=$(VERSION)
	mkdir -p $(DIST)/stage
	cp -R bin/rook.app $(DIST)/stage/
	go build -tags production -trimpath -ldflags "-w -s $(VERSION_FLAG)" -o $(DIST)/stage/rookctl ./cmd/rookctl
	@# ditto -c -k, not zip: preserves xattrs and the ad-hoc signature exactly
	ditto -c -k $(DIST)/stage $(DIST)/$(RELEASE_ZIP)
	cd $(DIST) && shasum -a 256 $(RELEASE_ZIP) > checksums.txt
	git tag -a $(VERSION) -m "rook $(VERSION)"
	git push origin main $(VERSION)
	gh release create $(VERSION) $(DIST)/$(RELEASE_ZIP) $(DIST)/checksums.txt --title "rook $(VERSION)" --generate-notes
