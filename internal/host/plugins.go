package host

// The plugin lifecycle surface — generic across kinds, exercised by one
// kind today (language). GET /plugins lists the catalog against the USER
// config (no repo layer: lifecycle is per-machine, not per-workspace);
// the install/upgrade verbs materialize synchronously, which is what
// `rookctl plugin install` wants — it waits, prints, exits.

import (
	"encoding/json"
	"net/http"
	"slices"

	"github.com/incantery/rook/internal/config"
	"github.com/incantery/rook/internal/plugin"
)

type pluginStatus struct {
	Name     string `json:"name"`
	Kind     string `json:"kind"`
	Version  string `json:"version"`
	Server   string `json:"server,omitempty"`
	Selected bool   `json:"selected"` // named by `lsp =` in the user config
	State    string `json:"state"`
	Detail   string `json:"detail,omitempty"`
}

func (h *Host) pluginList() []pluginStatus {
	cfg := config.Load()
	out := make([]pluginStatus, 0, len(plugin.Catalog))
	for _, e := range plugin.Catalog {
		st := pluginStatus{
			Name:     e.Name,
			Kind:     string(e.Kind),
			Version:  e.Version,
			Selected: slices.Contains(cfg.LSP, e.Name),
		}
		if e.Lang != nil {
			st.Server = e.Lang.Server
		}
		st.State, st.Detail = h.pm.State(e)
		out = append(out, st)
	}
	return out
}

func (h *Host) handlePlugins(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/plugins" && r.Method == http.MethodGet:
		writeJSON(w, h.pluginList())
	case r.URL.Path == "/plugins/install" && r.Method == http.MethodPost:
		h.handlePluginInstall(w, r, false)
	case r.URL.Path == "/plugins/upgrade" && r.Method == http.MethodPost:
		h.handlePluginInstall(w, r, true)
	default:
		http.Error(w, "not found", http.StatusNotFound)
	}
}

// handlePluginInstall materializes one plugin (or every selected one when
// name is empty), synchronously. upgrade also prunes non-pinned versions
// once the pin is ready.
func (h *Host) handlePluginInstall(w http.ResponseWriter, r *http.Request, upgrade bool) {
	var req struct{ Name string }
	json.NewDecoder(r.Body).Decode(&req)
	var targets []plugin.Entry
	if req.Name != "" {
		e := plugin.CatalogEntry(req.Name)
		if e == nil {
			http.Error(w, "no such plugin: "+req.Name, http.StatusNotFound)
			return
		}
		targets = append(targets, *e)
	} else {
		cfg := config.Load()
		for _, name := range cfg.LSP {
			if e := plugin.CatalogEntry(name); e != nil {
				targets = append(targets, *e)
			}
		}
		if len(targets) == 0 {
			http.Error(w, "nothing selected — set `lsp = <languages>` or name a plugin", http.StatusBadRequest)
			return
		}
	}
	type result struct {
		Name  string `json:"name"`
		State string `json:"state"`
		Error string `json:"error,omitempty"`
	}
	out := []result{}
	for _, e := range targets {
		res := result{Name: e.Name}
		if err := h.pm.Install(e); err != nil {
			res.Error = err.Error()
		} else if upgrade {
			h.pm.Prune(e)
		}
		res.State, _ = h.pm.State(e)
		out = append(out, res)
	}
	writeJSON(w, out)
}
