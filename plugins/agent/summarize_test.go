package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/incantery/rook/plugins/internal/transcript"
)

var t0 = time.Date(2026, 8, 3, 21, 0, 0, 0, time.UTC)

// ---- the shape guard ----

func TestParseDigestAcceptsTheAskedShape(t *testing.T) {
	h, b, err := parseDigest("The build passes and v0.42.0 is released.\n- Relaunch rook to pick up the new binary.\n- Apply the pending config after the relaunch.")
	if err != nil {
		t.Fatal(err)
	}
	if h != "The build passes and v0.42.0 is released." {
		t.Fatalf("headline: %q", h)
	}
	if len(b) != 2 || b[0] != "Relaunch rook to pick up the new binary." {
		t.Fatalf("bullets: %v", b)
	}
}

func TestParseDigestToleratesUnicodeBulletsAndBlankLines(t *testing.T) {
	h, b, err := parseDigest("Done.\n\n• One thing.\n\n• Another thing.\n")
	if err != nil {
		t.Fatal(err)
	}
	if h != "Done." || len(b) != 2 {
		t.Fatalf("h=%q b=%v", h, b)
	}
}

func TestParseDigestRejectsWhatBrokeTheContract(t *testing.T) {
	long := strings.Repeat("word ", maxHeadlineWords+1)
	cases := map[string]string{
		"bullet first":     "- no headline came",
		"headline too big": long,
		"bullet too big":   "Fine.\n- " + strings.Repeat("word ", maxBulletWords+1),
		"too many bullets": "Fine.\n" + strings.Repeat("- a bullet\n", maxBullets+1),
		"prose after":      "Fine.\n- a bullet\nand then it kept talking",
		"empty":            "  \n ",
	}
	for name, in := range cases {
		if _, _, err := parseDigest(in); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestFallbackDigestNeverComesBackEmptyHanded(t *testing.T) {
	h, b := fallbackDigest("Way too long a headline that would never pass the guard but is all we have.\nsome prose\n- one real bullet")
	if h == "" || len(b) != 1 {
		t.Fatalf("h=%q b=%v", h, b)
	}
}

// ---- pricing ----

func TestPriceMatchesByLongestPrefix(t *testing.T) {
	in, out, ok := price("gpt-5-mini-2025-08-07")
	if !ok || in != 0.25 || out != 2.00 {
		t.Fatalf("gpt-5-mini dated: %v %v %v", in, out, ok)
	}
	in, _, ok = price("gpt-5-2025-08-07")
	if !ok || in != 1.25 {
		t.Fatalf("bare gpt-5 must not take the mini price: %v %v", in, ok)
	}
	if _, _, ok = price("o3-mini"); ok {
		t.Fatal("unknown model priced — a made-up number in a MONEY field")
	}
}

// ---- the trigger edge ----

func TestShouldSummarizeOnlyOnAFinishedWatchedTurn(t *testing.T) {
	W, B, N, I := transcript.StateWorking, transcript.StateBlocked, transcript.StateNeedsYou, transcript.StateIdle
	cases := []struct {
		name     string
		baseline bool
		old, cur transcript.State
		words    int
		want     bool
	}{
		{"working to needs-you", false, W, N, 500, true},
		{"blocked to needs-you", false, B, N, 500, true},
		{"baseline pass never spends", true, W, N, 500, false},
		{"idle to needs-you is history", false, I, N, 500, false},
		{"still working", false, W, W, 500, false},
		{"short reply", false, W, N, 50, false},
	}
	for _, c := range cases {
		if got := shouldSummarize(c.baseline, c.old, c.cur, c.words, 120); got != c.want {
			t.Errorf("%s: got %v", c.name, got)
		}
	}
}

// ---- the API round trip, against a stub ----

func stubSession() transcript.Session {
	return transcript.Session{
		ID:       "sess1",
		Title:    "pane-dim release",
		Prompt:   "ship it",
		Cwd:      "/tmp/x",
		LastText: strings.Repeat("many words of verbose reply ", 40),
	}
}

func completion(content string, in, out int) string {
	b, _ := json.Marshal(map[string]any{
		"choices": []map[string]any{{"message": map[string]any{"content": content}}},
		"usage":   map[string]int{"prompt_tokens": in, "completion_tokens": out},
	})
	return string(b)
}

func TestSummarizeHappyPathPricesFromUsage(t *testing.T) {
	var gotBody map[string]any
	var auth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		json.Unmarshal(raw, &gotBody)
		auth = r.Header.Get("Authorization")
		io.WriteString(w, completion("It shipped.\n- Relaunch rook.", 1000, 100))
	}))
	defer srv.Close()
	z := &Summarizer{Client: srv.Client(), Base: srv.URL, Key: "sk-test", Model: "gpt-5-mini", Effort: "low", MaxChars: 16000}
	d := z.Summarize(stubSession(), t0)
	if d.Err != "" {
		t.Fatal(d.Err)
	}
	if d.Headline != "It shipped." || len(d.Bullets) != 1 {
		t.Fatalf("digest: %+v", d)
	}
	// 1000 in at $0.25/M + 100 out at $2/M.
	if want := 0.25*1000/1e6 + 2.0*100/1e6; d.CostUSD != want {
		t.Fatalf("cost %v want %v", d.CostUSD, want)
	}
	if auth != "Bearer sk-test" {
		t.Fatalf("auth: %q", auth)
	}
	if gotBody["model"] != "gpt-5-mini" || gotBody["reasoning_effort"] != "low" {
		t.Fatalf("body: %v", gotBody)
	}
	if d.ID != "sess1:"+shortHash(stubSession().LastText) {
		t.Fatalf("id must be stable per reply text: %q", d.ID)
	}
}

