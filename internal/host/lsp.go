package host

// The language-type plugin surface: /workspaces/{name}/lsp/* . The host is
// the only LSP speaker (internal/lsp); Monaco and rookctl see rook-shaped
// JSON with 1-based editor positions and workspace-relative paths. Posture
// is fail open everywhere (host-protocol-skew rule): no server for a
// filetype, a binary still installing, a crashed server — all read as
// empty results plus a note, never an error the editor would shout about.

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/incantery/rook/internal/config"
	"github.com/incantery/rook/internal/lsp"
	"github.com/incantery/rook/internal/plugin"
)

const (
	lspQueryTimeout = 10 * time.Second
	// a crashed instance sits out this long before a query may respawn it
	// — restart-with-backoff without a restart storm
	lspCooldown = 15 * time.Second
)

// lspInstance is one live server: (server, root) → a running client.
type lspInstance struct {
	client  *lsp.Client
	spec    plugin.ServerSpec
	root    string
	started time.Time
}

type lspManager struct {
	pm  *plugin.Manager
	ctx context.Context

	mu        sync.Mutex
	instances map[string]*lspInstance
	starting  map[string]chan struct{}
	cooldown  map[string]time.Time
}

func newLSPManager(ctx context.Context, pm *plugin.Manager) *lspManager {
	return &lspManager{
		pm:        pm,
		ctx:       ctx,
		instances: map[string]*lspInstance{},
		starting:  map[string]chan struct{}{},
		cooldown:  map[string]time.Time{},
	}
}

func lspKey(server, root string) string { return server + "\x00" + root }

// instance returns a live client for (spec, root), starting one if needed.
// A nil client with a note is the fail-open answer: not ready, here's why.
func (lm *lspManager) instance(spec plugin.ServerSpec, root string) (*lsp.Client, string) {
	// Managed binaries must be materialized first — kick the lazy install
	// and answer empty until it lands.
	if spec.Tier == "catalog" {
		e := plugin.CatalogEntry(spec.Plugin)
		if e == nil {
			return nil, "catalog entry vanished" // can't happen; belt+braces
		}
		switch state, detail := lm.pm.State(*e); state {
		case "ready":
		case "missing":
			lm.pm.EnsureInstalled(*e)
			return nil, spec.Server + " installing"
		case "installing":
			return nil, spec.Server + " installing"
		case "needs-toolchain":
			return nil, spec.Server + " needs the " + detail + " toolchain"
		default:
			return nil, spec.Server + " install failed: " + detail
		}
	}
	key := lspKey(spec.Server, root)
	for {
		lm.mu.Lock()
		if inst := lm.instances[key]; inst != nil {
			lm.mu.Unlock()
			return inst.client, ""
		}
		if until := lm.cooldown[key]; time.Now().Before(until) {
			lm.mu.Unlock()
			return nil, spec.Server + " restarting (crashed recently)"
		}
		if ch := lm.starting[key]; ch != nil {
			lm.mu.Unlock()
			<-ch // someone else is mid-handshake; take their result
			continue
		}
		ch := make(chan struct{})
		lm.starting[key] = ch
		lm.mu.Unlock()

		client, err := lsp.Start(lm.ctx, spec.Command, root, spec.Settings)
		lm.mu.Lock()
		delete(lm.starting, key)
		close(ch)
		if err != nil {
			lm.cooldown[key] = time.Now().Add(lspCooldown)
			lm.mu.Unlock()
			return nil, spec.Server + ": " + err.Error()
		}
		inst := &lspInstance{client: client, spec: spec, root: root, started: time.Now()}
		lm.instances[key] = inst
		lm.mu.Unlock()
		go lm.reap(key, inst)
		return client, ""
	}
}

// reap notices an instance dying and clears it, with a cooldown so a
// crash-looping server backs off instead of respawning per keystroke.
func (lm *lspManager) reap(key string, inst *lspInstance) {
	<-inst.client.Done()
	lm.mu.Lock()
	if lm.instances[key] == inst {
		delete(lm.instances, key)
		lm.cooldown[key] = time.Now().Add(lspCooldown)
	}
	lm.mu.Unlock()
}

