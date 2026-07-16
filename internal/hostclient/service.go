// Package hostclient is the app-side bridge to the rook-host daemon: it
// ensures one is running (spawning the binary that ships next to the app
// executable if not) and hands the frontend the endpoint + token. All actual
// session traffic goes directly from the webview to the host.
package hostclient

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	"github.com/incantery/rook/internal/host"
	"github.com/incantery/rook/internal/version"
)

type Info struct {
	Endpoint string `json:"endpoint"`
	Token    string `json:"token"`
}

type Service struct{}

func (s *Service) Info() (Info, error) {
	if st, err := host.ReadState(); err == nil && st.Healthy() {
		if shouldRide(st, version.Build, hostBinaryChanged) {
			return Info{Endpoint: st.Endpoint(), Token: st.Token}, nil
		}
		// Drift: the running daemon is not the code we would spawn.
		// Replace it — its sessions die with it, the one upgrade cost.
		syscall.Kill(st.PID, syscall.SIGTERM)
		time.Sleep(300 * time.Millisecond)
	}
	if err := spawnHost(); err != nil {
		return Info{}, err
	}
	for i := 0; i < 60; i++ {
		time.Sleep(50 * time.Millisecond)
		if st, err := host.ReadState(); err == nil && st.Healthy() {
			return Info{Endpoint: st.Endpoint(), Token: st.Token}, nil
		}
	}
	return Info{}, errors.New("rook-host did not become healthy within 3s (see ~/.local/state/rook/host.log)")
}

// shouldRide reports whether a healthy daemon can be used as it stands.
//
// Compatibility is build identity: binaries from one make run match exactly,
// so after install + relaunch the daemon is guaranteed replaced — no protocol
// number to remember to bump.
//
// Unstamped builds break that, and quietly. `wails3 dev` and `go run` ALL
// report Build "dev", so "dev" == "dev" says nothing about whether the daemon
// is the code you just wrote — it only says neither was stamped. Riding on
// that comparison is how `make dev` came to run a host from hours earlier
// while cheerfully rebuilding the binary on every save. So for unstamped
// builds the id is ignored entirely and the binary is compared instead.
//
// binChanged is injected so the decision is testable without a daemon; this
// function is where the bug was, so it is the thing that needs a test.
func shouldRide(st host.State, build string, binChanged func(host.State) bool) bool {
	if build == "dev" {
		return !binChanged(st)
	}
	return st.Build == build
}

// hostBinaryChanged reports whether the running daemon is a different binary
// from the one we would spawn — the staleness check for unstamped builds,
// which all share the id "dev" and so can never drift by Build alone.
//
// It exists because `make dev` used to be a trap. Its sandbox has its own
// XDG triple and therefore its own daemon, so "the hacking instance must not
// kill the daily driver's host" was protecting nothing there — while
// `wails3 build DEV=true` rebuilt rook-host on every save (build/config.yml
// watches *.go) and the app rode the process from hours ago regardless. Host
// changes silently never loaded, and the symptom was a 404 on a route that
// demonstrably existed in the source.
//
// It compares CONTENT, not the timestamp: `go build` rewrites its output on
// every run even when the bytes are identical, so an mtime would call every
// no-op `make dev` restart a change and kill the sessions that riding exists
// to keep. Anything unreadable (a `go run` binary with no rook-host beside
// it, a daemon on PATH we cannot hash) returns false and rides, which is
// exactly the old behaviour: the case this fixes is a sandbox we own, not
// someone else's daemon.
func hostBinaryChanged(st host.State) bool {
	path, err := hostBinary()
	if err != nil {
		return false // nothing we could spawn — riding is all there is
	}
	sum := host.HashFile(path)
	if sum == "" {
		return false
	}
	if st.BinHash == "" {
		// A daemon older than the field itself. For an unstamped client
		// that is proof of staleness, and it bootstraps the scheme: the
		// first run after this change replaces the pre-field daemon once,
		// and never needs to again.
		return true
	}
	return st.BinHash != sum
}

func spawnHost() error {
	path, err := hostBinary()
	if err != nil {
		return err
	}
	cmd := exec.Command(path)
	// Own session: the daemon must outlive the app.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.Stdout = nil
	cmd.Stderr = nil
	if err := cmd.Start(); err != nil {
		return err
	}
	return cmd.Process.Release()
}

func hostBinary() (string, error) {
	if exe, err := os.Executable(); err == nil {
		p := filepath.Join(filepath.Dir(exe), "rook-host")
		if _, err := os.Stat(p); err == nil {
			return p, nil
		}
	}
	if p, err := exec.LookPath("rook-host"); err == nil {
		return p, nil
	}
	return "", errors.New("rook-host binary not found next to the app or on PATH")
}
