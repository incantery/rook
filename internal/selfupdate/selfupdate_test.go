package selfupdate

import "testing"

func TestFindChecksum(t *testing.T) {
	sums := []byte(
		"abc123  rook-v0.1.0-darwin-arm64.zip\n" +
			"def456  other.zip\n" +
			"\n")
	if got, ok := findChecksum(sums, "rook-v0.1.0-darwin-arm64.zip"); !ok || got != "abc123" {
		t.Fatalf("got %q %v, want abc123 true", got, ok)
	}
	if _, ok := findChecksum(sums, "missing.zip"); ok {
		t.Fatal("found checksum for a file not in the list")
	}
}
