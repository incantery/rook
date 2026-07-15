package host

import (
	"encoding/json"
	"os"
	"testing"
)

func selfPID() int { return os.Getpid() }

func TestRoleOf(t *testing.T) {
	const webkit = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
	cases := []struct {
		comm, coder, want string
	}{
		{"/Applications/rook.app/Contents/MacOS/rook", "claude", "app"},
		{"/Applications/rook.app/Contents/MacOS/rook-host", "claude", "host"},
		{"/Users/x/go/bin/rook-agent", "claude", "agent"},
		{webkit, "claude", "webkit"},
		// the .Development variant is still WebKit — matched on the framework
		// path, not the leaf, so debug builds are not silently uncounted
		{"/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.Development.xpc/Contents/MacOS/com.apple.WebKit.WebContent.Development", "claude", "webkit"},
		{"claude", "claude", "coder"},
		{"/opt/homebrew/bin/claude", "claude", "coder"},
		// a configured coder other than claude is what counts
		{"/usr/local/bin/aider", "aider", "coder"},
		{"claude", "aider", ""},
		// everything else on the machine is not rook's business
		{"/usr/bin/ssh", "claude", ""},
		{"/sbin/launchd", "claude", ""},
		// an empty coder must not swallow unrelated processes
		{"/usr/bin/ssh", "", ""},
	}
	for _, c := range cases {
		if got := roleOf(c.comm, c.coder); got != c.want {
			t.Errorf("roleOf(%q, coder=%q) = %q, want %q", c.comm, c.coder, got, c.want)
		}
	}
}

func TestSampleLabelJSONIsStable(t *testing.T) {
	// Series identity is the label string: if key order wobbled, one series
	// would split into many and every chart would lie.
	s := sample{Metric: "m", Labels: map[string]string{"role": "host", "map": "binds", "a": "1"}}
	first := s.labelJSON()
	for range 20 {
		if got := s.labelJSON(); got != first {
			t.Fatalf("label json unstable: %q vs %q", got, first)
		}
	}
	var back map[string]string
	if err := json.Unmarshal([]byte(first), &back); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if back["role"] != "host" || back["map"] != "binds" {
		t.Fatalf("round trip lost labels: %v", back)
	}
	if (sample{Metric: "m"}).labelJSON() != "" {
		t.Error("no labels must encode as empty, not null")
	}
}

func TestSampleProcsParsesRealTable(t *testing.T) {
	// The format is ps's, not ours — parse the live table and assert we can
	// find ourselves in it.
	tbl, err := sampleProcs()
	if err != nil {
		t.Fatalf("sampleProcs: %v", err)
	}
	if len(tbl) < 2 {
		t.Fatalf("implausible process table: %d rows", len(tbl))
	}
	self, ok := tbl[selfPID()]
	if !ok {
		t.Fatal("the test process is missing from its own process table")
	}
	if self.RSS <= 0 {
		t.Errorf("self RSS = %d, want > 0", self.RSS)
	}
	if self.Comm == "" {
		t.Error("self comm is empty")
	}
	if self.PPID <= 0 {
		t.Errorf("self PPID = %d, want > 0", self.PPID)
	}
}

func TestProcTableCachesWithinTTL(t *testing.T) {
	pt := newProcTable()
	first := pt.current()
	if len(first) == 0 {
		t.Fatal("empty table")
	}
	at := pt.at
	// a second read inside the TTL must not re-fork ps
	pt.current()
	if !pt.at.Equal(at) {
		t.Error("table refreshed inside the TTL — the fork-per-call this replaces is back")
	}
}

func TestMapSizesCoversEveryLongLivedMap(t *testing.T) {
	// If a new long-lived map is added to Host without a gauge, the leak it
	// can hide is invisible — this is the reminder.
	h := &Host{
		sessions: map[string]*session{},
		cwdCache: map[int]cwdEntry{},
		claims:   map[string]string{},
		binds:    map[string]string{},
		drafts:   map[string]draftInfo{},
	}
	h.cwdCache[42] = cwdEntry{}
	h.binds["t"] = "s"
	got := h.mapSizes()
	for _, want := range []string{"sessions", "cwd_cache", "claims", "binds", "drafts"} {
		if _, ok := got[want]; !ok {
			t.Errorf("mapSizes missing %q", want)
		}
	}
	if got["cwd_cache"] != 1 || got["binds"] != 1 || got["sessions"] != 0 {
		t.Errorf("mapSizes wrong: %v", got)
	}
}
