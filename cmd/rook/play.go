package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"html"
	"image/png"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/incantery/rook/internal/mux"
)

// `rook play`: a terminal program under test, the way a browser is
// under Playwright (docs/play.md). A session is a rook server of its
// own — no terminal attached, its own socket, a config of its own —
// with the program in its first pane. Every rook verb works on it;
// each one that acts is written to the session's trace with the
// screen it left.
//
//	name=$(rook play start --size 100x30 -- ./my-tui)
//	rook play -s $name key . down
//	rook play -s $name expect "3 items" --row 0
//	rook play stop $name          # prints where the trace is
//
// or `export ROOK_PLAY=$name`, and plain `rook key . down` is that
// session's.

// playDir is where sessions live: /tmp, because a unix socket's path
// has a hundred bytes to fit in.
func playDir() string {
	return filepath.Join("/tmp", "rook-play-"+strconv.Itoa(os.Getuid()))
}

type playSession struct {
	Name    string `json:"name"`
	Cwd     string `json:"cwd"`
	Size    string `json:"size"`
	Command string `json:"command"`
	Started int64  `json:"started"`
	Pid     int    `json:"pid"`
	Trace   bool   `json:"trace"`
}

func (p playSession) sock() string     { return filepath.Join(playDir(), p.Name+".sock") }
func (p playSession) meta() string     { return filepath.Join(playDir(), p.Name+".json") }
func (p playSession) conf() string     { return filepath.Join(playDir(), p.Name+".toml") }
func (p playSession) log() string      { return filepath.Join(playDir(), p.Name+".log") }
func (p playSession) traceDir() string { return filepath.Join(playDir(), p.Name+".trace") }

// env is the environment a command gets to speak to this session and
// to nobody else.
func (p playSession) env(pane int) []string {
	var env []string
	for _, kv := range mux.Env() {
		if strings.HasPrefix(kv, "ROOK_MUX_SOCK=") || strings.HasPrefix(kv, "ROOK_MUX_PANE=") ||
			strings.HasPrefix(kv, "ROOK_PLAY=") || strings.HasPrefix(kv, "ROOK_CONFIG=") ||
			strings.HasPrefix(kv, mux.FrontDoorEnv+"=") ||
			strings.HasPrefix(kv, "TMUX=") || strings.HasPrefix(kv, "TMUX_PANE=") {
			continue
		}
		env = append(env, kv)
	}
	env = append(env, "ROOK_MUX_SOCK="+p.sock(), "ROOK_CONFIG="+p.conf())
	// The engine asks a front door for its config, and it has to be
	// this one: an inherited $ROOK_FRONT_DOOR may name a rook that does
	// not know $ROOK_CONFIG and would hand the session the person's own
	// config — their home, their programs, typed into by a test.
	if self, err := os.Executable(); err == nil {
		env = append(env, mux.FrontDoorEnv+"="+self)
	}
	if pane > 0 {
		env = append(env, "ROOK_MUX_PANE="+strconv.Itoa(pane))
	}
	return env
}

func (p playSession) alive() bool {
	c, err := net.DialTimeout("unix", p.sock(), 300*time.Millisecond)
	if err != nil {
		return false
	}
	c.Close()
	return true
}

// engine runs one engine verb against the session and returns what it
// printed.
func (p playSession) engine(args ...string) (string, error) {
	cmd := exec.Command(mux.EnginePath(), args...)
	cmd.Env = p.env(0)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s", strings.TrimPrefix(strings.TrimSpace(string(out)), "rook: "))
	}
	return string(out), nil
}

// pane is the session's pane under test: the focused one.
func (p playSession) pane() int {
	out, err := p.engine("state")
	if err != nil {
		return 0
	}
	var st struct {
		Focus struct {
			Pane int `json:"pane"`
		} `json:"focus"`
	}
	json.Unmarshal([]byte(out), &st)
	return st.Focus.Pane
}

