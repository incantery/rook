package spendfile

import (
	"path/filepath"
	"testing"
	"time"
)

func TestAddAndTotals(t *testing.T) {
	path := filepath.Join(t.TempDir(), "spend.json")
	now := time.Date(2026, 8, 11, 12, 0, 0, 0, time.UTC)
	if err := Add(path, now, 0.002); err != nil {
		t.Fatal(err)
	}
	if err := Add(path, now, 0.003); err != nil {
		t.Fatal(err)
	}
	if err := Add(path, now.Add(-3*24*time.Hour), 0.010); err != nil {
		t.Fatal(err)
	}
	if err := Add(path, now.Add(-10*24*time.Hour), 5.0); err != nil {
		t.Fatal(err)
	}
	today, week := Totals(path, now)
	if today < 0.0049 || today > 0.0051 {
		t.Fatalf("today %f want 0.005", today)
	}
	if week < 0.0149 || week > 0.0151 {
		t.Fatalf("week %f want 0.015 (the 10-day-old entry is outside the window)", week)
	}
	// Zero-cost calls (local models) never touch the file.
	if err := Add("", now, 0.1); err != nil {
		t.Fatal(err)
	}
}
