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
		// Compatibility is build identity: binaries from one make run
		// match exactly, so after install + relaunch the daemon is
		// guaranteed replaced — no protocol number to remember to bump.
		// Unstamped builds (wails3 dev, go run) never replace the daemon:
		// the hacking instance rides the daily driver's host, and the
		// frontend's fail-open posture absorbs any skew.
		if st.Build == version.Build || version.Build == "dev" {
			return Info{Endpoint: st.Endpoint(), Token: st.Token}, nil
		}
		// Build drift: the running daemon is not what's installed.
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
