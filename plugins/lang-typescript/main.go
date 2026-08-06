// rook-plugin-lang-typescript — what TypeScript project is this, and
// what should rook run for it.
//
// The companion to rook-plugin-lang-python, and it exists for the same
// reason: rook knows which files are TypeScript from a declaration in
// the environment graph, but which SERVER to run has no static answer,
// and the answer depends on the project rather than on the language.
//
// Three servers are in real use and they are not interchangeable. tsgo
// ships with @typescript/native-preview and is TypeScript 7's own
// server — a project that has it has chosen a compiler whose lib
// directory contains no tsserver.js at all, which the older servers
// cannot drive. vtsls and typescript-language-server both wrap
// tsserver, and both want to be told where the project's compiler is:
// run one against its own bundled TypeScript and it reports errors the
// project's pinned version does not have, then suggests fixes for a
// compiler nobody is using.
//
// So: find the project's own tooling first, then the machine's, and
// only then install one — into ROOK'S prefix, never into the project.
// Adding a language server to somebody's package.json to make an editor
// work is a change every other contributor then has to carry, for a
// tool none of them asked about. One server for TypeScript and
// JavaScript both — tsserver has always type-checked .js from JSDoc,
// and splitting them would index the same project twice.
//
// Protocol: man 7 rook-plugin, one op, lsp.resolve.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
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
				"name":         "lang-typescript",
				"version":      version,
				"capabilities": []string{"lsp.resolve"},
			}, "")
		case "lsp.resolve":
			var p struct {
				Language string `json:"language"`
				Root     string `json:"root"`
				Dir      string `json:"dir"`
			}
			if json.Unmarshal(req.Params, &p) != nil {
				send(out, req.ID, false, nil, "params did not parse")
				continue
			}
			send(out, req.ID, true, resolve(p.Root, p.Dir), "")
		default:
			send(out, req.ID, false, nil, "lang-typescript does not do "+req.Op)
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

// The servers worth looking for, best first.
//
// tsgo first, and only ever found project-locally: having it means the
// project chose TypeScript 7, whose lib has no tsserver.js for the
// others to drive.
type serverKind int

const (
	kindTsgo     serverKind = iota // TypeScript 7's own; IS the compiler
	kindTsserver                   // the wrappers, which need a tsdk
)

var candidates = []struct {
	bin       string
	args      []string
	localOnly bool
	kind      serverKind
}{
	{"tsgo", []string{"--lsp", "--stdio"}, true, kindTsgo},
	{"vtsls", []string{"--stdio"}, false, kindTsserver},
	{"typescript-language-server", []string{"--stdio"}, false, kindTsserver},
}

func resolve(root, dir string) map[string]any {
	if root == "" {
		return map[string]any{"error": "no project directory"}
	}
	// The project's own, first and always: a repo that installed a
	// server pinned that server, and the machine's copy may be a
	// different major version reporting rules nobody opted into.
	if cmd, kind, where := find(filepath.Join(root, "node_modules", ".bin"), true); cmd != nil {
		return served(cmd, kind, root, where)
	}
	// Then the machine's — somebody who installed one globally meant it.
	if cmd, kind, where := find("", false); cmd != nil {
		return served(cmd, kind, root, where)
	}
	// Then one rook installed earlier.
	if cmd, kind, where := find(filepath.Join(dir, "node_modules", ".bin"), false); cmd != nil {
		return served(cmd, kind, root, where)
	}
	// And only then install one, into rook's own prefix.
	cmd, err := installServer(dir)
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	return served(cmd, kindTsserver, root, "installed by rook")
}

func served(cmd []string, kind serverKind, root, where string) map[string]any {
	res := map[string]any{
		"command": cmd,
		"note":    filepath.Base(cmd[0]) + " (" + where + ")",
	}
	// tsgo IS the compiler; the wrappers have to be told where the
	// project's one is.
	if kind == kindTsserver {
		if lib := tsdk(root); lib != "" {
			res["settings"] = map[string]any{"typescript": map[string]any{"tsdk": lib}}
			res["note"] = res["note"].(string) + ", tsdk from the project"
		}
	}
	return res
}

