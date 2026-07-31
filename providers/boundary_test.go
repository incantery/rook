package providers

// The boundary, enforced rather than described.
//
// A provider is meant to be writable by someone who has never seen
// rook's source — the SDK and the standard library and nothing else. The
// providers rook ships are the only evidence that is true, so they have
// to live under the same rule: reach into internal/ and this fails.
//
// Go's own `internal` rule will NOT do this for us. It is import-path
// based, so anything under github.com/incantery/rook/ can import
// github.com/incantery/rook/internal/… — including a provider, and
// including a provider in its own module. Only a different module path
// (a separate repository) closes it by construction. Until there is one,
// this test is the boundary.

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestProvidersUseOnlyThePublicSDK(t *testing.T) {
	dirs, err := filepath.Glob("*")
	if err != nil {
		t.Fatal(err)
	}
	var pkgs []string
	for _, d := range dirs {
		if st, err := os.Stat(d); err == nil && st.IsDir() {
			pkgs = append(pkgs, "./"+d)
		}
	}
	if len(pkgs) == 0 {
		t.Fatal("found no providers — this test is looking in the wrong place")
	}

	// The full transitive import set, so a provider cannot launder the
	// dependency through a helper package either.
	args := append([]string{"list", "-deps", "-f", "{{.ImportPath}}"}, pkgs...)
	out, err := exec.Command("go", args...).Output()
	if err != nil {
		t.Fatalf("go list: %v", err)
	}
	for line := range strings.SplitSeq(strings.TrimSpace(string(out)), "\n") {
		if strings.Contains(line, "incantery/rook/internal/") {
			t.Errorf("a provider reaches into core: %s\n"+
				"providers may import github.com/incantery/rook/sdk/... and the standard library, nothing else.", line)
		}
	}
}
