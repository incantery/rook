package main

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestZigVersionComesFromTheProjectsOwnZig(t *testing.T) {
	// A fake `zig` that answers a version, put where a project's shim
	// would be. This is how mise, asdf and direnv all work: $PATH
	// resolves per-directory, so running the real thing in the real
	// place respects every one of them without knowing any of them.
	dir := t.TempDir()
	writeExec(t, filepath.Join(dir, "zig"), "#!/bin/sh\necho 0.15.1\n")
	t.Setenv("PATH", dir)

	root := t.TempDir()
	v, from := zigVersion(root)
	if v != "0.15.1" {
		t.Fatalf("version = %q, want 0.15.1", v)
	}
	if from != "on PATH" {
		t.Fatalf("from = %q", from)
	}
}

func TestTheManifestAnswersWhenNoZigIsInstalled(t *testing.T) {
	// A machine with the project checked out but no toolchain. The
	// manifest still says what it expects, which is enough to fetch a
	// matching zls.
	t.Setenv("PATH", t.TempDir())
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "build.zig.zon"),
		[]byte(".{\n    .name = .x,\n    .minimum_zig_version = \"0.14.0\",\n}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	v, from := zigVersion(root)
	if v != "0.14.0" || from != "build.zig.zon" {
		t.Fatalf("version = %q from %q, want 0.14.0 from build.zig.zon", v, from)
	}
}

func TestNoZigAtAllIsRefusedRatherThanGuessed(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	res := resolve(t.TempDir(), t.TempDir())
	if _, bad := res["error"]; !bad {
		t.Fatalf("resolve = %v, want an error", res)
	}
}

func TestACachedZlsIsUsedRatherThanRefetched(t *testing.T) {
	// Keyed by the ZIG version, which is the question being asked —
	// switching between two projects must not re-download a binary that
	// is already on disk.
	bin := t.TempDir()
	writeExec(t, filepath.Join(bin, "zig"), "#!/bin/sh\necho 0.16.0\n")
	t.Setenv("PATH", bin)

	dir := t.TempDir()
	want := filepath.Join(dir, "zls", "0.16.0", "zls")
	if err := os.MkdirAll(filepath.Dir(want), 0o755); err != nil {
		t.Fatal(err)
	}
	writeExec(t, want, "#!/bin/sh\n")

	res := resolve(t.TempDir(), dir)
	cmd := res["command"].([]string)
	if cmd[0] != want {
		t.Fatalf("command = %v, want the cached %q", cmd, want)
	}
	if note := res["note"].(string); !strings.Contains(note, "cached") {
		t.Fatalf("note = %q, want it to say cached", note)
	}
}

func TestAMatchingZlsYouManageYourselfIsUsed(t *testing.T) {
	// The difference between reading somebody's environment and
	// overriding it. A zls from mise or a package manager that is the
	// right version is the right answer, and downloading a second copy
	// of it would be rude and slower.
	bin := t.TempDir()
	writeExec(t, filepath.Join(bin, "zig"), "#!/bin/sh\necho 0.16.0\n")
	writeExec(t, filepath.Join(bin, "zls"), "#!/bin/sh\necho 0.16.0\n")
	t.Setenv("PATH", bin)

	res := resolve(t.TempDir(), t.TempDir())
	cmd := res["command"].([]string)
	if cmd[0] != filepath.Join(bin, "zls") {
		t.Fatalf("command = %v, want your own zls", cmd)
	}
}

func TestAZlsOfTheWrongVersionIsNotUsed(t *testing.T) {
	// The whole reason this plugin exists. A zls built for 0.15 cannot
	// parse a 0.16 project, and the failure is errors on valid code —
	// so a mismatched binary on $PATH must be ignored, not preferred
	// for being closer to hand.
	bin := t.TempDir()
	writeExec(t, filepath.Join(bin, "zig"), "#!/bin/sh\necho 0.16.0\n")
	writeExec(t, filepath.Join(bin, "zls"), "#!/bin/sh\necho 0.15.1\n")
	t.Setenv("PATH", bin)

	// No network in tests: with the index unreachable this fails, and
	// what is under test is that it did NOT settle for the 0.15.1.
	res := resolve(t.TempDir(), t.TempDir())
	if cmd, served := res["command"]; served {
		t.Fatalf("command = %v, want no server rather than a mismatched one", cmd)
	}
}

func TestBuildMetadataDoesNotMakeTwoReleases(t *testing.T) {
	if !sameRelease("0.16.0", "0.16.0+abc123") {
		t.Fatal("0.16.0 and 0.16.0+abc123 are one release")
	}
	if sameRelease("0.16.0", "0.15.1") {
		t.Fatal("0.16.0 and 0.15.1 are not")
	}
	if sameRelease("", "0.16.0") {
		t.Fatal("an empty version matches nothing")
	}
}

func TestPlatformKeyMatchesTheIndexs(t *testing.T) {
	// Verified against a live response while writing this: the index
	// keys on `aarch64-macos`, not on Go's `arm64`/`darwin`.
	p := platform()
	if strings.Contains(p, "arm64") || strings.Contains(p, "darwin") || strings.Contains(p, "amd64") {
		t.Fatalf("platform = %q, still in Go's spelling", p)
	}
}

