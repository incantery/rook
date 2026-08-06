// rook-plugin-lang-zig — which zls goes with the Zig this project
// builds with.
//
// The strictest version-matching case rook has. zls is locked to a Zig
// release: a zls built for 0.15 cannot parse a 0.16 project, and the
// failure is not subtle — you get errors on valid code. Zigtools
// publish a version index for exactly this reason, keyed on the Zig
// version rather than on "latest".
//
// So this is not an updater. The question is never "is there a newer
// zls", it is "which zls goes with THIS project", and the answer
// changes when you cd. A machine with two Zig projects on two compilers
// wants two zls binaries, which is why the cache is keyed by version:
//
//	<dir>/zls/0.16.0/zls
//	<dir>/zls/0.15.1/zls
//
// `dir` is handed over by rook (language.serversDir) and is the only
// place this program writes. It reads the environment — including
// whatever mise, asdf or a shell has done to $PATH — and never manages
// it: version managers already answer "which Zig does this directory
// get", and competing with them would leave two things fighting over
// the answer.
//
// Protocol: man 7 rook-plugin, one op, lsp.resolve.
package main

import (
	"archive/zip"
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"time"
)

const version = "0.1.0"

// The index, which answers "what zls goes with this zig" per platform,
// with a sha256 for each. `only-runtime` asks for a zls that RUNS
// against this Zig, rather than one built by it — rook is not building
// anything, and the stricter compatibility class rejects pairs that
// work perfectly well.
const indexURL = "https://releases.zigtools.org/v1/zls/select-version"

// Overridden by the tests, which serve the index locally: the fetch
// path is the part most worth pinning and the least worth reaching the
// network for.
var indexURLForTest = indexURL

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
				"name":         "lang-zig",
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
			send(out, req.ID, false, nil, "lang-zig does not do "+req.Op)
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

func resolve(root, dir string) map[string]any {
	if root == "" {
		return map[string]any{"error": "no project directory"}
	}
	zig, from := zigVersion(root)
	if zig == "" {
		return map[string]any{
			"error": "no zig found for this project — install one, or set a version with mise/asdf",
		}
	}

	// Already have the right one? Two ways, and both mean no download.
	// A zls this plugin fetched before, or a zls the USER manages —
	// with mise, with a package manager, by hand. Taking theirs when it
	// matches is the difference between reading their environment and
	// overriding it.
	if p := cached(dir, zig); p != "" {
		return ok(p, zig, from, "cached")
	}
	if p, v := onPath(); p != "" && sameRelease(v, zig) {
		return ok(p, zig, from, "your own zls "+v)
	}

	asset, zlsVer, err := lookup(zig)
	if err != nil {
		return map[string]any{"error": err.Error()}
	}
	// A dev build asks the index for a version it will not answer for.
	// Say so precisely rather than falling back to a release that will
	// mis-parse the project.
	if asset == nil {
		return map[string]any{
			"error": fmt.Sprintf("no zls published for zig %s — `mise use zig@latest`, or install zls yourself", zig),
		}
	}
	p, err := install(dir, zig, asset)
	if err != nil {
		return map[string]any{"error": "could not install zls " + zlsVer + ": " + err.Error()}
	}
	return ok(p, zig, from, "fetched zls "+zlsVer)
}

func ok(bin, zig, from, how string) map[string]any {
	return map[string]any{
		"command": []string{bin},
		// Not settings — rook does not show this yet, but the reason a
		// particular binary was chosen is the thing anybody debugging
		// this will want, and losing it in the plugin's own head is how
		// "why is my zls wrong" becomes unanswerable.
		"note": fmt.Sprintf("zig %s (%s), %s", zig, from, how),
	}
}

// zigVersion is the Zig this project gets, and how we know.
//
// `zig version` with cwd set to the project, FIRST and by a distance:
// mise, asdf, direnv and rustup-style shims are all $PATH tricks that
// resolve per-directory, so running the real thing in the real place is
// what respects every one of them without this program knowing any of
// them exist.
func zigVersion(root string) (string, string) {
	if v := run(root, "zig", "version"); v != "" {
		return v, "on PATH"
	}
	// No zig at all. The manifest still says what this project expects,
	// which is enough to fetch a matching zls — useful on a machine
	// that has the project checked out but not the toolchain.
	if v := minimumZigVersion(root); v != "" {
		return v, "build.zig.zon"
	}
	return "", ""
}

