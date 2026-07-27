// Package edgesign is the authenticity layer of the edge protocol:
// Ed25519 signatures over canonical encodings of the two envelope
// shapes, plus the approval-grant document and its checklist.
//
// This is a deliberate COPY of rook-cloud's internal/edgesign — the
// repos share no module, so the canonical encodings exist twice, and
// testdata/golden.json (regenerated ONLY in rook-cloud, copied here
// verbatim) is the treaty that keeps the copies byte-identical; see
// golden_test.go. Edit the origin first, re-copy, and never let the
// two diverge on purpose.
//
// TLS is necessary but insufficient here: commands and events are
// queued, persisted, and replayed outside any one connection, so the
// envelope itself must carry proof of who minted it — a command's
// signature binds it to device, task, resource, payload, expiry, and
// fencing era, and holds no matter how many hops or restarts it
// survives on the way.
//
// The canonical encoding is deliberately not proto marshaling: proto
// bytes are not canonical across library versions, and a signature that
// breaks when a dependency upgrades is a signature nobody can trust.
// Instead each field is length-prefixed and concatenated in tag order
// under a versioned domain label, so the encoding can only change by
// changing the label.
package edgesign

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"fmt"

	edgev1 "github.com/incantery/rook/gen/rook/edge/v1"
)

// Domain labels version the canonical encodings. A change to what is
// signed is a new label, never a silent reinterpretation of the old one.
const (
	commandDomain = "rook-edge-command/v1"
	eventDomain   = "rook-edge-event/v1"
)

// NewKey generates an Ed25519 keypair.
func NewKey() (ed25519.PublicKey, ed25519.PrivateKey, error) {
	return ed25519.GenerateKey(rand.Reader)
}

// EncodeSeed and DecodeSeed move a private key through configuration as
// the base64 of its 32-byte seed — small enough for an env var, and the
// public half is always derivable from it.
func EncodeSeed(priv ed25519.PrivateKey) string {
	return base64.StdEncoding.EncodeToString(priv.Seed())
}

func DecodeSeed(encoded string) (ed25519.PrivateKey, error) {
	seed, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, fmt.Errorf("edgesign: seed is not base64: %w", err)
	}
	if len(seed) != ed25519.SeedSize {
		return nil, fmt.Errorf("edgesign: seed is %d bytes, want %d", len(seed), ed25519.SeedSize)
	}
	return ed25519.NewKeyFromSeed(seed), nil
}

// SignCommand fills the command's cloud_signature.
func SignCommand(priv ed25519.PrivateKey, cmd *edgev1.EdgeCommand) {
	cmd.CloudSignature = ed25519.Sign(priv, commandBytes(cmd))
}

// VerifyCommand checks the command against the cloud's public key.
func VerifyCommand(pub ed25519.PublicKey, cmd *edgev1.EdgeCommand) bool {
	return len(cmd.CloudSignature) > 0 && ed25519.Verify(pub, commandBytes(cmd), cmd.CloudSignature)
}

// SignEvent fills the event's device_signature.
func SignEvent(priv ed25519.PrivateKey, ev *edgev1.EdgeEvent) {
	ev.DeviceSignature = ed25519.Sign(priv, eventBytes(ev))
}

// VerifyEvent checks the event against the device's registered key.
func VerifyEvent(pub ed25519.PublicKey, ev *edgev1.EdgeEvent) bool {
	return len(ev.DeviceSignature) > 0 && ed25519.Verify(pub, eventBytes(ev), ev.DeviceSignature)
}

// commandBytes binds everything §13.5 requires: device, task, resource,
// payload (by digest of the exact bytes on the wire AND the ledger's
// recorded digest), expiry, state version, and fencing token. The
// signature field itself is excluded, necessarily.
func commandBytes(cmd *edgev1.EdgeCommand) []byte {
	var payload, payloadType []byte
	if cmd.Payload != nil {
		sum := sha256.Sum256(cmd.Payload.Value)
		payload = sum[:]
		payloadType = []byte(cmd.Payload.TypeUrl)
	}
	var expires int64
	if cmd.ExpiresAt != nil {
		expires = cmd.ExpiresAt.AsTime().UnixNano()
	}
	return canonical(commandDomain,
		[]byte(cmd.ProtocolVersion),
		[]byte(cmd.CommandId),
		[]byte(cmd.LogicalOperationId),
		u64(uint64(cmd.Attempt)),
		[]byte(cmd.DeviceId),
		[]byte(cmd.TaskId),
		[]byte(cmd.WorkflowRunId),
		[]byte(cmd.ResourceType),
		[]byte(cmd.ResourceId),
		u64(cmd.FencingToken),
		u64(cmd.ExpectedAggregateVersion),
		u64(uint64(expires)),
		[]byte(cmd.IdempotencyKey),
		[]byte(cmd.ApprovalGrantId),
		[]byte(cmd.PolicyContextHash),
		payloadType,
		payload,
		cmd.PayloadDigest,
	)
}

// eventBytes binds the event to its device, sequence, cause, type, and
// payload — everything the Cloud records from it.
func eventBytes(ev *edgev1.EdgeEvent) []byte {
	var payload, payloadType []byte
	if ev.Payload != nil {
		sum := sha256.Sum256(ev.Payload.Value)
		payload = sum[:]
		payloadType = []byte(ev.Payload.TypeUrl)
	}
	var occurred int64
	if ev.OccurredAt != nil {
		occurred = ev.OccurredAt.AsTime().UnixNano()
	}
	return canonical(eventDomain,
		[]byte(ev.EventId),
		[]byte(ev.DeviceId),
		u64(ev.DeviceSequence),
		[]byte(ev.CommandId),
		[]byte(ev.Type),
		u64(uint64(occurred)),
		u64(ev.FencingToken),
		payloadType,
		payload,
		ev.PayloadDigest,
	)
}

// canonical is the whole encoding: domain label, then each field
// length-prefixed, in order. Length prefixes make the concatenation
// unambiguous — no field can impersonate its neighbor's suffix.
func canonical(domain string, fields ...[]byte) []byte {
	out := make([]byte, 0, 64+len(fields)*16)
	out = append(out, u64(uint64(len(domain)))...)
	out = append(out, domain...)
	for _, f := range fields {
		out = append(out, u64(uint64(len(f)))...)
		out = append(out, f...)
	}
	return out
}

func u64(v uint64) []byte {
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], v)
	return b[:]
}
