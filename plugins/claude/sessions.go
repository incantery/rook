// Session discovery: what is every Claude Code session on this machine
// doing right now?
//
// The answer is derived, never stored. Claude Code appends every event to
// a transcript under ~/.claude/projects/<munged-cwd>/<session>.jsonl, and
// the tail of that file says exactly where a session stands: an assistant
// line whose stop_reason is end_turn means the turn is over and a human is
// next; a pending tool_use with no result yet means it is working — or,
// if the file has gone quiet under a permission mode that prompts, that it
// is sitting on an approval nobody has noticed.
//
// Only the tail is read (transcripts average megabytes; the state lives in
// the last few lines), and only one directory level is scanned — subagent
// transcripts sit in a subagents/ subdirectory per session and are
// deliberately out of scope: a subagent is the session's business, not the
// human's.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"
)

type State string

const (
	StateNeedsYou State = "needs you"
	StateBlocked  State = "blocked?"
	StateWorking  State = "working"
	StateIdle     State = "idle"
)

// prio orders the panel: what needs a human floats to the top.
func (s State) prio() int {
	switch s {
	case StateNeedsYou:
		return 0
	case StateBlocked:
		return 1
	case StateWorking:
		return 2
	default:
		return 3
	}
}

type Session struct {
	ID       string
	Path     string
	Title    string // Claude's own ai-title, or a path-derived fallback
	Prompt   string // the last thing the human asked
	Cwd      string
	Branch   string
	LastText string // the last thing the assistant said
	State    State
	Mtime    time.Time
	TurnDur  time.Duration // how long the just-finished turn ran; 0 if unknown
	Present  bool          // the human typed in this session's pane moments ago
}

type Scanner struct {
	Dir    string        // the projects directory
	Window time.Duration // sessions quiet longer than this are not listed
	Idle   time.Duration // quiet longer than this = idle
	Quiet  time.Duration // a pending tool call quiet longer than this = blocked?
	Max    int
}

// PaneActivity is one pane's row from rook's `panes.activity` answer:
// ms since the child last wrote / the human last typed (-1 = never),
// the foreground program, the shell's cwd.
type PaneActivity struct {
	ID    int    `json:"id"`
	OutMs int64  `json:"outMs"`
	InMs  int64  `json:"inMs"`
	Fg    string `json:"fg"`
	Path  string `json:"path"` // full exec path; the basename can lie
	Cwd   string `json:"cwd"`
}

// fuse folds the substrate's view into the transcript's. A session is
// matched to panes by cwd plus a Claude-looking foreground program;
// unmatched sessions (another machine's transcripts, a session run
// outside rook) keep their transcript-only state untouched.
//
// Two corrections, one per direction of the pty:
//   - OUTPUT: a "blocked?" whose pane is still redrawing is a long tool
//     run, not a stuck approval — the spinner is proof of life the
//     transcript cannot give, because a running tool logs nothing.
//   - INPUT: a human who typed in that pane moments ago is PRESENT, and
//     a banner for the pane you are looking at is noise. The state
//     still shows in the panel; only the interruption is suppressed.
func fuse(sessions []Session, panes []PaneActivity, names []string, alive, present time.Duration) {
	for i := range sessions {
		s := &sessions[i]
		outBest, inBest := int64(-1), int64(-1)
		for _, p := range panes {
			if p.Cwd != s.Cwd || !claudeLike(p, names) {
				continue
			}
			if p.OutMs >= 0 && (outBest < 0 || p.OutMs < outBest) {
				outBest = p.OutMs
			}
			if p.InMs >= 0 && (inBest < 0 || p.InMs < inBest) {
				inBest = p.InMs
			}
		}
		if s.State == StateBlocked && outBest >= 0 && outBest < alive.Milliseconds() {
			s.State = StateWorking
		}
		s.Present = inBest >= 0 && inBest < present.Milliseconds()
	}
	sortSessions(sessions)
}

