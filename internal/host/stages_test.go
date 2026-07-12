package host

import (
	"strings"
	"testing"
)

// The stage lifecycle's guards ARE the design: seed-once is the trigger
// dedup, pending→running→done/error transitions refuse to fire twice.
func TestStagesCRUD(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	r := loadRegistry()

	seeded, err := r.insertStages("ws", []string{"/security-review", "/review"})
	if err != nil || !seeded {
		t.Fatalf("first seed: %v %v", seeded, err)
	}
	// the dedup source of truth: existing rows make reseeding a no-op
	seeded, err = r.insertStages("ws", []string{"/other"})
	if err != nil || seeded {
		t.Fatalf("reseed must no-op: %v %v", seeded, err)
	}
	st := r.stagesFor("ws")
	if len(st) != 2 || st[0].Name != "/security-review" || st[1].Name != "/review" ||
		st[0].Status != "pending" || st[1].Status != "pending" {
		t.Fatalf("seeded rows: %+v", st)
	}

	if !r.startStage(st[0].ID, "s1") {
		t.Fatal("start pending must succeed")
	}
	if r.startStage(st[0].ID, "s2") {
		t.Fatal("double start must fail")
	}
	run := r.runningStage("ws")
	if run == nil || run.ID != st[0].ID || run.RookSession != "s1" {
		t.Fatalf("runningStage: %+v", run)
	}

	if r.finishStage(st[1].ID, "done", "") {
		t.Fatal("finishing a pending row must fail")
	}
	if !r.finishStage(st[0].ID, "done", "") {
		t.Fatal("finish running must succeed")
	}
	if r.finishStage(st[0].ID, "error", "again") {
		t.Fatal("double finish must fail")
	}
	if r.runningStage("ws") != nil {
		t.Fatal("nothing should be running")
	}

	// restart reconciliation errors every running stage, touches nothing else
	r.startStage(st[1].ID, "s2")
	r.failRunningStages("host restarted — window lost")
	rows := r.stagesFor("ws")
	if rows[0].Status != "done" {
		t.Fatalf("done row must survive reconciliation: %+v", rows[0])
	}
	if rows[1].Status != "error" || !strings.Contains(rows[1].Detail, "restarted") {
		t.Fatalf("running row must error with the detail: %+v", rows[1])
	}

	r.deleteStages("ws")
	if len(r.stagesFor("ws")) != 0 {
		t.Fatal("deleteStages must drop the pipeline")
	}
	// a deleted pipeline frees the workspace for a fresh seed (next PR cycle)
	if seeded, _ = r.insertStages("ws", []string{"/review"}); !seeded {
		t.Fatal("reseed after delete must work")
	}
}
