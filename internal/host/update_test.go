package host

import (
	"encoding/json"
	"net/http/httptest"
	"testing"

	"github.com/incantery/rook/internal/version"
)

// The indicator's contract: a dev build never claims an update (and never
// checked — runUpdateCheck exits immediately on "dev"), a stamped build
// flags only a tag that differs from its own, and an empty cache (check
// not yet run, or GitHub unreachable) reads as no update.
func TestUpdateStatus(t *testing.T) {
	h := &Host{}
	orig := version.Version
	defer func() { version.Version = orig }()

	get := func() UpdateStatus {
		rec := httptest.NewRecorder()
		h.handleUpdate(rec, httptest.NewRequest("GET", "/update", nil))
		var st UpdateStatus
		if err := json.NewDecoder(rec.Body).Decode(&st); err != nil {
			t.Fatalf("decode: %v", err)
		}
		return st
	}

	version.Version = "dev"
	h.latestTag = "v9.9.9"
	if st := get(); st.Available {
		t.Fatalf("dev build must never flag an update: %+v", st)
	}

	version.Version = "v0.1.0"
	h.latestTag = ""
	if st := get(); st.Available {
		t.Fatalf("empty cache must read as up to date: %+v", st)
	}

	h.latestTag = "v0.2.0"
	st := get()
	if !st.Available || st.Latest != "v0.2.0" || st.Current != "v0.1.0" {
		t.Fatalf("newer tag must flag: %+v", st)
	}

	h.latestTag = "v0.1.0"
	if st := get(); st.Available {
		t.Fatalf("matching tag must read as up to date: %+v", st)
	}
}
