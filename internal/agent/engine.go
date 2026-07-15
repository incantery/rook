package agent

import (
	"context"
	"time"
)

// Engine is the drafter's model backend. Two implementations, deliberately:
// OpenAI (an API key, strict json_schema, its own billing) and ClaudeCode
// (the `claude` CLI the user already has, output contract as a tool call).
//
// The interface exists because two implementations exist — the shape is
// pulled from the pair, not designed ahead of a third. If a third arrives,
// it argues for itself then.
//
// Neither engine actuates anything. They judge; approveDraft types. That
// boundary is the escalation gate's whole basis and no engine may cross it.
type Engine interface {
	// Judge decides one ask: mechanical (draft) or judgment-shaped
	// (escalate). system is the byte-stable rubric+preferences prefix;
	// user is this ask.
	Judge(ctx context.Context, system, user string) (*Judgment, Usage, error)

	// Extract runs one preference pass over decided verdicts.
	Extract(ctx context.Context, system, user string) (*Extraction, Usage, error)

	// Name identifies the model in the decisions ledger — the column that
	// makes an engine A/B legible after the fact.
	Name() string

	// Timeout bounds one call. It belongs to the engine because the two are
	// an order of magnitude apart — a nano POST answers in ~1s, a `claude
	// -p` cold start burns ~15s before inference even begins — so a shared
	// constant can only strangle one or forgive the other.
	Timeout() time.Duration
}

// Compile-time proof both engines satisfy the seam.
var (
	_ Engine = (*OpenAI)(nil)
	_ Engine = (*ClaudeCode)(nil)
)
