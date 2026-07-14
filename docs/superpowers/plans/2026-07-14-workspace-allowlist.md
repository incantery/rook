# Workspace Allowlist Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a presentation-only `workspace-allow` config key that filters which workspaces the host's list surfaces to the dashboard, mission control, and `/overview` — for clean demos and screenshots.

**Architecture:** One new `Config` field parsed like the existing `workflow` list. One filter applied at `Host.workspaceList()`, the sole base layer feeding `/workspaces` and `/overview`. Empty list = feature off (unchanged behavior). A workspace passes if its name or its `WorktreeOf` source is listed — the same name-or-worktree-source pattern already used for Jira and workflows. Presentation only: registration, sessions, and per-workspace endpoints are untouched.

**Tech Stack:** Go, standard library `testing`. Config is a ghostty-style `key = value` file; host tests spin up `Host` via `New()` with `XDG_DATA_HOME`/`XDG_CONFIG_HOME` pointed at temp dirs.

## Global Constraints

- Config parsing lives in `internal/config/config.go`; use the existing `splitList` helper (items trimmed, empties dropped, always non-nil).
- Empty or unset `workspace-allow` must leave `workspaceList()` output byte-for-byte identical to today.
- The filter reads config fresh via `config.Load()` per call (hot-reload, matching `issues.go`/`workflow.go`) — do **not** cache it on the `Host`.
- Follow existing test conventions: `t.Setenv("XDG_DATA_HOME", t.TempDir())` before `New()`; register workspaces via `h.reg.upsert` / `h.reg.createWorktreeWS`.
- This is a visibility filter, not access control: do not gate registration (`upsert`) or any `/workspace/<name>/...` endpoint.

---

### Task 1: Config field `WorkspaceAllow`

**Files:**
- Modify: `internal/config/config.go` (add struct field ~line 71; add parse case ~line 202, next to `case "workflow"`)
- Test: `internal/config/config_test.go`

**Interfaces:**
- Consumes: existing `splitList(string) []string` helper.
- Produces: `Config.WorkspaceAllow []string` — nil/empty when unset, populated (trimmed, non-empty items) from `workspace-allow = a, b`.

- [ ] **Step 1: Write the failing test**

Add to `internal/config/config_test.go`:

```go
func TestLoadWorkspaceAllow(t *testing.T) {
	writeConfig(t, `
workspace-allow = rook, dora
`)
	cfg := Load()
	if !slices.Equal(cfg.WorkspaceAllow, []string{"rook", "dora"}) {
		t.Fatalf("workspace-allow: %v", cfg.WorkspaceAllow)
	}

	// unset → feature off, nil list
	writeConfig(t, "# nothing configured\n")
	if cfg := Load(); cfg.WorkspaceAllow != nil {
		t.Fatalf("workspace-allow must default nil (off): %v", cfg.WorkspaceAllow)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/config/ -run TestLoadWorkspaceAllow -v`
Expected: FAIL — compile error, `cfg.WorkspaceAllow` undefined.

- [ ] **Step 3: Add the struct field**

In `internal/config/config.go`, inside the `Config` struct (after the `Keybinds` field, before the closing `}` at ~line 71-72), add:

```go
	// WorkspaceAllow is a presentation-only visibility filter: when
	// non-empty, only the named workspaces (and any worktree carved from
	// one of them) appear in the host's workspace list — the dashboard,
	// mission control, and /overview. Empty/unset means every workspace
	// shows. `workspace-allow = rook, dora`. Not access control:
	// registration and per-workspace endpoints are unaffected.
	WorkspaceAllow []string `json:"workspaceAllow"`
```

- [ ] **Step 4: Add the parse case**

In `internal/config/config.go`, in the `switch key` block, next to `case "workflow":` (~line 202), add:

