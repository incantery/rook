// `rookctl ask` — pose a question to the human through the rook UI and
// block until they answer. The RUI counterpart of `re`: where edit takes
// over this pane, ask opens a split beside it, so an agent running here
// keeps its window while the question gets its own.
//
// Questions ride in as JSON — an argument or stdin — shaped like Claude
// Code's AskUserQuestion input, plus what rook's form can do that a TUI
// cannot (mcp.go's schema is the full contract):
//
//	{"questions":[{"question":"…","header":"…","multiSelect":false,
//	  "options":[{"label":"…","description":"…",
//	              "preview":"an artifact, shown verbatim beside the rows",
//	              "recommended":true}]}]}
//
// Every added field is optional, and so is "options" itself — a question
// with none is a free-text box.
//
// The answer JSON prints to stdout; exit 0 = answered, 1 = dismissed.
// The MCP `ask` tool (mcp.go) is this same flow behind a tools/call.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"time"
)

// askQuestions validates the outer shape and returns the questions array
// as raw JSON — the host and the form own the finer shapes.
func askQuestions(input []byte) (json.RawMessage, error) {
	var outer struct {
		Questions json.RawMessage `json:"questions"`
	}
	if err := json.Unmarshal(input, &outer); err != nil {
		return nil, fmt.Errorf("bad ask JSON: %w", err)
	}
	var probe []json.RawMessage
	if err := json.Unmarshal(outer.Questions, &probe); err != nil || len(probe) == 0 {
		return nil, errors.New(`ask JSON needs a non-empty "questions" array`)
	}
	return outer.Questions, nil
}

// blockingAsk posts the questions and parks until the human answers.
// Returns the answer JSON; the dismissed flag is inside it
// ({"canceled":true}).
//
// An empty session posts to the session-LESS queue, which the app polls
// instead of receiving over a frame socket. Everything after the create is
// identical — same ask id, same ack, same long-poll — so the CLI's contract
// (stdout JSON, exit 0 answered / 1 dismissed) does not depend on which
// path delivered it.
func blockingAsk(c *client, session string, questions json.RawMessage) (json.RawMessage, error) {
	path := "/asks"
	body := map[string]any{"questions": questions}
	if session != "" {
		path = "/sessions/" + session + "/ask"
	} else {
		// Provenance for a queued ask, which has no session to derive it
		// from: the app shows where the question came from and can jump
		// there. Best-effort — a cwd we cannot read is not a reason to
		// fail an ask.
		if wd, err := os.Getwd(); err == nil {
			body["cwd"] = wd
		}
	}
	out, err := c.req("POST", path, body)
	if err != nil {
		return nil, err
	}
	var created struct {
		AskID string `json:"askId"`
	}
	if json.Unmarshal(out, &created) != nil || created.AskID == "" {
		return nil, fmt.Errorf("unexpected response: %s", out)
	}

	// Short polls until the app acks (so a dead app surfaces in seconds,
	// not a long-poll later), then long polls until the human decides.
	start, acked := time.Now(), false
	for {
		wait := "1"
		if acked {
			wait = "25"
		}
		out, err := c.req("GET", "/asks/"+created.AskID+"?wait="+wait, nil)
		if err != nil {
			return nil, err
		}
		var st struct {
			Acked  bool            `json:"acked"`
			Done   bool            `json:"done"`
			Answer json.RawMessage `json:"answer"`
		}
		if err := json.Unmarshal(out, &st); err != nil {
			return nil, err
		}
		if st.Done {
			return st.Answer, nil
		}
		if st.Acked {
			acked = true
		} else if time.Since(start) > ackDeadline {
			return nil, errors.New("the app didn't pick up the ask — old rook version? (relaunch rook)")
		}
	}
}

// askCanceled reports whether an answer is a dismissal.
func askCanceled(answer json.RawMessage) bool {
	var st struct {
		Canceled bool `json:"canceled"`
	}
	return json.Unmarshal(answer, &st) == nil && st.Canceled
}

func runAsk(args []string) error {
	// $ROOK_SESSION is set by an app that registers its shells with the
	// host. The zig app owns its ptys in-process and registers none, so
	// this is empty in every rook window today — and the session-scoped
	// path would 409 anyway ("no app attached to this session"). Falling
	// back to the session-less queue is what makes `ask` work at all
	// there; the app polls GET /asks for it.
	self := os.Getenv("ROOK_SESSION")

	var input []byte
	if len(args) > 0 {
		input = []byte(args[0])
	} else {
		b, err := io.ReadAll(os.Stdin)
		if err != nil {
			return err
		}
		input = b
	}
	questions, err := askQuestions(input)
	if err != nil {
		return err
	}

	c, err := connect()
	if err != nil {
		return err
	}
	answer, err := blockingAsk(c, self, questions)
	if err != nil {
		return err
	}
	os.Stdout.Write(append(answer, '\n'))
	if askCanceled(answer) {
		os.Exit(1)
	}
	return nil
}
