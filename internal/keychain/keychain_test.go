package keychain

import (
	"os/exec"
	"runtime"
	"testing"
)

// Round-trips the real login keychain under a throwaway service name —
// this is deliberately not mocked: the escaping contract with the
// security tool's tokenizer is the thing worth testing.
func TestRoundTrip(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("keychain is darwin-only")
	}
	if _, err := exec.LookPath("security"); err != nil {
		t.Skip("no security tool")
	}
	const svc, acct = "rook-test", "openai"
	secret := "sk-tr\"icky\\va lue_with_$ and `backtick` 09"
	t.Cleanup(func() { Delete(svc, acct) })

	if err := Set(svc, acct, secret); err != nil {
		t.Fatalf("set: %v", err)
	}
	if err := Set(svc, acct, secret); err != nil {
		t.Fatalf("set must upsert, not fail on existing: %v", err)
	}
	got, err := Get(svc, acct)
	if err != nil || got != secret {
		t.Fatalf("get = %q, %v; want the secret back byte-exact", got, err)
	}
	if err := Delete(svc, acct); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if got, _ := Get(svc, acct); got != "" {
		t.Fatalf("still present after delete: %q", got)
	}
	if err := Delete(svc, acct); err != nil {
		t.Fatalf("deleting a missing item must be a no-op: %v", err)
	}
	if err := Set(svc, acct, "two\nlines"); err == nil {
		Delete(svc, acct)
		t.Fatal("multiline secrets must be refused")
	}
}
