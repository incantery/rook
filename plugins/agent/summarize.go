// The OpenAI half: one finished turn in, one STE digest out.
//
// "STE" here is discipline, not certification — ASD-STE100's rules
// (active voice, one idea per sentence, hard word caps) are exactly what
// makes a digest render as panel rows, but nothing checks the approved
// dictionary. The caps ARE checked, deterministically, on the way out:
// a summarizer that rambles is the disease it was hired to cure, so a
// reply that breaks the shape gets one retry and then is taken as-is —
// a long digest still beats no digest.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/incantery/rook/plugins/internal/transcript"
)

// The shape contract, with slack: the prompt asks for 15/5/20 and the
// guard allows 25/6/28, because a model that lands one word over the ask
// did the job and a retry for it would be spending money on pedantry.
const (
	askHeadlineWords = 15
	askBullets       = 5
	askBulletWords   = 20
	maxHeadlineWords = 25
	maxBullets       = 6
	maxBulletWords   = 28
)

const sysPrompt = `You compress a verbose technical assistant reply into a digest a busy engineer reads in five seconds. Follow Simplified Technical English (ASD-STE100) discipline: active voice, one idea per sentence, simple words. Keep code identifiers, commands, paths, and numbers exactly as written.
Write exactly this shape:
First line: the core outcome or answer. One sentence, at most 15 words. No preamble.
Then up to 5 lines, each "- " plus one fact, decision, or action the human must take. At most 20 words each. Actions the human must take come first.
Nothing else: no headings, no blank lines, no closing remark.`

// Digest is one summarized turn — or one failure to summarize, which is
// also worth a row: "the panel is empty" and "the call failed" look
// identical from outside and are not the same problem.
type Digest struct {
	ID           string
	SessionID    string
	SessionTitle string
	Cwd          string
	Headline     string
	Bullets      []string
	InWords      int // the reply it compressed
	OutWords     int // the digest
	CostUSD      float64
	Model        string
	At           time.Time
	Err          string

	// The raw material a draft works from — the digest is a reading
	// aid, and drafting from a summary would compound its lossiness.
	Prompt   string
	FullText string

	// The suggested-reply lifecycle: Reply once drafted; ReplyState is
	// the row's chip ("drafting", "ready", "copied", "draft failed",
	// "clip refused"); ReplyErr carries the reason when one failed.
	Reply      string
	ReplyState string
	ReplyErr   string
}

type Summarizer struct {
	Client   *http.Client
	Base     string // .../v1 — a flag, so tests point it at a stub
	Key      string
	Model    string
	Effort   string // reasoning_effort; "" omits the field
	MaxChars int    // input cap; a 300KB paste is not a turn worth $0.10
}

// Summarize compresses one finished turn. Blocking, seconds — the watch
// loop is the only caller and has nothing better to do.
func (z *Summarizer) Summarize(s transcript.Session, now time.Time) Digest {
	d := Digest{
		ID:           s.ID + ":" + shortHash(s.LastText),
		SessionID:    s.ID,
		SessionTitle: s.Title,
		Cwd:          s.Cwd,
		InWords:      wordCount(s.LastText),
		Model:        z.Model,
		At:           now,
	}
	text := s.LastText
	if z.MaxChars > 0 && len(text) > z.MaxChars {
		text = text[:z.MaxChars] + "\n[truncated]"
	}
	d.Prompt = s.Prompt
	d.FullText = text
	msgs := []chatMsg{
		{"system", sysPrompt},
		{"user", "The human asked:\n" + transcript.Snip(s.Prompt, 600) + "\n\nThe reply to compress:\n" + text},
	}
	content, cost, err := z.complete(msgs)
	if err != nil {
		d.Err = err.Error()
		return d
	}
	d.CostUSD = cost
	headline, bullets, perr := parseDigest(content)
	if perr != nil {
		// One correction, then take what comes: the retry message names
		// the limits rather than restating the whole prompt, because the
		// model has the prompt and broke it anyway.
		msgs = append(msgs,
			chatMsg{"assistant", content},
			chatMsg{"user", fmt.Sprintf("Too long or wrong shape. Rewrite: first line one sentence ≤ %d words, then ≤ %d lines starting with \"- \", ≤ %d words each. Nothing else.", askHeadlineWords, askBullets, askBulletWords)})
		content2, cost2, err2 := z.complete(msgs)
		d.CostUSD += cost2
		if err2 == nil {
			if h2, b2, e2 := parseDigest(content2); e2 == nil {
				headline, bullets = h2, b2
			} else {
				headline, bullets = fallbackDigest(content2)
			}
		} else {
			headline, bullets = fallbackDigest(content)
		}
	}
	if len(bullets) > maxBullets {
		bullets = bullets[:maxBullets]
	}
	d.Headline = headline
	d.Bullets = bullets
	d.OutWords = wordCount(headline)
	for _, b := range bullets {
		d.OutWords += wordCount(b)
	}
	if d.Headline == "" {
		d.Err = "the model sent nothing usable"
	}
	return d
}

