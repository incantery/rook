package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/incantery/rook/internal/keychain"
)

// OpenAI is a minimal chat-completions client: structured output via
// json_schema (the escalation gate lives in the output contract), temp 0,
// a hard token ceiling. No SDK — this is one POST.
type OpenAI struct {
	Key     string
	Model   string
	BaseURL string // override in tests; default api.openai.com
	http    *http.Client
}

// KeyPath is ~/.config/rook/openai-key (XDG respected) — the fallback
// store for platforms without a keychain and for hand-run dev setups.
func KeyPath() string {
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "rook", "openai-key")
}

// LoadKey prefers the login keychain (set from the app's palette or
// `rookctl set-openai-key` — it doesn't ride along in dotfile syncs and
// backups the way ~/.config does), then falls back to the key file, which
// it refuses unless 0600 — an API key with group or world bits is a leak,
// not a config.
func LoadKey() (string, error) {
	if k, err := keychain.Get(keychain.Service, keychain.OpenAIAccount); err == nil && k != "" {
		return k, nil
	}
	path := KeyPath()
	st, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("no key in keychain (rookctl set-openai-key) and no key file: %w", err)
	}
	if st.Mode().Perm()&0o077 != 0 {
		return "", fmt.Errorf("%s must be 0600 (is %04o) — refusing to use it", path, st.Mode().Perm())
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	key := string(bytes.TrimSpace(raw))
	if key == "" {
		return "", fmt.Errorf("%s is empty", path)
	}
	return key, nil
}

func NewOpenAI(key, model string) *OpenAI {
	return &OpenAI{
		Key:     key,
		Model:   model,
		BaseURL: "https://api.openai.com/v1",
		http:    &http.Client{Timeout: 30 * time.Second},
	}
}

// Judgment is the drafter's whole output contract: decide whether this ask
// is mechanical (draft) or judgment-shaped (escalate), and say why.
type Judgment struct {
	Action     string  `json:"action"` // draft | escalate
	Reply      string  `json:"reply"`
	Confidence float64 `json:"confidence"`
	Reason     string  `json:"reason"`
}

type Usage struct {
	InputTokens  int64
	OutputTokens int64
	CachedTokens int64
	CostUSD      float64
}

// judgmentSchema keeps nano honest: strict json_schema output, enum-bound
// action, no extra fields.
var judgmentSchema = map[string]any{
	"type":                 "object",
	"additionalProperties": false,
	"required":             []string{"action", "reply", "confidence", "reason"},
	"properties": map[string]any{
		"action":     map[string]any{"type": "string", "enum": []string{"draft", "escalate"}},
		"reply":      map[string]any{"type": "string"},
		"confidence": map[string]any{"type": "number"},
		"reason":     map[string]any{"type": "string"},
	},
}

func (o *OpenAI) Judge(ctx context.Context, system, user string) (*Judgment, Usage, error) {
	body := map[string]any{
		"model": o.Model,
		"messages": []map[string]string{
			{"role": "system", "content": system},
			{"role": "user", "content": user},
		},
		"temperature":           0,
		"max_completion_tokens": 300,
		"response_format": map[string]any{
			"type": "json_schema",
			"json_schema": map[string]any{
				"name":   "judgment",
				"strict": true,
				"schema": judgmentSchema,
			},
		},
	}
	b, err := json.Marshal(body)
	if err != nil {
		return nil, Usage{}, err
	}
	req, err := http.NewRequestWithContext(ctx, "POST", o.BaseURL+"/chat/completions", bytes.NewReader(b))
	if err != nil {
		return nil, Usage{}, err
	}
	req.Header.Set("Authorization", "Bearer "+o.Key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := o.http.Do(req)
	if err != nil {
		return nil, Usage{}, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return nil, Usage{}, fmt.Errorf("openai: %s: %s", resp.Status, truncate(string(raw), 300))
	}
	var out struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
				Refusal string `json:"refusal"`
			} `json:"message"`
		} `json:"choices"`
		Usage struct {
			PromptTokens        int64 `json:"prompt_tokens"`
			CompletionTokens    int64 `json:"completion_tokens"`
			PromptTokensDetails struct {
				CachedTokens int64 `json:"cached_tokens"`
			} `json:"prompt_tokens_details"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, Usage{}, err
	}
	if len(out.Choices) == 0 {
		return nil, Usage{}, fmt.Errorf("openai: no choices")
	}
	if out.Choices[0].Message.Refusal != "" {
		return nil, Usage{}, fmt.Errorf("openai: refusal: %s", out.Choices[0].Message.Refusal)
	}
	u := Usage{
		InputTokens:  out.Usage.PromptTokens,
		OutputTokens: out.Usage.CompletionTokens,
		CachedTokens: out.Usage.PromptTokensDetails.CachedTokens,
	}
	u.CostUSD = cost(o.Model, u)
	var j Judgment
	if err := json.Unmarshal([]byte(out.Choices[0].Message.Content), &j); err != nil {
		return nil, u, fmt.Errorf("openai: bad judgment json: %w", err)
	}
	if j.Action != "draft" && j.Action != "escalate" {
		return nil, u, fmt.Errorf("openai: bad action %q", j.Action)
	}
	return &j, u, nil
}

// pricing per million tokens: input, cached input, output. Unknown models
// record zero cost (tokens are still in the row — the ledger stays honest
// about what it doesn't know).
var pricing = map[string][3]float64{
	"gpt-5.4-nano": {0.20, 0.02, 1.25},
}

func cost(model string, u Usage) float64 {
	p, ok := pricing[model]
	if !ok {
		return 0
	}
	fresh := max(u.InputTokens-u.CachedTokens, 0)
	return (float64(fresh)*p[0] + float64(u.CachedTokens)*p[1] + float64(u.OutputTokens)*p[2]) / 1e6
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