// stop closes every instance of one server (or all, server "") — the
// restart verb's first half; the next query starts fresh.
func (lm *lspManager) stop(server string) int {
	lm.mu.Lock()
	var victims []*lspInstance
	for key, inst := range lm.instances {
		if server == "" || inst.spec.Server == server {
			delete(lm.instances, key)
			delete(lm.cooldown, lspKey(inst.spec.Server, inst.root))
			victims = append(victims, inst)
		}
	}
	// an explicit restart also clears backoffs for dead instances
	for key := range lm.cooldown {
		if server == "" || strings.HasPrefix(key, server+"\x00") {
			delete(lm.cooldown, key)
		}
	}
	lm.mu.Unlock()
	for _, v := range victims {
		v.client.Close()
	}
	return len(victims)
}

// snapshot lists live instances per server for the status surface.
func (lm *lspManager) snapshot() map[string][]lspInstanceStatus {
	lm.mu.Lock()
	defer lm.mu.Unlock()
	out := map[string][]lspInstanceStatus{}
	for _, inst := range lm.instances {
		out[inst.spec.Server] = append(out[inst.spec.Server], lspInstanceStatus{
			Root:      inst.root,
			Pid:       inst.client.Pid(),
			UptimeSec: int(time.Since(inst.started).Seconds()),
		})
	}
	return out
}

// ---- wire shapes ----

type lspQueryRequest struct {
	Path string `json:"path"`
	Line int    `json:"line"` // 1-based
	Col  int    `json:"col"`  // 1-based
	// Text is the current buffer when it's dirty; empty serves from disk.
	Text string `json:"text"`
}

type lspLocation struct {
	Path      string `json:"path"` // workspace-relative, or absolute when External
	StartLine int    `json:"startLine"`
	StartCol  int    `json:"startCol"`
	EndLine   int    `json:"endLine"`
	EndCol    int    `json:"endCol"`
	LineText  string `json:"lineText,omitempty"`
	// External marks a hit outside the workspace (stdlib, dependencies) —
	// the path is absolute and the file endpoints can't serve it.
	External bool `json:"external,omitempty"`
}

type lspQueryResult struct {
	Locations []lspLocation `json:"locations"`
	Note      string        `json:"note,omitempty"`
}

type lspHoverResult struct {
	Contents string `json:"contents"`
	Note     string `json:"note,omitempty"`
}

// lspSemanticResult carries the server's legend alongside its token data,
// because the data is indices INTO the legend and the two are only
// meaningful together. Data is LSP's relative 5-tuple encoding, untouched —
// Monaco's is byte-identical, so the whole path is a passthrough.
type lspSemanticResult struct {
	Types     []string `json:"types"`
	Modifiers []string `json:"modifiers"`
	Data      []uint32 `json:"data"`
	Note      string   `json:"note,omitempty"`
}

type lspInstanceStatus struct {
	Root      string `json:"root"`
	Pid       int    `json:"pid"`
	UptimeSec int    `json:"uptimeSec"`
}

type lspServerStatus struct {
	Server    string              `json:"server"`
	Plugin    string              `json:"plugin,omitempty"`
	Tier      string              `json:"tier"`
	State     string              `json:"state"`
	Detail    string              `json:"detail,omitempty"`
	Version   string              `json:"version,omitempty"`
	Filetypes []string            `json:"filetypes"`
	Instances []lspInstanceStatus `json:"instances,omitempty"`
}

type lspStatusResult struct {
	Servers []lspServerStatus `json:"servers"`
	Issues  []plugin.Issue    `json:"issues,omitempty"`
	Refused []string          `json:"refused,omitempty"`
}

// ---- request plumbing ----