func loadPlay(name string) (playSession, error) {
	var p playSession
	if name == "" {
		return p, fmt.Errorf("play: which session? (-s NAME, or $ROOK_PLAY; `rook play ls` lists them)")
	}
	if strings.ContainsAny(name, "/. \t") {
		return p, fmt.Errorf("play: a session name is a plain word")
	}
	data, err := os.ReadFile(filepath.Join(playDir(), name+".json"))
	if err != nil {
		return p, fmt.Errorf("play: no session called %s (`rook play ls`)", name)
	}
	if err := json.Unmarshal(data, &p); err != nil {
		return p, fmt.Errorf("play: %s: %w", name, err)
	}
	return p, nil
}

func allPlays() []playSession {
	var out []playSession
	metas, _ := filepath.Glob(filepath.Join(playDir(), "*.json"))
	for _, m := range metas {
		if p, err := loadPlay(strings.TrimSuffix(filepath.Base(m), ".json")); err == nil {
			out = append(out, p)
		}
	}
	sort.Slice(out, func(a, b int) bool { return out[a].Started < out[b].Started })
	return out
}

const playUsage = `usage: rook play start [NAME] [--size WxH] [--cwd DIR] [--shell PATH] [--no-trace] [-- <command...>]
       rook play -s NAME <any rook verb…>     (or export ROOK_PLAY=NAME and say plain rook)
       rook play ls | stop NAME|--all | trace NAME [-o FILE] | attach NAME | env NAME
`

func runPlay(args []string) error {
	if len(args) == 0 {
		fmt.Print(playUsage)
		return nil
	}
	switch args[0] {
	case "start":
		return playStart(args[1:])
	case "ls", "list":
		return playList()
	case "stop":
		return playStop(args[1:])
	case "trace":
		return playTrace(args[1:])
	case "attach":
		if len(args) < 2 {
			return fmt.Errorf("usage: rook play attach NAME")
		}
		p, err := loadPlay(args[1])
		if err != nil {
			return err
		}
		if !p.alive() {
			return fmt.Errorf("play: %s is not running", p.Name)
		}
		bin := mux.EnginePath()
		return syscall.Exec(bin, []string{filepath.Base(bin), "attach"}, p.env(0))
	case "env":
		if len(args) < 2 {
			return fmt.Errorf("usage: rook play env NAME")
		}
		p, err := loadPlay(args[1])
		if err != nil {
			return err
		}
		fmt.Printf("export ROOK_PLAY=%s\n", p.Name)
		return nil
	case "-s", "--session":
		if len(args) < 3 {
			return fmt.Errorf("usage: rook play -s NAME <verb…>")
		}
		return playDo(args[1], args[2:])
	case "help", "--help", "-h":
		fmt.Print(playUsage)
		return nil
	}
	return fmt.Errorf("play: unknown verb %q\n%s", args[0], playUsage)
}

