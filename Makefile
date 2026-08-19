# rook — build and local install.

BINDIR ?= $(HOME)/.local/bin

.PHONY: build test install

build:
	go build -o rook ./cmd/rook

test:
	go test ./...

install: build test
	@mkdir -p $(BINDIR)
	@rm -f $(BINDIR)/rook   # may be a symlink; never write through it
	install -m 0755 rook $(BINDIR)/rook
	@echo "rook: installed $(BINDIR)/rook"
