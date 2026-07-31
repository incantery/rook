package cloud

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// New returning nil is the whole "not configured" mechanism — every call
// site is a nil check, so anything that would produce a half-wired client
// has to produce nil instead. A base URL that isn't one is the case worth
// stating: a typo'd config must disable the feature, not point posts at a
// relative path.
func TestNewRefusesAnythingUnusable(t *testing.T) {
	for _, tc := range []struct {
		name, base, token string
		want              bool // want a client
	}{
		{"configured", "https://api.rookide.com", "tok", true},
		{"trailing slash and padding", "  https://api.rookide.com/ ", " tok ", true},
		{"no url", "", "tok", false},
		{"no token", "https://api.rookide.com", "", false},
		{"token is whitespace", "https://api.rookide.com", "   ", false},
		{"not a url", "api.rookide.com", "tok", false},
		{"scheme without host", "https://", "tok", false},
	} {
		c := New(tc.base, tc.token)
		if (c != nil) != tc.want {
			t.Errorf("%s: New(%q, %q) = %v, want client: %v", tc.name, tc.base, tc.token, c, tc.want)
		}
		if c != nil && c.Base() != "https://api.rookide.com" {
			t.Errorf("%s: base not normalized: %q", tc.name, c.Base())
		}
	}
}

func TestPostStatusSendsTheSnapshotAuthenticated(t *testing.T) {
	var gotPath, gotAuth, gotType string
	var body Status
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotAuth = r.URL.Path, r.Header.Get("Authorization")
		gotType = r.Header.Get("Content-Type")
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &body)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	c := New(srv.URL, "machine-tok")
	if c == nil {
		t.Fatal("New returned nil for a live server")
	}
	err := c.PostStatus(context.Background(), Status{
		Hostname:   "workbench.local",
		Workspaces: []Workspace{{Name: "rook", Branch: "main"}},
	})
	if err != nil {
		t.Fatalf("PostStatus: %v", err)
	}
	if gotPath != "/v1/status" {
		t.Errorf("path = %q", gotPath)
	}
	if gotAuth != "Bearer machine-tok" {
		t.Errorf("auth = %q", gotAuth)
	}
	if gotType != "application/json" {
		t.Errorf("content-type = %q", gotType)
	}
	if body.Hostname != "workbench.local" || len(body.Workspaces) != 1 {
		t.Errorf("snapshot arrived wrong: %+v", body)
	}
}

// A refused token has to surface as an error the caller can log, with the
// server's own words in it — "cloud: post status: 401" and nothing else is
// how a revoked machine token becomes an afternoon.
func TestPostStatusReportsServerRefusal(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "machine revoked", http.StatusUnauthorized)
	}))
	defer srv.Close()

	err := New(srv.URL, "stale").PostStatus(context.Background(), Status{})
	if err == nil {
		t.Fatal("want an error for 401")
	}
	if got := err.Error(); !strings.Contains(got, "401") || !strings.Contains(got, "machine revoked") {
		t.Errorf("error loses the server's answer: %q", got)
	}
}

func TestWhoamiResolvesTheMachine(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/whoami" {
			t.Errorf("path = %q", r.URL.Path)
		}
		_, _ = w.Write([]byte(`{"machineId":"m_7","name":"workbench"}`))
	}))
	defer srv.Close()

	id, name, err := New(srv.URL, "tok").Whoami(context.Background())
	if err != nil {
		t.Fatalf("Whoami: %v", err)
	}
	if id != "m_7" || name != "workbench" {
		t.Errorf("got %q/%q", id, name)
	}
}

// The client must not outlive a hung server: the reporter's loop blocks on
// this call, and a tunnel that accepts and never answers would otherwise
// stop the machine reporting until the daemon restarts.
func TestPostStatusHonoursContext(t *testing.T) {
	block := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-block
	}))
	defer srv.Close()
	defer close(block)

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if err := New(srv.URL, "tok").PostStatus(ctx, Status{}); err == nil {
		t.Fatal("want an error when the context expires")
	}
}
