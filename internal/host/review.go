package host

// The read-only review surface: what the Monaco diff pane and file viewer
// fetch. Everything goes through the host API — never an app-process side
// door (README decisions 2/3/8) — so rookctl and future agents read the
// identical thing. All content paths are repo-top-relative with forward
// slashes (git reports them that way), and confinePath guards this first
// file-read surface against crafted ../ escapes. An in-repo symlink
// pointing outside the repo can still be followed by os.ReadFile —
// accepted for now: localhost, token-gated, the user's own files.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	reviewTimeout = 5 * time.Second
	// per-side content cap — Monaco chokes on giant models long before
	// the wire does
	reviewMaxSide = 2 << 20
	// A save may grow a file past the 2 MB read cap; the editor only lets
	// you edit files that loaded WHOLE (untruncated), so a bounded amount
	// of growth is legitimate. This is the write ceiling, generous but not
	// unbounded — localhost, token-gated, the user's own files.
	writeMaxSize = 16 << 20
	// NUL anywhere in this prefix marks the file binary (git's own sniff)
	reviewSniffLen  = 8000
	reviewMaxFiles  = 1000  // changes list
	reviewMaxIndex  = 10000 // ls-files listing
	reviewMaxWalked = 5000  // non-repo WalkDir fallback
)

// gitOut runs git in dir and returns raw stdout — unlike runGit it never
// trims or mixes in stderr, because file CONTENT flows through here and
// trailing newlines must survive the round trip.
func gitOut(dir string, timeout time.Duration, args ...string) ([]byte, error) {
	git, err := exec.LookPath("git")
	if err != nil {
		git = "/usr/bin/git" // launchd's minimal PATH
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, git, append([]string{"-C", dir}, args...)...).Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok && len(ee.Stderr) > 0 {
			return out, fmt.Errorf("git %s: %s", args[0], strings.TrimSpace(string(ee.Stderr)))
		}
		return out, fmt.Errorf("git %s: %w", args[0], err)
	}
	return out, nil
}