// A checksummed archive served over a local HTTP server: the whole
// fetch path — download, verify, unpack, rename — without the network.
func TestTheFetchPathVerifiesAndLandsAVersionedBinary(t *testing.T) {
	arc, sum := makeZip(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, arc)
	}))
	defer srv.Close()

	dir := t.TempDir()
	got, err := install(dir, "0.16.0", &asset{Tarball: srv.URL + "/zls.zip", Shasum: sum})
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(dir, "zls", "0.16.0", "zls")
	if got != want {
		t.Fatalf("installed at %q, want %q", got, want)
	}
	if !executable(got) {
		t.Fatalf("%q is not executable", got)
	}
	// Nothing left behind: a partial directory surviving would be
	// picked up as a cached install next time.
	entries, _ := os.ReadDir(filepath.Join(dir, "zls"))
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".partial-") {
			t.Fatalf("a partial install survived: %s", e.Name())
		}
	}
}

func TestABadChecksumIsRefusedAndNothingIsInstalled(t *testing.T) {
	// The pin. A mismatch is either a corrupted download or somebody
	// else's binary, and neither is a thing to work around — this is a
	// program rook is about to execute.
	arc, _ := makeZip(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, arc)
	}))
	defer srv.Close()

	dir := t.TempDir()
	_, err := install(dir, "0.16.0", &asset{
		Tarball: srv.URL + "/zls.zip",
		Shasum:  "0000000000000000000000000000000000000000000000000000000000000000",
	})
	if err == nil {
		t.Fatal("a mismatched checksum was accepted")
	}
	if !strings.Contains(err.Error(), "checksum") {
		t.Fatalf("error = %v, want it to name the checksum", err)
	}
	if exists(filepath.Join(dir, "zls", "0.16.0")) {
		t.Fatal("a refused download still landed a directory")
	}
}

func TestAnArchiveWithoutZlsIsRefused(t *testing.T) {
	arc, sum := makeZipWith(t, "not-zls")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, arc)
	}))
	defer srv.Close()
	if _, err := install(t.TempDir(), "0.16.0", &asset{Tarball: srv.URL + "/z.zip", Shasum: sum}); err == nil {
		t.Fatal("an archive with no zls in it was accepted")
	}
}

func TestTwoZigVersionsGetTwoDirectories(t *testing.T) {
	// A machine with two Zig projects on two compilers wants two zls
	// binaries. Keying the cache on the version is what stops the
	// second install clobbering the first.
	arc, sum := makeZip(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeFile(w, r, arc)
	}))
	defer srv.Close()

	dir := t.TempDir()
	a, err := install(dir, "0.16.0", &asset{Tarball: srv.URL + "/z.zip", Shasum: sum})
	if err != nil {
		t.Fatal(err)
	}
	b, err := install(dir, "0.15.1", &asset{Tarball: srv.URL + "/z.zip", Shasum: sum})
	if err != nil {
		t.Fatal(err)
	}
	if a == b {
		t.Fatalf("both versions landed at %q", a)
	}
	if !executable(a) || !executable(b) {
		t.Fatal("one of them stopped being executable")
	}
}

func TestTheIndexsRefusalIsNotAnError(t *testing.T) {
	// A dev build. The index answers `{"error":...}` rather than
	// failing, and that is a real answer: there is no zls for a
	// half-finished compiler, and falling back to a release would
	// mis-parse the project.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]string{"error": "not a valid version"})
	}))
	defer srv.Close()

	old := indexURLForTest
	indexURLForTest = srv.URL
	defer func() { indexURLForTest = old }()

	a, _, err := lookup("0.17.0-dev.1+abc")
	if err != nil {
		t.Fatalf("err = %v, want the refusal treated as an answer", err)
	}
	if a != nil {
		t.Fatalf("asset = %v, want none", a)
	}
}

// ---- helpers ----

func writeExec(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
}

func makeZip(t *testing.T) (string, string) { return makeZipWith(t, "zls") }

// makeZipWith builds a flat archive shaped like the real one — the
// binary, a LICENSE and a README beside it — and returns its path and
// sha256.
func makeZipWith(t *testing.T, binName string) (string, string) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "z.zip")
	f, err := os.Create(p)
	if err != nil {
		t.Fatal(err)
	}
	zw := zip.NewWriter(f)
	for name, body := range map[string]string{
		binName:   "#!/bin/sh\necho zls\n",
		"LICENSE": "MIT\n",
		"README":  "hi\n",
	} {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		w.Write([]byte(body))
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	f.Close()

	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	h := sha256.Sum256(b)
	return p, hex.EncodeToString(h[:])
}

// tar is used for the .tar.xz assets; a machine without it would fail
// the real path, so it is worth knowing.
func TestTheSystemTarIsThere(t *testing.T) {
	if _, err := exec.LookPath("tar"); err != nil {
		t.Skip("no tar; the .tar.xz assets cannot be unpacked here")
	}
}
