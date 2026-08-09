package cmdjournal

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// TestHelperProcess is not a test: it is the OTHER PROCESS. The
// cross-process tests re-invoke this test binary with CMDJOURNAL_HELPER
// set, and this function plays the second rail — its own Open, its own
// flock, a real fork boundary between its memory and the caller's.
func TestHelperProcess(t *testing.T) {
	if os.Getenv("CMDJOURNAL_HELPER") != "1" {
		return
	}
	path := os.Getenv("CMDJOURNAL_PATH")
	key := os.Getenv("CMDJOURNAL_KEY")
	l, err := Open(path, 7*24*time.Hour, time.Now())
	if err != nil {
		fmt.Fprintln(os.Stderr, "helper open:", err)
		os.Exit(1)
	}
	switch os.Getenv("CMDJOURNAL_OP") {
	case "deliver":
		l.MarkDelivered(key)
	case "fail":
		fmt.Println(l.Failed(key))
	default:
		fmt.Fprintln(os.Stderr, "helper: unknown op")
		os.Exit(1)
	}
	os.Exit(0)
}

func runHelper(t *testing.T, path, op, key string) string {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=TestHelperProcess")
	cmd.Env = append(os.Environ(),
		"CMDJOURNAL_HELPER=1",
		"CMDJOURNAL_PATH="+path,
		"CMDJOURNAL_OP="+op,
		"CMDJOURNAL_KEY="+key,
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("helper process: %v\n%s", err, out)
	}
	return string(out)
}

// The promise the flock + reload exist for: the cloud bridge and the
// link server hold the SAME journal open at once. When process A types
// an answer and marks it delivered, process B — already open, never
// reopened — must refuse to type it again.
func TestDeliveryVisibleAcrossLiveProcesses(t *testing.T) {
	path := filepath.Join(t.TempDir(), "d.jsonl")

	b := openAt(t, path, time.Now()) // B opens FIRST, before A writes
	if b.Delivered("ask_x") {
		t.Fatal("a fresh journal claims a delivery")
	}

	runHelper(t, path, "deliver", "ask_x") // A: a whole other process

	if !b.Delivered("ask_x") {
		t.Error("B cannot see A's delivery without reopening — a redelivered answer would type twice")
	}
	if b.Delivered("ask_y") {
		t.Error("an untouched key came back delivered")
	}
}

// The retry budget is shared too: both rails burning tries at the same
// dead pane spend one budget, not two fresh ones.
func TestAttemptsAreSharedAcrossProcesses(t *testing.T) {
	path := filepath.Join(t.TempDir(), "d.jsonl")

	b := openAt(t, path, time.Now())
	if got := b.Failed("cmd:dead"); got != 1 {
		t.Fatalf("first failure counted %d", got)
	}

	if out := runHelper(t, path, "fail", "cmd:dead"); out != "2\n" {
		t.Errorf("the other process got a fresh budget: counted %q, want 2", out)
	}

	if got := b.Failed("cmd:dead"); got != 3 {
		t.Errorf("B's next failure counted %d, want 3 — A's try was lost", got)
	}
}

// Two handles in ONE process (the flock contends between fds, not just
// pids): a mark through one is the truth through the other, and a
// Forget in one process must not resurrect on reload.
func TestTwoHandlesOneFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "d.jsonl")
	a := openAt(t, path, time.Now())
	b := openAt(t, path, time.Now())

	a.MarkDelivered("k1")
	if !b.Delivered("k1") {
		t.Error("second handle does not see the first's delivery")
	}

	b.Failed("k2")
	a.Forget("k2")
	if _, ok := a.state["k2"]; ok {
		t.Error("Forget did not drop the key")
	}
	b.MarkDelivered("k3") // changes the file; a's next read reloads
	if !a.Delivered("k3") {
		t.Error("reload missed a fresh delivery")
	}
	if a.Delivered("k2") || a.state["k2"].Attempts != 0 {
		t.Error("a forgotten key came back from the shared file")
	}
}