func TestSummarizeRetriesOnceOnAShapeBreakAndSumsTheBill(t *testing.T) {
	calls := 0
	var second []chatMsg
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			io.WriteString(w, completion(strings.Repeat("word ", maxHeadlineWords+5), 100, 10))
			return
		}
		var body struct {
			Messages []chatMsg `json:"messages"`
		}
		raw, _ := io.ReadAll(r.Body)
		json.Unmarshal(raw, &body)
		second = body.Messages
		io.WriteString(w, completion("Short now.\n- One bullet.", 100, 10))
	}))
	defer srv.Close()
	z := &Summarizer{Client: srv.Client(), Base: srv.URL, Key: "k", Model: "gpt-5-mini"}
	d := z.Summarize(stubSession(), t0)
	if calls != 2 {
		t.Fatalf("calls: %d", calls)
	}
	if d.Headline != "Short now." {
		t.Fatalf("headline: %q", d.Headline)
	}
	// The correction rides the same conversation: the model's own failure
	// is in the transcript it corrects from.
	if len(second) != 4 || second[2].Role != "assistant" || !strings.Contains(second[3].Content, "Rewrite") {
		t.Fatalf("retry conversation: %+v", second)
	}
	if want := 2 * (0.25*100/1e6 + 2.0*10/1e6); d.CostUSD != want {
		t.Fatalf("both calls must bill: %v want %v", d.CostUSD, want)
	}
}

func TestSummarizeTakesTheFallbackWhenTheRetryBreaksToo(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, completion("A headline that is fine.\nprose that is not a bullet", 10, 10))
	}))
	defer srv.Close()
	z := &Summarizer{Client: srv.Client(), Base: srv.URL, Key: "k", Model: "gpt-5-mini"}
	d := z.Summarize(stubSession(), t0)
	if d.Err != "" || d.Headline != "A headline that is fine." {
		t.Fatalf("fallback: %+v", d)
	}
}

func TestSummarizeReportsTheAPIsOwnWords(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(429)
		io.WriteString(w, `{"error":{"message":"rate limit exceeded"}}`)
	}))
	defer srv.Close()
	z := &Summarizer{Client: srv.Client(), Base: srv.URL, Key: "k", Model: "gpt-5-mini"}
	d := z.Summarize(stubSession(), t0)
	if d.Err != "rate limit exceeded" {
		t.Fatalf("err: %q", d.Err)
	}
}

func TestSummarizeCapsWhatItSendsNotWhatItCounts(t *testing.T) {
	var sent string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Messages []chatMsg `json:"messages"`
		}
		raw, _ := io.ReadAll(r.Body)
		json.Unmarshal(raw, &body)
		sent = body.Messages[1].Content
		io.WriteString(w, completion("Fine.", 10, 10))
	}))
	defer srv.Close()
	z := &Summarizer{Client: srv.Client(), Base: srv.URL, Key: "k", Model: "gpt-5-mini", MaxChars: 100}
	s := stubSession()
	d := z.Summarize(s, t0)
	if !strings.Contains(sent, "[truncated]") {
		t.Fatal("input was not capped")
	}
	if d.InWords != wordCount(s.LastText) {
		t.Fatal("InWords must count the real reply, not the capped one")
	}
}

// ---- the panel shape ----

