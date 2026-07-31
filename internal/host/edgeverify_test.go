package host

// The gate's contract: it runs what the USER named and nothing else, and
// the three statuses stay distinct — a suite that ran and failed is a
// verdict, a suite this device will not run is a refusal.

import (
	"crypto/ed25519"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"google.golang.org/protobuf/types/known/timestamppb"

	edgev1 "github.com/incantery/rook/gen/rook/edge/v1"
	"github.com/incantery/rook/internal/edgesign"
)

// withSuites rewrites the config newEdgeHost planted, keeping its coder
// line so nothing in this file can start a real one.
func withSuites(t *testing.T, lines string) {
	t.Helper()
	p := filepath.Join(os.Getenv("XDG_CONFIG_HOME"), "rook", "config")
	if err := os.WriteFile(p, []byte("coder = /usr/bin/true\n"+lines), 0o644); err != nil {
		t.Fatal(err)
	}
}

func verifyCmd(t *testing.T, priv ed25519.PrivateKey, id, run, suite string) *edgev1.EdgeCommand {
	t.Helper()
	return edgeCmd(t, priv, id, run, "run_verification",
		&edgev1.RunVerification{WorktreeId: "worktree_" + run, Suite: suite}, nil)
}

func TestEdgeRunVerification(t *testing.T) {
	h, _ := newEdgeHost(t)
	pub, priv, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	run := "wfr_verify_1"
	name := edgeWorkspaceName(run)
	if status, result := h.edgeExecuteOne(edgeCmd(t, priv, "cmd_c", run, "create_worktree",
		&edgev1.CreateWorktree{Repository: "src", BaseRef: "main"}, nil), pub, false); status != "succeeded" {
		t.Fatalf("create: %s %s", status, result)
	}

	// Nothing configured: the refusal says so, and says what to do.
	status, result := h.edgeExecuteOne(verifyCmd(t, priv, "cmd_v0", run, "go-test"), pub, false)
	if status != "rejected" || !strings.Contains(result, "none are configured") {
		t.Fatalf("unconfigured device: %s %s", status, result)
	}

	withSuites(t, "verify-green = echo all good\nverify-red = echo boom >&2; exit 3\nverify-pwd = pwd\n")

	// A suite that passes.
	status, result = h.edgeExecuteOne(verifyCmd(t, priv, "cmd_v1", run, "green"), pub, false)
	if status != "succeeded" {
		t.Fatalf("green: %s %s", status, result)
	}
	var res struct {
		Suite    string `json:"suite"`
		Passed   bool   `json:"passed"`
		ExitCode int    `json:"exitCode"`
		Output   string `json:"output"`
		Command  string `json:"command"`
	}
	if err := json.Unmarshal([]byte(result), &res); err != nil {
		t.Fatal(err)
	}
	if !res.Passed || res.ExitCode != 0 || !strings.Contains(res.Output, "all good") {
		t.Fatalf("receipt: %+v", res)
	}

	// A suite that RAN and did not pass is failed, not rejected — the run
	// routes a verdict to the supervisor and a refusal to a human, so the
	// two must not collapse. Its last words ride back for whoever reads.
	status, result = h.edgeExecuteOne(verifyCmd(t, priv, "cmd_v2", run, "red"), pub, false)
	if status != "failed" {
		t.Fatalf("red: %s %s", status, result)
	}
	if err := json.Unmarshal([]byte(result), &res); err != nil {
		t.Fatal(err)
	}
	if res.Passed || res.ExitCode != 3 || !strings.Contains(res.Output, "boom") {
		t.Fatalf("receipt: %+v", res)
	}

	// It runs IN the run's worktree, not wherever the host happens to be.
	if _, result = h.edgeExecuteOne(verifyCmd(t, priv, "cmd_v3", run, "pwd"), pub, false); true {
		if err := json.Unmarshal([]byte(result), &res); err != nil {
			t.Fatal(err)
		}
		if got := strings.TrimSpace(res.Output); !strings.HasSuffix(got, worktreeDir(name)) {
			t.Fatalf("cwd: %q, want the run's worktree %q", got, worktreeDir(name))
		}
	}

	// A suite the device does not have is a refusal that names what it
	// does — a definition pinned against another machine is readable from
	// the run's record.
	status, result = h.edgeExecuteOne(verifyCmd(t, priv, "cmd_v4", run, "cargo-test"), pub, false)
	if status != "rejected" || !strings.Contains(result, "cargo-test") || !strings.Contains(result, "green") {
		t.Fatalf("unknown suite: %s %s", status, result)
	}

	// No worktree for the run: refused before anything executes.
	status, result = h.edgeExecuteOne(verifyCmd(t, priv, "cmd_v5", "wfr_nothing", "green"), pub, false)
	if status != "rejected" || !strings.Contains(result, "create_worktree") {
		t.Fatalf("no worktree: %s %s", status, result)
	}
}

// A suite that outlives the cloud's own patience is stopped and reported
// as unfinished — which is not a verdict on the code, and must not read
// like one.
func TestEdgeRunVerificationDeadline(t *testing.T) {
	h, _ := newEdgeHost(t)
	pub, priv, err := edgesign.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	run := "wfr_verify_slow"
	if status, result := h.edgeExecuteOne(edgeCmd(t, priv, "cmd_c", run, "create_worktree",
		&edgev1.CreateWorktree{Repository: "src", BaseRef: "main"}, nil), pub, false); status != "succeeded" {
		t.Fatalf("create: %s %s", status, result)
	}
	withSuites(t, "verify-slow = sleep 30\n")

	slow := verifyCmd(t, priv, "cmd_slow", run, "slow")
	slow.ExpiresAt = timestamppb.New(time.Now().Add(500 * time.Millisecond))
	edgesign.SignCommand(priv, slow)

	started := time.Now()
	status, result := h.edgeExecuteOne(slow, pub, false)
	if elapsed := time.Since(started); elapsed > 10*time.Second {
		t.Fatalf("the deadline must bound the run: %s", elapsed)
	}
	if status != "failed" || !strings.Contains(result, "did not finish") {
		t.Fatalf("slow suite: %s %s", status, result)
	}
}
