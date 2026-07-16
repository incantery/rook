package host

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// State is how clients find a running host: written next to the host's log
// in the state dir, verified with a health check before trust.
type State struct {
	Port  int    `json:"port"`
	Token string `json:"token"`
	PID   int    `json:"pid"`
	// Release is the daemon's semver (version.Version), for humans.
	Release string `json:"release,omitempty"`
	// Build is the daemon's build id (version.Build) — THE compatibility
	// key: clients built together with the daemon match it exactly. A
	// pre-Build daemon's state file yields "", which never matches a
	// stamped client, so upgrading past this scheme replaces the daemon.
	Build string `json:"build,omitempty"`
	// BinHash is a content hash of the daemon's own executable, taken at
	// startup.
	//
	// It exists for the one case Build cannot cover: unstamped builds all
	// report Build "dev", so "dev" == "dev" and a client rides whatever
	// daemon is already up — forever, including one running code from hours
	// ago. `wails3 build DEV=true` rebuilds rook-host on every *.go save
	// (build/config.yml), so the binary on disk is always fresh while the
	// process is not, and host changes silently never load.
	//
	// Content, not mtime: `go build` rewrites its output even when the
	// result is byte-identical, so a timestamp would call every no-op
	// restart a change and kill the sessions that riding exists to keep.
	// The hash rides when the code really is the same and replaces when it
	// is not. See internal/hostclient.
	//
	// Empty means a daemon older than this field, which for an unstamped
	// client is itself proof of staleness.
	BinHash string `json:"binHash,omitempty"`
}

// BinHash returns a content hash of this executable, or "" when it cannot be
// read — in which case a client cannot tell staleness and keeps riding, which
// is the pre-existing behaviour. Costs one read of the binary at startup.
func BinHash() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	return HashFile(exe)
}

// HashFile is a content hash of path, or "" when it cannot be read. Exported
// for hostclient, which hashes the binary it would spawn to compare against
// the running daemon's BinHash.
func HashFile(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return ""
	}
	return hex.EncodeToString(h.Sum(nil))
}

func StateDir() string {
	base := os.Getenv("XDG_STATE_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		base = filepath.Join(home, ".local", "state")
	}
	return filepath.Join(base, "rook")
}

func statePath() string { return filepath.Join(StateDir(), "host.json") }

func ReadState() (State, error) {
	var st State
	data, err := os.ReadFile(statePath())
	if err != nil {
		return st, err
	}
	if err := json.Unmarshal(data, &st); err != nil {
		return st, err
	}
	return st, nil
}

func WriteState(st State) error {
	dir := StateDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	data, err := json.Marshal(st)
	if err != nil {
		return err
	}
	return os.WriteFile(statePath(), data, 0o600)
}

func (st State) Endpoint() string { return fmt.Sprintf("http://127.0.0.1:%d", st.Port) }

// Healthy verifies the state file points at a live, token-matching host.
func (st State) Healthy() bool {
	if st.Port == 0 || st.Token == "" {
		return false
	}
	client := &http.Client{Timeout: 500 * time.Millisecond}
	req, err := http.NewRequest(http.MethodGet, st.Endpoint()+"/health", nil)
	if err != nil {
		return false
	}
	req.Header.Set("Authorization", "Bearer "+st.Token)
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}