// lspWorkspace resolves the workspace root the way the file endpoints do:
// repo top when the root is a repo (paths stay git-shaped), the bare root
// otherwise. The .rook/config repo layer reads from the same top.
func (h *Host) lspWorkspace(w http.ResponseWriter, name string) (top string, ok bool) {
	ws := h.reg.get(name)
	if ws == nil {
		http.Error(w, "no such workspace: "+name, http.StatusNotFound)
		return "", false
	}
	if ws.Root == "" {
		http.Error(w, "workspace has no root", http.StatusBadRequest)
		return "", false
	}
	top, err := repoTop(ws.Root)
	if err != nil {
		top = ws.Root
	}
	return top, true
}

// specFor picks the effective server for a file by extension.
func specFor(specs []plugin.ServerSpec, path string) *plugin.ServerSpec {
	ext := strings.TrimPrefix(filepath.Ext(path), ".")
	if ext == "" {
		// extensionless well-known files: go.mod is ".mod"-less "go.mod"?
		// No — filepath.Ext("go.mod") is ".mod". Nothing to do here yet.
		return nil
	}
	for i := range specs {
		for _, ft := range specs[i].Filetypes {
			if strings.EqualFold(ft, ext) {
				return &specs[i]
			}
		}
	}
	return nil
}

// lspRoot walks from the file's directory up to top looking for the first
// directory holding any root marker — the monorepo answer (principle:
// roots, not directory config). No marker → top.
func lspRoot(abs, top string, markers []string) string {
	dir := filepath.Dir(abs)
	for {
		for _, m := range markers {
			if _, err := os.Stat(filepath.Join(dir, m)); err == nil {
				return dir
			}
		}
		if dir == top {
			return top
		}
		parent := filepath.Dir(dir)
		if parent == dir || len(parent) < len(top) {
			return top
		}
		dir = parent
	}
}

// handleWorkspaceLSP routes /workspaces/{name}/lsp/{verb}.
func (h *Host) handleWorkspaceLSP(w http.ResponseWriter, r *http.Request, name, verb string) {
	switch {
	case verb == "status" && r.Method == http.MethodGet:
		h.handleLSPStatus(w, name)
	case verb == "restart" && r.Method == http.MethodPost:
		var req struct{ Server string }
		json.NewDecoder(r.Body).Decode(&req)
		writeJSON(w, map[string]int{"stopped": h.lm.stop(req.Server)})
	case (verb == "definition" || verb == "references" || verb == "hover" ||
		verb == "semanticTokens") && r.Method == http.MethodPost:
		h.handleLSPQuery(w, r, name, verb)
	default:
		http.Error(w, "not found", http.StatusNotFound)
	}
}

func (h *Host) handleLSPQuery(w http.ResponseWriter, r *http.Request, name, verb string) {
	top, ok := h.lspWorkspace(w, name)
	if !ok {
		return
	}
	var req lspQueryRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, writeMaxSize)).Decode(&req); err != nil {
		http.Error(w, "bad body: "+err.Error(), http.StatusBadRequest)
		return
	}
	// An absolute path is a query FROM an external file (gd landed in the
	// stdlib and the user keeps digging). It rides the WORKSPACE's instance —
	// the server that produced those locations already has them open; walking
	// root markers up from GOROOT would mint a second instance for nothing.
	external := strings.HasPrefix(req.Path, "/")
	var abs string
	if external {
		abs = filepath.Clean(req.Path)
	} else {
		var err error
		abs, err = confinePath(top, req.Path)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
	}
	specs, _ := plugin.Resolve(config.LoadWorkspace(top), h.pm)
	spec := specFor(specs, req.Path)
	if spec == nil {
		h.lspEmpty(w, verb, "no language server configured for ."+strings.TrimPrefix(filepath.Ext(req.Path), "."))
		return
	}
	root := top
	if !external {
		root = lspRoot(abs, top, spec.Roots)
	}
	client, note := h.lm.instance(*spec, root)
	if client == nil {
		h.lspEmpty(w, verb, note)
		return
	}
	if err := client.EnsureOpen(abs, req.Text); err != nil {
		h.lspEmpty(w, verb, "open: "+err.Error())
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), lspQueryTimeout)
	defer cancel()
	pos := lsp.Position{Line: req.Line - 1, Col: req.Col - 1}
	switch verb {
	case "semanticTokens":
		// No position: this verb is whole-file. The legend rides along
		// because the data indexes into it.
		lg := client.Legend()
		res := lspSemanticResult{Types: lg.Types, Modifiers: lg.Modifiers, Data: []uint32{}}
		if len(lg.Types) == 0 {
			res.Note = "server has no semantic tokens"
			writeJSON(w, res)
			return
		}
		data, err := client.SemanticTokens(ctx, abs)
		if err != nil {
			res.Note = err.Error() // fail open: no tokens + why
		} else if data != nil {
			res.Data = data
		}
		writeJSON(w, res)
	case "hover":
		text, _, err := client.Hover(ctx, abs, pos)
		res := lspHoverResult{Contents: text}
		if err != nil {
			res.Note = err.Error() // fail open: empty hover + why
		}
		writeJSON(w, res)
	default:
		var locs []lsp.Location
		var err error
		if verb == "definition" {
			locs, err = client.Definition(ctx, abs, pos)
		} else {
			locs, err = client.References(ctx, abs, pos)
		}
		res := lspQueryResult{Locations: []lspLocation{}}
		if err != nil {
			res.Note = err.Error()
		}
		for _, l := range locs {
			res.Locations = append(res.Locations, toWireLocation(l, top))
		}
		writeJSON(w, res)
	}
}