type chatMsg struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// complete is one chat-completions round trip, priced from the usage the
// API reports (reasoning tokens bill as output; the meter should agree
// with the invoice, not with what landed in the digest).
func (z *Summarizer) complete(msgs []chatMsg) (content string, cost float64, err error) {
	body := struct {
		Model     string    `json:"model"`
		Messages  []chatMsg `json:"messages"`
		MaxTokens int       `json:"max_completion_tokens"`
		Effort    string    `json:"reasoning_effort,omitempty"`
	}{z.Model, msgs, 4096, z.Effort}
	buf, err := json.Marshal(body)
	if err != nil {
		return "", 0, err
	}
	req, err := http.NewRequest("POST", strings.TrimRight(z.Base, "/")+"/chat/completions", bytes.NewReader(buf))
	if err != nil {
		return "", 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+z.Key)
	resp, err := z.Client.Do(req)
	if err != nil {
		return "", 0, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", 0, err
	}
	if resp.StatusCode != 200 {
		var e struct {
			Error struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if json.Unmarshal(raw, &e) == nil && e.Error.Message != "" {
			return "", 0, errors.New(e.Error.Message)
		}
		return "", 0, fmt.Errorf("openai: HTTP %d", resp.StatusCode)
	}
	var rep struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Usage struct {
			In  int `json:"prompt_tokens"`
			Out int `json:"completion_tokens"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(raw, &rep); err != nil {
		return "", 0, err
	}
	if len(rep.Choices) == 0 {
		return "", 0, errors.New("openai: no choices")
	}
	pin, pout, known := price(z.Model)
	if known {
		cost = pin*float64(rep.Usage.In)/1e6 + pout*float64(rep.Usage.Out)/1e6
	}
	return rep.Choices[0].Message.Content, cost, nil
}

const draftPrompt = `You draft the user's next reply to their AI coding agent. From the agent's last message and the user's earlier prompt, write the reply the user most plausibly wants to send: answer the agent's questions, pick among options it offered when one is clearly better (and say why in a clause), approve good plans, flag real risks. First person, direct, specific, at most 120 words, plain text only — no greeting, no signature, no markdown.`

// Draft writes the reply the human would probably send back — or, when
// `guidance` carries the human's rough words, the polished version of
// the reply they MEANT. It works from the FULL turn, not the digest —
// drafting from a summary would compound its lossiness — and it is only
// ever called on demand: a draft nobody asked for is a bill nobody
// wanted.
func (z *Summarizer) Draft(d Digest, guidance string) (text string, cost float64, err error) {
	ask := "Draft the user's reply."
	if guidance != "" {
		ask = "The user wants to reply, roughly:\n" + guidance + "\n\nWrite the polished reply they mean: keep their decisions and intent EXACTLY — expand and sharpen with specifics from the agent's message, never override them."
	}
	msgs := []chatMsg{
		{"system", draftPrompt},
		{"user", "The user had asked:\n" + transcript.Snip(d.Prompt, 600) + "\n\nThe agent replied:\n" + d.FullText + "\n\n" + ask},
	}
	content, c, cerr := z.complete(msgs)
	if cerr != nil {
		return "", c, cerr
	}
	content = strings.TrimSpace(content)
	if content == "" {
		return "", c, errors.New("the model sent nothing usable")
	}
	return content, c, nil
}

// parseDigest holds the model to the shape it was asked for.
func parseDigest(content string) (headline string, bullets []string, err error) {
	for line := range strings.SplitSeq(content, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if headline == "" {
			if strings.HasPrefix(line, "- ") || strings.HasPrefix(line, "• ") {
				return "", nil, errors.New("no headline before the bullets")
			}
			headline = line
			continue
		}
		cut, ok := strings.CutPrefix(line, "- ")
		if !ok {
			cut, ok = strings.CutPrefix(line, "• ")
		}
		if !ok {
			return "", nil, errors.New("a line is neither headline nor bullet")
		}
		bullets = append(bullets, cut)
	}
	switch {
	case headline == "":
		return "", nil, errors.New("empty")
	case wordCount(headline) > maxHeadlineWords:
		return "", nil, fmt.Errorf("headline ran to %d words", wordCount(headline))
	case len(bullets) > maxBullets:
		return "", nil, fmt.Errorf("%d bullets", len(bullets))
	}
	for _, b := range bullets {
		if wordCount(b) > maxBulletWords {
			return "", nil, fmt.Errorf("a bullet ran to %d words", wordCount(b))
		}
	}
	return headline, bullets, nil
}

// fallbackDigest salvages a reply that failed the guard twice: first
// line as headline, everything bullet-shaped kept. Never errors — by
// this point the money is spent and something must land in the panel.
func fallbackDigest(content string) (string, []string) {
	var headline string
	var bullets []string
	for line := range strings.SplitSeq(content, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if cut, ok := strings.CutPrefix(line, "- "); ok {
			bullets = append(bullets, cut)
		} else if headline == "" {
			headline = line
		}
	}
	return headline, bullets
}

// price per million tokens (input, output), matched by longest prefix —
// the API reports dated names like gpt-5-mini-2025-08-07. Unknown models
// summarize fine and simply show no cost, which is honest: a made-up
// number in a MONEY field is worse than none.
var prices = []struct {
	prefix  string
	in, out float64
}{
	// gpt-5.6 ships named tiers; only luna's price is verified (the
	// 2026-07-30 cut: $0.20/$1.20). Sol and terra summarize fine and
	// show no cost until someone verifies theirs.
	{"gpt-5.6-luna", 0.20, 1.20},
	{"gpt-5-nano", 0.05, 0.40},
	{"gpt-5-mini", 0.25, 2.00},
	{"gpt-5", 1.25, 10.00},
	{"gpt-4.1-nano", 0.10, 0.40},
	{"gpt-4.1-mini", 0.40, 1.60},
	{"gpt-4.1", 2.00, 8.00},
	{"gpt-4o-mini", 0.15, 0.60},
	{"gpt-4o", 2.50, 10.00},
}

func price(model string) (in, out float64, ok bool) {
	best := -1
	for i, p := range prices {
		if strings.HasPrefix(model, p.prefix) && (best < 0 || len(p.prefix) > len(prices[best].prefix)) {
			best = i
		}
	}
	if best < 0 {
		return 0, 0, false
	}
	return prices[best].in, prices[best].out, true
}

func wordCount(s string) int { return len(strings.Fields(s)) }

// chunkText splits prose into pieces at most max bytes each, breaking
// at spaces (falling back to a hard cut for an unbreakable run) — the
// wire caps child titles, and a chunk that silently vanished would be
// a reply the panel misquotes.
func chunkText(s string, max int) []string {
	s = strings.Join(strings.Fields(s), " ")
	var out []string
	for len(s) > max {
		cut := strings.LastIndexByte(s[:max+1], ' ')
		if cut <= 0 {
			cut = max
		}
		out = append(out, strings.TrimSpace(s[:cut]))
		s = strings.TrimSpace(s[cut:])
	}
	if s != "" {
		out = append(out, s)
	}
	return out
}

// shortHash identifies a turn by its text, so a state that flaps back
// through "needs you" cannot bill the same reply twice. FNV-1a: this is
// an identity for a map key, not a defense.
func shortHash(s string) string {
	var h uint64 = 14695981039346656037
	for i := range len(s) {
		h ^= uint64(s[i])
		h *= 1099511628211
	}
	return fmt.Sprintf("%08x", uint32(h^(h>>32)))
}
