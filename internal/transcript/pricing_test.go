package transcript

import (
	"math"
	"testing"
)

func near(t *testing.T, got, want float64) {
	t.Helper()
	if math.Abs(got-want) > 1e-9 {
		t.Errorf("cost = %v, want %v", got, want)
	}
}

func TestCostBasicRates(t *testing.T) {
	// haiku-4-5: $1/M in, $5/M out
	usd, priced := Cost("claude-haiku-4-5", Usage{InputTokens: 1_000_000, OutputTokens: 1_000_000})
	if !priced {
		t.Fatal("known model reported unpriced")
	}
	near(t, usd, 6)
}

func TestCostLongestPrefixWins(t *testing.T) {
	// A date-suffixed id must resolve to its family.
	usd, priced := Cost("claude-haiku-4-5-20251001", Usage{OutputTokens: 1_000_000})
	if !priced {
		t.Fatal("date-suffixed id reported unpriced")
	}
	near(t, usd, 5)

	// claude-opus-4-8 must not be matched by some shorter neighbour.
	usd, _ = Cost("claude-opus-4-8", Usage{OutputTokens: 1_000_000})
	near(t, usd, 25)
}

// An unknown model is a gap in the table, not a free session.
func TestCostUnknownModelIsUnpricedNotFree(t *testing.T) {
	usd, priced := Cost("claude-something-6", Usage{InputTokens: 5_000_000, OutputTokens: 5_000_000})
	if priced {
		t.Error("unknown model reported as priced")
	}
	if usd != 0 {
		t.Errorf("usd = %v; unknown models must return 0 *with* priced=false", usd)
	}
	if _, priced := Cost("", Usage{InputTokens: 100}); priced {
		t.Error("empty model reported as priced")
	}
}

func TestCostCacheReadAndWrite(t *testing.T) {
	// haiku: cacheRead 0.10, cache5m 1.25, cache1h 2.00 per M
	usd, _ := Cost("claude-haiku-4-5", Usage{
		CacheReadTokens:     1_000_000,
		CacheCreationTokens: 2_000_000,
		Cache5mTokens:       1_000_000,
		Cache1hTokens:       1_000_000,
	})
	near(t, usd, 0.10+1.25+2.00)
}

// The buckets may be absent: the whole cache_creation total then bills at
// the cheaper 5m rate rather than vanishing.
func TestCostCacheSplitAbsentBillsRemainderAt5m(t *testing.T) {
	usd, _ := Cost("claude-haiku-4-5", Usage{CacheCreationTokens: 1_000_000})
	near(t, usd, 1.25)
}

func TestCostCacheSplitPartialBillsRemainderAt5m(t *testing.T) {
	// 1M total, only 400k attributed to 1h → 600k remainder at 5m.
	usd, _ := Cost("claude-haiku-4-5", Usage{
		CacheCreationTokens: 1_000_000,
		Cache1hTokens:       400_000,
	})
	near(t, usd, 0.4*2.00+0.6*1.25)
}

// Buckets summing above the reported total must not go negative.
func TestCostCacheSplitOverAttributed(t *testing.T) {
	usd, _ := Cost("claude-haiku-4-5", Usage{
		CacheCreationTokens: 1_000_000,
		Cache5mTokens:       800_000,
		Cache1hTokens:       800_000,
	})
	near(t, usd, 0.8*1.25+0.8*2.00)
}

func TestCostZeroUsage(t *testing.T) {
	usd, priced := Cost("claude-opus-4-8", Usage{})
	if !priced {
		t.Error("known model with no usage should still be priced")
	}
	near(t, usd, 0)
}

// The trap agentmon documents: Claude Code writes one API response as
// several lines, each repeating the same usage. Cost is per-Usage and has
// no memory — deduping on Message.ID is the caller's job, and this test
// exists to pin the contract rather than the arithmetic.
func TestCostHasNoMemory(t *testing.T) {
	u := Usage{OutputTokens: 1_000_000}
	a, _ := Cost("claude-haiku-4-5", u)
	b, _ := Cost("claude-haiku-4-5", u)
	if a != b {
		t.Fatalf("Cost is not pure: %v then %v", a, b)
	}
}
