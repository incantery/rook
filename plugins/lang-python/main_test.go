package main

import (
	"os"
	"path/filepath"
	"testing"
)

// venv fakes a virtualenv at dir and returns its interpreter path.
func venv(t *testing.T, dir string) string {
	t.Helper()
	bin := filepath.Join(dir, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	py := filepath.Join(bin, "python")
	if err := os.WriteFile(py, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return py
}

func TestProjectVenvBeatsAnActivatedShell(t *testing.T) {
	// The ordering that matters most in practice. A terminal usually
	// has SOME venv active, and it is very often not this project's —
	// pointing a server at it reports the wrong dependency set, which
	// looks exactly like a broken project.
	root := t.TempDir()
	want := venv(t, filepath.Join(root, ".venv"))

	other := t.TempDir()
	venv(t, other)
	t.Setenv("VIRTUAL_ENV", other)

	if got := interpreter(root); got != want {
		t.Fatalf("interpreter = %q, want the project's own %q", got, want)
	}
}

func TestTheUsualVenvNames(t *testing.T) {
	for _, name := range []string{".venv", "venv", ".virtualenv", "env"} {
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			want := venv(t, filepath.Join(root, name))
			if got := interpreter(root); got != want {
				t.Fatalf("interpreter = %q, want %q", got, want)
			}
		})
	}
}

func TestAnActivatedShellIsUsedWhenTheProjectHasNothing(t *testing.T) {
	root := t.TempDir()
	active := t.TempDir()
	want := venv(t, active)
	t.Setenv("VIRTUAL_ENV", active)
	if got := interpreter(root); got != want {
		t.Fatalf("interpreter = %q, want %q", got, want)
	}
}

func TestNoInterpreterIsAnEmptyStringNotAGuess(t *testing.T) {
	// A path that does not exist is worse than no path: pyright told
	// about a missing interpreter reports every import unresolved.
	t.Setenv("VIRTUAL_ENV", "")
	t.Setenv("CONDA_PREFIX", "")
	if got := interpreter(t.TempDir()); got != "" {
		t.Fatalf("interpreter = %q, want none", got)
	}
}

func TestAVersionFileIsNotAPath(t *testing.T) {
	// `.python-version` usually holds "3.12", which names nothing on
	// disk. Guessing pyenv's layout from it points a server at an
	// interpreter that is not there.
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, ".python-version"), []byte("3.12\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("VIRTUAL_ENV", "")
	t.Setenv("CONDA_PREFIX", "")
	if got := interpreter(root); got != "" {
		t.Fatalf("interpreter = %q, want none — a version is not a path", got)
	}
}

func TestAVersionFileHoldingARealPathIsUsed(t *testing.T) {
	root := t.TempDir()
	env := t.TempDir()
	want := venv(t, env)
	if err := os.WriteFile(filepath.Join(root, ".venv-path"), []byte(env+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := interpreter(root); got != want {
		t.Fatalf("interpreter = %q, want %q", got, want)
	}
}

func TestTheProjectsOwnServerWinsOverTheMachines(t *testing.T) {
	// A venv with a server in it is a project that pinned that server.
	// The machine's copy may be a different major version, reporting
	// rules this project never opted into.
	root := t.TempDir()
	py := venv(t, filepath.Join(root, ".venv"))
	want := filepath.Join(filepath.Dir(py), "pyright-langserver")
	if err := os.WriteFile(want, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	cmd, kind := server(root, py)
	if len(cmd) == 0 || cmd[0] != want {
		t.Fatalf("server = %v, want the project's own %q", cmd, want)
	}
	if kind != kindPyright {
		t.Fatalf("kind = %v, want pyright", kind)
	}
	// The flag is not optional: `pyright-langserver` without --stdio
	// starts a server nobody can talk to.
	if len(cmd) != 2 || cmd[1] != "--stdio" {
		t.Fatalf("server = %v, want --stdio", cmd)
	}
}

func TestBasedpyrightIsPreferredToPyright(t *testing.T) {
	root := t.TempDir()
	py := venv(t, filepath.Join(root, ".venv"))
	bin := filepath.Dir(py)
	for _, n := range []string{"pyright-langserver", "basedpyright-langserver"} {
		if err := os.WriteFile(filepath.Join(bin, n), []byte("#!/bin/sh\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	cmd, _ := server(root, py)
	if len(cmd) == 0 || filepath.Base(cmd[0]) != "basedpyright-langserver" {
		t.Fatalf("server = %v, want basedpyright — a project that installed it did so on purpose", cmd)
	}
}

func TestSettingsMatchTheServerFamily(t *testing.T) {
	// The shapes genuinely differ, and rook used to emit pyright's for
	// every server — which meant pylsp got configuration it ignored and
	// then reported the wrong dependencies.
	py := "/p/.venv/bin/python"

	pyright := settings(kindPyright, py)
	if pyright["python"].(map[string]any)["pythonPath"] != py {
		t.Fatalf("pyright settings = %v", pyright)
	}

	pylsp := settings(kindPylsp, py)
	plugins := pylsp["pylsp"].(map[string]any)["plugins"].(map[string]any)
	if got := plugins["jedi"].(map[string]any)["environment"]; got != "/p/.venv" {
		// The ENVIRONMENT, not the interpreter: jedi wants the prefix.
		t.Fatalf("pylsp environment = %v, want /p/.venv", got)
	}

	jedi := settings(kindJedi, py)
	if got := jedi["jedi"].(map[string]any)["environment"]; got != "/p/.venv" {
		t.Fatalf("jedi environment = %v, want /p/.venv", got)
	}
}

func TestNoServerNamesTheFix(t *testing.T) {
	// The whole reason the resolver seam exists. "No language server
	// for this file" is a sentence nobody can act on.
	t.Setenv("PATH", t.TempDir())
	t.Setenv("VIRTUAL_ENV", "")
	t.Setenv("CONDA_PREFIX", "")
	res := resolve(t.TempDir())
	msg, ok := res["error"].(string)
	if !ok || msg == "" {
		t.Fatalf("resolve = %v, want an error naming the fix", res)
	}
	for _, want := range []string{"basedpyright", "pyright", "python-lsp-server"} {
		if !contains(msg, want) {
			t.Fatalf("error %q does not mention %q", msg, want)
		}
	}
}

func TestNoRootIsRefusedRatherThanSearchedFor(t *testing.T) {
	res := resolve("")
	if _, ok := res["error"]; !ok {
		t.Fatalf("resolve(\"\") = %v, want an error", res)
	}
}

func TestAResolvedProjectCarriesBothHalves(t *testing.T) {
	root := t.TempDir()
	py := venv(t, filepath.Join(root, ".venv"))
	srv := filepath.Join(filepath.Dir(py), "basedpyright-langserver")
	if err := os.WriteFile(srv, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	res := resolve(root)
	if _, bad := res["error"]; bad {
		t.Fatalf("resolve = %v, want a server", res)
	}
	cmd := res["command"].([]string)
	if cmd[0] != srv {
		t.Fatalf("command = %v, want %q", cmd, srv)
	}
	set := res["settings"].(map[string]any)
	if set["python"].(map[string]any)["pythonPath"] != py {
		t.Fatalf("settings = %v, want the project's interpreter", set)
	}
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (func() bool {
		for i := 0; i+len(sub) <= len(s); i++ {
			if s[i:i+len(sub)] == sub {
				return true
			}
		}
		return false
	})()
}
