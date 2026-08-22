# ReleaseSafe by default: ghostty-vt at Debug is a ~100x parse hole —
# a Debug rook-mux feels broken (vim lags), not just slow.
build:
	zig build -Doptimize=ReleaseSafe

debug:
	zig build

test:
	zig build test

install: build
	@mkdir -p $(HOME)/.local/bin
	install -m 0755 zig-out/bin/rook-mux $(HOME)/.local/bin/rook-mux
	@echo "rook-mux: installed $(HOME)/.local/bin/rook-mux"

.PHONY: build debug test install
