package host

// The explore work-type — an investigation as a durable RookTask. The root
// is the question ("why does the replay gate steal focus?"); its children
// are breadcrumbs: code anchors visited while the question was open,
// appended from the frontend's opener seam (and by anything else that
// cares to record a visit — the trail is agent-writable too). Threads
// carry the thoughts; this type only owns the trail. States: a root is
// open|done, a breadcrumb is visited|starred. Unlike review there is no
// batch builder and no gate — the trail is append-only history, not a
// work list to drain.

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
)

func validExploreState(s string, root bool) bool {
	if root {
		return s == "open" || s == "done"
	}
	return s == "visited" || s == "starred"
}

// handleWorkspaceExplore is POST /workspaces/{name}/explore {title} — start
// an investigation. Listing rides GET /tasks?workType=explore.
func (h *Host) handleWorkspaceExplore(w http.ResponseWriter, r *http.Request, name string) {
	if h.reg.get(name) == nil {
		http.Error(w, "no such workspace: "+name, http.StatusNotFound)
		return
	}
	var req struct{ Title string }
	json.NewDecoder(r.Body).Decode(&req)
	title := strings.TrimSpace(req.Title)
	if title == "" {
		http.Error(w, "missing title — an investigation is a question", http.StatusBadRequest)
		return
	}
	t, err := h.reg.createTask(&RookTask{
		Workspace:  name,
		WorkType:   "explore",
		State:      "open",
		Title:      title,
		AnchorKind: "none",
		Detail:     json.RawMessage("{}"),
	})
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, t)
}

// handleTaskVisit is POST /tasks/{id}/visit {path, line, col} — append a
// breadcrumb to an open investigation. Consecutive visits to the same line
// collapse (a jump that lands where you already are is not a step), and
// the anchored line's text is captured now — the trail should still read
// when the code has moved on.
func (h *Host) handleTaskVisit(w http.ResponseWriter, r *http.Request, id int64) {
	t := h.reg.getTask(id)
	if t == nil {
		http.Error(w, "no such task", http.StatusNotFound)
		return
	}
	if t.WorkType != "explore" || t.ParentID != 0 {
		http.Error(w, "visit wants an explore root", http.StatusBadRequest)
		return
	}
	if t.State != "open" {
		http.Error(w, "investigation is not open", http.StatusBadRequest)
		return
	}
	var req struct {
		Path      string
		Line, Col int
	}
	json.NewDecoder(r.Body).Decode(&req)
	if req.Path == "" {
		http.Error(w, "missing path", http.StatusBadRequest)
		return
	}
	if req.Line < 1 {
		req.Line = 1
	}
	if req.Col < 1 {
		req.Col = 1
	}
	ws := h.reg.get(t.Workspace)
	if ws == nil || ws.Root == "" {
		http.Error(w, "workspace has no root", http.StatusBadRequest)
		return
	}
	top, err := repoTop(ws.Root)
	if err != nil {
		top = ws.Root
	}
	abs, err := confinePath(top, req.Path)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	kids := h.reg.childrenOf(t.ID)
	if len(kids) > 0 {
		last := kids[len(kids)-1]
		if last.Path == req.Path && last.StartLine == req.Line {
			writeJSON(w, last)
			return
		}
	}
	child, err := h.reg.createTask(&RookTask{
		ParentID:   t.ID,
		Workspace:  t.Workspace,
		WorkType:   "explore",
		State:      "visited",
		AnchorKind: "code",
		Path:       req.Path,
		StartLine:  req.Line,
		EndLine:    req.Line,
		Side:       "modified",
		AnchorText: lineAt(abs, req.Line-1),
		Detail:     json.RawMessage(fmt.Sprintf(`{"col":%d}`, req.Col)),
	})
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, child)
}

// lineAt reads one line of a file — best-effort, bounded, never an error.
// It lived in lsp.go until the host stopped speaking LSP; the anchor text
// an explore task records is the last thing that wanted it.
func lineAt(path string, line int) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for i := 0; sc.Scan(); i++ {
		if i == line {
			return strings.TrimSpace(sc.Text())
		}
	}
	return ""
}
