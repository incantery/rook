# Developing rook using rook:
#   make install  — production .app into /Applications; the daily driver
#   make dev      — hot-reload dev instance (own window, own PTYs); run it
#                   from inside installed rook, changes never touch your
#                   daily shells
#   make start    — quick foreground run of a production build
# Promote: make install, then quit+relaunch the installed app. (Relaunch
# kills its shells until the PTY host splits into its own process.)

APP := /Applications/rook.app

.PHONY: build start dev package install clean

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
	@echo "installed $(APP) — quit + relaunch rook to pick it up"

clean:
	rm -rf bin frontend/dist
