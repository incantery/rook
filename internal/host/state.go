package host

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// State is how clients find a running host: written next to the host's log
// in the state dir, verified with a health check before trust.
type State struct {
	Port    int    `json:"port"`
	Token   string `json:"token"`
	PID     int    `json:"pid"`
	Version int    `json:"version"`
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