func playStart(args []string) error {
	p := playSession{Size: "100x30", Trace: true}
	shell := "/bin/sh"
	var command []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		val := func() (string, error) {
			if i+1 >= len(args) {
				return "", fmt.Errorf("play start: %s needs a value", a)
			}
			i++
			return args[i], nil
		}
		var err error
		switch {
		case a == "--":
			command = args[i+1:]
			i = len(args)
		case a == "--size":
			p.Size, err = val()
		case a == "--cwd":
			p.Cwd, err = val()
		case a == "--shell":
			shell, err = val()
		case a == "--no-trace":
			p.Trace = false
		case strings.HasPrefix(a, "-"):
			return fmt.Errorf("play start: unknown option %s\n%s", a, playUsage)
		case p.Name == "":
			p.Name = a
		default:
			return fmt.Errorf("play start: the program goes after `--`")
		}
		if err != nil {
			return err
		}
	}
	if err := os.MkdirAll(playDir(), 0o700); err != nil {
		return err
	}
	if p.Name == "" {
		for n := 1; ; n++ {
			p.Name = "p" + strconv.Itoa(n)
			if _, err := os.Stat(p.meta()); err != nil {
				break
			}
		}
	}
	if strings.ContainsAny(p.Name, "/. \t") || len(p.Name) > 40 {
		return fmt.Errorf("play start: a session name is a plain word, at most 40 bytes")
	}
	if old, err := loadPlay(p.Name); err == nil {
		if old.alive() {
			return fmt.Errorf("play start: %s is already running (`rook play stop %s`)", p.Name, p.Name)
		}
		playRemove(old, true)
	}
	// a name used before starts clean: its last trace is not this one's
	playRemove(p, true)
	if p.Cwd == "" {
		p.Cwd, _ = os.Getwd()
	}
	if abs, err := filepath.Abs(p.Cwd); err == nil {
		p.Cwd = abs
	}
	if st, err := os.Stat(p.Cwd); err != nil || !st.IsDir() {
		return fmt.Errorf("play start: no directory at %s", p.Cwd)
	}
	p.Command = strings.Join(command, " ")
	p.Started = time.Now().UnixMilli()

	// The session's own config: rook's defaults and nothing of the
	// person's, so what a test sees does not depend on whose desk it
	// runs at. It starts in a space, saves nothing, and restores nothing.
	conf := "# rook play: this session's config\n[mux]\nstartup = \"last-space\"\nrestore = false\n"
	if err := os.WriteFile(p.conf(), []byte(conf), 0o600); err != nil {
		return err
	}
	logf, err := os.Create(p.log())
	if err != nil {
		return err
	}
	defer logf.Close()
	srv := exec.Command(mux.EnginePath(), "server")
	srv.Env = append(p.env(0), "SHELL="+shell, "PS1=$ ", "TERM=xterm-256color")
	srv.Dir = p.Cwd
	srv.Stdout, srv.Stderr = logf, logf
	srv.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := srv.Start(); err != nil {
		return fmt.Errorf("play start: cannot start the engine: %w", err)
	}
	p.Pid = srv.Process.Pid
	srv.Process.Release()
	meta, _ := json.Marshal(p)
	if err := os.WriteFile(p.meta(), meta, 0o600); err != nil {
		return err
	}
	fail := func(err error) error {
		p.engine("kill")
		playRemove(p, true)
		return err
	}
	// the glass, then the program, typed at the shell so the pane is
	// still there to read when the program ends
	if _, err := p.engine("shot", "--size", p.Size, "--settle", "150"); err != nil {
		return fail(fmt.Errorf("play start: %v", err))
	}
	// and it is the session's config that took, or nothing is typed:
	// a session that came up as somebody's home is not a place to test
	if st, err := p.engine("state"); err != nil || !strings.Contains(st, `"scope":"space"`) || strings.Contains(st, `"home":true`) {
		return fail(fmt.Errorf("play start: the session did not come up with its own config; nothing was run"))
	}
	if p.Trace {
		os.MkdirAll(p.traceDir(), 0o700)
		playRecord(p, []string{"start"}, 0)
	}
	if p.Command != "" {
		pane := p.pane()
		if _, err := p.engine("run", strconv.Itoa(pane), p.Command); err != nil {
			return fail(fmt.Errorf("play start: %v", err))
		}
		if p.Trace {
			playRecord(p, append([]string{"run", "."}, command...), 0)
		}
	}
	fmt.Println(p.Name)
	return nil
}

func playList() error {
	plays := allPlays()
	n := 0
	for _, p := range plays {
		if !p.alive() {
			continue
		}
		n++
		fmt.Printf("%s\t%s\t%s\t%s\n", p.Name, p.Size, time.Since(time.UnixMilli(p.Started)).Round(time.Second), p.Command)
	}
	if n == 0 {
		fmt.Fprintln(os.Stderr, "no play sessions  (rook play start -- <command>)")
	}
	return nil
}

// playRemove forgets a session's files; the trace stays unless asked.
func playRemove(p playSession, trace bool) {
	for _, f := range []string{p.sock(), p.sock() + ".state", p.sock() + ".state.tmp", p.meta(), p.conf(), p.log()} {
		os.Remove(f)
	}
	if trace {
		os.RemoveAll(p.traceDir())
	}
}

func playStop(args []string) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: rook play stop NAME | --all")
	}
	var plays []playSession
	if args[0] == "--all" {
		plays = allPlays()
	} else {
		p, err := loadPlay(args[0])
		if err != nil {
			return err
		}
		plays = []playSession{p}
	}
	for _, p := range plays {
		page := ""
		if p.Trace {
			if out, err := writeTrace(p, ""); err == nil {
				page = out
			}
		}
		if p.alive() {
			p.engine("kill")
			for i := 0; i < 40 && p.alive(); i++ {
				time.Sleep(50 * time.Millisecond)
			}
		}
		playRemove(p, false)
		if page != "" {
			fmt.Printf("{\"ok\":true,\"session\":%q,\"trace\":%q}\n", p.Name, page)
		} else {
			fmt.Printf("{\"ok\":true,\"session\":%q}\n", p.Name)
		}
	}
	return nil
}

