// Package version holds the release version stamped into every rook binary
// at release time (make release → -X ldflag). Source builds report "dev".
// Distinct from host.Version, which is the host↔client protocol number.
package version

var Version = "dev"
