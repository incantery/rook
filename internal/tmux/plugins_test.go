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

func TestEnsurePluginsRejectsBadSpecs(t *testing.T) {
	for _, spec := range []string{"", "norepo", "a/b/c", "../evil", "owner/../x", "https://x/y"} {
		scripts, warnings := EnsurePlugins([]string{spec})
		if len(scripts) != 0 {
			t.Errorf("spec %q produced scripts %v", spec, scripts)
		}
		if len(warnings) == 0 {
			t.Errorf("spec %q produced no warning", spec)
		}
	}
}

// TestRunShellExecutesPluginScript proves the wiring end to end with
// tmux as the oracle: a stub plugin script marks the server when it
// runs, and the booted server must carry the mark.
func TestRunShellExecutesPluginScript(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not on PATH")
	}
	dir := t.TempDir()
	script := filepath.Join(dir, "probe.tmux")
	if err := os.WriteFile(script, []byte("#!/bin/sh\ntmux set -g @rook_probe loaded\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	s := Defaults()
	s.PluginScripts = []string{script}
	conf := filepath.Join(dir, "tmux.conf")
	if err := os.WriteFile(conf, []byte(s.Render(conf)), 0o644); err != nil {
		t.Fatal(err)
	}

	socket := fmt.Sprintf("rook-test-plugin-%d", os.Getpid())
	defer exec.Command("tmux", "-L", socket, "kill-server").Run()

	boot := exec.Command("tmux", "-L", socket, "-f", conf, "new-session", "-d", "-s", "probe")
	boot.Env = append(os.Environ(), "TMUX=")
	if out, err := boot.CombinedOutput(); err != nil {
		t.Fatalf("boot failed: %v\n%s", err, out)
	}

	// run-shell is asynchronous; poll briefly.
	deadline := time.Now().Add(3 * time.Second)
	for {
		out, err := exec.Command("tmux", "-L", socket, "show", "-gv", "@rook_probe").Output()
		if err == nil && strings.TrimSpace(string(out)) == "loaded" {
			return
		}
		if time.Now().After(deadline) {
			msgs, _ := exec.Command("tmux", "-L", socket, "show-messages").CombinedOutput()
			t.Fatalf("plugin script never ran; server messages:\n%s", msgs)
		}
		time.Sleep(50 * time.Millisecond)
	}
}
