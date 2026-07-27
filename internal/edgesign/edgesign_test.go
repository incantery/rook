package edgesign

import (
	"testing"
	"time"

	"google.golang.org/protobuf/types/known/anypb"
	"google.golang.org/protobuf/types/known/timestamppb"

	edgev1 "github.com/incantery/rook/gen/rook/edge/v1"
)

func sampleCommand(t *testing.T) *edgev1.EdgeCommand {
	t.Helper()
	payload, err := anypb.New(&edgev1.CreateWorktree{TaskId: "task_1", WorkflowRunId: "wfr_1"})
	if err != nil {
		t.Fatal(err)
	}
	return &edgev1.EdgeCommand{
		ProtocolVersion: "rook-edge/1",
		CommandId:       "cmd_wfr_1_work_1",
		DeviceId:        "dev_1",
		TaskId:          "task_1",
		WorkflowRunId:   "wfr_1",
		ResourceType:    "worktree",
		ResourceId:      "worktree_wfr_1",
		FencingToken:    3,
		ExpiresAt:       timestamppb.New(time.Now().Add(time.Hour)),
		IdempotencyKey:  "cmd_wfr_1_work_1",
		Payload:         payload,
		PayloadDigest:   []byte("0123456789abcdef0123456789abcdef"),
	}
}

func sampleEvent() *edgev1.EdgeEvent {
	payload, _ := anypb.New(&edgev1.CommandResult{CommandId: "cmd_1", Status: "succeeded"})
	return &edgev1.EdgeEvent{
		EventId:        "devevt_cmd_1_succeeded",
		DeviceId:       "dev_1",
		DeviceSequence: 7,
		CommandId:      "cmd_1",
		Type:           "com.rook.edge.command_result.v1",
		OccurredAt:     timestamppb.Now(),
		Payload:        payload,
	}
}

// Signatures verify, and every signed field is load-bearing: changing
// any of them — including the payload bytes inside the Any — kills the
// signature.
func TestCommandSignatureBindsTheEnvelope(t *testing.T) {
	pub, priv, err := NewKey()
	if err != nil {
		t.Fatal(err)
	}
	cmd := sampleCommand(t)
	if VerifyCommand(pub, cmd) {
		t.Fatal("unsigned command must not verify")
	}
	SignCommand(priv, cmd)
	if !VerifyCommand(pub, cmd) {
		t.Fatal("signed command must verify")
	}

	tampers := map[string]func(*edgev1.EdgeCommand){
		"device":  func(c *edgev1.EdgeCommand) { c.DeviceId = "dev_EVIL" },
		"fence":   func(c *edgev1.EdgeCommand) { c.FencingToken++ },
		"expiry":  func(c *edgev1.EdgeCommand) { c.ExpiresAt = timestamppb.New(time.Now().Add(240 * time.Hour)) },
		"digest":  func(c *edgev1.EdgeCommand) { c.PayloadDigest[0] ^= 1 },
		"payload": func(c *edgev1.EdgeCommand) { c.Payload.Value[0] ^= 1 },
		"type":    func(c *edgev1.EdgeCommand) { c.Payload.TypeUrl = "type.googleapis.com/rook.edge.v1.RunVerification" },
	}
	for name, tamper := range tampers {
		fresh := sampleCommand(t)
		SignCommand(priv, fresh)
		tamper(fresh)
		if VerifyCommand(pub, fresh) {
			t.Fatalf("tampered %s must not verify", name)
		}
	}

	// A different key does not vouch for it either.
	otherPub, _, _ := NewKey()
	if VerifyCommand(otherPub, cmd) {
		t.Fatal("wrong key must not verify")
	}
}

func TestEventSignatureBindsTheEnvelope(t *testing.T) {
	pub, priv, err := NewKey()
	if err != nil {
		t.Fatal(err)
	}
	ev := sampleEvent()
	if VerifyEvent(pub, ev) {
		t.Fatal("unsigned event must not verify")
	}
	SignEvent(priv, ev)
	if !VerifyEvent(pub, ev) {
		t.Fatal("signed event must verify")
	}

	tampers := map[string]func(*edgev1.EdgeEvent){
		"sequence": func(e *edgev1.EdgeEvent) { e.DeviceSequence++ },
		"device":   func(e *edgev1.EdgeEvent) { e.DeviceId = "dev_EVIL" },
		"payload":  func(e *edgev1.EdgeEvent) { e.Payload.Value[0] ^= 1 },
		"type":     func(e *edgev1.EdgeEvent) { e.Type = "com.rook.edge.mystery.v1" },
	}
	for name, tamper := range tampers {
		fresh := sampleEvent()
		SignEvent(priv, fresh)
		tamper(fresh)
		if VerifyEvent(pub, fresh) {
			t.Fatalf("tampered %s must not verify", name)
		}
	}
}

// The seed round trip: what goes into configuration comes back as the
// same key, and garbage is refused with a reason.
func TestSeedRoundTrip(t *testing.T) {
	_, priv, err := NewKey()
	if err != nil {
		t.Fatal(err)
	}
	got, err := DecodeSeed(EncodeSeed(priv))
	if err != nil {
		t.Fatal(err)
	}
	if !priv.Equal(got) {
		t.Fatal("seed round trip changed the key")
	}
	for _, bad := range []string{"", "not base64!!!", "aGVsbG8="} {
		if _, err := DecodeSeed(bad); err == nil {
			t.Fatalf("%q must not decode", bad)
		}
	}
}
