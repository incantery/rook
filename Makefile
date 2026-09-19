# rook — build and local install.

BINDIR ?= $(HOME)/.local/bin

.PHONY: build rookd test install engine sandbox

# An isolated rook (own server/state/config/data) in a new Ghostty
# window; prints the socket to drive it with `tmux -L <socket> …`.
sandbox:
	@scripts/sandbox.sh

VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null)
LDFLAGS := -s -w -X main.version=$(VERSION) -X main.commit=$(COMMIT)

build:
	go build -ldflags "$(LDFLAGS)" -o rook ./cmd/rook

# The nanny: it keeps the engine alive, serves the web client, and runs
# the tab namer. launchd runs it, nobody types it — but it ships here,
# because a rook installed without it is a rook whose tabs never get a
# better name than the first program that spoke.
rookd:
	go build -ldflags "$(LDFLAGS)" -o rookd ./cmd/rookd

test:
	go test ./...

# The Zig engine, off $PATH: nobody types it, `rook` execs it.
# ~/.local/bin/rook → ~/.local/libexec/rook/engine.
engine:
	@$(MAKE) -C mux install LIBEXECDIR=$(LIBEXECDIR)

LIBEXECDIR ?= $(dir $(BINDIR))libexec/rook

install: build rookd test engine
	@mkdir -p $(BINDIR)
	@rm -f $(BINDIR)/rook   # may be a symlink; never write through it
	install -m 0755 rook $(BINDIR)/rook
	@echo "rook: installed $(BINDIR)/rook"
	install -m 0755 rookd $(BINDIR)/rookd
	@echo "rook: installed $(BINDIR)/rookd"
	@scripts/restart-rookd.sh
