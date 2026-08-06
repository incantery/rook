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
// So: find the project's own tooling first, and only fall back to the
// machine's. One server for TypeScript and JavaScript both — tsserver
// has always type-checked .js from JSDoc, and splitting them would
// index the same project twice.
//
// Protocol: man 7 rook-plugin, one op, lsp.resolve.
package main

import (
	"bufio"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
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
			}
			if json.Unmarshal(req.Params, &p) != nil {
				send(out, req.ID, false, nil, "params did not parse")
				continue
			}
			send(out, req.ID, true, resolve(p.Root), "")
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
var candidates = []struct {
	bin       string
	args      []string
	localOnly bool
	// wantsTsdk is true for the tsserver wrappers, which have to be
	// told where the project's compiler is. tsgo IS the compiler.
	wantsTsdk bool
}{
	{"tsgo", []string{"--lsp", "--stdio"}, true, false},
	{"vtsls", []string{"--stdio"}, false, true},
	{"typescript-language-server", []string{"--stdio"}, false, true},
}

func resolve(root string) map[string]any {
	if root == "" {
		return map[string]any{"error": "no project directory"}
	}
	local := filepath.Join(root, "node_modules", ".bin")

	for _, c := range candidates {
		p := filepath.Join(local, c.bin)
		if !executable(p) {
			if c.localOnly {
				continue
			}
			found, err := exec.LookPath(c.bin)
			if err != nil {
				continue
			}
			p = found
		}
		res := map[string]any{"command": append([]string{p}, c.args...)}
		if c.wantsTsdk {
			if lib := tsdk(root); lib != "" {
				res["settings"] = map[string]any{"typescript": map[string]any{"tsdk": lib}}
			}
		}
		return res
	}
	return map[string]any{
		"error": "no TypeScript language server — `npm i -D @typescript/native-preview`, " +
			"or `npm i -g typescript-language-server typescript`",
	}
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

func executable(p string) bool {
	fi, err := os.Stat(p)
	if err != nil || fi.IsDir() {
		return false
	}
	return fi.Mode()&0o111 != 0
}
