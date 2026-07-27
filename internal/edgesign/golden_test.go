package edgesign

// The cross-repo drift tripwire. This package is a deliberate COPY of
// rook-cloud's internal/edgesign — the repos share no module, so the
// canonical encodings exist twice. testdata/golden.json is the treaty:
// fixed inputs and the exact canonical bytes, signatures, and digests
// both implementations must produce. rook-cloud regenerates the file
// (its golden test's -update flag) and it is copied here VERBATIM;
// there is intentionally no update path on this side — if this test
// fails, either re-copy the treaty (the protocol moved) or fix the
// drift here (this copy moved). Never regenerate it from this copy.

import (
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
	"time"

	"google.golang.org/protobuf/types/known/anypb"
	"google.golang.org/protobuf/types/known/timestamppb"

	edgev1 "github.com/incantery/rook/gen/rook/edge/v1"
)

// goldenFile mirrors the JSON layout. Every byte field is hex; seeds
// and grant signatures are base64 because that is their wire form.
type goldenFile struct {
	CloudSeed  string `json:"cloudSeed"`
	DeviceSeed string `json:"deviceSeed"`
	Command    struct {
		ProtocolVersion          string `json:"protocolVersion"`
		CommandID                string `json:"commandId"`
		LogicalOperationID       string `json:"logicalOperationId"`
		Attempt                  uint32 `json:"attempt"`
		DeviceID                 string `json:"deviceId"`
		TaskID                   string `json:"taskId"`
		WorkflowRunID            string `json:"workflowRunId"`
		ResourceType             string `json:"resourceType"`
		ResourceID               string `json:"resourceId"`
		FencingToken             uint64 `json:"fencingToken"`
		ExpectedAggregateVersion uint64 `json:"expectedAggregateVersion"`
		ExpiresAt                string `json:"expiresAt"` // RFC3339
		IdempotencyKey           string `json:"idempotencyKey"`
		ApprovalGrantID          string `json:"approvalGrantId"`
		PolicyContextHash        string `json:"policyContextHash"`
		PayloadType              string `json:"payloadType"`
		PayloadValueHex          string `json:"payloadValueHex"`
		PayloadDigestHex         string `json:"payloadDigestHex"`
		CanonicalHex             string `json:"canonicalHex"`
		SignatureHex             string `json:"signatureHex"`
	} `json:"command"`
	Event struct {
		EventID          string `json:"eventId"`
		DeviceID         string `json:"deviceId"`
		DeviceSequence   uint64 `json:"deviceSequence"`
		CommandID        string `json:"commandId"`
		Type             string `json:"type"`
		OccurredAt       string `json:"occurredAt"` // RFC3339
		FencingToken     uint64 `json:"fencingToken"`
		PayloadType      string `json:"payloadType"`
		PayloadValueHex  string `json:"payloadValueHex"`
		PayloadDigestHex string `json:"payloadDigestHex"`
		CanonicalHex     string `json:"canonicalHex"`
		SignatureHex     string `json:"signatureHex"`
	} `json:"event"`
	Grant struct {
		Doc          GrantDoc `json:"doc"` // ServerSignature filled = the expected signature
		UnsignedJSON string   `json:"unsignedJson"`
	} `json:"grant"`
	ActionDigestVector struct {
		WorkflowRunID string `json:"workflowRunId"`
		DeviceID      string `json:"deviceId"`
		ResourceType  string `json:"resourceType"`
		ResourceID    string `json:"resourceId"`
		LedgerPayload string `json:"ledgerPayload"`
		Digest        string `json:"digest"`
	} `json:"actionDigest"`
}

const goldenPath = "testdata/golden.json"

