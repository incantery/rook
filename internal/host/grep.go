package host

// Workspace-wide content search — the ⌃G half of exploration (the file
// picker being ⌘P). Repos get `git grep` (tracked + untracked, ignores
// respected — the same view the file picker lists); non-repo roots get a
// bounded walk-and-scan so grep works in every workspace. The pattern is
// extended regex with a fixed-string retry on a bad pattern, because a
// live-grep box holds half-typed regexes most of the time and "(" must
// mean "find (" while the user keeps typing, never an error. All-lowercase
// queries search case-insensitively (smart case).

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	grepMaxHits = 500
	// display cap per matched line (minified JS says hello) — the file
	// itself opens whole, only the row text is trimmed
	grepMaxText = 300
)

type grepHit struct {
	Path string `json:"path"`
	Line int    `json:"line"` // 1-based
	Col  int    `json:"col"`  // 1-based
	Text string `json:"text"`
}

type grepResult struct {
	Hits      []grepHit `json:"hits"`
	Truncated bool      `json:"truncated"`
	Note      string    `json:"note,omitempty"`
}

// handleWorkspaceGrep is GET /workspaces/{name}/grep?q= .
func (h *Host) handleWorkspaceGrep(w http.ResponseWriter, r *http.Request, name string) {
	ws := h.reg.get(name)
	if ws == nil {
		http.Error(w, "no such workspace: "+name, http.StatusNotFound)
		return
	}
	if ws.Root == "" {
		http.Error(w, "workspace has no root", http.StatusBadRequest)
		return
	}
	q := r.URL.Query().Get("q")
	if q == "" {
		http.Error(w, "missing q", http.StatusBadRequest)
		return
	}
	var res grepResult
	if top, err := repoTop(ws.Root); err == nil {
		res = gitGrep(top, q)
	} else {
		res = walkGrep(ws.Root, q)
	}
	writeJSON(w, res)
}

// smartCase: an all-lowercase query means "don't make me care about case".
func smartCase(q string) bool {
	return strings.ToLower(q) == q
}

// gitRunCode is gitOut for commands whose exit code is data — git grep
// exits 1 for "no matches" and >1 for a broken pattern, and both must be
// told apart from stdout-carrying success.
func gitRunCode(dir string, timeout time.Duration, args ...string) ([]byte, int, error) {
	git, err := exec.LookPath("git")
	if err != nil {
		git = "/usr/bin/git"
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, git, append([]string{"-C", dir}, args...)...).Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return out, ee.ExitCode(), nil
		}
		return out, -1, fmt.Errorf("git %s: %w", args[0], err)
	}
	return out, 0, nil
}

func gitGrep(top, q string) grepResult {
	args := func(mode string) []string {
		a := []string{"grep", "-I", "-n", "--column", "--untracked", "-z", mode}
		if smartCase(q) {
			a = append(a, "-i")
		}
		return append(a, "-e", q, "--")
	}
	out, code, err := gitRunCode(top, reviewTimeout, args("-E")...)
	if code > 1 {
		// half-typed regex — search it as literal text instead
		out, code, err = gitRunCode(top, reviewTimeout, args("-F")...)
	}
	if err != nil {
		return grepResult{Hits: []grepHit{}, Note: err.Error()}
	}
	if code == 1 {
		return grepResult{Hits: []grepHit{}}
	}
	if code != 0 {
		return grepResult{Hits: []grepHit{}, Note: "git grep failed"}
	}
	res := grepResult{Hits: []grepHit{}}
	for line := range strings.SplitSeq(string(out), "\n") {
		if line == "" {
			continue
		}
		if len(res.Hits) == grepMaxHits {
			res.Truncated = true
			break
		}
		// -z with -n --column NUL-separates every field:
		// path\0line\0col\0text (so colons in paths and text never lie)
		parts := strings.SplitN(line, "\x00", 4)
		if len(parts) != 4 {
			continue
		}
		path, text := parts[0], parts[3]
		lineNo, e1 := strconv.Atoi(parts[1])
		colNo, e2 := strconv.Atoi(parts[2])
		if e1 != nil || e2 != nil {
			continue
		}
		res.Hits = append(res.Hits, grepHit{
			Path: filepath.ToSlash(path),
			Line: lineNo,
			Col:  colNo,
			Text: trimHitText(text),
		})
	}
	return res
}

func trimHitText(s string) string {
	s = strings.TrimRight(s, "\r")
	if len(s) > grepMaxText {
		s = s[:grepMaxText]
	}
	return s
}

// walkGrep scans a non-repo root with the same bounded walk the file
// picker uses. Same smart-case regex semantics as the git path; a pattern
// that won't compile searches as literal text.
func walkGrep(root, q string) grepResult {
	pat := q
	if smartCase(q) {
		pat = "(?i)" + pat
	}
	re, err := regexp.Compile(pat)
	if err != nil {
		lit := regexp.QuoteMeta(q)
		if smartCase(q) {
			lit = "(?i)" + lit
		}
		re = regexp.MustCompile(lit)
	}
	files, walkTruncated := walkFiles(root, reviewMaxWalked)
	res := grepResult{Hits: []grepHit{}, Truncated: walkTruncated}
	for _, rel := range files {
		if len(res.Hits) == grepMaxHits {
			res.Truncated = true
			break
		}
		b, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
		if err != nil || len(b) > reviewMaxSide {
			continue
		}
		if bytes.IndexByte(b[:min(len(b), reviewSniffLen)], 0) != -1 {
			continue // binary
		}
		sc := bufio.NewScanner(bytes.NewReader(b))
		sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for n := 1; sc.Scan(); n++ {
			loc := re.FindStringIndex(sc.Text())
			if loc == nil {
				continue
			}
			res.Hits = append(res.Hits, grepHit{
				Path: rel,
				Line: n,
				Col:  loc[0] + 1,
				Text: trimHitText(sc.Text()),
			})
			if len(res.Hits) == grepMaxHits {
				break
			}
		}
	}
	return res
}
