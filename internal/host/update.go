package host

import (
	"net/http"
	"time"

	"github.com/incantery/rook/internal/selfupdate"
	"github.com/incantery/rook/internal/version"
)

// The update indicator's data: is a newer release published than the binary
// serving this? The host owns the check so every client (the webview today,
// a native shell someday) reads one cached answer instead of each polling
// GitHub on its own schedule.

type UpdateStatus struct {
	Current   string `json:"current"`
	Latest    string `json:"latest,omitempty"`
	Available bool   `json:"available"`
}

// runUpdateCheck polls GitHub's latest-release tag on a slow cadence and
// caches it. Dev builds never check: "newer than dev" is meaningless
// (rookctl update refuses to overwrite them for the same reason), and it
// keeps sandboxed hosts — the e2e suite runs a real daemon — from calling
// out to the network.
func (h *Host) runUpdateCheck() {
	if version.Version == "dev" {
		return
	}
	// first check shortly after boot — attach replay and the first polls
	// own the boot window
	t := time.NewTimer(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-h.ctx.Done():
			return
		case <-t.C:
		}
		// errors keep the last known answer — the indicator fails open to
		// silence, never to a false "update available"
		if rel, err := selfupdate.Latest(); err == nil {
			h.updMu.Lock()
			h.latestTag = rel.Tag
			h.updMu.Unlock()
		}
		t.Reset(6 * time.Hour)
	}
}

// handleUpdate is GET /update: the cached release check.
func (h *Host) handleUpdate(w http.ResponseWriter, _ *http.Request) {
	h.updMu.Lock()
	latest := h.latestTag
	h.updMu.Unlock()
	writeJSON(w, UpdateStatus{
		Current:   version.Version,
		Latest:    latest,
		Available: latest != "" && latest != version.Version && version.Version != "dev",
	})
}