func (h *Host) lspEmpty(w http.ResponseWriter, verb, note string) {
	switch verb {
	case "hover":
		writeJSON(w, lspHoverResult{Note: note})
	case "semanticTokens":
		writeJSON(w, lspSemanticResult{Types: []string{}, Data: []uint32{}, Note: note})
	default:
		writeJSON(w, lspQueryResult{Locations: []lspLocation{}, Note: note})
	}
}

func toWireLocation(l lsp.Location, top string) lspLocation {
	out := lspLocation{
		StartLine: l.Range.Start.Line + 1,
		StartCol:  l.Range.Start.Col + 1,
		EndLine:   l.Range.End.Line + 1,
		EndCol:    l.Range.End.Col + 1,
		LineText:  lineAt(l.Path, l.Range.Start.Line),
	}
	if rel, err := filepath.Rel(top, l.Path); err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		out.Path = filepath.ToSlash(rel)
	} else {
		out.Path, out.External = l.Path, true
	}
	return out
}

// lineAt reads one line of a file for the grep-shaped surface —
// best-effort, bounded, never an error.
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

func (h *Host) handleLSPStatus(w http.ResponseWriter, name string) {
	top, ok := h.lspWorkspace(w, name)
	if !ok {
		return
	}
	cfg := config.LoadWorkspace(top)
	specs, issues := plugin.Resolve(cfg, h.pm)
	live := h.lm.snapshot()
	res := lspStatusResult{Servers: []lspServerStatus{}, Issues: issues, Refused: cfg.LSPRefused}
	for _, spec := range specs {
		s := lspServerStatus{
			Server:    spec.Server,
			Plugin:    spec.Plugin,
			Tier:      spec.Tier,
			Filetypes: spec.Filetypes,
		}
		if spec.Tier == "catalog" {
			if e := plugin.CatalogEntry(spec.Plugin); e != nil {
				s.Version = e.Version
				s.State, s.Detail = h.pm.State(*e)
			}
		} else {
			if p, err := exec.LookPath(spec.Command[0]); err == nil {
				s.State, s.Detail = "ready", p
			} else {
				s.State, s.Detail = "missing", spec.Command[0]+" not on PATH"
			}
		}
		// instance roots render workspace-relative like every other path
		for _, inst := range live[spec.Server] {
			rel, err := filepath.Rel(top, inst.Root)
			if err == nil && !strings.HasPrefix(rel, "..") {
				inst.Root = filepath.ToSlash(rel)
				if inst.Root == "." {
					inst.Root = ""
				}
			}
			s.Instances = append(s.Instances, inst)
		}
		res.Servers = append(res.Servers, s)
	}
	writeJSON(w, res)
}