// claudeLike: is this pane's foreground program Claude Code? By name
// when the name is honest ("claude", "node"), by path when it is not —
// the versioned install runs a binary literally named "2.1.220", and
// only its path (…/claude/versions/2.1.220) still says whose it is.
func claudeLike(p PaneActivity, names []string) bool {
	return slices.Contains(names, p.Fg) || strings.Contains(p.Path, "claude")
}

// Scan lists the sessions worth showing, most urgent first.
func (sc *Scanner) Scan(now time.Time) []Session {
	projects, err := os.ReadDir(sc.Dir)
	if err != nil {
		return nil
	}
	var out []Session
	for _, p := range projects {
		if !p.IsDir() {
			continue
		}
		files, err := os.ReadDir(filepath.Join(sc.Dir, p.Name()))
		if err != nil {
			continue
		}
		for _, f := range files {
			if f.IsDir() || !strings.HasSuffix(f.Name(), ".jsonl") {
				continue
			}
			info, err := f.Info()
			if err != nil || now.Sub(info.ModTime()) > sc.Window {
				continue
			}
			path := filepath.Join(sc.Dir, p.Name(), f.Name())
			s := parseTail(path, info.ModTime(), now, sc.Idle, sc.Quiet)
			s.ID = strings.TrimSuffix(f.Name(), ".jsonl")
			if s.Title == "" {
				s.Title = fallbackTitle(s.Cwd, p.Name(), s.ID)
			}
			out = append(out, s)
		}
	}
	sortSessions(out)
	if sc.Max > 0 && len(out) > sc.Max {
		out = out[:sc.Max]
	}
	return out
}

func sortSessions(out []Session) {
	sort.Slice(out, func(i, j int) bool {
		if a, b := out[i].State.prio(), out[j].State.prio(); a != b {
			return a < b
		}
		return out[i].Mtime.After(out[j].Mtime)
	})
}

// The transcript line shapes this cares about. Claude Code's format is
// internal and drifts between versions, so every field is optional and an
// unrecognizable line is skipped, not an error — a wrong "working" beats a
// dead panel.
type wireLine struct {
	Type           string   `json:"type"`
	Timestamp      string   `json:"timestamp"`
	IsSidechain    bool     `json:"isSidechain"`
	Cwd            string   `json:"cwd"`
	GitBranch      string   `json:"gitBranch"`
	AiTitle        string   `json:"aiTitle"`
	LastPrompt     string   `json:"lastPrompt"`
	PermissionMode string   `json:"permissionMode"`
	Message        *wireMsg `json:"message"`
}

type wireMsg struct {
	Role       string          `json:"role"`
	StopReason string          `json:"stop_reason"`
	Content    json.RawMessage `json:"content"`
}

const tailBytes = 256 * 1024