var minZigRe = regexp.MustCompile(`\.minimum_zig_version\s*=\s*"([^"]+)"`)

func minimumZigVersion(root string) string {
	b, err := os.ReadFile(filepath.Join(root, "build.zig.zon"))
	if err != nil {
		return ""
	}
	if m := minZigRe.FindSubmatch(b); m != nil {
		return string(m[1])
	}
	return ""
}

// cached is <dir>/zls/<zigversion>/zls when it is already there.
//
// Keyed by the ZIG version rather than the zls version: it is the
// question being asked, and it means switching projects never
// re-downloads a thing that is already on disk under another name.
func cached(dir, zig string) string {
	if dir == "" {
		return ""
	}
	p := filepath.Join(dir, "zls", zig, "zls")
	if executable(p) {
		return p
	}
	return ""
}

// onPath is a zls the user manages, and its version.
func onPath() (string, string) {
	p, err := exec.LookPath("zls")
	if err != nil {
		return "", ""
	}
	// `zls --version` prints a bare version, sometimes with a `+hash`
	// on a dev build.
	return p, run("", p, "--version")
}

// sameRelease compares two Zig-shaped versions ignoring build
// metadata, so `0.16.0` and `0.16.0+abc123` are one release.
func sameRelease(a, b string) bool {
	cut := func(s string) string {
		if i := strings.IndexByte(s, '+'); i >= 0 {
			return s[:i]
		}
		return s
	}
	a, b = cut(strings.TrimSpace(a)), cut(strings.TrimSpace(b))
	return a != "" && a == b
}

// asset is one platform's build, as the index describes it.
type asset struct {
	Tarball string `json:"tarball"`
	Shasum  string `json:"shasum"`
}

