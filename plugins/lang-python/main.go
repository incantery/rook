// rook-plugin-lang-python — what Python project is this, and what
// should rook run for it.
//
// rook has no built-in catalog of languages. Which files are Python is
// a declaration in the environment graph; which SERVER to run and which
// interpreter to point it at has no static answer, so rook asks. That
// question is this program.
//
// It exists because the answer is genuinely Python's, not rook's. There
// are at least four servers people use in earnest — basedpyright,
// pyright, pylsp, jedi — configured differently from each other, and at
// least six ways a project can name its interpreter: a .venv beside the
// pyproject, poetry's cache, uv's, conda, pyenv, or an already-activated
// shell. Getting that wrong is not a subtle failure: point pyright at a
// project without its interpreter and every third-party import comes
// back "could not be resolved", which is a diagnostic panel full of
// errors that are not errors, and worse than silence.
//
// None of that reasoning belongs in a terminal emulator, and while it
// lived in one it could not be fixed without shipping a new rook.
//
// Protocol: man 7 rook-plugin. One op, lsp.resolve:
//
//	→ {"op":"lsp.resolve","params":{"language":"python","root":"/p"}}
//	← {"ok":true,"result":{"command":[...],"settings":{...}}}
//	← {"ok":true,"result":{"error":"no interpreter — run `uv sync`"}}
//
// The error branch is the point of the whole seam. "No language server
// for this file" is a sentence nobody can act on; naming the missing
// piece and the command that installs it is one they can.
package main

import (
	"bufio"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

const version = "0.1.0"

func main() {
	out := bufio.NewWriter(os.Stdout)
	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 64*1024), 1024*1024)
	for in.Scan() {
		var req struct {
			ID     uint64          `json:"id"`
			Op     string          `json:"op"`
			Params json.RawMessage `json:"params"`
		}
		if json.Unmarshal(in.Bytes(), &req) != nil || req.Op == "" {
			continue
		}
		switch req.Op {
		case "describe":
			send(out, req.ID, true, map[string]any{
				"name":         "lang-python",
				"version":      version,
				"capabilities": []string{"lsp.resolve"},
			}, "")
		case "lsp.resolve":
			var p struct {
				Language string `json:"language"`
				Root     string `json:"root"`
			}
			if json.Unmarshal(req.Params, &p) != nil {
				send(out, req.ID, false, nil, "params did not parse")
				continue
			}
			send(out, req.ID, true, resolve(p.Root), "")
		default:
			send(out, req.ID, false, nil, "lang-python does not do "+req.Op)
		}
	}
}

func send(w *bufio.Writer, id uint64, ok bool, result any, errStr string) {
	line, err := json.Marshal(map[string]any{
		"v": 1, "id": id, "ok": ok, "result": result, "error": errStr,
	})
	if err != nil {
		return
	}
	w.Write(line)
	w.WriteByte('\n')
	w.Flush()
}

// resolve answers what to run for the project at root.
//
// Two independent questions, answered in this order because the second
// depends on the first: which interpreter this project means, and which
// server to drive it with. A server found INSIDE the project's own
// environment is preferred over one on $PATH — a venv with pyright in
// it is a project that pinned pyright, and the machine's copy may be a
// different major version.
func resolve(root string) map[string]any {
	if root == "" {
		return map[string]any{"error": "no project directory"}
	}
	py := interpreter(root)
	srv, kind := server(root, py)
	if srv == nil {
		// Name the fix, not the failure. Every one of these is a
		// one-line install, and a user who is told which line does not
		// have to go and read rook's source to find out what it wanted.
		return map[string]any{
			"error": "no Python language server — `uv tool install basedpyright`, " +
				"`pipx install pyright`, or `pip install python-lsp-server`",
		}
	}
	res := map[string]any{"command": srv}
	if py != "" {
		res["settings"] = settings(kind, py)
	}
	return res
}

// serverKind is which family the chosen binary belongs to. It decides
// the shape of the settings, which is the only thing they disagree
// about that matters here.
type serverKind int

const (
	kindPyright serverKind = iota // basedpyright, pyright
	kindPylsp                     // python-lsp-server
	kindJedi                      // jedi-language-server
)

// The servers worth looking for, best first.
//
// basedpyright ahead of pyright: it is a superset, and a project that
// installed it did so on purpose. pylsp and jedi after both, because
// they are the ones people reach for when they do not want a Node
// runtime — a preference, not a fallback, so a project that installed
// one gets it.
var candidates = []struct {
	bin  string
	args []string
	kind serverKind
}{
	{"basedpyright-langserver", []string{"--stdio"}, kindPyright},
	{"pyright-langserver", []string{"--stdio"}, kindPyright},
	{"pylsp", nil, kindPylsp},
	{"jedi-language-server", nil, kindJedi},
}

// server picks one, preferring the project's own environment.
func server(root, py string) ([]string, serverKind) {
	// The bin directory of whatever interpreter we settled on. A server
	// installed next to the interpreter is the one that can import the
	// project's dependencies, which is the entire job.
	var dirs []string
	if py != "" {
		dirs = append(dirs, filepath.Dir(py))
	}
	dirs = append(dirs, filepath.Join(root, "node_modules", ".bin"))

	for _, c := range candidates {
		for _, d := range dirs {
			p := filepath.Join(d, c.bin)
			if executable(p) {
				return append([]string{p}, c.args...), c.kind
			}
		}
	}
	for _, c := range candidates {
		if p, err := exec.LookPath(c.bin); err == nil {
			return append([]string{p}, c.args...), c.kind
		}
	}
	return nil, kindPyright
}