```go
		case "workspace-allow":
			cfg.WorkspaceAllow = splitList(value)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `go test ./internal/config/ -run TestLoadWorkspaceAllow -v`
Expected: PASS.

- [ ] **Step 6: Run the full config package to check nothing regressed**

Run: `go test ./internal/config/`
Expected: PASS (ok).

- [ ] **Step 7: Commit**

```bash
git add internal/config/config.go internal/config/config_test.go
git commit -m "config: add workspace-allow visibility filter key"
```

---

### Task 2: Filter `workspaceList()` by the allowlist

**Files:**
- Modify: `internal/host/host.go` (`workspaceList()` at lines 377-395; add helpers `allowSet` and `allowedWorkspace` nearby)
- Test: `internal/host/workspace_allow_test.go` (create)

**Interfaces:**
- Consumes: `config.Load().WorkspaceAllow` (Task 1); existing `h.reg.upsert`, `h.reg.createWorktreeWS`, `h.workspaceList()`.
- Produces:
  - `allowSet(names []string) map[string]bool` — nil for empty input, else a membership set.
  - `allowedWorkspace(name, worktreeOf string, allow map[string]bool) bool` — true when `allow` is empty (filter off) or `allow[name]` or (`worktreeOf != ""` and `allow[worktreeOf]`).

- [ ] **Step 1: Write the failing unit test for the helper**

Create `internal/host/workspace_allow_test.go`:

```go
package host

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

