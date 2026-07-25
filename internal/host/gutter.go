package host

// The git gutter for NORMAL buffers: which lines of a file differ from a
// base blob, as margin stripes — added, modified, and a marker at each
// deletion boundary. This is what lets review reading happen in the real
// file instead of a special diff mode: the gutter supplies the change
// context, the buffer stays a buffer.
//
// Rides the reanchor machinery (diffHunks/parseHunks) rather than its own
// diff: one hunk grammar in the codebase, one set of gotchas.

import (
	"net/http"
	"path/filepath"
	"strings"
)

type gutterHunk struct {
	// 1-based inclusive range in the WORKING file
	Start int    `json:"start"`
	End   int    `json:"end"`
	Kind  string `json:"kind"` // added|modified|deleted
	// lines removed at this hunk (deleted: all of them; modified: how many
	// the new range replaced). Deleted-line virtual text is deferred — the
	// count is the honest summary until then.
	DelLines int `json:"delLines,omitempty"`
}

// classifyHunks maps --unified=0 hunks onto gutter stripes. A pure function
// of the hunk headers, so the table test needs no repo.
func classifyHunks(hunks []hunk) []gutterHunk {
	out := []gutterHunk{}
	for _, hk := range hunks {
		switch {
		case hk.newCount == 0 && hk.oldCount > 0:
			// pure deletion: git reports the new-file line BEFORE the cut
			// (0 when the cut is at the very top) — the marker sits on that
			// boundary line, clamped into the file
			line := max(hk.newStart, 1)
			out = append(out, gutterHunk{Start: line, End: line, Kind: "deleted", DelLines: hk.oldCount})
		case hk.oldCount == 0 && hk.newCount > 0:
			out = append(out, gutterHunk{Start: hk.newStart, End: hk.newStart + hk.newCount - 1, Kind: "added"})
		case hk.newCount > 0:
			out = append(out, gutterHunk{
				Start: hk.newStart, End: hk.newStart + hk.newCount - 1,
				Kind: "modified", DelLines: hk.oldCount,
			})
		}
	}
	return out
}

// gutterBaseFor resolves the ?base= param: ""/head/branch ride the review
// machinery; anything else is an explicit ref (the active review's scope
// base — a merge-base sha, a commit's parent). An unresolvable ref fails
// open to HEAD: a bare margin beats a broken buffer.
func (h *Host) gutterBaseFor(ws *WorkspaceInfo, top, param string) reviewBase {
	switch param {
	case "", "head":
		return h.reviewBaseFor(ws, top, "head")
	case "branch":
		return h.reviewBaseFor(ws, top, "branch")
	}
	if _, err := gitOut(top, reviewTimeout, "rev-parse", "--verify", "--quiet", param+"^{commit}"); err == nil {
		return reviewBase{mode: "ref", ref: param, name: shortSHA(param)}
	}
	return reviewBase{mode: "head", ref: "HEAD", name: "HEAD", fallback: "unknown base " + param}
}

// handleWorkspaceGutter is GET /workspaces/{name}/gutter?path=&base= — the
// stripes for one file vs a base (default HEAD).
//
// Path takes the same two shapes as every read. Relative = this workspace's
// repo, reviewed against the review base. Absolute = the EXTERNAL tier, and
// the workspace's repo has nothing to say about it: the file's OWN repo
// answers, always against its HEAD (a merge-base computed in one checkout
// means nothing in another). A file in no repo at all gets a bare margin —
// an unstriped file is a normal thing, not an error.
func (h *Host) handleWorkspaceGutter(w http.ResponseWriter, r *http.Request, name string) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	reqPath := r.URL.Query().Get("path")
	if reqPath == "" {
		http.Error(w, "path required", http.StatusBadRequest)
		return
	}
	var (
		abs     string // the file on disk
		top     string // the repo that answers for it
		gitPath string // abs relative to top, forward slashes — git's spelling
		base    reviewBase
	)
	if strings.HasPrefix(reqPath, "/") {
		abs = filepath.Clean(reqPath)
		// top stays empty when the file is in no repo — the read below still
		// decides 404 vs bare margin, so a bogus path can't hide behind
		// "not a repo"
		if t, err := repoTop(filepath.Dir(abs)); err == nil {
			// canonical both sides: git reports the resolved top while the
			// client may spell the file through a symlink (/tmp, /var on
			// macOS), and a literal Rel would climb out with ../
			if rel, rerr := filepath.Rel(canonical(t), canonicalFile(abs)); rerr == nil &&
				!strings.HasPrefix(rel, "..") {
				top, gitPath = t, filepath.ToSlash(rel)
				base = reviewBase{mode: "head", ref: "HEAD", name: "HEAD"}
			}
		}
	} else {
		ws, t, ok := h.reviewRepo(w, name)
		if !ok {
			return
		}
		a, err := confinePath(t, reqPath)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		abs, top, gitPath = a, t, reqPath
		base = h.gutterBaseFor(ws, t, r.URL.Query().Get("base"))
	}
	cur, missing, err := readOrMissing(abs)
	if err != nil {
		http.Error(w, "no such file: "+reqPath, http.StatusNotFound)
		return
	}
	answer := func(hunks []gutterHunk) {
		writeJSON(w, map[string]any{"base": base.name, "hunks": hunks})
	}
	if missing || top == "" {
		// a new file has nothing to stripe yet; a file in no repo never will
		answer([]gutterHunk{})
		return
	}
	if _, binary, _ := capSide(cur); binary || len(cur) > reviewMaxSide {
		answer([]gutterHunk{}) // a bare margin, not an error
		return
	}
	old, err := gitOut(top, reviewTimeout, "show", base.ref+":"+gitPath)
	if err != nil {
		// not at the base — the whole file is an addition
		n := strings.Count(string(cur), "\n")
		if len(cur) > 0 && !strings.HasSuffix(string(cur), "\n") {
			n++
		}
		if n == 0 {
			answer([]gutterHunk{})
			return
		}
		answer([]gutterHunk{{Start: 1, End: n, Kind: "added"}})
		return
	}
	hunks, err := diffHunks(old, cur)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	answer(classifyHunks(hunks))
}