// lookup asks the index which zls goes with this Zig.
//
// A nil asset with no error means the index answered but has nothing
// for this platform or this version — a dev build, most often, which it
// refuses outright.
func lookup(zig string) (*asset, string, error) {
	url := fmt.Sprintf("%s?zig_version=%s&compatibility=only-runtime", indexURLForTest, zig)
	c := &http.Client{Timeout: 20 * time.Second}
	resp, err := c.Get(url)
	if err != nil {
		return nil, "", fmt.Errorf("could not reach the zls index: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, "", err
	}
	var wire map[string]json.RawMessage
	if json.Unmarshal(body, &wire) != nil {
		return nil, "", fmt.Errorf("the zls index answered something that is not JSON")
	}
	if _, bad := wire["error"]; bad {
		return nil, "", nil
	}
	var zlsVer string
	if raw, okv := wire["version"]; okv {
		json.Unmarshal(raw, &zlsVer)
	}
	raw, okv := wire[platform()]
	if !okv {
		return nil, "", nil
	}
	var a asset
	if json.Unmarshal(raw, &a) != nil || a.Tarball == "" {
		return nil, "", nil
	}
	return &a, zlsVer, nil
}

// platform is the index's key for this machine: `aarch64-macos`.
func platform() string {
	arch := runtime.GOARCH
	switch arch {
	case "amd64":
		arch = "x86_64"
	case "arm64":
		arch = "aarch64"
	case "386":
		arch = "x86"
	}
	osname := runtime.GOOS
	if osname == "darwin" {
		osname = "macos"
	}
	return arch + "-" + osname
}

// install downloads, verifies and unpacks one asset into
// <dir>/zls/<zigVer>/, and returns the binary inside it.
//
// Verified BEFORE anything is unpacked, and unpacked beside the final
// directory then RENAMED into place — so an interrupted install cannot
// leave half a binary sitting where a whole one is expected. The same
// rule rook's own plugin and grammar fetches follow.
func install(dir, zigVer string, a *asset) (string, error) {
	if dir == "" {
		return "", fmt.Errorf("rook offered no directory to install into")
	}
	home := filepath.Join(dir, "zls")
	if err := os.MkdirAll(home, 0o755); err != nil {
		return "", err
	}
	final := filepath.Join(home, zigVer)

	tmp, err := os.MkdirTemp(home, ".partial-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(tmp)

	arc := filepath.Join(tmp, "zls"+archiveExt(a.Tarball))
	if err := download(a.Tarball, arc); err != nil {
		return "", err
	}
	sum, err := sha256File(arc)
	if err != nil {
		return "", err
	}
	if !strings.EqualFold(sum, a.Shasum) {
		// The pin. A mismatch is not something to work around: it is
		// either a corrupted download or somebody else's binary.
		return "", fmt.Errorf("checksum mismatch (wanted %s, got %s)", a.Shasum, sum)
	}
	unpacked := filepath.Join(tmp, "x")
	if err := os.MkdirAll(unpacked, 0o755); err != nil {
		return "", err
	}
	if err := unpack(arc, unpacked); err != nil {
		return "", err
	}
	name := "zls"
	if runtime.GOOS == "windows" {
		name = "zls.exe"
	}
	if !exists(filepath.Join(unpacked, name)) {
		return "", fmt.Errorf("no %s in the archive", name)
	}
	if err := os.Chmod(filepath.Join(unpacked, name), 0o755); err != nil {
		return "", err
	}
	// The archive carries a LICENSE and a README beside the binary, and
	// they come with it: keeping the whole thing is what makes
	// `rm -rf <dir>/zls/<version>` a complete uninstall of this zls.
	if err := os.Rename(unpacked, final); err != nil {
		// Another rook won the race and put an identical build here.
		// Its copy is as good as ours, verified the same way.
		if exists(filepath.Join(final, name)) {
			return filepath.Join(final, name), nil
		}
		return "", err
	}
	return filepath.Join(final, name), nil
}

func archiveExt(u string) string {
	if strings.HasSuffix(u, ".zip") {
		return ".zip"
	}
	return ".tar.xz"
}

func download(url, dest string) error {
	c := &http.Client{Timeout: 5 * time.Minute}
	resp, err := c.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("%s: %s", url, resp.Status)
	}
	f, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer f.Close()
	// Capped: a redirect to something enormous should fail rather than
	// fill the disk. zls is a couple of megabytes.
	if _, err := io.Copy(f, io.LimitReader(resp.Body, 256<<20)); err != nil {
		return err
	}
	return f.Sync()
}

func sha256File(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// unpack handles both shapes the index serves.
//
// `.tar.xz` goes through the system tar, which has handled xz through
// libarchive on macOS for years and through xz-utils everywhere else.
// Shelling out to a system archiver is not the same as shelling out to
// a package manager: it installs nothing and touches nothing outside
// the directory it is pointed at.
func unpack(archive, dest string) error {
	if strings.HasSuffix(archive, ".zip") {
		return unzip(archive, dest)
	}
	cmd := exec.Command("tar", "-xf", archive, "-C", dest)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("tar: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func unzip(archive, dest string) error {
	r, err := zip.OpenReader(archive)
	if err != nil {
		return err
	}
	defer r.Close()
	for _, f := range r.File {
		name := filepath.Base(f.Name) // flat archives only; no traversal
		if f.FileInfo().IsDir() || name == "." || name == ".." {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return err
		}
		out, err := os.OpenFile(filepath.Join(dest, name), os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o755)
		if err != nil {
			rc.Close()
			return err
		}
		_, err = io.Copy(out, io.LimitReader(rc, 256<<20))
		rc.Close()
		out.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

// run executes a command in dir and returns its trimmed first line, or
// "". Failure is ordinary: most of these are "the tool is not here".
func run(dir, bin string, args ...string) string {
	cmd := exec.Command(bin, args...)
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	line := strings.TrimSpace(string(out))
	if i := strings.IndexByte(line, '\n'); i >= 0 {
		line = strings.TrimSpace(line[:i])
	}
	return line
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
