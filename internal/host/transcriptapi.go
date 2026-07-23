package host

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/incantery/rook/internal/transcript"
)

// The transcript endpoint: whole records for one claude session, for the
// session view to render (docs/agent.md, amendment 2026-07-15).
//
// Read from the file on demand, never retained. The reducer
// (transcriptwatch.go) turns records into AgentStatus and drops them, and
// that stays true: live is a stream, history is a file. Holding every
// session's records in memory to serve a view nobody may open would be
// paying for scrollback at all times, and the file is already on disk.
//
// This is the read the tailer cannot do. `watch` follows appends forward;
// scrollback needs to page backward from the end. Two reads of the same
// artifact, which is exactly why the parser is stateless.

// wireBlock is one content block as the frontend needs it.
//
// Signature is deliberately absent. Claude Code writes thinking blocks with
// an encrypted signature and no text — 7430 of them across this machine's
// corpus carry zero renderable characters between them, for 25MB of
// signature. It is an attestation for replaying to the API, which rook never
// does. The block itself is kept so a turn's shape survives.
//
// Input and Content are NOT capped. That cap is what made agentmon useless
// here, and the window is what bounds the response: the last 200 records of
// a real 1.3MB transcript are ~485KB with the largest single payload at
// 34KB. If a session ever makes that hurt, ask for a smaller window — do not
// start truncating content again.
type wireBlock struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`

	// tool_use — ID pairs with a later block's ToolUseID.
	ID    string          `json:"id,omitempty"`
	Name  string          `json:"name,omitempty"`
	Input json.RawMessage `json:"input,omitempty"`

	// tool_result
	ToolUseID string `json:"toolUseId,omitempty"`
	Content   string `json:"content,omitempty"`
	IsError   bool   `json:"isError,omitempty"`
}

// wireRecord is one transcript record. Offset is the cursor: pass the first
// record's offset back as `before` to page further into the past.
type wireRecord struct {
	Offset     int64       `json:"offset"`
	Type       string      `json:"type"` // user | assistant | system
	TS         time.Time   `json:"ts,omitempty"`
	UUID       string      `json:"uuid,omitempty"`
	Model      string      `json:"model,omitempty"`
	Blocks     []wireBlock `json:"blocks,omitempty"`
	Subtype    string      `json:"subtype,omitempty"`
	DurationMs int64       `json:"durationMs,omitempty"`
}

type wireTranscript struct {
	SessionID string       `json:"sessionId"`
	Records   []wireRecord `json:"records"`
	More      bool         `json:"more"`
	// Status is the reduced chip for this session — state, ask, model, cost.
	// It rides along because the view needs both and the alternative is a
	// second poll per open pane for something the host already has in a map.
	// Absent when the reducer has never seen the session: a transcript on
	// disk outlives the process that wrote it.
	Status *AgentStatus `json:"status,omitempty"`
}

// conversational reports whether a record is part of the conversation rather
// than Claude Code's own bookkeeping. attachment, file-history-snapshot,
// queue-operation, mode, permission-mode, ai-title and last-prompt are all
// real records and none of them is something the agent said — the reducer
// reads several of them, the view renders none.
func conversational(rec *transcript.Record) bool {
	switch rec.Type {
	case transcript.TypeUser, transcript.TypeAssistant:
		return rec.Message != nil
	case transcript.TypeSystem:
		return rec.Subtype == transcript.SubtypeTurnDuration
	}
	return false
}

func toWire(ln transcript.Line) wireRecord {
	rec := ln.Record
	out := wireRecord{
		Offset:     ln.Offset,
		Type:       rec.Type,
		TS:         rec.Timestamp,
		UUID:       rec.UUID,
		Subtype:    rec.Subtype,
		DurationMs: rec.DurationMs,
	}
	if rec.Message == nil {
		return out
	}
	out.Model = rec.Message.Model
	for _, b := range rec.Message.Content {
		wb := wireBlock{Type: b.Type, Text: b.Text}
		switch b.Type {
		case transcript.BlockToolUse:
			wb.ID, wb.Name, wb.Input = b.ID, b.Name, b.Input
		case transcript.BlockToolResult:
			wb.ToolUseID, wb.IsError = b.ToolUseID, b.IsError
			wb.Content = b.ResultText()
		}
		out.Blocks = append(out.Blocks, wb)
	}
	return out
}

// handleAgentTranscript serves GET /agents/{id}/transcript?limit=&before=&after=.
//
// Records come back oldest-first within the window, which ends at `before`
// (exclusive) or at the end of the session. `more` reports whether older
// records exist — page by passing the first record's offset back as
// `before`.
//
// `after` is the OTHER direction: the incremental poll. A view that already
// holds the tail passes its last record's offset and gets only what landed
// since — usually nothing but the status chip, at the cost of a stat. The
// full-window poll it replaces re-served (and re-parsed) megabytes every
// tick on a long session; that is what ate the webview. `after` wins over
// `before` when both are sent.
//
// A session with no transcript on disk is 404, not an error: rook shows
// agent sessions it correlated from a tree it does not own, and a file can
// be deleted out from under it.
func (h *Host) handleAgentTranscript(w http.ResponseWriter, r *http.Request, id string) {
	path, err := transcript.FindSession("", id)
	if err != nil {
		http.Error(w, "no such agent session", http.StatusNotFound)
		return
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	before, _ := strconv.ParseInt(r.URL.Query().Get("before"), 10, 64)
	after, _ := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)

	var lines []transcript.Line
	var more bool
	if after > 0 {
		lines, more, err = transcript.ReadSessionAfter(path, limit, after)
	} else {
		lines, more, err = transcript.ReadSession(path, limit, before)
	}
	if err != nil {
		http.Error(w, "read transcript: "+err.Error(), http.StatusInternalServerError)
		return
	}
	out := wireTranscript{SessionID: id, Records: []wireRecord{}, More: more}
	for _, ln := range lines {
		if !conversational(ln.Record) || ln.Record.IsSidechain {
			continue
		}
		out.Records = append(out.Records, toWire(ln))
	}
	if st, _, ok := h.aw.context(id); ok {
		out.Status = &st
	}
	writeJSON(w, out)
}
