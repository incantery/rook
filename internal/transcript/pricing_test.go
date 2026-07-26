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

// Opus 5 is a drop-in at Opus 4.8's rates, and the id carries no date
// suffix. The trap it *does* carry is a context-variant bracket —
// claude-opus-5[1m] is what a 1M-context session reports as its model —
// which the prefix match has to absorb rather than drop on the floor.
func TestCostOpus5(t *testing.T) {
	for _, id := range []string{"claude-opus-5", "claude-opus-5[1m]"} {
		usd, priced := Cost(id, Usage{InputTokens: 1_000_000, OutputTokens: 1_000_000})
		if !priced {
			t.Fatalf("%s reported unpriced", id)
		}
		near(t, usd, 30)
	}

	// Opus 5 must not be swallowed by the opus-4-x rows, nor swallow them.
	usd, _ := Cost("claude-opus-5", Usage{CacheReadTokens: 1_000_000, Cache1hTokens: 1_000_000, CacheCreationTokens: 1_000_000})
	near(t, usd, 0.50+10)
}

// Fast mode is a premium rate, not a flag to ignore: the same tokens on
// Opus 5 cost 2x standard.
func TestCostFastMode(t *testing.T) {
	u := Usage{InputTokens: 1_000_000, OutputTokens: 1_000_000}

	std, _ := Cost("claude-opus-5", u)
	near(t, std, 30)

	u.Speed = SpeedFast
	fast, priced := Cost("claude-opus-5", u)
	if !priced {
		t.Fatal("fast-mode opus 5 reported unpriced")
	}
	near(t, fast, 60)

	// The fast rates must reach the cache columns too, not just in/out.
	cacheFast, _ := Cost("claude-opus-5", Usage{
		Speed:               SpeedFast,
		CacheReadTokens:     1_000_000,
		CacheCreationTokens: 1_000_000,
		Cache1hTokens:       1_000_000,
	})
	near(t, cacheFast, 1.00+20)
}

// "standard" and the empty speed on older lines are the same thing, and
// neither may be mistaken for fast.
func TestCostStandardAndEmptySpeedAgree(t *testing.T) {
	u := Usage{InputTokens: 1_000_000, OutputTokens: 1_000_000}
	blank, _ := Cost("claude-opus-5", u)
	u.Speed = "standard"
	std, _ := Cost("claude-opus-5", u)
	if blank != std {
		t.Errorf("empty speed = %v, standard = %v; must agree", blank, std)
	}
	near(t, std, 30)
}

// A model with no published fast rate falls back to standard rather than
// going unpriced — a floor, not a hole. Opus 4.8 supports fast mode but
// Anthropic has not published its price; this pins that deliberate choice
// so a later "obvious" 2x guess has to argue with a test first.
func TestCostFastFallsBackWhenUnpublished(t *testing.T) {
	u := Usage{OutputTokens: 1_000_000, Speed: SpeedFast}
	usd, priced := Cost("claude-opus-4-8", u)
	if !priced {
		t.Fatal("fast-mode opus 4.8 reported unpriced; standard rates are the floor")
	}
	near(t, usd, 25)
}

// Every fast row must name a model the standard table also knows, since the
// fast lookup reuses the prefix matched against table.
func TestFastTableKeysExistInTable(t *testing.T) {
	for k := range fastTable {
		if _, ok := table[k]; !ok {
			t.Errorf("fastTable has %q with no matching row in table — it can never be reached", k)
		}
	}
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