func TestGoldenVectors(t *testing.T) {
	raw, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatalf("read %s (copy it from rook-cloud's internal/edgesign/testdata): %v", goldenPath, err)
	}
	var g goldenFile
	if err := json.Unmarshal(raw, &g); err != nil {
		t.Fatal(err)
	}
	cloudKey, err := DecodeSeed(g.CloudSeed)
	if err != nil {
		t.Fatal(err)
	}
	deviceKey, err := DecodeSeed(g.DeviceSeed)
	if err != nil {
		t.Fatal(err)
	}

	// Command: rebuild the envelope purely from the fixture, then the
	// canonical bytes and signature must match to the byte.
	c := &g.Command
	cmdExpires, err := time.Parse(time.RFC3339, c.ExpiresAt)
	if err != nil {
		t.Fatal(err)
	}
	cmd := &edgev1.EdgeCommand{
		ProtocolVersion: c.ProtocolVersion, CommandId: c.CommandID,
		LogicalOperationId: c.LogicalOperationID, Attempt: c.Attempt,
		DeviceId: c.DeviceID, TaskId: c.TaskID, WorkflowRunId: c.WorkflowRunID,
		ResourceType: c.ResourceType, ResourceId: c.ResourceID,
		FencingToken: c.FencingToken, ExpectedAggregateVersion: c.ExpectedAggregateVersion,
		ExpiresAt: timestamppb.New(cmdExpires), IdempotencyKey: c.IdempotencyKey,
		ApprovalGrantId: c.ApprovalGrantID, PolicyContextHash: c.PolicyContextHash,
		Payload:       &anypb.Any{TypeUrl: c.PayloadType, Value: unhex(t, c.PayloadValueHex)},
		PayloadDigest: unhex(t, c.PayloadDigestHex),
	}
	if got := hex.EncodeToString(commandBytes(cmd)); got != c.CanonicalHex {
		t.Errorf("command canonical bytes drifted from the treaty:\n got %s\nwant %s", got, c.CanonicalHex)
	}
	SignCommand(cloudKey, cmd)
	if got := hex.EncodeToString(cmd.CloudSignature); got != c.SignatureHex {
		t.Errorf("command signature drifted: got %s want %s", got, c.SignatureHex)
	}

	// Event, same discipline, device key.
	e := &g.Event
	evOccurred, err := time.Parse(time.RFC3339, e.OccurredAt)
	if err != nil {
		t.Fatal(err)
	}
	ev := &edgev1.EdgeEvent{
		EventId: e.EventID, DeviceId: e.DeviceID, DeviceSequence: e.DeviceSequence,
		CommandId: e.CommandID, Type: e.Type, OccurredAt: timestamppb.New(evOccurred),
		FencingToken:  e.FencingToken,
		Payload:       &anypb.Any{TypeUrl: e.PayloadType, Value: unhex(t, e.PayloadValueHex)},
		PayloadDigest: unhex(t, e.PayloadDigestHex),
	}
	if got := hex.EncodeToString(eventBytes(ev)); got != e.CanonicalHex {
		t.Errorf("event canonical bytes drifted from the treaty:\n got %s\nwant %s", got, e.CanonicalHex)
	}
	SignEvent(deviceKey, ev)
	if got := hex.EncodeToString(ev.DeviceSignature); got != e.SignatureHex {
		t.Errorf("event signature drifted: got %s want %s", got, e.SignatureHex)
	}

	// Grant: unsigned JSON and signature both pinned.
	doc := g.Grant.Doc
	wantSig := doc.ServerSignature
	if err := SignGrant(cloudKey, &doc); err != nil {
		t.Fatal(err)
	}
	if doc.ServerSignature != wantSig {
		t.Errorf("grant signature drifted: got %s want %s", doc.ServerSignature, wantSig)
	}
	unsigned := doc
	unsigned.ServerSignature = ""
	if raw, _ := json.Marshal(unsigned); string(raw) != g.Grant.UnsignedJSON {
		t.Errorf("grant canonical JSON drifted:\n got %s\nwant %s", raw, g.Grant.UnsignedJSON)
	}
	if !VerifyGrantSignature(cloudKey.Public().(ed25519.PublicKey), doc) {
		t.Error("golden grant must verify")
	}

	// The action digest formula.
	a := &g.ActionDigestVector
	if got := ActionDigest(a.WorkflowRunID, a.DeviceID, a.ResourceType, a.ResourceID, []byte(a.LedgerPayload)); got != a.Digest {
		t.Errorf("action digest drifted: got %s want %s", got, a.Digest)
	}
}

func unhex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