// parseTail reads the end of one transcript and decides its state.
func parseTail(path string, mtime, now time.Time, idle, quiet time.Duration) Session {
	s := Session{Path: path, Mtime: mtime}

	data, err := readTail(path, tailBytes)
	if err != nil {
		s.State = StateIdle
		return s
	}

	// What the last real event was. Meta lines (ai-title, last-prompt,
	// permission-mode, ...) repeat after every turn and never count.
	const (
		evNone = iota
		evPrompt
		evToolResult
		evAssistant
	)
	lastEv := evNone
	endTurn := false
	interrupted := false
	permMode := ""
	var lastEvTime, promptTime time.Time

	for raw := range bytes.SplitSeq(data, []byte("\n")) {
		if len(bytes.TrimSpace(raw)) == 0 {
			continue
		}
		var l wireLine
		if json.Unmarshal(raw, &l) != nil {
			continue
		}
		if l.AiTitle != "" {
			s.Title = l.AiTitle
		}
		if l.LastPrompt != "" {
			s.Prompt = l.LastPrompt
		}
		if l.PermissionMode != "" {
			permMode = l.PermissionMode
		}
		if l.Cwd != "" {
			s.Cwd = l.Cwd
		}
		if l.GitBranch != "" {
			s.Branch = l.GitBranch
		}
		if l.IsSidechain || l.Message == nil {
			continue
		}
		ts, _ := time.Parse(time.RFC3339, l.Timestamp)
		switch l.Type {
		case "assistant":
			lastEv = evAssistant
			endTurn = l.Message.StopReason == "end_turn" || l.Message.StopReason == "stop_sequence"
			interrupted = false
			if t := contentText(l.Message.Content); t != "" {
				s.LastText = t
			}
		case "user":
			if isToolResult(l.Message.Content) {
				lastEv = evToolResult
			} else {
				lastEv = evPrompt
				interrupted = strings.HasPrefix(contentText(l.Message.Content), "[Request interrupted")
				promptTime = ts
			}
			endTurn = false
		default:
			continue
		}
		lastEvTime = ts
	}

	age := now.Sub(mtime)
	autoPerm := permMode == "auto" || permMode == "bypassPermissions"
	switch {
	case age > idle:
		s.State = StateIdle
	case lastEv == evAssistant && endTurn:
		s.State = StateNeedsYou
	case lastEv == evPrompt && interrupted:
		s.State = StateNeedsYou
	case lastEv == evAssistant && !endTurn && age > quiet && !autoPerm:
		// A tool call was issued, nothing has come back, and the session
		// runs under a permission mode that prompts: the likeliest reading
		// is an approval box nobody has seen. The "?" is honest — a slow
		// tool looks identical from here.
		s.State = StateBlocked
	default:
		s.State = StateWorking
	}
	if s.State == StateNeedsYou && !promptTime.IsZero() && lastEvTime.After(promptTime) {
		s.TurnDur = lastEvTime.Sub(promptTime)
	}
	return s
}

// readTail returns up to max bytes from the end of the file, aligned to
// the first whole line.
func readTail(path string, max int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, err
	}
	off := int64(0)
	if info.Size() > max {
		off = info.Size() - max
	}
	data := make([]byte, info.Size()-off)
	if _, err := f.ReadAt(data, off); err != nil {
		return nil, err
	}
	if off > 0 {
		if i := bytes.IndexByte(data, '\n'); i >= 0 {
			data = data[i+1:]
		}
	}
	return data, nil
}

// contentText: a message's content is either a plain string or a list of
// typed blocks; the human-readable text is the last text block.
func contentText(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &blocks) == nil {
		for i := len(blocks) - 1; i >= 0; i-- {
			if blocks[i].Type == "text" && blocks[i].Text != "" {
				return blocks[i].Text
			}
		}
	}
	return ""
}

func isToolResult(raw json.RawMessage) bool {
	var blocks []struct {
		Type string `json:"type"`
	}
	return json.Unmarshal(raw, &blocks) == nil && len(blocks) > 0 && blocks[0].Type == "tool_result"
}

// fallbackTitle names a session that never got an ai-title: the directory
// it works in, plus enough of the id to tell twins apart.
func fallbackTitle(cwd, projDir, id string) string {
	name := filepath.Base(cwd)
	if name == "" || name == "." || name == "/" {
		name = strings.TrimLeft(projDir, "-")
	}
	short := id
	if len(short) > 8 {
		short = short[:8]
	}
	return name + " · " + short
}

// relAge renders "how long ago" at the resolution a human cares about.
func relAge(d time.Duration) string {
	switch {
	case d < 5*time.Second:
		return "now"
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd", int(d.Hours()/24))
	}
}

// snip truncates for a fixed-width wire field without splitting a rune.
func snip(s string, max int) string {
	s = strings.Join(strings.Fields(s), " ") // one line, one space
	if len(s) <= max {
		return s
	}
	cut := max - len("…")
	for cut > 0 && !isRuneStart(s[cut]) {
		cut--
	}
	return s[:cut] + "…"
}

func isRuneStart(b byte) bool { return b&0xC0 != 0x80 }
