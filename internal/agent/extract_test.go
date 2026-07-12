package agent

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
)

// isolate points the store and cursor at a temp dir.
func isolate(t *testing.T) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	t.Setenv("XDG_STATE_HOME", dir)
}

func TestAppendLearnedCreatesAndPreservesUserContent(t *testing.T) {
	isolate(t)
	if err := os.MkdirAll(strings.TrimSuffix(PreferencesPath(), "/preferences.md"), 0o755); err != nil {
		t.Fatal(err)
	}
	user := "# my prefs\n\n- always squash-merge\n"
	if err := os.WriteFile(PreferencesPath(), []byte(user), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := AppendLearned([]string{"prefer running tests before commits"}); err != nil {
		t.Fatal(err)
	}
	if err := AppendLearned([]string{"never approve force-pushes"}); err != nil {
		t.Fatal(err)
	}

	got := LoadPreferences()
	if !strings.HasPrefix(got, user) {
		t.Fatalf("user content disturbed:\n%s", got)
	}
	if strings.Count(got, learnedHeader) != 1 {
		t.Fatalf("learned section duplicated:\n%s", got)
	}
	for _, want := range []string{"- prefer running tests before commits", "- never approve force-pushes"} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in:\n%s", want, got)
		}
	}
}

func TestAppendLearnedFromScratch(t *testing.T) {
	isolate(t)
	if err := AppendLearned([]string{"prefer yes to running tests"}); err != nil {
		t.Fatal(err)
	}
	got := LoadPreferences()
	if !strings.Contains(got, learnedHeader) || !strings.Contains(got, "- prefer yes to running tests") {
		t.Fatalf("store not created properly:\n%s", got)
	}
}

func TestHasPreferenceNormalizes(t *testing.T) {
	content := "## Learned by the drafter\n- Prefer  running tests before commits.\n"
	if !hasPreference(content, "prefer running tests before commits") {
		t.Error("normalized duplicate not detected")
	}
	if hasPreference(content, "never approve force-pushes") {
		t.Error("false positive")
	}
}

func TestCursorRoundTrip(t *testing.T) {
	isolate(t)
	if got := loadCursor(); got != 0 {
		t.Fatalf("fresh cursor = %d, want 0", got)
	}
	if err := saveCursor(42); err != nil {
		t.Fatal(err)
	}
	if got := loadCursor(); got != 42 {
		t.Fatalf("cursor = %d, want 42", got)
	}
}

// extractHost serves a canned decisions ledger and a spend.
func extractHost(t *testing.T, rows []DecisionRow, spend Spend) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/decisions", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(rows) // newest first, like the host
	})
	mux.HandleFunc("/agent/spend", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(spend)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func fakeExtractAI(t *testing.T, prefs []string) (*httptest.Server, *atomic.Int32) {
	t.Helper()
	var calls atomic.Int32
	content, _ := json.Marshal(Extraction{Preferences: prefs})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		json.NewEncoder(w).Encode(map[string]any{
			"choices": []map[string]any{{"message": map[string]any{"content": string(content)}}},
			"usage":   map[string]any{"prompt_tokens": 500, "completion_tokens": 20},
		})
	}))
	t.Cleanup(srv.Close)
	return srv, &calls
}

var sampleRows = []DecisionRow{
	{ID: 3, Verdict: "edited", Ask: "run the tests?", Action: "draft", Draft: "yes", FinalText: "yes, and lint"},
	{ID: 2, Verdict: "approved", Ask: "continue?", Action: "draft", Draft: "yes", FinalText: "yes"},
	{ID: 1, Verdict: "stale", Ask: "old ask", Action: "draft", Draft: "yes"},
}

func TestExtractAppendsAndAdvancesCursor(t *testing.T) {
	isolate(t)
	host := extractHost(t, sampleRows, Spend{})
	ai, calls := fakeExtractAI(t, []string{"when approving tests, also run lint"})
	a := New(&Client{Endpoint: host.URL, Token: "t", http: http.DefaultClient},
		NewOpenAI("k", "gpt-5.4-nano"), 1.00)
	a.AI.BaseURL = ai.URL

	a.extract(context.Background())

	if calls.Load() != 1 {
		t.Fatalf("openai calls = %d, want 1", calls.Load())
	}
	if got := LoadPreferences(); !strings.Contains(got, "- when approving tests, also run lint") {
		t.Fatalf("preference not appended:\n%s", got)
	}
	if got := loadCursor(); got != 3 {
		t.Fatalf("cursor = %d, want 3", got)
	}

	// Second pass: cursor filters everything → no call, no growth.
	before := LoadPreferences()
	a.extract(context.Background())
	if calls.Load() != 1 {
		t.Fatalf("openai called again with no new verdicts")
	}
	if LoadPreferences() != before {
		t.Fatal("store changed with no new verdicts")
	}
}

// A duplicate the model returns anyway must not be appended twice, but the
// cursor still advances — those rows are spent.
func TestExtractDedupsAgainstStore(t *testing.T) {
	isolate(t)
	if err := AppendLearned([]string{"when approving tests, also run lint"}); err != nil {
		t.Fatal(err)
	}
	host := extractHost(t, sampleRows, Spend{})
	ai, _ := fakeExtractAI(t, []string{"When approving tests, also run lint."})
	a := New(&Client{Endpoint: host.URL, Token: "t", http: http.DefaultClient},
		NewOpenAI("k", "gpt-5.4-nano"), 1.00)
	a.AI.BaseURL = ai.URL

	a.extract(context.Background())

	got := LoadPreferences()
	if strings.Count(strings.ToLower(got), "also run lint") != 1 {
		t.Fatalf("duplicate appended:\n%s", got)
	}
	if loadCursor() != 3 {
		t.Fatalf("cursor = %d, want 3", loadCursor())
	}
}

// Over the daily cap: verdicts wait, nothing is spent.
func TestExtractBudgetGuard(t *testing.T) {
	isolate(t)
	host := extractHost(t, sampleRows, Spend{TodayUSD: 1.50})
	ai, calls := fakeExtractAI(t, []string{"anything"})
	a := New(&Client{Endpoint: host.URL, Token: "t", http: http.DefaultClient},
		NewOpenAI("k", "gpt-5.4-nano"), 1.00)
	a.AI.BaseURL = ai.URL

	a.extract(context.Background())

	if calls.Load() != 0 {
		t.Fatalf("openai called despite blown budget")
	}
	if loadCursor() != 0 {
		t.Fatalf("cursor advanced despite no extraction")
	}
}

// Only decided verdicts feed the pass — a ledger of open/stale rows is not
// worth a model call.
func TestExtractSkipsUndecided(t *testing.T) {
	isolate(t)
	host := extractHost(t, []DecisionRow{
		{ID: 2, Verdict: "open", Ask: "x", Action: "draft", Draft: "yes"},
		{ID: 1, Verdict: "stale", Ask: "y", Action: "draft", Draft: "yes"},
	}, Spend{})
	ai, calls := fakeExtractAI(t, nil)
	a := New(&Client{Endpoint: host.URL, Token: "t", http: http.DefaultClient},
		NewOpenAI("k", "gpt-5.4-nano"), 1.00)
	a.AI.BaseURL = ai.URL

	a.extract(context.Background())

	if calls.Load() != 0 {
		t.Fatalf("openai called for undecided rows")
	}
}
