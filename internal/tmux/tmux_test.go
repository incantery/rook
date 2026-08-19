package tmux

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestRenderDeterministic(t *testing.T) {
	a := Defaults().Render("/tmp/x.conf")
	b := Defaults().Render("/tmp/x.conf")
	if a != b {
		t.Fatal("Render is not deterministic")
	}
}

// TestTmuxAcceptsRenderedConf uses tmux itself as the oracle: boot a
// throwaway server on a private socket with the rendered conf and fail
// on any config complaint. String-matching the conf would only prove we
// wrote what we wrote.
func TestTmuxAcceptsRenderedConf(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not on PATH")
	}
	dir := t.TempDir()
	conf := filepath.Join(dir, "tmux.conf")
	if err := os.WriteFile(conf, []byte(Defaults().Render(conf)), 0o644); err != nil {
		t.Fatal(err)
	}

	socket := fmt.Sprintf("rook-test-%d", os.Getpid())
	kill := exec.Command("tmux", "-L", socket, "kill-server")
	defer kill.Run()

	// -d needs no tty; config errors surface on stderr and via the
	// server's message log.
	cmd := exec.Command("tmux", "-L", socket, "-f", conf, "new-session", "-d", "-s", "probe")
	cmd.Env = append(os.Environ(), "TMUX=") // never nest into a surrounding tmux
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("tmux rejected the rendered conf: %v\n%s", err, out)
	}
	if len(out) != 0 {
		t.Fatalf("tmux complained about the rendered conf:\n%s", out)
	}

	msgs, err := exec.Command("tmux", "-L", socket, "show-messages").CombinedOutput()
	if err == nil {
		for line := range strings.SplitSeq(string(msgs), "\n") {
			if strings.Contains(line, "error") || strings.Contains(line, "unknown") {
				t.Fatalf("config error in server message log: %s", line)
			}
		}
	}
}

func TestSessionName(t *testing.T) {
	cases := map[string]string{
		"/Users/x/dev/rook":  "rook",
		"/Users/x/rook.tmux": "rook_tmux",
		"/":                  "rook",
		"":                   "rook",
	}
	for dir, want := range cases {
		if got := SessionName(dir); got != want {
			t.Errorf("SessionName(%q) = %q, want %q", dir, got, want)
		}
	}
}
