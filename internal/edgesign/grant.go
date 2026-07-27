// The grant half of the authenticity layer: §12.2's approval grant as
// a signed document, and the device-side checklist that decides whether
// a command may spend it. Cloud and device both use THIS file, so "what
// exactly does a grant promise" has a single answer — the same stance
// as the envelope signatures above.
package edgesign

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"time"

	edgev1 "github.com/incantery/rook/gen/rook/edge/v1"
)

// GrantDoc is the §12.2 approval grant: a human's yes as a signed,
// exact-action-bound document. The cloud mints it when an approval is
// granted; the device verifies signature and binding before executing.
//
// The signature is over json.Marshal of the doc with ServerSignature
// empty — this struct's field order IS the canonical encoding, so a
// field added here without a schema bump breaks verification on every
// older device. That failure is closed, which is the right direction,
// but it is a protocol change and must be treated as one.
type GrantDoc struct {
	Schema          string   `json:"schema"` // rook.approval_grant.v1
	GrantID         string   `json:"grantId"`
	RequestID       string   `json:"requestId"`
	ActorID         string   `json:"actorId"`
	ActionType      string   `json:"actionType"`
	ActionDigest    string   `json:"actionDigest"` // sha256:<hex>, see ActionDigest
	ResourceScope   []string `json:"resourceScope"`
	WorkflowRunID   string   `json:"workflowRunId"`
	IssuedAt        string   `json:"issuedAt"`
	ExpiresAt       string   `json:"expiresAt"`
	SingleUse       bool     `json:"singleUse"`
	ServerSignature string   `json:"serverSignature,omitempty"` // ed25519 over the doc with this field empty
}

// GrantSchema names the one grant shape this package signs.
const GrantSchema = "rook.approval_grant.v1"

// ActionDigest is the exact-action fingerprint an approval binds to:
// the ledger payload bytes plus the addressing that scopes them. Same
// request, same digest — and any mutation between the human's yes and
// the mint changes it, which is the whole point. The cloud computes it
// at request time; the device recomputes it from the command envelope's
// ledger_payload before spending a grant.
func ActionDigest(workflowRunID, deviceID, resourceType, resourceID string, ledgerPayload []byte) string {
	sum := sha256.Sum256(fmt.Appendf(nil, "%s|%s|%s|%s|%s",
		workflowRunID, deviceID, resourceType, resourceID, ledgerPayload))
	return hex.EncodeToString(sum[:])
}

// SignGrant fills the doc's ServerSignature: ed25519 over the canonical
// JSON with the signature field empty.
func SignGrant(priv ed25519.PrivateKey, doc *GrantDoc) error {
	doc.ServerSignature = ""
	unsigned, err := json.Marshal(doc)
	if err != nil {
		return err
	}
	doc.ServerSignature = base64.StdEncoding.EncodeToString(ed25519.Sign(priv, unsigned))
	return nil
}

// VerifyGrantSignature checks the doc's signature against the cloud's
// public key, by reconstructing the unsigned canonical JSON.
func VerifyGrantSignature(pub ed25519.PublicKey, doc GrantDoc) bool {
	sig, err := base64.StdEncoding.DecodeString(doc.ServerSignature)
	if err != nil || len(sig) == 0 {
		return false
	}
	doc.ServerSignature = ""
	unsigned, err := json.Marshal(doc)
	if err != nil {
		return false
	}
	return ed25519.Verify(pub, unsigned, sig)
}

// VerifyCommandGrant is the device's §12.2 checklist, run before any
// command that carries a grant is executed. It returns the parsed grant
// on success; any error is a refusal — the device reports "rejected"
// with the reason and performs no effect. cloudKey may be nil when the
// cloud registered no signing key, in which case the signature check is
// skipped with the same stated degradation as unsigned envelopes; every
// structural check still applies.
//
// Single-use enforcement is deliberately absent here: whether this
// grant was already spent is a fact only the device's journal knows,
// and the journal-owning caller checks it alongside this function.
func VerifyCommandGrant(cloudKey ed25519.PublicKey, cmd *edgev1.EdgeCommand, now time.Time) (GrantDoc, error) {
	if len(cmd.ApprovalGrant) == 0 {
		return GrantDoc{}, errors.New("command names a grant but carries no grant document")
	}
	payload, err := VerifiedLedgerPayload(cmd)
	if err != nil {
		return GrantDoc{}, err
	}
	var doc GrantDoc
	if err := json.Unmarshal(cmd.ApprovalGrant, &doc); err != nil {
		return GrantDoc{}, fmt.Errorf("grant document is not JSON: %w", err)
	}
	if doc.Schema != GrantSchema {
		return GrantDoc{}, fmt.Errorf("grant schema %q, want %q", doc.Schema, GrantSchema)
	}
	if doc.GrantID != cmd.ApprovalGrantId {
		return GrantDoc{}, fmt.Errorf("grant %s does not match the command's named grant %s", doc.GrantID, cmd.ApprovalGrantId)
	}
	if cloudKey != nil && !VerifyGrantSignature(cloudKey, doc) {
		return GrantDoc{}, errors.New("grant signature does not verify")
	}
	expires, err := time.Parse(time.RFC3339, doc.ExpiresAt)
	if err != nil {
		return GrantDoc{}, fmt.Errorf("grant expiry %q is not RFC3339", doc.ExpiresAt)
	}
	if now.After(expires) {
		return GrantDoc{}, fmt.Errorf("grant expired %s", doc.ExpiresAt)
	}
	if doc.WorkflowRunID != cmd.WorkflowRunId {
		return GrantDoc{}, fmt.Errorf("grant is for run %s, command is for run %s", doc.WorkflowRunID, cmd.WorkflowRunId)
	}
	for _, scope := range []string{"device:" + cmd.DeviceId, cmd.ResourceType + ":" + cmd.ResourceId} {
		if !slices.Contains(doc.ResourceScope, scope) {
			return GrantDoc{}, fmt.Errorf("grant scope %v does not cover %s", doc.ResourceScope, scope)
		}
	}
	digest := "sha256:" + ActionDigest(cmd.WorkflowRunId, cmd.DeviceId, cmd.ResourceType, cmd.ResourceId, payload)
	if doc.ActionDigest != digest {
		return GrantDoc{}, errors.New("grant action digest does not match this command")
	}
	return doc, nil
}

// VerifiedLedgerPayload returns the command's ledger payload bytes after
// proving they are the ones the cloud hashed: sha256(ledger_payload)
// must equal payload_digest, which the envelope signature covers. Every
// device-side check that reads the payload starts here — unverified
// bytes are not payload, they are noise.
func VerifiedLedgerPayload(cmd *edgev1.EdgeCommand) ([]byte, error) {
	if len(cmd.LedgerPayload) == 0 {
		return nil, errors.New("command carries no ledger payload")
	}
	sum := sha256.Sum256(cmd.LedgerPayload)
	if !slices.Equal(sum[:], cmd.PayloadDigest) {
		return nil, errors.New("ledger payload does not match payload digest")
	}
	return cmd.LedgerPayload, nil
}
