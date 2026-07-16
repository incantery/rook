package hostclient

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/incantery/rook/internal/host"
)

// hostBinaryChanged resolves rook-host next to the running executable, which
// under `go test` is the test binary — so a rook-host dropped beside it is
// the one the code under test will find.
func fakeHostBinary(t *testing.T) string {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Skip("no executable path")
	}
	path := filepath.Join(filepath.Dir(exe), "rook-host")
	if _, err := os.Stat(path); err == nil {
		t.Skip("a real rook-host sits next to the test binary; refusing to clobber it")
	}
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Skipf("cannot write beside the test binary: %v", err)
	}
	t.Cleanup(func() { os.Remove(path) })
	return path
}

func hashOf(t *testing.T, path string) string {
	t.Helper()
	sum := host.HashFile(path)
	if sum == "" {
		t.Fatalf("HashFile(%s) = \"\"", path)
	}
	return sum
}

// shouldRide is where the bug was: an earlier cut wrote
//
//	st.Build == version.Build || (version.Build == "dev" && !changed)
//
// which short-circuits on "dev" == "dev" and rides before the binary is ever
// compared. hostBinaryChanged's own tests all passed while make dev stayed
// broken, which is why the DECISION gets tested and not just its helper.
func TestShouldRide(t *testing.T) {
	changed := func(host.State) bool { return true }
	same := func(host.State) bool { return false }

	tests := []struct {
		name    string
		st      host.State
		build   string
		binFunc func(host.State) bool
		want    bool
	}{
		{
			name: "unstamped, binary rebuilt under the daemon → replace",
			// the regression: both ids are "dev" and must NOT be compared
			st: host.State{Build: "dev"}, build: "dev", binFunc: changed, want: false,
		},
		{
			name: "unstamped, same binary → ride (sessions survive a frontend restart)",
			st:   host.State{Build: "dev"}, build: "dev", binFunc: same, want: true,
		},
		{
			name: "stamped, ids match → ride, and the binary is irrelevant",
			// the daily driver's path: a matching build id is proof enough,
			// and must not be second-guessed by an mtime
			st: host.State{Build: "abc123"}, build: "abc123", binFunc: changed, want: true,
		},
		{
			name: "stamped, ids differ → replace (install + relaunch)",
			st:   host.State{Build: "old"}, build: "new", binFunc: same, want: false,
		},
		{
			name: "stamped client, pre-Build daemon → replace",
			st:   host.State{Build: ""}, build: "abc123", binFunc: same, want: false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := shouldRide(tt.st, tt.build, tt.binFunc); got != tt.want {
				t.Errorf("shouldRide = %v, want %v", got, tt.want)
			}
		})
	}
}

// The daemon is running the very binary we would spawn: ride it. This is the
// case the whole ride rule exists for — a frontend-only restart must not cost
// you your sessions.
func TestHostBinaryUnchangedRides(t *testing.T) {
	path := fakeHostBinary(t)
	st := host.State{BinHash: hashOf(t, path)}
	if hostBinaryChanged(st) {
		t.Error("hostBinaryChanged = true for the binary the daemon is running")
	}
}

// `go build` rewrites its output on every run even when the bytes are
// identical. An mtime-based check called that a change and killed the
// sessions riding exists to keep — content does not.
func TestHostBinaryRewrittenIdenticallyRides(t *testing.T) {
	path := fakeHostBinary(t)
	st := host.State{BinHash: hashOf(t, path)}

	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	later := time.Now().Add(time.Hour)
	if err := os.WriteFile(path, body, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, later, later); err != nil {
		t.Fatal(err)
	}
	if hostBinaryChanged(st) {
		t.Error("hostBinaryChanged = true for a byte-identical rebuild — mtime is not the signal")
	}
}

// The trap this fixes: wails3 rebuilds rook-host on every *.go save, so the
// binary moves while the process does not. Riding there means host changes
// silently never load.
func TestHostBinaryRebuiltReplaces(t *testing.T) {
	path := fakeHostBinary(t)
	st := host.State{BinHash: hashOf(t, path)}

	if err := os.WriteFile(path, []byte("#!/bin/sh\necho rebuilt\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if !hostBinaryChanged(st) {
		t.Error("hostBinaryChanged = false after the binary changed under the daemon")
	}
}

// A daemon predating the field is, for an unstamped client, proof of
// staleness — and this is what bootstraps the scheme after an upgrade.
func TestHostBinaryPreFieldDaemonReplaces(t *testing.T) {
	fakeHostBinary(t)
	if !hostBinaryChanged(host.State{BinHash: ""}) {
		t.Error("a daemon with no BinHash should be replaced once")
	}
}

// Nothing we could spawn → riding is all there is, which is the pre-existing
// behaviour and the reason `go run` never kills the daily driver's daemon.
func TestHostBinaryUnresolvableRides(t *testing.T) {
	exe, err := os.Executable()
	if err != nil {
		t.Skip("no executable path")
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(exe), "rook-host")); err == nil {
		t.Skip("a rook-host is resolvable here; this test needs none")
	}
	if _, err := hostBinary(); err == nil {
		t.Skip("rook-host is on PATH; this test needs it absent")
	}
	if hostBinaryChanged(host.State{BinHash: ""}) {
		t.Error("hostBinaryChanged = true with no binary to compare against — it must ride")
	}
}

// BinHash must actually read the executable, or the whole check is inert.
func TestBinHashReadsTheExecutable(t *testing.T) {
	got := host.BinHash()
	if got == "" {
		t.Fatal("BinHash = \"\" for a running executable")
	}
	exe, err := os.Executable()
	if err != nil {
		t.Skip("no executable path")
	}
	if want := hashOf(t, exe); got != want {
		t.Errorf("BinHash = %s, want %s", got, want)
	}
}

func TestHashFileUnreadableIsEmpty(t *testing.T) {
	if got := host.HashFile(filepath.Join(t.TempDir(), "nope")); got != "" {
		t.Errorf("HashFile(missing) = %q, want \"\"", got)
	}
}
