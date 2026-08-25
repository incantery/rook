# ReleaseSafe by default: ghostty-vt at Debug is a ~100x parse hole —
# a Debug engine feels broken (vim lags), not just slow.
build:
	zig build -Doptimize=ReleaseSafe

debug:
	zig build

test:
	zig build test

# Off $PATH on purpose: there is one command, and it is `rook`. The Go
# front door (and rookd) look for the engine in the libexec sibling of
# the directory they are installed in, then ~/.local/libexec/rook.
LIBEXECDIR ?= $(HOME)/.local/libexec/rook

install: build
	@mkdir -p $(LIBEXECDIR)
	install -m 0755 zig-out/bin/engine $(LIBEXECDIR)/engine
	@echo "rook: engine installed $(LIBEXECDIR)/engine"

.PHONY: build debug test install
