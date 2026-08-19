package tmux

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
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
	for name, mutate := range map[string]func(*Settings){
		"defaults":        func(*Settings) {},
		"backtick-prefix": func(s *Settings) { s.Prefix = "`" },
		"ctrl-a-prefix":   func(s *Settings) { s.Prefix = "C-a" },
	} {
		t.Run(name, func(t *testing.T) {
			s := Defaults()
			mutate(&s)
			assertTmuxAccepts(t, s)
		})
	}
}

func assertTmuxAccepts(t *testing.T, s Settings) {
	t.Helper()
	conf := filepath.Join(t.TempDir(), "tmux.conf")
	if err := os.WriteFile(conf, []byte(s.Render(conf)), 0o644); err != nil {
		t.Fatal(err)
	}

	socket := fmt.Sprintf("rook-test-%d-%d", os.Getpid(), time.Now().UnixNano())
	defer exec.Command("tmux", "-L", socket, "kill-server").Run()

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

	// The rendered prefix must be the one the live server reports.
	got, err := exec.Command("tmux", "-L", socket, "show", "-gv", "prefix").Output()
	if err != nil {
		t.Fatalf("show prefix: %v", err)
	}
	if want := s.Prefix; strings.TrimSpace(string(got)) != want {
		t.Fatalf("live prefix = %q, want %q", strings.TrimSpace(string(got)), want)
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