// repoTop resolves the repository's top-level directory. Workspace roots
// can sit below it — git reports paths top-relative, so every content
// path in this file joins against top, not root.
func repoTop(root string) (string, error) {
	out, err := gitOut(root, reviewTimeout, "rev-parse", "--show-toplevel")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// confinePath resolves a client-supplied repo-relative path to an absolute
// one, rejecting anything that would land outside top.
func confinePath(top, rel string) (string, error) {
	if rel == "" || strings.HasPrefix(rel, "/") || filepath.IsAbs(filepath.FromSlash(rel)) {
		return "", fmt.Errorf("bad path %q", rel)
	}
	p := filepath.Clean(filepath.Join(top, filepath.FromSlash(rel)))
	r, err := filepath.Rel(top, p)
	if err != nil || r == ".." || strings.HasPrefix(r, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("path %q escapes the repository", rel)
	}
	return p, nil
}

type changedFile struct {
	Path   string `json:"path"`
	Status string `json:"status"` // modified|added|deleted|renamed|untracked
	// OldPath is the pre-rename path — Monaco diffs old content against
	// the new path's file.
	OldPath string `json:"oldPath,omitempty"`
}

type changesResult struct {
	Base      string        `json:"base"`    // "head" | "branch" — what was actually diffed
	BaseRef   string        `json:"baseRef"` // "HEAD", or the merge-base sha
	BaseName  string        `json:"baseName"`
	Fallback  string        `json:"fallback,omitempty"` // branch mode failed open to head — why
	Files     []changedFile `json:"files"`
	Truncated bool          `json:"truncated,omitempty"`
}

type diffResult struct {
	Path      string `json:"path"`
	Base      string `json:"base"`
	BaseRef   string `json:"baseRef"`
	BaseName  string `json:"baseName"`
	Original  string `json:"original"`
	Modified  string `json:"modified"`
	Binary    bool   `json:"binary,omitempty"`
	Truncated bool   `json:"truncated,omitempty"`
	Fallback  string `json:"fallback,omitempty"`
}

type fileResult struct {
	Path      string `json:"path"`
	Content   string `json:"content"`
	Binary    bool   `json:"binary,omitempty"`
	Truncated bool   `json:"truncated,omitempty"`
}

type filesResult struct {
	Files     []string `json:"files"`
	Truncated bool     `json:"truncated,omitempty"`
}

type writeRequest struct {
	Path    string `json:"path"`
	Content string `json:"content"`
}

type writeResult struct {
	Path  string `json:"path"`
	Bytes int    `json:"bytes"`
}

// reviewBase is the resolved diff base for one request.
type reviewBase struct {
	mode     string // "head" | "branch"
	ref      string // what git compares against: "HEAD" or the merge-base sha
	name     string // display name: "HEAD" or the base branch
	fallback string // set when branch mode failed open to head
}

// reviewBaseFor turns the ?base= param into a concrete base. No param:
// worktree workspaces default to branch (the task's whole work), everything
// else to head (uncommitted changes) — the host decides, the client reads
// the response's base back.
func (h *Host) reviewBaseFor(ws *WorkspaceInfo, top, param string) reviewBase {
	mode := param
	if mode == "" {
		if ws.WorktreeOf != "" {
			mode = "branch"
		} else {
			mode = "head"
		}
	}
	if mode != "branch" {
		return reviewBase{mode: "head", ref: "HEAD", name: "HEAD"}
	}
	sha, name, fallback := h.resolveReviewBase(ws, top)
	if sha == "" {
		return reviewBase{mode: "head", ref: "HEAD", name: "HEAD", fallback: fallback}
	}
	return reviewBase{mode: "branch", ref: sha, name: name}
}

// resolveReviewBase picks branch mode's base: the merge-base of HEAD and
// the first candidate that exists. Candidates: the source workspace's
// CURRENT branch for worktrees (the registry's Branch field is the
// worktree's own branch, not its base), then origin's default branch,
// then main/master. Nothing resolves → empty sha; the caller fails open
// to head mode with the reason.
func (h *Host) resolveReviewBase(ws *WorkspaceInfo, top string) (sha, name, fallback string) {
	var candidates []string
	if ws.WorktreeOf != "" {
		if src := h.reg.get(ws.WorktreeOf); src != nil && src.Root != "" {
			if gi := gitInfo(src.Root); gi != nil && gi.Branch != "" && gi.Branch != "(detached)" {
				candidates = append(candidates, gi.Branch)
			}
		}
	}
	if out, err := gitOut(top, reviewTimeout, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"); err == nil {
		if ref := strings.TrimSpace(string(out)); ref != "" {
			candidates = append(candidates, ref)
		}
	}
	candidates = append(candidates, "main", "master")
	reason := "no base branch found"
	for _, c := range candidates {
		if _, err := gitOut(top, reviewTimeout, "rev-parse", "--verify", "--quiet", c+"^{commit}"); err != nil {
			continue
		}
		out, err := gitOut(top, reviewTimeout, "merge-base", "HEAD", c)
		if err != nil {
			reason = "no common ancestor with " + c
			continue
		}
		return strings.TrimSpace(string(out)), c, ""
	}
	return "", "", "no merge base (" + reason + ")"
}

// reviewRepo resolves the workspace and its repo top for the diff-shaped
// endpoints: 404 unknown workspace, 400 rootless or not a repo.
func (h *Host) reviewRepo(w http.ResponseWriter, name string) (*WorkspaceInfo, string, bool) {
	ws := h.reg.get(name)
	if ws == nil {
		http.Error(w, "no such workspace: "+name, http.StatusNotFound)
		return nil, "", false
	}
	if ws.Root == "" {
		http.Error(w, "workspace has no root", http.StatusBadRequest)
		return nil, "", false
	}
	top, err := repoTop(ws.Root)
	if err != nil {
		http.Error(w, ws.Root+" is not a git repo", http.StatusBadRequest)
		return nil, "", false
	}
	return ws, top, true
}

// handleWorkspaceChanges is GET /workspaces/{name}/changes?base= — the
// review pane's file list.
func (h *Host) handleWorkspaceChanges(w http.ResponseWriter, r *http.Request, name string) {
	ws, top, ok := h.reviewRepo(w, name)
	if !ok {
		return
	}
	base := h.reviewBaseFor(ws, top, r.URL.Query().Get("base"))
	var files []changedFile
	var err error
	if base.mode == "branch" {
		files, err = branchChanges(top, base.ref)
	} else {
		files, err = headChanges(top)
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	res := changesResult{Base: base.mode, BaseRef: base.ref, BaseName: base.name, Fallback: base.fallback, Files: files}
	if len(res.Files) > reviewMaxFiles {
		res.Files, res.Truncated = res.Files[:reviewMaxFiles], true
	}
	writeJSON(w, res)
}

// statusWord folds a porcelain XY pair into the pane's vocabulary. The
// worktree side wins mixed states: "AD" (added, then deleted on disk)
// reads deleted.
func statusWord(x, y byte) string {
	switch {
	case x == '?':
		return "untracked"
	case x == 'R' || y == 'R':
		return "renamed"
	case x == 'D' || y == 'D':
		return "deleted"
	case x == 'A' || y == 'A':
		return "added"
	default:
		return "modified" // M, T, C, and mixed index/worktree edits
	}
}

// headChanges parses `git status --porcelain -z`: one record per path
// (staged and unstaged states share the XY pair), renames followed by the
// origin path as its own NUL record.
func headChanges(top string) ([]changedFile, error) {
	out, err := gitOut(top, reviewTimeout, "status", "--porcelain", "-z")
	if err != nil {
		return nil, err
	}
	files := []changedFile{}
	fields := strings.Split(string(out), "\x00")
	for i := 0; i < len(fields); i++ {
		f := fields[i]
		if len(f) < 4 {
			continue
		}
		cf := changedFile{Path: f[3:], Status: statusWord(f[0], f[1])}
		if f[0] == 'R' || f[0] == 'C' {
			i++
			if i < len(fields) {
				cf.OldPath = fields[i]
			}
		}
		files = append(files, cf)
	}
	return files, nil
}

// branchChanges is the branch-vs-merge-base list: committed + uncommitted
// work relative to the base, plus untracked files (part of "the task's
// whole work" even before an add).
func branchChanges(top, ref string) ([]changedFile, error) {
	out, err := gitOut(top, reviewTimeout, "diff", "--name-status", "-z", ref)
	if err != nil {
		return nil, err
	}
	files := []changedFile{}
	fields := strings.Split(string(out), "\x00")
	for i := 0; i < len(fields); {
		st := fields[i]
		if st == "" {
			break
		}
		// rename/copy records carry two paths: old, then new
		if (st[0] == 'R' || st[0] == 'C') && i+2 < len(fields) {
			files = append(files, changedFile{Path: fields[i+2], Status: "renamed", OldPath: fields[i+1]})
			i += 3
			continue
		}
		if i+1 >= len(fields) {
			break
		}
		status := "modified"
		switch st[0] {
		case 'A':
			status = "added"
		case 'D':
			status = "deleted"
		}
		files = append(files, changedFile{Path: fields[i+1], Status: status})
		i += 2
	}
	out, err = gitOut(top, reviewTimeout, "ls-files", "--others", "--exclude-standard", "-z")
	if err != nil {
		return nil, err
	}
	for _, f := range strings.Split(string(out), "\x00") {
		if f != "" {
			files = append(files, changedFile{Path: f, Status: "untracked"})
		}
	}
	return files, nil
}

// capSide enforces the per-side content rules: a NUL in the sniff window
// means binary (content withheld), anything past the cap truncates.
func capSide(b []byte) (text string, binary, truncated bool) {
	n := min(len(b), reviewSniffLen)
	if bytes.IndexByte(b[:n], 0) != -1 {
		return "", true, false
	}
	if len(b) > reviewMaxSide {
		return string(b[:reviewMaxSide]), false, true
	}
	return string(b), false, false
}

// handleWorkspaceDiff is GET /workspaces/{name}/diff?path=&base= — both
// full texts, because Monaco's DiffEditor wants sides, not patches.
// A missing original means added/untracked; a missing file on disk means
// deleted — both are labeled states, never errors.
func (h *Host) handleWorkspaceDiff(w http.ResponseWriter, r *http.Request, name string) {
	ws, top, ok := h.reviewRepo(w, name)
	if !ok {
		return
	}
	rel := r.URL.Query().Get("path")
	abs, err := confinePath(top, rel)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	base := h.reviewBaseFor(ws, top, r.URL.Query().Get("base"))
	res := diffResult{Path: rel, Base: base.mode, BaseRef: base.ref, BaseName: base.name, Fallback: base.fallback}
	var orig, mod []byte
	if out, err := gitOut(top, reviewTimeout, "show", base.ref+":"+rel); err == nil {
		orig = out
	}
	if out, err := os.ReadFile(abs); err == nil {
		mod = out
	}
	var ob, ot, mb, mt bool
	res.Original, ob, ot = capSide(orig)
	res.Modified, mb, mt = capSide(mod)
	res.Binary, res.Truncated = ob || mb, ot || mt
	if res.Binary {
		res.Original, res.Modified = "", ""
	}
	writeJSON(w, res)
}

// handleWorkspaceFile is GET /workspaces/{name}/file?path= — the ` e
// read-only viewer. Unlike the diff endpoints it serves non-repo roots
// too (confined to the root instead of the repo top).
func (h *Host) handleWorkspaceFile(w http.ResponseWriter, r *http.Request, name string) {
	ws := h.reg.get(name)
	if ws == nil {
		http.Error(w, "no such workspace: "+name, http.StatusNotFound)
		return
	}
	if ws.Root == "" {
		http.Error(w, "workspace has no root", http.StatusBadRequest)
		return
	}
	top, err := repoTop(ws.Root)
	if err != nil {
		top = ws.Root
	}
	rel := r.URL.Query().Get("path")
	abs, err := confinePath(top, rel)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	b, err := os.ReadFile(abs)
	if err != nil {
		http.Error(w, "no such file: "+rel, http.StatusNotFound)
		return
	}
	res := fileResult{Path: rel}
	res.Content, res.Binary, res.Truncated = capSide(b)
	writeJSON(w, res)
}

// handleWorkspaceWrite is POST /workspaces/{name}/write {path, content} —
// the editor's :w / ⌘S. This is the host API's first WRITE door, kept
// deliberately narrow: a repo-relative path, confined exactly like the
// read side (repoTop, else ws.Root), written atomically (temp + rename in
// the same dir) so a crash never leaves a half file. Existing permissions
// are preserved — an executable stays executable. The editor only enables
// saving for files it loaded whole, so this never truncates.
func (h *Host) handleWorkspaceWrite(w http.ResponseWriter, r *http.Request, name string) {
	ws := h.reg.get(name)
	if ws == nil {
		http.Error(w, "no such workspace: "+name, http.StatusNotFound)
		return
	}
	if ws.Root == "" {
		http.Error(w, "workspace has no root", http.StatusBadRequest)
		return
	}
	var req writeRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, writeMaxSize+1<<16)).Decode(&req); err != nil {
		http.Error(w, "bad body: "+err.Error(), http.StatusBadRequest)
		return
	}
	if len(req.Content) > writeMaxSize {
		http.Error(w, "content exceeds write cap", http.StatusRequestEntityTooLarge)
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
	if err := atomicWrite(abs, []byte(req.Content)); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, writeResult{Path: req.Path, Bytes: len(req.Content)})
}

