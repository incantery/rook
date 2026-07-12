package host

import (
	"context"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// rook-agent is a host-supervised child process, same posture as agentmon:
// find the binary, run it, restart with backoff, absent binary = feature
// off. It is NOT a third daemon — no state file, no discovery; the host
// owns its lifetime and hands it credentials via env. Iterating on the
// agent is `make agent` + this supervisor noticing the new mtime — zero
// daemon replacements, zero shell deaths.

// findRookAgent resolves the rook-agent binary: next to our own executable
// (packaged installs), then the conventional dev spots.
func findRookAgent() string {
	if exe, err := os.Executable(); err == nil {
		p := filepath.Join(filepath.Dir(exe), "rook-agent")
		if st, err := os.Stat(p); err == nil && st.Mode()&0o111 != 0 {
			return p
		}
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	for _, p := range []string{
		filepath.Join(home, "go", "bin", "rook-agent"),
		filepath.Join(home, "go", "src", "github.com", "incantery", "rook", "bin", "rook-agent"),
	} {
		if st, err := os.Stat(p); err == nil && st.Mode()&0o111 != 0 {
			return p
		}
	}
	return ""
}

// SuperviseAgent runs the rook-agent supervision loop; call it once, in a
// goroutine, after the host is listening. endpoint is this host's own
// address — the agent talks back through the same authenticated HTTP
// surface as every other client (no side doors, docs/agent.md).
func (h *Host) SuperviseAgent(ctx context.Context, endpoint string) {
	for {
		bin := findRookAgent()
		if bin == "" {
			select {
			case <-ctx.Done():
				return
			case <-time.After(5 * time.Minute):
				continue
			}
		}
		h.runAgent(ctx, bin, endpoint)
		select {
		case <-ctx.Done():
			return
		case <-time.After(15 * time.Second):
		}
	}
}

func (h *Host) runAgent(ctx context.Context, bin, endpoint string) {
	mtimeOf := func() time.Time {
		st, err := os.Stat(bin)
		if err != nil {
			return time.Time{}
		}
		return st.ModTime()
	}
	startMtime := mtimeOf()

	cmd := exec.CommandContext(ctx, bin)
	cmd.Env = append(os.Environ(),
		"ROOK_HOST_ENDPOINT="+endpoint,
		"ROOK_HOST_TOKEN="+h.token)
	// The agent gets its own log — prompt-and-loop iteration lives there,
	// not interleaved into the host's.
	if logf, err := os.OpenFile(filepath.Join(StateDir(), "agent.log"),
		os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600); err == nil {
		cmd.Stdout, cmd.Stderr = logf, logf
		defer logf.Close()
	}
	if err := cmd.Start(); err != nil {
		log.Printf("agentproc: start %s: %v", bin, err)
		return
	}
	log.Printf("agentproc: running %s (pid %d)", bin, cmd.Process.Pid)

	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	tick := time.NewTicker(5 * time.Second)
	defer tick.Stop()
	for {
		select {
		case err := <-done:
			log.Printf("agentproc: rook-agent exited: %v", err)
			return
		case <-ctx.Done():
			cmd.Process.Kill()
			<-done
			return
		case <-tick.C:
			// dev loop: `make agent` replaced the binary → restart onto it
			if mt := mtimeOf(); !mt.Equal(startMtime) && !mt.IsZero() {
				log.Printf("agentproc: %s changed on disk; restarting", bin)
				cmd.Process.Kill()
				<-done
				return
			}
		}
	}
}