// traced is the verbs that act: each is a step in the trace. Reading
// (shot, read, find, state) is not.
var traced = map[string]bool{
	"run": true, "send": true, "key": true, "click": true, "expect": true,
	"split": true, "window": true, "focus": true, "close-pane": true,
	"new": true, "switch": true, "close": true, "popup": true, "bg": true, "notify": true,
}

// playDo runs one rook verb against a session: the same binary, told
// which server is its and which pane `.` is.
func playDo(name string, args []string) error {
	p, err := loadPlay(name)
	if err != nil {
		return err
	}
	if !p.alive() {
		return fmt.Errorf("play: %s is not running (its program may have closed its last pane; `rook play start` again)", p.Name)
	}
	if args[0] == "play" || args[0] == "kill" || args[0] == "server" || args[0] == "attach" {
		return fmt.Errorf("play: `rook play stop %s` ends a session; %s is not a verb to say inside one", p.Name, args[0])
	}
	self, err := os.Executable()
	if err != nil {
		return err
	}
	cmd := exec.Command(self, args...)
	cmd.Env = p.env(p.pane())
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	code := 0
	if err := cmd.Run(); err != nil {
		code = 1
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		}
	}
	if p.Trace && traced[args[0]] && p.alive() {
		playRecord(p, args, code)
	}
	os.Exit(code)
	return nil
}

// A traceStep is one thing done and the screen it left: the picture's
// file, shared with the step before when nothing changed.
type traceStep struct {
	N    int      `json:"n"`
	Ms   int64    `json:"ms"`
	Argv []string `json:"argv"`
	Exit int      `json:"exit"`
	Png  string   `json:"png"`
	Hash string   `json:"hash"`
	Text string   `json:"text"`
}

func readSteps(p playSession) []traceStep {
	var steps []traceStep
	data, _ := os.ReadFile(filepath.Join(p.traceDir(), "steps.jsonl"))
	for _, line := range strings.Split(string(data), "\n") {
		var s traceStep
		if json.Unmarshal([]byte(line), &s) == nil && s.N > 0 {
			steps = append(steps, s)
		}
	}
	return steps
}

