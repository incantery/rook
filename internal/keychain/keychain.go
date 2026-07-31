// Package keychain stores rook's secrets in the macOS login keychain.
// Everything goes through /usr/bin/security on purpose: keychain ACLs are
// per-binary, and rook-agent is rebuilt constantly (`make agent`) — linking
// Security.framework would mean a permission prompt on every rebuild. The
// Apple-signed security tool is the stable identity that gets the ACL, so
// writes and reads never prompt.
package keychain

import (
	"errors"
	"fmt"
	"os/exec"
	"runtime"
	"strings"
)

// The items rook owns: the drafter's OpenAI key and the issue queue's
// Jira API token (`security find-generic-password -s rook -a <account>`).
const (
	Service       = "rook"
	OpenAIAccount = "openai"
	// LinearAccount is the Linear API key. rook WRITES it and never reads
	// it — rook-provider-linear is the only thing that fetches it back,
	// which is what keeps the credential out of rook's address space.
	LinearAccount = "linear"
	// RelayAccount is the bearer token for the configured rook-server
	// (relay-url in config). A secret that reaches a network service has
	// no business sitting in a hand-edited file — and even less once
	// config starts syncing between machines.
	RelayAccount = "relay"
	// CloudAccount is the machine token rook-cloud mints when you add a
	// machine on the dashboard ([cloud] url in config). One token per
	// machine by design — revoking one machine never touches the others.
	CloudAccount = "cloud"
)

var ErrUnsupported = errors.New("keychain: only supported on macOS")

// Get returns the secret, or "" (no error) when the item doesn't exist or
// the platform has no keychain — callers fall back to the key file.
func Get(service, account string) (string, error) {
	if runtime.GOOS != "darwin" {
		return "", nil
	}
	out, err := exec.Command("security", "find-generic-password",
		"-s", service, "-a", account, "-w").Output()
	if err != nil {
		// errSecItemNotFound exits 44; a locked/absent keychain also
		// lands here — either way there's no secret to use
		return "", nil
	}
	return strings.TrimSpace(string(out)), nil
}

// quote wraps s for the security tool's interactive tokenizer, which
// honors double quotes with backslash escapes.
func quote(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	return `"` + s + `"`
}

// Set upserts the secret. The command goes over stdin (`security -i`), not
// argv — secrets on argv are visible to every process via ps.
func Set(service, account, secret string) error {
	if runtime.GOOS != "darwin" {
		return ErrUnsupported
	}
	if strings.ContainsAny(secret, "\n\r") {
		return errors.New("keychain: secret must be a single line")
	}
	cmd := exec.Command("security", "-i")
	cmd.Stdin = strings.NewReader(fmt.Sprintf("add-generic-password -U -s %s -a %s -w %s\n",
		quote(service), quote(account), quote(secret)))
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("keychain: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// Delete removes the item; a missing item is success.
func Delete(service, account string) error {
	if runtime.GOOS != "darwin" {
		return nil
	}
	out, err := exec.Command("security", "delete-generic-password",
		"-s", service, "-a", account).CombinedOutput()
	if err != nil && !strings.Contains(string(out), "could not be found") {
		return fmt.Errorf("keychain: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}
