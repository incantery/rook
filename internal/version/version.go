// Package version holds the one identity every rook binary shares.
//
// Version is the human-facing semver release ("v0.1.0"), stamped by
// `make release`; source builds report "dev". Build is the machine-facing
// build id (git sha + timestamp), stamped by `make install` AND
// `make release` — every binary produced by one make run carries the same
// Build, and host↔client compatibility is Build equality. There is no
// hand-bumped protocol number: if two binaries were built together they
// agree, if not the daemon gets replaced (see internal/hostclient).
package version

var (
	Version = "dev"
	// Build stays "dev" only in unstamped builds (make dev, go run) —
	// those never replace a running daemon, they ride it.
	Build = "dev"
)
