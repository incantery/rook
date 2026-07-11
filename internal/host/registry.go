package host

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// WorkspaceInfo is a persistent workspace: it exists independent of live
// sessions (VS Code-style), stored in the state dir so it survives host
// restarts. Scratch workspaces are the exception — ephemeral by design,
// removed when their last session dies.
type WorkspaceInfo struct {
	Name     string    `json:"name"`
	Root     string    `json:"root,omitempty"`
	Scratch  bool      `json:"scratch,omitempty"`
	Created  time.Time `json:"created"`
	LastUsed time.Time `json:"lastUsed"`
}

type registry struct {
	mu    sync.Mutex
	path  string
	items map[string]*WorkspaceInfo
}

func loadRegistry() *registry {
	r := &registry{
		path:  filepath.Join(StateDir(), "workspaces.json"),
		items: make(map[string]*WorkspaceInfo),
	}
	if data, err := os.ReadFile(r.path); err == nil {
		var list []*WorkspaceInfo
		if json.Unmarshal(data, &list) == nil {
			for _, w := range list {
				r.items[w.Name] = w
			}
		}
	}
	return r
}

// save persists under the caller's lock.
func (r *registry) save() {
	list := make([]*WorkspaceInfo, 0, len(r.items))
	for _, w := range r.items {
		list = append(list, w)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Created.Before(list[j].Created) })
	data, err := json.MarshalIndent(list, "", "  ")
	if err != nil {
		return
	}
	os.MkdirAll(filepath.Dir(r.path), 0o700)
	os.WriteFile(r.path, data, 0o600)
}

// upsert registers a workspace (or refreshes LastUsed on an existing one)
// and returns it.
func (r *registry) upsert(name, root string, scratch bool) *WorkspaceInfo {
	r.mu.Lock()
	defer r.mu.Unlock()
	w, ok := r.items[name]
	if !ok {
		w = &WorkspaceInfo{Name: name, Root: root, Scratch: scratch, Created: time.Now()}
		r.items[name] = w
	} else if root != "" {
		w.Root = root
	}
	w.LastUsed = time.Now()
	r.save()
	return w
}

func (r *registry) get(name string) *WorkspaceInfo {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.items[name]
}

func (r *registry) remove(name string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.items[name]; ok {
		delete(r.items, name)
		r.save()
	}
}

func (r *registry) list() []*WorkspaceInfo {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]*WorkspaceInfo, 0, len(r.items))
	for _, w := range r.items {
		cp := *w
		out = append(out, &cp)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].LastUsed.After(out[j].LastUsed) })
	return out
}
