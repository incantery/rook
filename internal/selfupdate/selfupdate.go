// Package selfupdate is rook's upgrade path: releases are zips on GitHub,
// `rookctl update` swaps them in place. Downloads here never touch
// LaunchServices, so no quarantine attribute is set and the ad-hoc-signed
// app runs without Gatekeeper prompts — the reason rook self-manages
// updates instead of shipping through a brew cask.
package selfupdate

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const (
	repo       = "incantery/rook"
	appPath    = "/Applications/rook.app"
	lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
)

var httpClient = &http.Client{Timeout: 5 * time.Minute}

type Release struct {
	Tag    string
	assets map[string]string // asset name → download URL
}

// Latest fetches the newest published release from GitHub.
func Latest() (*Release, error) {
	resp, err := httpClient.Get("https://api.github.com/repos/" + repo + "/releases/latest")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, fmt.Errorf("no releases published yet")
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET releases/latest: %s", resp.Status)
	}
	var body struct {
		TagName string `json:"tag_name"`
		Assets  []struct {
			Name string `json:"name"`
			URL  string `json:"browser_download_url"`
		} `json:"assets"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, err
	}
	rel := &Release{Tag: body.TagName, assets: map[string]string{}}
	for _, a := range body.Assets {
		rel.assets[a.Name] = a.URL
	}
	return rel, nil
}

func (r *Release) NewerThan(current string) bool { return r.Tag != current }

func zipName(tag string) string {
	return fmt.Sprintf("rook-%s-darwin-%s.zip", tag, runtime.GOARCH)
}

// Apply downloads r, verifies its checksum, and swaps /Applications/rook.app
// plus the running rookctl binary. A running app keeps working on its old
// pages; the new version takes over at next launch.
func Apply(r *Release) error {
	name := zipName(r.Tag)
	zipURL := r.assets[name]
	if zipURL == "" {
		return fmt.Errorf("release %s has no asset %s (arch not published?)", r.Tag, name)
	}
	sumURL := r.assets["checksums.txt"]
	if sumURL == "" {
		return fmt.Errorf("release %s has no checksums.txt", r.Tag)
	}

	tmp, err := os.MkdirTemp("", "rook-update-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)

	zipPath := filepath.Join(tmp, name)
	if err := download(zipURL, zipPath); err != nil {
		return err
	}
	sums, err := fetch(sumURL)
	if err != nil {
		return err
	}
	want, ok := findChecksum(sums, name)
	if !ok {
		return fmt.Errorf("checksums.txt has no entry for %s", name)
	}
	got, err := fileSHA256(zipPath)
	if err != nil {
		return err
	}
	if got != want {
		return fmt.Errorf("checksum mismatch for %s: got %s want %s", name, got, want)
	}

	// ditto, not archive/zip: it restores the bundle exactly as packaged
	// (permissions, symlinks, extended attributes), which codesign checks.
	stage := filepath.Join(tmp, "stage")
	if out, err := exec.Command("ditto", "-x", "-k", zipPath, stage).CombinedOutput(); err != nil {
		return fmt.Errorf("unpack: %v: %s", err, out)
	}
	newApp := filepath.Join(stage, "rook.app")
	if _, err := os.Stat(newApp); err != nil {
		return fmt.Errorf("release zip did not contain rook.app: %v", err)
	}

	// Swap the bundle: old one aside first so a failed move is recoverable.
	old := filepath.Join(tmp, "rook.app.old")
	hadOld := false
	if _, err := os.Stat(appPath); err == nil {
		hadOld = true
		if out, err := exec.Command("mv", appPath, old).CombinedOutput(); err != nil {
			return fmt.Errorf("move old app aside: %v: %s", err, out)
		}
	}
	if out, err := exec.Command("mv", newApp, appPath).CombinedOutput(); err != nil {
		if hadOld {
			exec.Command("mv", old, appPath).Run()
		}
		return fmt.Errorf("install new app: %v: %s", err, out)
	}
	// Same post-install dance as make install: without registration
	// Spotlight won't offer the app.
	exec.Command(lsregister, "-f", appPath).Run()
	exec.Command("mdimport", appPath).Run()

	// Replace this very binary (rename over a running executable is fine).
	if newCtl := filepath.Join(stage, "rookctl"); fileExists(newCtl) {
		self, err := os.Executable()
		if err == nil {
			if resolved, err := filepath.EvalSymlinks(self); err == nil {
				self = resolved
			}
			if err := replaceBinary(newCtl, self); err != nil {
				return fmt.Errorf("app updated, but replacing rookctl at %s failed: %v", self, err)
			}
			linkCLI(filepath.Dir(self))
		}
	}
	return nil
}

// linkCLI points `rook` and `re` at the app binary, in the same dir the
// running rookctl lives in.
//
// This is the UPGRADE path, and it is not the same as a fresh install:
// install.sh writes these links itself, but someone who has been running
// rook since before the app was rewritten reaches the new version through
// `rookctl update` alone. Without this they would get the new app with no
// `rook` on PATH at all, and `re` still meaning "rookctl edit" — pointing
// at an editor that no longer exists.
//
// Both are FORCED, not created-if-missing: `re` already exists on every
// such machine, aimed at the old meaning, and leaving it alone is the bug
// rather than the safe choice. Best-effort throughout — a symlink failure
// cannot be worth failing an otherwise-complete update over.
func linkCLI(bindir string) {
	appBin := filepath.Join(appPath, "Contents", "MacOS", "rook")
	if !fileExists(appBin) {
		return
	}
	for _, name := range []string{"rook", "re"} {
		p := filepath.Join(bindir, name)
		// Only ever replace a symlink or a missing entry. A real file
		// there is someone else's `re`, and clobbering it is not ours
		// to do.
		if fi, err := os.Lstat(p); err == nil && fi.Mode()&os.ModeSymlink == 0 {
			continue
		}
		os.Remove(p)
		os.Symlink(appBin, p)
	}
}

func download(url, dst string) error {
	resp, err := httpClient.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GET %s: %s", url, resp.Status)
	}
	f, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(f, resp.Body)
	return err
}

func fetch(url string) ([]byte, error) {
	resp, err := httpClient.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: %s", url, resp.Status)
	}
	return io.ReadAll(resp.Body)
}

// findChecksum reads shasum output ("<hex>  <name>" per line).
func findChecksum(sums []byte, name string) (string, bool) {
	for line := range strings.SplitSeq(string(sums), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[1] == name {
			return fields[0], true
		}
	}
	return "", false
}

func fileSHA256(path string) (string, error) {
	f, err := os.Open(path)
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

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// replaceBinary copies src next to dst then renames over it — atomic on the
// same volume, and legal even while dst is the running executable.
func replaceBinary(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	staged := dst + ".new"
	out, err := os.OpenFile(staged, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(staged)
		return err
	}
	if err := out.Close(); err != nil {
		os.Remove(staged)
		return err
	}
	return os.Rename(staged, dst)
}