// settings is the initialization options the chosen family wants.
//
// The shapes genuinely differ. pyright reads python.pythonPath; pylsp
// wants it nested under its own plugin namespace; jedi takes an
// environment path rather than an interpreter path. Rook used to emit
// only the first of these, for every server, which meant pylsp got
// configuration it ignored.
func settings(kind serverKind, py string) map[string]any {
	switch kind {
	case kindPylsp:
		return map[string]any{
			"pylsp": map[string]any{
				"plugins": map[string]any{
					"jedi": map[string]any{"environment": filepath.Dir(filepath.Dir(py))},
				},
			},
		}
	case kindJedi:
		return map[string]any{"jedi": map[string]any{"environment": filepath.Dir(filepath.Dir(py))}}
	default:
		return map[string]any{"python": map[string]any{"pythonPath": py}}
	}
}

// interpreter finds the Python this project means, or "".
//
// Ordered by how explicitly the project said so. A venv sitting in the
// project directory is the project's own answer and beats everything;
// an activated shell comes last, because a terminal that happens to
// have another project's venv active must not win over the one on disk
// next to the file you are editing.
func interpreter(root string) string {
	// 1. A virtualenv in the project, under any of its usual names.
	for _, d := range []string{".venv", "venv", ".virtualenv", "env"} {
		if p := pythonIn(filepath.Join(root, d)); p != "" {
			return p
		}
	}
	// 2. Written down in the project's own configuration. Both of these
	//    are things a human typed on purpose.
	if p := fromFile(filepath.Join(root, ".python-version"), root); p != "" {
		return p
	}
	if p := fromFile(filepath.Join(root, ".venv-path"), root); p != "" {
		return p
	}
	// 3. A tool that keeps its environments elsewhere — but ONLY when
	//    this project shows signs of using it.
	//
	//    The gate is load-bearing, not tidiness. `uv python find` in a
	//    directory with no project answers with whatever system Python
	//    it can see, and answering at all would mean a machine with uv
	//    installed never reports "no interpreter" and never falls
	//    through to an activated shell. A lockfile is the project
	//    saying which tool manages it; anything less is a guess.
	for _, q := range []struct {
		marker string
		bin    string
		args   []string
	}{
		{"uv.lock", "uv", []string{"python", "find"}},
		{"poetry.lock", "poetry", []string{"env", "info", "--executable"}},
		{"pdm.lock", "pdm", []string{"info", "--python"}},
		{"hatch.toml", "hatch", []string{"env", "find"}},
	} {
		if !exists(filepath.Join(root, q.marker)) {
			continue
		}
		if p := ask(root, q.bin, q.args...); p != "" {
			return p
		}
	}
	// 4. An activated shell. Last, and deliberately.
	if ve := os.Getenv("VIRTUAL_ENV"); ve != "" {
		if p := pythonIn(ve); p != "" {
			return p
		}
	}
	if cp := os.Getenv("CONDA_PREFIX"); cp != "" {
		if p := pythonIn(cp); p != "" {
			return p
		}
	}
	return ""
}

// pythonIn returns <dir>/bin/python if it is there and runnable.
func pythonIn(dir string) string {
	if dir == "" {
		return ""
	}
	sub, name := "bin", "python"
	if runtime.GOOS == "windows" {
		sub, name = "Scripts", "python.exe"
	}
	for _, n := range []string{name, name + "3"} {
		p := filepath.Join(dir, sub, n)
		if executable(p) {
			return p
		}
	}
	return ""
}

// fromFile reads a path out of a one-line file, relative to root.
//
// A `.python-version` usually holds a pyenv VERSION rather than a path,
// and that is fine: the check below rejects it and the next source is
// tried. Guessing at pyenv's layout from a version string is how you
// point a server at an interpreter that does not exist.
func fromFile(path, root string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	line := strings.TrimSpace(string(b))
	if line == "" || strings.ContainsAny(line, "\n") {
		return ""
	}
	if !filepath.IsAbs(line) {
		line = filepath.Join(root, line)
	}
	if executable(line) {
		return line
	}
	return pythonIn(line)
}

// ask runs a tool that knows where it put an environment.
//
// Failure is silent and ordinary: most projects have none of these
// installed, and "poetry is not on this machine" is not news.
func ask(root, bin string, args ...string) string {
	if _, err := exec.LookPath(bin); err != nil {
		return ""
	}
	cmd := exec.Command(bin, args...)
	cmd.Dir = root
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	// First line only: uv and hatch are chatty on some versions.
	line := strings.TrimSpace(string(out))
	if i := strings.IndexByte(line, '\n'); i >= 0 {
		line = strings.TrimSpace(line[:i])
	}
	if line == "" {
		return ""
	}
	if executable(line) {
		return line
	}
	// hatch answers with the environment DIRECTORY, not the binary.
	return pythonIn(line)
}

func exists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

func executable(p string) bool {
	fi, err := os.Stat(p)
	if err != nil || fi.IsDir() {
		return false
	}
	return fi.Mode()&0o111 != 0
}
