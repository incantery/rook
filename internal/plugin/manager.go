package plugin

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// installTimeout bounds one materialization — a toolchain that hangs must
// not pin the "installing" state forever.
const installTimeout = 10 * time.Minute

// Manager owns the materialization prefix:
// <dir>/<plugin>/<version>/<bin...>. Installs delegate to the language's
// own toolchain and land only here — never the user's global environment.
// Uninstall is rm -rf of a plugin dir; the binary is the lock (no
// manifest, no lockfile).
type Manager struct {
	Dir string

	mu         sync.Mutex
	installing map[string]bool
	lastErr    map[string]string
}

func NewManager(dir string) *Manager {
	return &Manager{Dir: dir, installing: map[string]bool{}, lastErr: map[string]string{}}
}

// BinPath is the managed binary's absolute path for e — derived, never a
// symlink, so status shows exactly which version serves.
func (m *Manager) BinPath(e Entry) string {
	if e.Lang == nil {
		return ""
	}
	return filepath.Join(m.versionDir(e), filepath.FromSlash(e.Lang.Bin))
}

func (m *Manager) versionDir(e Entry) string {
	return filepath.Join(m.Dir, e.Name, e.Version)
}

// toolchain names the external command a method delegates to.
func toolchain(method string) string {
	switch method {
	case "go":
		return "go"
	case "npm":
		return "npm"
	}
	return ""
}

// State reports where e stands: ready | installing | needs-toolchain |
// error | missing. detail carries the toolchain name or the last install
// error. Everything here is cheap (a stat, a LookPath) — safe on a poll.
func (m *Manager) State(e Entry) (state, detail string) {
	m.mu.Lock()
	inflight, lastErr := m.installing[e.Name], m.lastErr[e.Name]
	m.mu.Unlock()
	if inflight {
		return "installing", ""
	}
	if st, err := os.Stat(m.BinPath(e)); err == nil && st.Mode()&0o111 != 0 {
		return "ready", ""
	}
	if lastErr != "" {
		return "error", lastErr
	}
	tc := toolchain(e.Lang.Method)
	if _, err := exec.LookPath(tc); err != nil {
		return "needs-toolchain", tc
	}
	return "missing", ""
}

// EnsureInstalled kicks off a background install when e is missing and
// its toolchain is present — the lazy path, called from the query side.
// Fail-open posture: it never blocks, the caller serves empty results
// until the state turns ready.
func (m *Manager) EnsureInstalled(e Entry) {
	if state, _ := m.State(e); state != "missing" {
		return
	}
	go func() {
		if err := m.Install(e); err != nil {
			log.Printf("plugin: install %s@%s: %v", e.Name, e.Version, err)
		}
	}()
}

// Install materializes e synchronously: toolchain into a staging dir,
// rename into place on success — a crashed install never half-populates a
// version dir. Already-materialized is a no-op; a concurrent install is
// an error (one at a time per plugin).
func (m *Manager) Install(e Entry) error {
	if e.Lang == nil {
		return fmt.Errorf("plugin %s: no payload", e.Name)
	}
	m.mu.Lock()
	if m.installing[e.Name] {
		m.mu.Unlock()
		return fmt.Errorf("plugin %s: install already in progress", e.Name)
	}
	m.installing[e.Name] = true
	m.mu.Unlock()
	err := m.install(e)
	m.mu.Lock()
	delete(m.installing, e.Name)
	if err != nil {
		m.lastErr[e.Name] = err.Error()
	} else {
		delete(m.lastErr, e.Name)
	}
	m.mu.Unlock()
	return err
}

func (m *Manager) install(e Entry) error {
	if st, err := os.Stat(m.BinPath(e)); err == nil && st.Mode()&0o111 != 0 {
		return nil // the binary is the lock
	}
	tc := toolchain(e.Lang.Method)
	if tc == "" {
		return fmt.Errorf("plugin %s: unknown install method %q", e.Name, e.Lang.Method)
	}
	if _, err := exec.LookPath(tc); err != nil {
		return fmt.Errorf("plugin %s: needs the %s toolchain on PATH", e.Name, tc)
	}
	if err := os.MkdirAll(filepath.Join(m.Dir, e.Name), 0o755); err != nil {
		return err
	}
	staging, err := os.MkdirTemp(filepath.Join(m.Dir, e.Name), ".staging-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(staging) // no-op miss after a successful rename

	ctx, cancel := context.WithTimeout(context.Background(), installTimeout)
	defer cancel()
	var cmd *exec.Cmd
	switch e.Lang.Method {
	case "go":
		cmd = exec.CommandContext(ctx, tc, "install", e.Lang.Pkg+"@"+e.Version)
		cmd.Env = append(os.Environ(), "GOBIN="+filepath.Join(staging, "bin"))
	case "npm":
		cmd = exec.CommandContext(ctx, tc, "install", "--prefix", staging,
			"--no-fund", "--no-audit", "--loglevel=error",
			e.Lang.Pkg+"@"+e.Version)
	}
	log.Printf("plugin: installing %s@%s (%s)", e.Name, e.Version, e.Lang.Method)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("plugin %s: %s install: %v: %s", e.Name, tc, err, tail(out, 400))
	}
	// The staged tree must actually contain the promised binary — a
	// toolchain that "succeeded" without producing it is an install error,
	// not a ready plugin.
	staged := filepath.Join(staging, filepath.FromSlash(e.Lang.Bin))
	if st, err := os.Stat(staged); err != nil || st.Mode()&0o111 == 0 {
		return fmt.Errorf("plugin %s: install produced no %s", e.Name, e.Lang.Bin)
	}
	if err := os.Rename(staging, m.versionDir(e)); err != nil {
		// A concurrent-ish install may have won the rename; ready is ready.
		if st, statErr := os.Stat(m.BinPath(e)); statErr == nil && st.Mode()&0o111 != 0 {
			return nil
		}
		return err
	}
	log.Printf("plugin: %s@%s ready", e.Name, e.Version)
	return nil
}

// Prune removes e's non-pinned version dirs — the upgrade cleanup, run
// only after the pinned version is ready.
func (m *Manager) Prune(e Entry) {
	entries, err := os.ReadDir(filepath.Join(m.Dir, e.Name))
	if err != nil {
		return
	}
	for _, d := range entries {
		if d.Name() == e.Version || strings.HasPrefix(d.Name(), ".staging-") {
			continue
		}
		os.RemoveAll(filepath.Join(m.Dir, e.Name, d.Name()))
	}
}

func tail(b []byte, n int) string {
	s := strings.TrimSpace(string(b))
	if len(s) > n {
		s = "…" + s[len(s)-n:]
	}
	return s
}