// atomicWrite replaces abs's contents in one rename: write a sibling temp
// file, fsync it closed, chmod it to the existing file's mode (0644 for a
// new file), then rename over the target. The temp is removed on any early
// return; after a successful rename the remove is a no-op miss.
func atomicWrite(abs string, data []byte) error {
	dir := filepath.Dir(abs)
	mode := os.FileMode(0o644)
	if fi, err := os.Stat(abs); err == nil {
		mode = fi.Mode().Perm()
	}
	tmp, err := os.CreateTemp(dir, ".rook-save-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmpName, mode); err != nil {
		return err
	}
	return os.Rename(tmpName, abs)
}

// handleWorkspaceFiles is GET /workspaces/{name}/files — the file picker's
// list. Repos get git's view (tracked + untracked, ignores respected);
// anything else falls back to a bounded WalkDir so ` e works in every
// workspace.
func (h *Host) handleWorkspaceFiles(w http.ResponseWriter, name string) {
	ws := h.reg.get(name)
	if ws == nil {
		http.Error(w, "no such workspace: "+name, http.StatusNotFound)
		return
	}
	if ws.Root == "" {
		http.Error(w, "workspace has no root", http.StatusBadRequest)
		return
	}
	if top, err := repoTop(ws.Root); err == nil {
		out, err := gitOut(top, reviewTimeout, "ls-files", "--cached", "--others", "--exclude-standard", "-z")
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		res := filesResult{Files: []string{}}
		for _, f := range strings.Split(string(out), "\x00") {
			if f == "" {
				continue
			}
			if len(res.Files) == reviewMaxIndex {
				res.Truncated = true
				break
			}
			res.Files = append(res.Files, f)
		}
		writeJSON(w, res)
		return
	}
	files, truncated := walkFiles(ws.Root, reviewMaxWalked)
	writeJSON(w, filesResult{Files: files, Truncated: truncated})
}

// walkFiles lists a non-repo root: hidden entries and node_modules are
// noise, unreadable subtrees skip rather than fail.
func walkFiles(root string, limit int) ([]string, bool) {
	files := []string{}
	truncated := false
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		base := d.Name()
		if d.IsDir() {
			if p != root && (strings.HasPrefix(base, ".") || base == "node_modules") {
				return fs.SkipDir
			}
			return nil
		}
		if strings.HasPrefix(base, ".") {
			return nil
		}
		if len(files) == limit {
			truncated = true
			return fs.SkipAll
		}
		if rel, err := filepath.Rel(root, p); err == nil {
			files = append(files, filepath.ToSlash(rel))
		}
		return nil
	})
	return files, truncated
}
