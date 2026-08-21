# rook — build and local install.

BINDIR ?= $(HOME)/.local/bin

.PHONY: build test install sandbox

# An isolated rook (own server/state/config/data) in a new Ghostty
# window; prints the socket to drive it with `tmux -L <socket> …`.
sandbox:
	@scripts/sandbox.sh

VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null)
LDFLAGS := -s -w -X main.version=$(VERSION) -X main.commit=$(COMMIT)

build:
	go build -ldflags "$(LDFLAGS)" -o rook ./cmd/rook

test:
	go test ./...

install: build test
	@mkdir -p $(BINDIR)
	@rm -f $(BINDIR)/rook   # may be a symlink; never write through it
	install -m 0755 rook $(BINDIR)/rook
	@echo "rook: installed $(BINDIR)/rook"
