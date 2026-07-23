// `rookctl edit` — the `re` shim's implementation: ask the app to take over
// THIS pane with the editor, vim-style, and block until :q. The pane is
// found via $ROOK_SESSION (set in every rook pty); paths resolve against
// the shell's cwd, host-side. Exit code is the editor's (:q = 0, :cq = 1),
// so EDITOR=re works for git commit et al.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"
)

// ackDeadline bounds how long we wait for the app to acknowledge the edit
// before declaring it unreachable — an old app ignores the frame kind
// entirely (fail open), and this timeout is what turns that into a message
// instead of a hang.
const ackDeadline = 5 * time.Second

func runEdit(paths []string) error {
	self := os.Getenv("ROOK_SESSION")
	if self == "" {
		return errors.New("re runs inside a rook terminal — this shell has no $ROOK_SESSION")
	}
	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	c, err := connect()
	if err != nil {
		return err
	}

	out, err := c.req("POST", "/sessions/"+self+"/edit", map[string]any{
		"cwd":   cwd,
		"paths": paths,
	})
	if err != nil {
		return err
	}
	var created struct {
		EditID string `json:"editId"`
	}
	if json.Unmarshal(out, &created) != nil || created.EditID == "" {
		return fmt.Errorf("unexpected response: %s", out)
	}

	// Short polls until the app acks (so a dead app surfaces in seconds,
	// not a long-poll later), then long polls until :q.
	start, acked := time.Now(), false
	for {
		wait := "1"
		if acked {
			wait = "25"
		}
		out, err := c.req("GET", "/edits/"+created.EditID+"?wait="+wait, nil)
		if err != nil {
			return err
		}
		var st struct {
			Acked bool `json:"acked"`
			Done  bool `json:"done"`
			Code  int  `json:"code"`
		}
		if err := json.Unmarshal(out, &st); err != nil {
			return err
		}
		if st.Done {
			os.Exit(st.Code)
		}
		if st.Acked {
			acked = true
		} else if time.Since(start) > ackDeadline {
			return errors.New("the app didn't pick up the edit — old rook version? (relaunch rook)")
		}
	}
}