// playRecord appends a step: the whole glass, once it is still.
func playRecord(p playSession, argv []string, code int) {
	doc, err := p.engine("shot", "--json")
	if err != nil {
		return
	}
	var g shotGrid
	if json.Unmarshal([]byte(doc), &g) != nil {
		return
	}
	steps := readSteps(p)
	sum := sha256.Sum256([]byte(doc))
	step := traceStep{
		N: len(steps) + 1, Ms: time.Now().UnixMilli() - p.Started, Argv: argv, Exit: code,
		Hash: fmt.Sprintf("%x", sum[:8]), Text: newScreen(g, 0).text(),
	}
	if len(steps) > 0 && steps[len(steps)-1].Hash == step.Hash {
		step.Png = steps[len(steps)-1].Png
		step.Text = ""
	} else if img, err := drawShot(g); err == nil {
		step.Png = fmt.Sprintf("%04d.png", step.N)
		if f, err := os.Create(filepath.Join(p.traceDir(), step.Png)); err == nil {
			png.Encode(f, img)
			f.Close()
		}
	}
	line, _ := json.Marshal(step)
	f, err := os.OpenFile(filepath.Join(p.traceDir(), "steps.jsonl"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	f.Write(append(line, '\n'))
	f.Close()
}

func playTrace(args []string) error {
	out := ""
	name := ""
	for i := 0; i < len(args); i++ {
		switch {
		case (args[i] == "-o" || args[i] == "--out") && i+1 < len(args):
			out = args[i+1]
			i++
		case strings.HasPrefix(args[i], "-"):
			return fmt.Errorf("usage: rook play trace NAME [-o FILE]")
		default:
			name = args[i]
		}
	}
	// a stopped session's trace is still there: its directory is all
	// that is left of it
	p := playSession{Name: name}
	if name == "" || strings.ContainsAny(name, "/. \t") {
		return fmt.Errorf("usage: rook play trace NAME [-o FILE]")
	}
	if loaded, err := loadPlay(name); err == nil {
		p = loaded
	}
	page, err := writeTrace(p, out)
	if err != nil {
		return err
	}
	fmt.Println(page)
	return nil
}

// writeTrace makes the trace a page: every step, what it was, whether
// it passed, and the screen it left, pictures inline so the one file
// is the whole thing.
func writeTrace(p playSession, out string) (string, error) {
	steps := readSteps(p)
	if len(steps) == 0 {
		return "", fmt.Errorf("play: no trace for %s", p.Name)
	}
	if out == "" {
		out = filepath.Join(p.traceDir(), "trace.html")
	}
	var b strings.Builder
	failed := 0
	for _, s := range steps {
		if s.Exit != 0 {
			failed++
		}
	}
	fmt.Fprintf(&b, `<!doctype html><meta charset="utf-8"><title>rook play: %s</title>
<style>
:root{color-scheme:dark}
body{background:#11111b;color:#cdd6f4;font:14px/1.5 -apple-system,system-ui,sans-serif;margin:0 auto;max-width:1100px;padding:24px 16px}
h1{font-size:18px;margin:0 0 4px}
.sub{color:#a6adc8;margin-bottom:24px}
.step{border-top:1px solid #313244;padding:16px 0}
.head{display:flex;gap:12px;align-items:baseline;flex-wrap:wrap}
.n{color:#6c7086;min-width:2.5em}
code{font:13px/1.4 ui-monospace,Menlo,monospace;background:#1e1e2e;padding:2px 6px;border-radius:4px;word-break:break-all}
.t{color:#6c7086;margin-left:auto}
.ok{color:#a6e3a1}.bad{color:#f38ba8;font-weight:600}
img{display:block;max-width:100%%;height:auto;margin-top:10px;border:1px solid #313244;border-radius:4px}
.same{color:#6c7086;margin-top:6px;font-style:italic}
</style>
<h1>rook play: %s</h1>
<div class="sub">%s · %s · %d steps%s</div>
`, html.EscapeString(p.Name), html.EscapeString(p.Name), html.EscapeString(dash(p.Command)), html.EscapeString(p.Size), len(steps),
		map[bool]string{true: fmt.Sprintf(` · <span class="bad">%d failed</span>`, failed), false: ""}[failed > 0])
	last := ""
	for _, s := range steps {
		status := `<span class="ok">ok</span>`
		if s.Exit != 0 {
			status = fmt.Sprintf(`<span class="bad">exit %d</span>`, s.Exit)
		}
		fmt.Fprintf(&b, `<div class="step"><div class="head"><span class="n">%d</span><code>rook %s</code>%s<span class="t">+%.2fs</span></div>`,
			s.N, html.EscapeString(shellJoin(s.Argv)), status, float64(s.Ms)/1000)
		if s.Png == last && last != "" {
			b.WriteString(`<div class="same">the screen did not change</div>`)
		} else if data, err := os.ReadFile(filepath.Join(p.traceDir(), s.Png)); err == nil {
			fmt.Fprintf(&b, `<img alt="%s" src="data:image/png;base64,%s">`, html.EscapeString("the screen after step "+strconv.Itoa(s.N)), base64.StdEncoding.EncodeToString(data))
			last = s.Png
		}
		b.WriteString("</div>\n")
	}
	if err := os.WriteFile(out, []byte(b.String()), 0o644); err != nil {
		return "", err
	}
	return out, nil
}

// shellJoin writes an argv the way it would be typed.
func shellJoin(argv []string) string {
	var out []string
	for _, a := range argv {
		plain := a != ""
		for _, r := range a {
			if !(r == '-' || r == '_' || r == '.' || r == '/' || r == ',' || r == ':' || r == '=' || r == '#' || r == '%' || r == '+' ||
				(r >= '0' && r <= '9') || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')) {
				plain = false
			}
		}
		if !plain {
			q := strconv.QuoteToGraphic(a)
			a = "'" + strings.ReplaceAll(q[1:len(q)-1], "'", "'\\''") + "'"
		}
		out = append(out, a)
	}
	return strings.Join(out, " ")
}