func TestAllowedWorkspace(t *testing.T) {
	off := allowSet(nil)
	if !allowedWorkspace("anything", "", off) {
		t.Fatal("empty allowlist must pass everything (filter off)")
	}

	allow := allowSet([]string{"rook", "dora"})
	cases := []struct {
		name, worktreeOf string
		want             bool
	}{
		{"rook", "", true},                // named directly
		{"rook-t1", "rook", true},         // worktree of a named source
		{"scratch", "", false},            // not named
		{"dora-t2", "dora", true},         // worktree of the other named source
		{"secret-t1", "secret", false},    // worktree of an un-named source
	}
	for _, c := range cases {
		if got := allowedWorkspace(c.name, c.worktreeOf, allow); got != c.want {
			t.Errorf("allowedWorkspace(%q, %q) = %v, want %v", c.name, c.worktreeOf, got, c.want)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/host/ -run TestAllowedWorkspace -v`
Expected: FAIL — compile error, `allowSet`/`allowedWorkspace` undefined.

- [ ] **Step 3: Add the helpers**

In `internal/host/host.go`, immediately above `func (h *Host) workspaceList()` (~line 375), add:

```go
// allowSet turns the workspace-allow config list into a membership set, or
// nil when the list is empty (the filter is off).
func allowSet(names []string) map[string]bool {
	if len(names) == 0 {
		return nil
	}
	m := make(map[string]bool, len(names))
	for _, n := range names {
		m[n] = true
	}
	return m
}

// allowedWorkspace reports whether a workspace is visible under the
// workspace-allow filter. An empty set means the filter is off (everything
// visible). A workspace passes if its own name or its worktree source is
// listed — the name-or-WorktreeOf pattern shared with Jira/workflow lookups.
func allowedWorkspace(name, worktreeOf string, allow map[string]bool) bool {
	if len(allow) == 0 {
		return true
	}
	return allow[name] || (worktreeOf != "" && allow[worktreeOf])
}
```

- [ ] **Step 4: Run the helper test to verify it passes**

Run: `go test ./internal/host/ -run TestAllowedWorkspace -v`
Expected: PASS.

- [ ] **Step 5: Write the failing integration test through workspaceList()**

Append to `internal/host/workspace_allow_test.go`:

```go
// writeHostConfig points XDG_CONFIG_HOME at a temp dir holding a rook config
// with the given contents, so config.Load() (which workspaceList reads) sees it.
func writeHostConfig(t *testing.T, content string) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	if err := os.MkdirAll(filepath.Join(dir, "rook"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "rook", "config"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func listNames(items []workspaceListItem) []string {
	out := make([]string, 0, len(items))
	for _, it := range items {
		out = append(out, it.Name)
	}
	slices.Sort(out)
	return out
}

func TestWorkspaceListAllowFilter(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	h := New()
	defer h.Shutdown()

	h.reg.upsert("rook", "", false)
	h.reg.upsert("secret", "", false)
	if _, err := h.reg.createWorktreeWS("rook-t1", "", "rook", "rook/rook-t1", nil); err != nil {
		t.Fatal(err)
	}

	// filter off: everything shows
	writeHostConfig(t, "# no allowlist\n")
	if got, want := listNames(h.workspaceList()), []string{"rook", "rook-t1", "secret"}; !slices.Equal(got, want) {
		t.Fatalf("filter off: got %v, want %v", got, want)
	}

	// allow rook: rook + its worktree survive, secret is hidden
	writeHostConfig(t, "workspace-allow = rook\n")
	if got, want := listNames(h.workspaceList()), []string{"rook", "rook-t1"}; !slices.Equal(got, want) {
		t.Fatalf("allow=rook: got %v, want %v", got, want)
	}
}
```

- [ ] **Step 6: Run the integration test to verify it fails**

Run: `go test ./internal/host/ -run TestWorkspaceListAllowFilter -v`
Expected: FAIL — the `allow=rook` case still returns `secret` (filter not wired into `workspaceList` yet).

- [ ] **Step 7: Wire the filter into workspaceList()**

In `internal/host/host.go`, replace the body of `workspaceList()` (lines 377-395) with:

```go
func (h *Host) workspaceList() []workspaceListItem {
	counts := map[string]int{}
	h.mu.Lock()
	for _, s := range h.sessions {
		counts[s.info.Workspace]++
	}
	h.mu.Unlock()
	allow := allowSet(config.Load().WorkspaceAllow)
	list := h.reg.list()
	out := make([]workspaceListItem, 0, len(list))
	for _, ws := range list {
		sessions := counts[ws.Name]
		delete(counts, ws.Name) // consumed; must not reappear below even if filtered out
		if !allowedWorkspace(ws.Name, ws.WorktreeOf, allow) {
			continue
		}
		out = append(out, workspaceListItem{WorkspaceInfo: *ws, Sessions: sessions, PR: h.prm.get(ws.Name)})
	}
	// live sessions in unregistered workspaces (pre-registry hosts)
	for name, n := range counts {
		if !allowedWorkspace(name, "", allow) {
			continue
		}
		out = append(out, workspaceListItem{WorkspaceInfo: WorkspaceInfo{Name: name}, Sessions: n})
	}
	return out
}
```

(`config` is already imported in `host.go` — it is used at `host.go:451`. No new import.)

- [ ] **Step 8: Run the integration test to verify it passes**

Run: `go test ./internal/host/ -run TestWorkspaceListAllowFilter -v`
Expected: PASS.

- [ ] **Step 9: Run the full host package to confirm no regression**

Run: `go test ./internal/host/`
Expected: PASS (ok). In particular `TestOverview` still passes — it sets no allowlist, so the filter is off.

- [ ] **Step 10: Commit**

```bash
git add internal/host/host.go internal/host/workspace_allow_test.go
git commit -m "host: filter workspace list by workspace-allow (demo visibility)"
```

---

## Self-Review

**Spec coverage:**
- Config key `workspace-allow` → `Config.WorkspaceAllow` via `splitList` — Task 1. ✓
- Empty/unset = off, unchanged output — Task 1 (nil default test) + Task 2 (filter-off integration case + `allowedWorkspace` early return). ✓
- Filter at sole chokepoint `workspaceList()` covering `/workspaces` + `/overview` — Task 2 Step 7. ✓
- Name-or-`WorktreeOf` match — Task 2 `allowedWorkspace` + worktree test cases. ✓
- Unregistered-live-session branch filtered too — Task 2 Step 7 second loop. ✓
- Not a registration gate / no endpoint gating — nothing in either task touches `upsert` or `/workspace/<name>`; Global Constraints restate this. ✓
- Tests: config present/empty/absent + filter table (empty passes all, named included, worktree-of-named included, un-named excluded) — Tasks 1 & 2. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. ✓

**Type consistency:** `allowSet(names []string) map[string]bool` and `allowedWorkspace(name, worktreeOf string, allow map[string]bool) bool` are defined in Task 2 Step 3 and used identically in Steps 1, 5, and 7. `WorkspaceAllow []string` defined in Task 1 Step 3, consumed in Task 2 Step 7. `workspaceListItem` / `.Name` match host.go usage. ✓
