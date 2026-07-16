package transcript

import "strings"

// Pricing computes the notional API cost of a session from per-model
// published rates (USD per million tokens), ported from agentmon's
// internal/pricing — AgentStatus.CostUSD came from its stamping, and the
// table has to live somewhere once rook reads transcripts itself.
//
// Rates are Anthropic's published list prices as cached 2026-06-24. List
// prices are used deliberately even where introductory pricing applies
// (Sonnet 5 is $2/$10 through 2026-08-31): stable, and a conservative
// overestimate. The number is notional either way — a subscription session
// does not bill per token, and this is what it *would* have cost.

// rates are USD per million tokens.
type rates struct {
	input        float64
	output       float64
	cacheRead    float64 // 0.1x input
	cache5mWrite float64 // 1.25x input
	cache1hWrite float64 // 2x input
}

// table is keyed by model-ID prefix; longest prefix wins, so date-suffixed
// ids like claude-haiku-4-5-20251001 resolve to their family.
var table = map[string]rates{
	"claude-fable-5":    {10, 50, 1.00, 12.50, 20},
	"claude-mythos-5":   {10, 50, 1.00, 12.50, 20},
	"claude-opus-4-8":   {5, 25, 0.50, 6.25, 10},
	"claude-opus-4-7":   {5, 25, 0.50, 6.25, 10},
	"claude-opus-4-6":   {5, 25, 0.50, 6.25, 10},
	"claude-sonnet-5":   {3, 15, 0.30, 3.75, 6},
	"claude-sonnet-4-6": {3, 15, 0.30, 3.75, 6},
	"claude-haiku-4-5":  {1, 5, 0.10, 1.25, 2},
}

// Cost returns the USD cost of u under model's published rates.
//
// priced is false when the model is not in the table, and callers must
// surface that as "unpriced" rather than zero: a model rook has never heard
// of is a gap in the table, not a free session. Adding a model here is the
// whole fix.
//
// The cache-creation split is handled here rather than by the caller.
// Claude Code reports cache_creation_input_tokens as a total and *may*
// break it into 5m/1h ephemeral buckets. When the buckets are absent or
// only partial, the unattributed remainder is billed at the cheaper 5m
// rate — conservative-low, and the same choice agentmon makes.
func Cost(model string, u Usage) (usd float64, priced bool) {
	var best string
	for prefix := range table {
		if strings.HasPrefix(model, prefix) && len(prefix) > len(best) {
			best = prefix
		}
	}
	if best == "" {
		return 0, false
	}
	r := table[best]

	write5m, write1h := u.Cache5mTokens, u.Cache1hTokens
	if rem := u.CacheCreationTokens - (write5m + write1h); rem > 0 {
		write5m += rem
	}

	usd = float64(u.InputTokens)*r.input/1e6 +
		float64(u.OutputTokens)*r.output/1e6 +
		float64(u.CacheReadTokens)*r.cacheRead/1e6 +
		float64(write5m)*r.cache5mWrite/1e6 +
		float64(write1h)*r.cache1hWrite/1e6
	return usd, true
}
