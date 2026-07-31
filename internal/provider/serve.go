package provider

// The provider's own half: everything a `rook-provider-<name>` binary
// needs to be one. Kept deliberately small — a provider should be its API
// client plus a table of handlers, and nothing here should be the reason
// somebody writes one in Go rather than in whatever they already know.

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"
)

// Handler answers one op. The context carries the caller's deadline, so a
// provider can abandon an API call rook has already stopped waiting for.
type Handler func(ctx context.Context, params json.RawMessage) (any, error)

// Serve runs the provider loop on stdin/stdout until stdin closes, which
// is how rook says "you are done" — a provider needs no shutdown verb and
// no signal handler, and a supervisor that dies takes its providers with
// it rather than leaking them.
//
// `describe` is answered from d here rather than by the caller, so the
// handshake cannot disagree with itself: what Serve advertises is exactly
// the handler table it will dispatch.
func Serve(d Describe, handlers map[string]Handler) {
	d.Capabilities = d.Capabilities[:0]
	for op := range handlers {
		d.Capabilities = append(d.Capabilities, op)
	}
	sortStrings(d.Capabilities)

	in := bufio.NewReaderSize(os.Stdin, 1<<16)
	out := bufio.NewWriter(os.Stdout)
	for {
		line, err := in.ReadBytes('\n')
		if len(line) == 0 && err != nil {
			return // stdin closed: rook is gone, and so are we
		}
		var req Request
		if jsonErr := json.Unmarshal(line, &req); jsonErr != nil {
			// No id to answer to — say so on stderr and keep reading.
			fmt.Fprintf(os.Stderr, "provider: unreadable request: %v\n", jsonErr)
			if err != nil {
				return
			}
			continue
		}
		reply(out, serve(d, handlers, req))
		if err != nil {
			return
		}
	}
}

func serve(d Describe, handlers map[string]Handler, req Request) Response {
	res := Response{V: Version, ID: req.ID}
	if req.V != Version {
		// A version mismatch is refused, never guessed: this frame would
		// have caused an ACTION, and a misread action is worse than none.
		res.Error = fmt.Sprintf("protocol version %d, this provider speaks %d", req.V, Version)
		return res
	}
	if req.Op == OpDescribe {
		res.OK, res.Result = true, mustJSON(d)
		return res
	}
	h, ok := handlers[req.Op]
	if !ok {
		res.Error = fmt.Sprintf("%s does not offer %q (offers: %v)", d.Name, req.Op, d.Capabilities)
		return res
	}

	ctx := context.Background()
	if req.DeadlineMS > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, time.Duration(req.DeadlineMS)*time.Millisecond)
		defer cancel()
	}
	v, err := h(ctx, req.Params)
	if err != nil {
		res.Error = err.Error()
		return res
	}
	res.OK, res.Result = true, mustJSON(v)
	return res
}

func reply(out *bufio.Writer, res Response) {
	data, err := json.Marshal(res)
	if err != nil {
		data, _ = json.Marshal(Response{V: Version, ID: res.ID, Error: "unencodable result"})
	}
	out.Write(data)
	out.WriteByte('\n')
	out.Flush()
}

func mustJSON(v any) json.RawMessage {
	data, err := json.Marshal(v)
	if err != nil {
		return nil
	}
	return data
}

// sortStrings keeps the capability list stable so a describe response is
// the same bytes every run — a handshake that reordered itself would make
// every log diff noisy for no reason.
func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}
