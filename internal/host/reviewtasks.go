package host

// The review work-type: the first builder over RookTask
// (docs/superpowers/specs/2026-07-17-rooktask-review-design.md). Preparation
// is pure git — no inference ever originates here; the scorer is a claude
// session wielding rookctl. A review is a parent task (anchor_kind 'ref',
// anchor_ref = the scope key) with one leaf child per diff hunk (anchor_kind
// 'code'). Re-preparing the same scope RECONCILES: dispositions carry forward
// by (path, hunk-body) identity, so an edit elsewhere never resets your work.

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
)

// review leaf states (the work_type owns this vocabulary). Blocking states
// keep the gate closed; Approved/Deferred are the two non-blocking verdicts.
const (
	reviewParentState   = "reviewing"
	reviewStateProposed = "proposed"
	reviewStateApproved = "approved"
	reviewStateRejected = "rejected" // wants change — blocks the commit
	reviewStateDeferred = "deferred" // set aside without deep review — non-blocking
	reviewStatePending  = "pending"  // conversation pending (a thread is open — later)
)

// emptyTreeSHA is git's well-known hash of the empty tree — the diff base
// for a root commit (which has no parent).
const emptyTreeSHA = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

func validReviewLeafState(s string) bool {
	switch s {
	case reviewStateProposed, reviewStateApproved, reviewStateRejected,
		reviewStateDeferred, reviewStatePending:
		return true
	}
	return false
}

// reviewBlocking: only an explicit Approve or Defer clears a hunk. Everything
// else (proposed, rejected, conversation-pending) keeps the gate closed.
func reviewBlocking(state string) bool {
	return state != reviewStateApproved && state != reviewStateDeferred
}

// reviewHunk is one parsed diff hunk — the new-side range for reveal, and the
// body (the +/- lines) as both the anchor snapshot and the reconcile identity.
// The body is stable under edits ELSEWHERE in the file (it carries no line
// numbers), so a hunk that merely shifted still matches its prior disposition.
type reviewHunk struct {
	path     string
	newStart int
	newCount int
	body     string
}

// gitDiffPath strips git's a//b/ prefix; /dev/null (add/delete) yields "".
func gitDiffPath(s string) string {
	if s == "/dev/null" {
		return ""
	}
	if len(s) > 2 && (s[:2] == "a/" || s[:2] == "b/") {
		return s[2:]
	}
	return s
}

// parseReviewHunks splits a unified `git diff` into per-hunk records. Binary
// files (no @@ body) fall out naturally. Reuses hunkRE (reanchor.go) for the
// @@ header — same format at any context width.
func parseReviewHunks(diff []byte) []reviewHunk {
	var out []reviewHunk
	var curPath, oldPath string
	var cur *reviewHunk
	flush := func() {
		if cur != nil {
			out = append(out, *cur)
			cur = nil
		}
	}
	for _, line := range strings.Split(string(diff), "\n") {
		switch {
		case strings.HasPrefix(line, "diff --git "):
			flush()
			curPath, oldPath = "", ""
		case strings.HasPrefix(line, "--- "):
			oldPath = gitDiffPath(line[4:])
		case strings.HasPrefix(line, "+++ "):
			curPath = gitDiffPath(line[4:])
		case strings.HasPrefix(line, "@@ "):
			flush()
			m := hunkRE.FindStringSubmatch(line)
			if m == nil {
				continue
			}
			p := curPath
			if p == "" {
				p = oldPath // deleted file: +++ is /dev/null
			}
			ns, _ := strconv.Atoi(m[3])
			nc := 1
			if m[4] != "" {
				nc, _ = strconv.Atoi(m[4])
			}
			cur = &reviewHunk{path: p, newStart: ns, newCount: nc}
		default:
			if cur != nil && len(line) > 0 &&
				(line[0] == ' ' || line[0] == '+' || line[0] == '-' || line[0] == '\\') {
				if cur.body != "" {
					cur.body += "\n"
				}
				cur.body += line
			}
		}
	}
	flush()
	return out
}

