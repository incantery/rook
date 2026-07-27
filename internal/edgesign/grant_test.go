package edgesign

import (
	"crypto/sha256"
	"encoding/json"
	"strings"
	"testing"
	"time"

	edgev1 "github.com/incantery/rook/gen/rook/edge/v1"
)

func sampleGrant(t *testing.T, cmd *edgev1.EdgeCommand) GrantDoc {
	t.Helper()
	return GrantDoc{
		Schema: GrantSchema, GrantID: "apr_1", RequestID: "apr_1",
		ActorID: "usr_1", ActionType: "cleanup_worktree",
		ActionDigest: "sha256:" + ActionDigest(cmd.WorkflowRunId, cmd.DeviceId,
			cmd.ResourceType, cmd.ResourceId, cmd.LedgerPayload),
		ResourceScope: []string{"device:" + cmd.DeviceId, cmd.ResourceType + ":" + cmd.ResourceId},
		WorkflowRunID: cmd.WorkflowRunId,
		IssuedAt:      time.Now().UTC().Format(time.RFC3339),
		ExpiresAt:     time.Now().Add(time.Hour).UTC().Format(time.RFC3339),
		SingleUse:     true,
	}
}

// grantCommand is a command whose ledger payload and digest agree —
// the envelope shape the cloud actually ships.
func grantCommand(t *testing.T) *edgev1.EdgeCommand {
	t.Helper()
	cmd := sampleCommand(t)
	cmd.LedgerPayload = []byte(`{"op":"cleanup_worktree","step":"cleanup"}`)
	cmd.PayloadDigest = digestOf(cmd.LedgerPayload)
	cmd.ApprovalGrantId = "apr_1"
	return cmd
}

func digestOf(b []byte) []byte {
	sum := sha256.Sum256(b)
	return sum[:]
}

// The grant signature binds every field: a signed doc verifies, and any
// mutation kills it.
func TestGrantSignatureBindsTheDocument(t *testing.T) {
	pub, priv, err := NewKey()
	if err != nil {
		t.Fatal(err)
	}
	cmd := grantCommand(t)
	doc := sampleGrant(t, cmd)
	if VerifyGrantSignature(pub, doc) {
		t.Fatal("unsigned grant must not verify")
	}
	if err := SignGrant(priv, &doc); err != nil {
		t.Fatal(err)
	}
	if !VerifyGrantSignature(pub, doc) {
		t.Fatal("signed grant must verify")
	}

	tampers := map[string]func(*GrantDoc){
		"actor":  func(d *GrantDoc) { d.ActorID = "usr_EVIL" },
		"digest": func(d *GrantDoc) { d.ActionDigest = "sha256:" + strings.Repeat("0", 64) },
		"expiry": func(d *GrantDoc) { d.ExpiresAt = time.Now().Add(240 * time.Hour).UTC().Format(time.RFC3339) },
		"scope":  func(d *GrantDoc) { d.ResourceScope = append(d.ResourceScope, "device:dev_EVIL") },
		"single": func(d *GrantDoc) { d.SingleUse = false },
	}
	for name, tamper := range tampers {
		fresh := sampleGrant(t, cmd)
		if err := SignGrant(priv, &fresh); err != nil {
			t.Fatal(err)
		}
		tamper(&fresh)
		if VerifyGrantSignature(pub, fresh) {
			t.Errorf("tampered %s must not verify", name)
		}
	}
}

// The device's checklist: the happy path passes, and each §12.2 refusal
// fires with the failing fact named.
func TestVerifyCommandGrantChecklist(t *testing.T) {
	pub, priv, err := NewKey()
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	sign := func(cmd *edgev1.EdgeCommand, doc GrantDoc) *edgev1.EdgeCommand {
		t.Helper()
		if err := SignGrant(priv, &doc); err != nil {
			t.Fatal(err)
		}
		raw, err := json.Marshal(doc)
		if err != nil {
			t.Fatal(err)
		}
		cmd.ApprovalGrant = raw
		return cmd
	}

	good := sign(grantCommand(t), sampleGrant(t, grantCommand(t)))
	if _, err := VerifyCommandGrant(pub, good, now); err != nil {
		t.Fatalf("a well-formed grant must pass: %v", err)
	}
	// Without a cloud key the structural checks still hold.
	if _, err := VerifyCommandGrant(nil, good, now); err != nil {
		t.Fatalf("keyless verification must still pass structure: %v", err)
	}

	refusals := map[string]func() *edgev1.EdgeCommand{
		"no document": func() *edgev1.EdgeCommand {
			c := grantCommand(t)
			c.ApprovalGrant = nil
			return c
		},
		"tampered ledger payload": func() *edgev1.EdgeCommand {
			c := sign(grantCommand(t), sampleGrant(t, grantCommand(t)))
			c.LedgerPayload = []byte(`{"op":"cleanup_worktree","step":"cleanup","force":"true"}`)
			return c
		},
		"wrong schema": func() *edgev1.EdgeCommand {
			c := grantCommand(t)
			d := sampleGrant(t, c)
			d.Schema = "rook.approval_grant.v2"
			return sign(c, d)
		},
		"grant id mismatch": func() *edgev1.EdgeCommand {
			c := grantCommand(t)
			d := sampleGrant(t, c)
			d.GrantID = "apr_OTHER"
			return sign(c, d)
		},
		"tampered signature": func() *edgev1.EdgeCommand {
			c := sign(grantCommand(t), sampleGrant(t, grantCommand(t)))
			var d GrantDoc
			_ = json.Unmarshal(c.ApprovalGrant, &d)
			d.ActorID = "usr_EVIL"
			c.ApprovalGrant, _ = json.Marshal(d)
			return c
		},
		"expired": func() *edgev1.EdgeCommand {
			c := grantCommand(t)
			d := sampleGrant(t, c)
			d.ExpiresAt = now.Add(-time.Minute).UTC().Format(time.RFC3339)
			return sign(c, d)
		},
		"wrong run": func() *edgev1.EdgeCommand {
			c := grantCommand(t)
			d := sampleGrant(t, c)
			d.WorkflowRunID = "wfr_OTHER"
			return sign(c, d)
		},
		"missing scope": func() *edgev1.EdgeCommand {
			c := grantCommand(t)
			d := sampleGrant(t, c)
			d.ResourceScope = []string{"device:" + c.DeviceId}
			return sign(c, d)
		},
		"digest for another action": func() *edgev1.EdgeCommand {
			c := grantCommand(t)
			d := sampleGrant(t, c)
			d.ActionDigest = "sha256:" + ActionDigest(c.WorkflowRunId, c.DeviceId,
				c.ResourceType, c.ResourceId, []byte(`{"op":"create_worktree"}`))
			return sign(c, d)
		},
	}
	for name, build := range refusals {
		if _, err := VerifyCommandGrant(pub, build(), now); err == nil {
			t.Errorf("%s must be refused", name)
		}
	}
}

// A grant a device cannot re-verify structurally is refused even when
// the signature would check out — the binding is not optional.
func TestVerifyCommandGrantNeedsTheLedgerPayload(t *testing.T) {
	pub, priv, err := NewKey()
	if err != nil {
		t.Fatal(err)
	}
	cmd := grantCommand(t)
	doc := sampleGrant(t, cmd)
	if err := SignGrant(priv, &doc); err != nil {
		t.Fatal(err)
	}
	cmd.ApprovalGrant, _ = json.Marshal(doc)
	cmd.LedgerPayload = nil
	if _, err := VerifyCommandGrant(pub, cmd, time.Now()); err == nil {
		t.Fatal("a command without ledger payload cannot spend a grant")
	}
}
