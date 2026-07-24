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
	"os"
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
	// newRef is where the diff's NEW side lives: a commit sha for the
	// commit scope, "" for the working tree — the content the leaves'
	// anchor blobs snapshot (reanchor's shared seam).
	newRef string
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
			verb: "next steps", args: []string{"diff", parent, sha}, newRef: sha}, nil
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
	blobs := h.captureReviewBlobs(top, sc, hunks)
	parentID, err := h.reg.createReviewTree(ws.Name, sc, string(detail), commit, hunks, prior, blobs)
	if err != nil {
		return nil, err
	}
	// the replaced tree's blobs (if any) are unreferenced now
	h.reg.pruneAnchorBlobs()
	return h.reg.getTask(parentID), nil
}

// captureReviewBlobs snapshots the NEW side of each touched file, so review
// leaves re-anchor through the same blob-diff seam threads use. A file that
// can't be read (deleted in the diff), is binary, or exceeds the anchor cap
// simply gets no blob — its leaves keep the stored range, fail open.
func (h *Host) captureReviewBlobs(top string, sc reviewScope, hunks []reviewHunk) map[string]anchorBlob {
	out := map[string]anchorBlob{}
	for _, hk := range hunks {
		if _, done := out[hk.path]; done {
			continue
		}
		var content []byte
		var err error
		if sc.newRef != "" {
			content, err = gitOut(top, reviewTimeout, "show", sc.newRef+":"+hk.path)
		} else {
			abs, cerr := confinePath(top, hk.path)
			if cerr != nil {
				continue
			}
			content, err = os.ReadFile(abs)
		}
		if err != nil {
			continue
		}
		if _, binary, _ := capSide(content); binary || len(content) > reviewMaxSide {
			continue
		}
		out[hk.path] = anchorBlob{sha: gitBlobSHA(content), content: content}
	}
	return out
}

// anchorBlob is one captured snapshot headed for anchor_blobs.
type anchorBlob struct {
	sha     string
	content []byte
}

// createReviewTree writes the parent + one leaf per hunk in a single tx,
// blobs included — the blob lands before any leaf referencing it, the same
// ordering createThread guarantees.
func (r *registry) createReviewTree(ws string, sc reviewScope, detail, commit string,
	hunks []reviewHunk, prior map[string]string, blobs map[string]anchorBlob) (int64, error) {
	if r.db == nil {
		return 0, fmt.Errorf("no registry db")
	}
	now := time.Now().Format(time.RFC3339Nano)
	tx, err := r.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	for _, b := range blobs {
		if _, err := tx.Exec(`INSERT OR IGNORE INTO anchor_blobs (sha, content) VALUES (?, ?)`,
			b.sha, b.content); err != nil {
			return 0, err
		}
	}
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
			BlobSHA: blobs[hk.path].sha,
		}, now); err != nil {
			return 0, err
		}
	}
	return parentID, tx.Commit()
}

// resolveThreadLink picks what a review-linked thread attaches to:
// anchored inside a leaf's CURRENT range → that leaf (a local comment — it
// flips the leaf pending and blocks the gate); anywhere else → the review
// parent (a global comment). The local-vs-global distinction, for free.
// Unknown or foreign roots fail open to no link at all.
func (h *Host) resolveThreadLink(ws *WorkspaceInfo, top string, rootID int64,
	path string, start, end int) int64 {
	root := h.reg.getTask(rootID)
	if root == nil || root.WorkType != "review" || root.ParentID != 0 ||
		root.Workspace != ws.Name {
		return 0
	}
	for _, c := range h.reg.childrenOf(root.ID) {
		if c.AnchorKind != "code" || c.Path != path {
			continue
		}
		h.anchorTaskNow(ws, top, c)
		if c.Outdated {
			continue
		}
		if start <= c.CurrentEnd && end >= c.CurrentStart {
			return c.ID
		}
	}
	return root.ID
}

// syncLinkedLeaf recomputes a review leaf's state from its linked threads:
// any open thread keeps it pending (the gate stays closed — reviewBlocking
// finally has something setting the state it always counted); the last
// resolve restores the prior disposition. Creation, resolve, reopen and the
// gt-abort delete all route through here, so the flip can't drift.
func (h *Host) syncLinkedLeaf(taskID int64) {
	if taskID == 0 {
		return
	}
	leaf := h.reg.getTask(taskID)
	if leaf == nil || leaf.WorkType != "review" || leaf.ParentID == 0 {
		return // parent links carry no state — a global comment doesn't gate
	}
	if h.reg.openThreadsLinkedTo(taskID) > 0 {
		if leaf.State == reviewStatePending {
			return
		}
		prior, _ := json.Marshal(leaf.State)
		if err := h.reg.mergeTaskDetail(leaf.ID, map[string]json.RawMessage{"prior": prior}); err != nil {
			return // don't flip a state we couldn't remember
		}
		_ = h.reg.setTaskState(leaf.ID, reviewStatePending)
		return
	}
	if leaf.State != reviewStatePending {
		return
	}
	var d struct {
		Prior string `json:"prior"`
	}
	json.Unmarshal(leaf.Detail, &d)
	restore := d.Prior
	if !validReviewLeafState(restore) || restore == reviewStatePending {
		restore = reviewStateProposed
	}
	_ = h.reg.setTaskState(leaf.ID, restore)
}

// openThreadsLinkedTo counts a task's unresolved threads — what keeps a
// review leaf pending.
func (r *registry) openThreadsLinkedTo(taskID int64) int {
	if r.db == nil {
		return 0
	}
	var n int
	if err := r.db.QueryRow(
		`SELECT COUNT(*) FROM threads WHERE rook_task_id = ? AND state != 'resolved'`,
		taskID).Scan(&n); err != nil {
		return 0
	}
	return n
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