// reviewScope is a resolved review subject: the diff to run, the anchor_ref
// key that identifies this review for reconcile, and the ready-verb.
type reviewScope struct {
	key     string   // parent anchor_ref: "unstaged" | "commit:<sha>" | "branch:<base>"
	label   string   // parent title
	baseRef string   // informational, stored in detail
	verb    string   // "commit" | "next steps" | "PR"
	args    []string // git args producing the diff
}

func shortSHA(s string) string {
	if len(s) > 10 {
		return s[:10]
	}
	return s
}

// resolveReviewScope maps a scope+arg to a concrete diff. Unstaged tracks the
// working tree (live, reconciled on re-run); commit pins to a sha (immutable);
// branch diffs against the merge-base. PR is deferred (needs gh).
// NOTE (v1 gap): `diff HEAD` omits untracked files — new whole files don't
// appear as hunks yet. Tracked edits are covered.
func (h *Host) resolveReviewScope(ws *WorkspaceInfo, top, scope, arg string) (reviewScope, error) {
	switch scope {
	case "", "unstaged":
		return reviewScope{key: "unstaged", label: "unstaged changes", baseRef: "HEAD",
			verb: "commit", args: []string{"diff", "HEAD"}}, nil
	case "commit":
		sha := strings.TrimSpace(arg)
		if sha == "" {
			return reviewScope{}, fmt.Errorf("commit scope needs a sha")
		}
		// A root commit has no parent — diff against git's empty-tree object
		// so the very first commit still reviews as all-additions.
		parent := sha + "^"
		if _, err := gitOut(top, reviewTimeout, "rev-parse", "--verify", "--quiet", parent+"^{commit}"); err != nil {
			parent = emptyTreeSHA
		}
		return reviewScope{key: "commit:" + sha, label: "commit " + shortSHA(sha), baseRef: parent,
			verb: "next steps", args: []string{"diff", parent, sha}}, nil
	case "branch":
		base := h.reviewBaseFor(ws, top, "branch")
		if base.mode != "branch" {
			return reviewScope{}, fmt.Errorf("no branch base (%s)", base.fallback)
		}
		return reviewScope{key: "branch:" + base.name, label: "branch vs " + base.name, baseRef: base.ref,
			verb: "PR", args: []string{"diff", base.ref}}, nil
	default:
		return reviewScope{}, fmt.Errorf("unknown scope %q (want unstaged|commit|branch)", scope)
	}
}

// prepareReview builds (or rebuilds) a review batch for a scope and returns
// its parent task. Pure git; no inference.
func (h *Host) prepareReview(ws *WorkspaceInfo, top, scope, arg string) (*RookTask, error) {
	sc, err := h.resolveReviewScope(ws, top, scope, arg)
	if err != nil {
		return nil, err
	}
	out, err := gitOut(top, reviewTimeout, sc.args...)
	if err != nil {
		return nil, err
	}
	hunks := parseReviewHunks(out)

	// reconcile: carry prior dispositions forward by (path, body) identity
	prior := map[string]string{}
	if p := h.reg.findReviewParent(ws.Name, sc.key); p != nil {
		for _, c := range h.reg.childrenOf(p.ID) {
			prior[c.Path+"\x00"+c.AnchorText] = c.State
		}
		if err := h.reg.deleteTaskTree(p.ID); err != nil {
			return nil, err
		}
	}

	commit := ""
	if o, err := gitOut(top, reviewTimeout, "rev-parse", "HEAD"); err == nil {
		commit = strings.TrimSpace(string(o))
	}
	detail, _ := json.Marshal(map[string]string{
		"scope": sc.key, "base": sc.baseRef, "verb": sc.verb, "label": sc.label,
	})
	parentID, err := h.reg.createReviewTree(ws.Name, sc, string(detail), commit, hunks, prior)
	if err != nil {
		return nil, err
	}
	return h.reg.getTask(parentID), nil
}

