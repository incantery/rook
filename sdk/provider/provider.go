// Package provider is the wire between rook and a PROVIDER — a separate
// process that owns authority over exactly one external system (GitHub,
// Linear, …) and answers questions about it.
//
// The split this enforces: a provider owns credentials and an API client;
// rook owns everything a user sees. A provider returns typed data and
// never a rendered thing, never a prompt, never a command line. When the
// issue queue spawns an agent, the PROMPT is built here in rook (see
// host.buildTask) from data the provider supplied — the same rule the
// edge protocol keeps, where the cloud names a profile and the device
// owns what that profile means.
//
// # Why a process
//
// Providers are the parts of rook most likely to be slow, flaky, or
// written by someone else: they make network calls to systems rook does
// not control. A process boundary buys crash containment, independent
// resource accounting, a clean kill, and language freedom — a provider
// can be written in anything that can read a line of JSON. None of that
// is available in-process at any price.
//
// # The wire
//
// Newline-delimited JSON over stdin/stdout, one request in flight at a
// time. stderr is the provider's log and belongs to whoever is watching.
//
//	-> {"v":1,"id":1,"op":"describe"}
//	<- {"v":1,"id":1,"ok":true,"result":{"name":"github","capabilities":["issues.list"]}}
//	-> {"v":1,"id":2,"op":"issues.list","deadlineMs":10000,"params":{"root":"/w/rook"}}
//	<- {"v":1,"id":2,"ok":true,"result":{"issues":[…]}}
//
// JSON and not protobuf, deliberately, for as long as the payloads stay
// this shape: a provider is debuggable by hand (`echo '{"v":1,"id":1,
// "op":"describe"}' | rook-provider-github`) and writable in any language
// without a codegen step. The transport is meant to be replaceable —
// nothing above Client knows what the bytes look like.
//
// # Capabilities are declared, and what is not declared is refused
//
// `describe` is the handshake: a provider states what it offers, and
// Client refuses to send an op the provider did not name. Same discipline
// as edgeCapabilities — a capability this provider never claimed is a
// named refusal rather than a request that hangs.
package provider

import "encoding/json"

// Version is the protocol version every frame carries. A reader that sees
// a version it does not know refuses rather than guesses: unlike config,
// where fail-open is right, a misread request here would ACT.
const Version = 1

// The ops rook knows how to ask for. A provider declares which of these
// it answers; anything else is refused before it is sent.
const (
	// OpDescribe is the handshake, and every provider must answer it.
	OpDescribe = "describe"
	// OpIssuesList is the work queue: issues that could be my next task.
	OpIssuesList = "issues.list"
	// OpPullsStatus resolves a branch to its pull request on the code
	// host. A code-host capability rather than a tracker one — a
	// Linear-tracked repo still merges through GitHub — so a provider may
	// well offer one of these two and not the other.
	OpPullsStatus = "pulls.status"
)

// Request is one call. ID is unique per connection and echoes back, so
// the framing can grow to concurrent calls without a wire change.
type Request struct {
	V          int             `json:"v"`
	ID         int             `json:"id"`
	Op         string          `json:"op"`
	DeadlineMS int             `json:"deadlineMs,omitempty"`
	Params     json.RawMessage `json:"params,omitempty"`
}

// Response is one answer. OK false means Error is the reason, phrased for
// whoever reads the run's record rather than for the caller's switch —
// providers fail in ways rook cannot enumerate.
type Response struct {
	V      int             `json:"v"`
	ID     int             `json:"id"`
	OK     bool            `json:"ok"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  string          `json:"error,omitempty"`
}

// Describe is the handshake result: who this is and what it offers.
type Describe struct {
	Name         string   `json:"name"`
	Version      string   `json:"version,omitempty"`
	Capabilities []string `json:"capabilities"`
}

// IssuesListParams scopes the query. Root is the workspace checkout, for
// providers that resolve their target from it (GitHub reads the repo out
// of the checkout's remote, exactly as `gh issue list` does).
type IssuesListParams struct {
	Root string `json:"root,omitempty"`
}

// Issue is one row of a work queue, provider-agnostic.
//
// There is deliberately no Task field. The ready-to-spawn prompt is built
// in rook from these fields, so a provider cannot decide what an agent is
// told to do — data in, prompt out, and the prompt is the host's.
type Issue struct {
	// Provider is the name from Describe ("github", "linear").
	Provider string `json:"provider"`
	// Key is the tracker's own identifier ("#123", "ENG-42").
	Key   string `json:"key"`
	Title string `json:"title"`
	Body  string `json:"body,omitempty"`
	URL   string `json:"url,omitempty"`
	// State is the tracker's own label — its vocabulary, not rook's.
	State string `json:"state,omitempty"`
	// Mine: assigned to the authenticated user. False means UNASSIGNED —
	// a queue never contains work someone else already owns, so providers
	// filter those out rather than reporting them as not-mine.
	Mine    bool     `json:"mine"`
	Labels  []string `json:"labels,omitempty"`
	Updated string   `json:"updated,omitempty"` // RFC3339; "" when unknown
}

// IssuesListResult is OpIssuesList's payload.
type IssuesListResult struct {
	Issues []Issue `json:"issues"`
}

// PullsStatusParams asks about one branch in one checkout.
type PullsStatusParams struct {
	Root   string `json:"root"`
	Branch string `json:"branch"`
}

// PullsStatusResult is OpPullsStatus's payload.
//
// Found=false is the load-bearing field: it means CHECKED, and there is
// no PR — which is a fact, and must never be confused with the error
// case (no gh, offline, a remote that is not GitHub), where nothing is
// known and the caller keeps whatever it knew before. Collapsing those
// two would report "no PR" for a branch that has one.
type PullsStatusResult struct {
	Found    bool   `json:"found"`
	Number   int    `json:"number,omitempty"`
	State    string `json:"state,omitempty"` // OPEN | CLOSED | MERGED
	URL      string `json:"url,omitempty"`
	MergedAt string `json:"mergedAt,omitempty"`
	// Mergeable is the code host's merge check: MERGEABLE | CONFLICTING |
	// UNKNOWN, or empty from a gh too old to report it. Callers must test
	// for CONFLICTING exactly — every other value, including the empty
	// one, has to read as "fine" so a missing answer never invents a
	// conflict.
	Mergeable string `json:"mergeable,omitempty"`
}