// find looks in one directory, or on $PATH when bin is empty.
//
// `localOnly` candidates are skipped on the $PATH pass: tsgo ships as a
// dependency, so one on $PATH belongs to some other project.
func find(bin string, local bool) ([]string, serverKind, string) {
	for _, c := range candidates {
		if !local && c.localOnly {
			continue
		}
		var p string
		if bin == "" {
			found, err := exec.LookPath(c.bin)
			if err != nil {
				continue
			}
			p = found
		} else {
			p = filepath.Join(bin, c.bin)
			if !executable(p) {
				continue
			}
		}
		where := "on PATH"
		if local {
			where = "the project's own"
		} else if bin != "" {
			where = "rook's"
		}
		return append([]string{p}, c.args...), c.kind, where
	}
	return nil, kindTsserver, ""
}

// installServer puts typescript-language-server in rook's prefix.
//
// Into a temporary prefix and RENAMED into place, which does two
// things: an interrupted install cannot leave a half a node_modules
// that looks present, and two roots resolving at once — an ordinary
// monorepo has several — cannot corrupt each other's tree. The loser of
// that race finds the winner's install and uses it.
//
// `typescript` comes along because the server needs one to fall back
// on; a project with its own still wins through tsdk.
func installServer(dir string) ([]string, error) {
	if dir == "" {
		return nil, fmt.Errorf("rook offered no directory to install into")
	}
	npm, err := exec.LookPath("npm")
	if err != nil {
		// Worth naming precisely: a node managed by nvm is a SHELL
		// FUNCTION, and rook spawns plugins without a shell — so "npm
		// is right there" and "rook can see npm" are different facts.
		return nil, fmt.Errorf("no TypeScript language server, and no npm on rook's PATH to install one — " +
			"`brew install node`, or install typescript-language-server yourself")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	tmp, err := os.MkdirTemp(dir, ".partial-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(tmp)

	cmd := exec.Command(npm, "install", "--prefix", tmp, "--no-save", "--no-audit", "--no-fund",
		"typescript-language-server", "typescript")
	// Never the project: --prefix is what keeps this inside rook's
	// directory, and cwd is set away from any package.json that could
	// be picked up instead.
	cmd.Dir = tmp
	if out, err := cmd.CombinedOutput(); err != nil {
		msg := strings.TrimSpace(string(out))
		if len(msg) > 200 {
			msg = msg[:200] + "…"
		}
		return nil, fmt.Errorf("could not install typescript-language-server: %s", msg)
	}
	if err := os.Rename(filepath.Join(tmp, "node_modules"), filepath.Join(dir, "node_modules")); err != nil {
		if !exists(filepath.Join(dir, "node_modules", ".bin", "typescript-language-server")) {
			return nil, err
		}
	}
	p := filepath.Join(dir, "node_modules", ".bin", "typescript-language-server")
	if !executable(p) {
		return nil, fmt.Errorf("typescript-language-server is not where npm was asked to put it")
	}
	return []string{p, "--stdio"}, nil
}

// tsdk is <root>/node_modules/typescript/lib when the project installed
// its own compiler, else "".
//
// Probed through tsserver.js rather than through the directory, which
// buys two things. A half-removed node_modules leaves an empty
// typescript/lib behind, and pointing a server at one is worse than not
// configuring it at all. And TypeScript 7 has no tsserver.js — it is a
// native binary — so the probe answers "no tsdk" for exactly the
// projects where a tsdk would mean nothing, without this function
// having to know a version number.
func tsdk(root string) string {
	lib := filepath.Join(root, "node_modules", "typescript", "lib")
	if _, err := os.Stat(filepath.Join(lib, "tsserver.js")); err != nil {
		return ""
	}
	return lib
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
