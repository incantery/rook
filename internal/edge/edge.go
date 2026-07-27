// Package edge is the transport half of the Cloud–IDE edge protocol:
// a ConnectRPC client over the machine bearer token, nothing more. The
// journal, the verification checklist, and the executor live in
// internal/host — this package only ever moves envelopes.
//
// Unlike internal/cloud and internal/relay, the wire types here are
// GENERATED (gen/rook/edge/v1, from the copied proto) rather than
// duplicated by hand: commands are signed over canonical encodings of
// their exact fields, and hand-kept mirrors of signed shapes is how
// signatures stop meaning anything. The no-module-dependency rule
// stands — the proto is copied, not imported, and testdata/golden.json
// in internal/edgesign is the drift tripwire.
package edge

import (
	"context"
	"log"
	"net/http"
	"net/url"
	"time"

	"connectrpc.com/connect"

	edgev1 "github.com/incantery/rook/gen/rook/edge/v1"
	"github.com/incantery/rook/gen/rook/edge/v1/edgev1connect"
)

// ProtocolVersion mirrors the cloud's edge.ProtocolVersion. A version
// the server refuses is surfaced by the server, not guessed at here.
const ProtocolVersion = "rook-edge/1"

// Client speaks the protocol for one authenticated machine identity.
type Client struct {
	RPC edgev1connect.EdgeServiceClient
}

// New returns a ready client, or nil when the base URL is unusable —
// the same nil-means-inert contract as cloud.New. The token rides only
// in the Authorization header.
func New(base, token string) *Client {
	u, err := url.Parse(base)
	if err != nil || u.Scheme == "" || u.Host == "" || token == "" {
		return nil
	}
	return &Client{RPC: edgev1connect.NewEdgeServiceClient(
		&http.Client{}, base, connect.WithInterceptors(bearer(token)))}
}

// bearer stamps the token on unary AND streaming calls — a
// UnaryInterceptorFunc would silently skip the wake stream.
type bearer string

func (b bearer) WrapUnary(next connect.UnaryFunc) connect.UnaryFunc {
	return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
		req.Header().Set("Authorization", "Bearer "+string(b))
		return next(ctx, req)
	}
}

func (b bearer) WrapStreamingClient(next connect.StreamingClientFunc) connect.StreamingClientFunc {
	return func(ctx context.Context, spec connect.Spec) connect.StreamingClientConn {
		conn := next(ctx, spec)
		conn.RequestHeader().Set("Authorization", "Bearer "+string(b))
		return conn
	}
}

func (b bearer) WrapStreamingHandler(next connect.StreamingHandlerFunc) connect.StreamingHandlerFunc {
	return next
}

// Register announces the device, offering its verification key and
// learning the cloud's. The device learns its own identity from the
// server, never the other way around.
func (c *Client) Register(ctx context.Context, name, platform string, capabilities []string, publicKey []byte) (*edgev1.RegisterDeviceResponse, error) {
	res, err := c.RPC.RegisterDevice(ctx, connect.NewRequest(&edgev1.RegisterDeviceRequest{
		ProtocolVersion: ProtocolVersion,
		DeviceName:      name,
		Platform:        platform,
		Capabilities:    capabilities,
		PublicKey:       publicKey,
	}))
	if err != nil {
		return nil, err
	}
	return res.Msg, nil
}

// Watch holds the wake stream, nudging the caller's loop on every wake
// (the LISTENING greeting included — anything minted while the stream
// was down raced the subscription). Only ever an accelerator: failures
// back off and retry, Unimplemented or Unauthenticated retires the
// watcher for good, and the poll loop never learns any of this.
func (c *Client) Watch(ctx context.Context, wake chan<- struct{}) {
	backoff := time.Second
	for ctx.Err() == nil {
		stream, err := c.RPC.WatchEdge(ctx, connect.NewRequest(&edgev1.WatchEdgeRequest{
			ProtocolVersion: ProtocolVersion,
		}))
		if err == nil {
			for stream.Receive() {
				backoff = time.Second // a live stream resets the clock
				switch stream.Msg().Kind {
				case edgev1.WatchEdgeResponse_KIND_WAKE, edgev1.WatchEdgeResponse_KIND_LISTENING:
					select {
					case wake <- struct{}{}:
					default: // a pending nudge needs no second one
					}
				}
			}
			err = stream.Err()
		}
		switch connect.CodeOf(err) {
		case connect.CodeUnimplemented:
			log.Printf("edge: wake stream not offered; polling only")
			return
		case connect.CodeUnauthenticated:
			return // the poll loop is about to learn the same thing
		}
		if ctx.Err() != nil {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, 30*time.Second)
	}
}