// createReviewTree writes the parent + one leaf per hunk in a single tx.
func (r *registry) createReviewTree(ws string, sc reviewScope, detail, commit string,
	hunks []reviewHunk, prior map[string]string) (int64, error) {
	if r.db == nil {
		return 0, fmt.Errorf("no registry db")
	}
	now := time.Now().Format(time.RFC3339Nano)
	tx, err := r.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	parentID, err := insertTask(tx, &RookTask{
		Workspace: ws, WorkType: "review", State: reviewParentState,
		Title: sc.label, AnchorKind: "ref", AnchorRef: sc.key,
		Detail: json.RawMessage(detail),
	}, now)
	if err != nil {
		return 0, err
	}
	for _, hk := range hunks {
		state := reviewStateProposed
		if s, ok := prior[hk.path+"\x00"+hk.body]; ok {
			state = s
		}
		end := hk.newStart
		if hk.newCount > 1 {
			end = hk.newStart + hk.newCount - 1
		}
		if _, err := insertTask(tx, &RookTask{
			ParentID: parentID, Workspace: ws, WorkType: "review", State: state,
			Title:      fmt.Sprintf("%s:%d", hk.path, hk.newStart),
			AnchorKind: "code", Path: hk.path, StartLine: hk.newStart, EndLine: end,
			Side: "modified", CommitSHA: commit, AnchorText: hk.body,
		}, now); err != nil {
			return 0, err
		}
	}
	return parentID, tx.Commit()
}

// reviewGate is the derived readiness of a review parent — a pure function of
// its children's states. The verb turns "ready" into the human action.
type reviewGate struct {
	Ready    bool           `json:"ready"`
	Verb     string         `json:"verb"`
	Blocking int            `json:"blocking"`
	Total    int            `json:"total"`
	Counts   map[string]int `json:"counts"`
}

// gateFromChildren is the pure gate — a function of the children's states.
// Both the persisted path and the in-memory dry run go through it.
func gateFromChildren(kids []*RookTask, verb string) reviewGate {
	g := reviewGate{Counts: map[string]int{}, Total: len(kids), Verb: verb}
	for _, c := range kids {
		g.Counts[c.State]++
		if reviewBlocking(c.State) {
			g.Blocking++
		}
	}
	g.Ready = g.Blocking == 0
	return g
}

func parentVerb(parent *RookTask) string {
	var d struct {
		Verb string `json:"verb"`
	}
	json.Unmarshal(parent.Detail, &d)
	return d.Verb
}

func (h *Host) reviewGateFor(parent *RookTask) reviewGate {
	return gateFromChildren(h.reg.childrenOf(parent.ID), parentVerb(parent))
}

// dryRunReview builds a review batch in memory and returns it WITHOUT touching
// the registry — no rows, no reconcile, nothing written to rook.db. Every hunk
// comes back Proposed (there is no stored disposition to carry). Child ids are
// positional (1..n), a preview label only. Same diff path as prepareReview.
func (h *Host) dryRunReview(ws *WorkspaceInfo, top, scope, arg string) (*RookTask, error) {
	sc, err := h.resolveReviewScope(ws, top, scope, arg)
	if err != nil {
		return nil, err
	}
	out, err := gitOut(top, reviewTimeout, sc.args...)
	if err != nil {
		return nil, err
	}
	hunks := parseReviewHunks(out)
	detail, _ := json.Marshal(map[string]string{
		"scope": sc.key, "base": sc.baseRef, "verb": sc.verb, "label": sc.label,
	})
	parent := &RookTask{
		Workspace: ws.Name, WorkType: "review", State: reviewParentState,
		Title: sc.label, AnchorKind: "ref", AnchorRef: sc.key, Detail: json.RawMessage(detail),
	}
	for i, hk := range hunks {
		end := hk.newStart
		if hk.newCount > 1 {
			end = hk.newStart + hk.newCount - 1
		}
		parent.Children = append(parent.Children, &RookTask{
			ID: int64(i + 1), Workspace: ws.Name, WorkType: "review", State: reviewStateProposed,
			Title:      fmt.Sprintf("%s:%d", hk.path, hk.newStart),
			AnchorKind: "code", Path: hk.path, StartLine: hk.newStart, EndLine: end,
			Side: "modified", AnchorText: hk.body,
		})
	}
	return parent, nil
}
