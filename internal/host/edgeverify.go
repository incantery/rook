package host

// run_verification: the gate that decides whether an agent's completion
// CLAIM was true. §19.4 states the rule this file exists to keep — agent
// completion text alone cannot finish a step — so the claim routes here,
// and what lands in the run's record is an exit status, not a sentence.
//
// The whole design is about who chooses the argv.
//
// The cloud names a SUITE and never a command line (§11.2). The device
// resolves that name from the USER's config ([verify] — see
// Config.Verify), and a name it does not know is refused. So the set of
// programs a remote run can execute here is exactly the set the person
// at this machine wrote down, and it cannot be grown from away: not by
// the cloud, which has no vocabulary for argv, and not by a repository,
// because a `.rook/config` arrives by git clone and the repo layer is
// stopped before it reaches any key but lsp*. That bound is load-bearing
// rather than incidental — without it, cloning a repo would be running
// it.
//
// There are deliberately NO built-in suites. A device that shipped with
// `go test ./...` would run it in a tree the user never pointed at, and
// the refusal for an unconfigured suite says what to add instead, which
// is the better first experience than a command nobody asked for.
//
// Two honest limitations, both stated rather than hidden. The executor
// is serial (edgeExecutePending), so a long suite holds every command
// behind it — including an interrupt for a runaway agent; the deadline
// below is what bounds that, and it comes from the cloud's own expiry.
// And a suite runs with the host's environment and the user's PATH: this
// is the user's machine running the user's command, not a sandbox.

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	edgev1 "github.com/incantery/rook/gen/rook/edge/v1"
	"github.com/incantery/rook/internal/config"
)

const (
	// verifyMaxRun caps a suite even when the cloud would wait longer
	// (its commandTTL is hours). The executor is serial, so this is the
	// device's own guard on how long one step may hold the queue.
	verifyMaxRun = 15 * time.Minute
	// verifyOutputTail is how much of the suite's output rides back in
	// the receipt. A failure's last words are what a supervisor reads;
	// the whole log is not a receipt's job.
	verifyOutputTail = 8 << 10
	// verifyLogName is where the WHOLE output is kept, in the artifact
	// store beside the run's other evidence. It is what makes the tail
	// above honest rather than lossy: collect_artifact can declare the
	// full log (kind test_log) whenever the run wants it, and truncating
	// the receipt costs nothing that cannot be asked for.
	verifyLogName = "verification.log"
)

// edgeRunVerification runs a named suite in the run's worktree.
//
// The status vocabulary matters more here than anywhere else in the edge
// surface, because two of the three mean opposite things to a run:
//
//	rejected  the device would not run it — unknown suite, no worktree
//	failed    it RAN and did not pass; this is a verdict, not an error
//	succeeded it ran and passed
//
// A run routes a failed gate to the supervisor and a rejected one to a
// human. Collapsing them would send every misconfiguration to the
// supervisor as if the code were broken.
//
// It converges by being re-runnable, which is also what the cloud's own
// retry_verification action assumes: the same tree and the same suite
// give the same verdict, and a device restart mid-suite just runs it
// again.
func (h *Host) edgeRunVerification(cmd *edgev1.EdgeCommand, p *edgev1.RunVerification) (string, string) {
	suites := config.Load().Verify
	line := strings.TrimSpace(suites[p.Suite])
	if line == "" {
		return "rejected", edgeReason(fmt.Sprintf(
			"no verification suite named %q on this device%s", p.Suite, verifyOffered(suites)))
	}
	name := edgeWorkspaceName(cmd.WorkflowRunId)
	ws := h.reg.get(name)
	if ws == nil || ws.Root == "" {
		return "rejected", edgeReason(fmt.Sprintf(
			"no worktree for run %s on this device — create_worktree has not succeeded here", cmd.WorkflowRunId))
	}

	// The cloud already decided how long it is willing to wait; the
	// device's own cap is the shorter of that and verifyMaxRun.
	deadline := time.Now().Add(verifyMaxRun)
	if cmd.ExpiresAt != nil && cmd.ExpiresAt.AsTime().Before(deadline) {
		deadline = cmd.ExpiresAt.AsTime()
	}
	ctx, cancel := context.WithDeadline(h.ctx, deadline)
	defer cancel()

	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/zsh"
	}
	log.Printf("edge: verifying %s in %s: %s", p.Suite, name, line)
	started := time.Now()
	run := exec.CommandContext(ctx, shell, "-c", line)
	run.Dir = ws.Root
	// One stream, in the order it was written: interleaving is how a
	// test log reads, and splitting it would only make the tail lie
	// about what happened last.
	out, err := run.CombinedOutput()
	elapsed := time.Since(started)
	// Keep the whole thing where the run's evidence lives. Best-effort:
	// a suite that ran and cannot be logged still has a verdict, and
	// losing the verdict over the log would be the wrong trade.
	if dir := edgeArtifactDir(name); os.MkdirAll(dir, 0o700) == nil {
		if werr := os.WriteFile(filepath.Join(dir, verifyLogName), out, 0o600); werr != nil {
			log.Printf("edge: could not keep %s's log: %v", p.Suite, werr)
		}
	}

	res := map[string]any{
		"suite":     p.Suite,
		"worktree":  name,
		"command":   line,
		"seconds":   int(elapsed.Seconds()),
		"exitCode":  run.ProcessState.ExitCode(),
		"output":    lastBytes(out, verifyOutputTail),
		"truncated": len(out) > verifyOutputTail,
	}
	switch {
	case ctx.Err() != nil:
		// A timeout is not a verdict on the code: the suite never
		// finished, so it never said anything about the claim.
		res["passed"], res["reason"] = false,
			fmt.Sprintf("suite %q did not finish within %s", p.Suite, deadline.Sub(started).Round(time.Second))
	case err != nil:
		res["passed"], res["reason"] = false, err.Error()
	default:
		res["passed"] = true
	}
	data, _ := json.Marshal(res)
	if res["passed"] == true {
		log.Printf("edge: %s passed in %s", p.Suite, elapsed.Round(time.Second))
		return "succeeded", string(data)
	}
	log.Printf("edge: %s did not pass in %s: %v", p.Suite, elapsed.Round(time.Second), err)
	return "failed", string(data)
}

// verifyOffered names what this device does have, so a mismatch between
// the pinned definition and the machine is readable from the run's
// record — and says how to fix it when there is nothing to name.
func verifyOffered(suites map[string]string) string {
	if len(suites) == 0 {
		return " (none are configured — add a [verify] suite to rook's config)"
	}
	return " (offered: " + strings.Join(sortedKeys(suites), ", ") + ")"
}

// lastBytes keeps the TAIL: a suite that fails says why at the end.
func lastBytes(b []byte, n int) string {
	if len(b) <= n {
		return string(b)
	}
	return "…" + string(b[len(b)-n:])
}
