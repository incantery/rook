package host

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMergePaths(t *testing.T) {
	cases := []struct{ cur, login, want string }{
		// login extras append AFTER cur — shims first on cur keep winning
		{"/shim:/usr/bin", "/opt/homebrew/bin:/usr/bin", "/shim:/usr/bin:/opt/homebrew/bin"},
		// full overlap is a no-op
		{"/a:/b", "/b:/a", "/a:/b"},
		{"", "/a:/b", "/a:/b"},
		{"/a", "", "/a"},
		// empty segments drop
		{"/a::/b", ":/c:", "/a:/b:/c"},
	}
	for _, c := range cases {
		if got := mergePaths(c.cur, c.login); got != c.want {
			t.Errorf("mergePaths(%q, %q) = %q, want %q", c.cur, c.login, got, c.want)
		}
	}
}

func TestLastNonEmptyLine(t *testing.T) {
	if got := lastNonEmptyLine("banner\nmotd\n/a:/b\n\n"); got != "/a:/b" {
		t.Errorf("lastNonEmptyLine = %q, want /a:/b", got)
	}
	if got := lastNonEmptyLine("\n\n"); got != "" {
		t.Errorf("lastNonEmptyLine on blanks = %q, want empty", got)
	}
}

// A fake $SHELL that prints a banner (profiles do) and carries an extra PATH
// entry — adoption must append the new entry after the inherited ones and
// survive the noise.
func TestAdoptLoginPATH(t *testing.T) {
	dir := t.TempDir()
	shell := filepath.Join(dir, "fakeshell")
	script := "#!/bin/sh\necho 'welcome to fakeshell'\nPATH=\"$PATH:/fake/login/bin\" exec /bin/sh \"$@\"\n"
	if err := os.WriteFile(shell, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SHELL", shell)
	t.Setenv("PATH", "/shim:/usr/bin:/bin")

	AdoptLoginPATH()

	got := os.Getenv("PATH")
	if !strings.HasPrefix(got, "/shim:/usr/bin:/bin") {
		t.Fatalf("inherited entries must stay first, got %q", got)
	}
	if !strings.Contains(got, "/fake/login/bin") {
		t.Fatalf("login entry not adopted, got %q", got)
	}
}

// A shell that fails (or doesn't exist) must leave PATH untouched.
func TestAdoptLoginPATHFailOpen(t *testing.T) {
	t.Setenv("SHELL", filepath.Join(t.TempDir(), "no-such-shell"))
	t.Setenv("PATH", "/only:/these")
	AdoptLoginPATH()
	if got := os.Getenv("PATH"); got != "/only:/these" {
		t.Fatalf("PATH changed on failure: %q", got)
	}
}