func TestItemsShapeBulletsAsChildrenAndShedFieldsInOrder(t *testing.T) {
	st := &store{keep: 10}
	st.add(Digest{
		ID: "s1:aa", SessionTitle: "release", Headline: "It shipped.",
		Bullets: []string{"Relaunch rook.", "Apply the config."},
		InWords: 400, OutWords: 8, CostUSD: 0.0004, Model: "gpt-5-mini", At: t0,
	})
	its := items(st, t0.Add(2*time.Minute))
	if len(its) != 1 {
		t.Fatalf("items: %d", len(its))
	}
	it := its[0]
	if it.Title != "It shipped." || len(it.Children) != 2 || it.Children[1].Title != "Apply the config." {
		t.Fatalf("row: %+v", it)
	}
	if it.Children[0].ID != "s1:aa:b0" {
		t.Fatalf("child id: %q", it.Children[0].ID)
	}
	// Cost last: the panel sheds off the left, the money survives longest.
	if it.Fields[len(it.Fields)-1].Kind != "MONEY" || it.Fields[len(it.Fields)-1].Value != "$0.0004" {
		t.Fatalf("fields: %+v", it.Fields)
	}
	if !strings.Contains(it.Subtitle, "release") || !strings.Contains(it.Subtitle, "2m") {
		t.Fatalf("subtitle: %q", it.Subtitle)
	}
}

func TestItemsSayWhatFailedAndWhatIsMissing(t *testing.T) {
	st := &store{keep: 10, nokey: "no OpenAI key — set $OPENAI_API_KEY"}
	st.add(Digest{ID: "s1:bb", SessionTitle: "x", Err: "rate limit exceeded", At: t0})
	its := items(st, t0)
	if len(its) != 2 || its[0].State != "error" || its[1].State != "error" {
		t.Fatalf("items: %+v", its)
	}
	if !strings.Contains(its[1].Title, "rate limit") {
		t.Fatalf("failure row: %q", its[1].Title)
	}
}

func TestDismissActsOnTheParentFromAChildRow(t *testing.T) {
	st := &store{keep: 10}
	st.add(Digest{ID: "s1:cc", Headline: "H", Bullets: []string{"b"}, At: t0})
	rep := act(nil, st, nil, 7, json.RawMessage(`{"itemId":"s1:cc:b0","actionId":"dismiss"}`))
	if !rep.OK {
		t.Fatalf("dismiss via child: %+v", rep)
	}
	if len(st.list()) != 0 {
		t.Fatal("digest survived its dismissal")
	}
	rep = act(nil, st, nil, 8, json.RawMessage(`{"itemId":"s1:cc","actionId":"dismiss"}`))
	if rep.OK {
		t.Fatal("dismissing the dismissed must refuse, not lie")
	}
}

func TestStoreKeepsNewestFirstAndBounded(t *testing.T) {
	st := &store{keep: 2}
	for _, id := range []string{"a", "b", "c"} {
		st.add(Digest{ID: id, At: t0})
	}
	ds := st.list()
	if len(ds) != 2 || ds[0].ID != "c" || ds[1].ID != "b" {
		t.Fatalf("ring: %+v", ds)
	}
}

// A local server (ollama, LM Studio) wants no auth. A keyless
// Summarizer must send NO Authorization header — "Bearer " with
// nothing after it is a malformed credential some servers reject —
// and an unknown local model must show no cost, not a made-up one.
func TestLocalAPINeedsNoKeyAndInventsNoCost(t *testing.T) {
	var auth string
	var hasAuth bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth = r.Header.Get("Authorization")
		_, hasAuth = r.Header["Authorization"]
		io.WriteString(w, completion("It shipped.\n- Relaunch rook.", 1000, 100))
	}))
	defer srv.Close()
	z := &Summarizer{Client: srv.Client(), Base: srv.URL, Key: "", Model: "llama3.2", MaxChars: 16000}
	d := z.Summarize(stubSession(), t0)
	if d.Err != "" {
		t.Fatal(d.Err)
	}
	if hasAuth {
		t.Fatalf("keyless request carried an Authorization header: %q", auth)
	}
	if d.CostUSD != 0 {
		t.Fatalf("unknown model priced anyway: %v", d.CostUSD)
	}
}

// The standing no-key notice belongs ONLY to the default OpenAI base:
// a custom base is a local server or a proxy, where a missing key is
// not a misconfiguration to nag about.
func TestNokeyNoticeOnlyForTheDefaultBase(t *testing.T) {
	if n := nokeyNotice("", defaultAPIBase, "/k"); n == "" {
		t.Fatal("default base with no key must notice")
	}
	if n := nokeyNotice("sk-x", defaultAPIBase, "/k"); n != "" {
		t.Fatalf("keyed run noticed anyway: %q", n)
	}
	if n := nokeyNotice("", "http://localhost:11434/v1", "/k"); n != "" {
		t.Fatalf("local base demanded a key: %q", n)
	}
}
