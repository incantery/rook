// Package transcript reads Claude Code's session transcripts
// (~/.claude/projects/**/*.jsonl) into whole records.
//
// It replaces the agentmon dependency (docs/agent.md, amendment
// 2026-07-15). agentmon is a telemetry shipper: its parser reduces each
// line to one of nine metric-shaped events, caps every content field at
// 2KB, and never captures a tool_use id — correct for Loki and Grafana,
// useless for rendering a session. Rook needs the opposite: whole records,
// nothing truncated, and call/result identity preserved so a pending tool
// call can be paired with the result that ends it.
//
// The division of labour here is deliberate. This file is a *stateless*
// line parser: bytes in, one Record out. Everything that needs memory
// across lines — session lifecycle, timestamp carry, the message-id
// dedupe, state reduction — belongs to the consumer. agentmon's parser
// mixes the two (it synthesises session_started from "have I seen a line
// yet", so a Parser resumed mid-file corrupts its own output); keeping the
// parse pure means a record can be read from anywhere in the file, which
// is what scrollback needs.
//
// Unknown record types, unknown content blocks, and undecodable lines are
// never errors worth stopping on: new Claude Code releases must degrade to
// a hole in the render, never a dead sensor. Callers switch on Type and
// ignore what they don't know.
package transcript

import (
	"encoding/json"
	"fmt"
	"time"
)

// Record types the reducer switches on. The set is deliberately open:
// anything else parses into a Record with only the common fields populated.
//
// The corpus on this machine (143k lines, 1334 files) also carries
// agent-name, attachment, bridge-session, file-history-delta,
// file-history-snapshot, last-prompt, pr-link, queue-operation, result and
// started. Six of those are types agentmon's parser has never heard of and
// silently counts as Skipped — which is the drift this package exists to
// stop swallowing. Name them here as they earn a consumer, not before.
const (
	TypeUser           = "user"
	TypeAssistant      = "assistant"
	TypeSystem         = "system"
	TypePermissionMode = "permission-mode"
	TypeMode           = "mode"
	TypeAITitle        = "ai-title"

	SubtypeTurnDuration = "turn_duration"
)

// Block types inside a message's content array.
const (
	BlockText       = "text"
	BlockThinking   = "thinking"
	BlockToolUse    = "tool_use"
	BlockToolResult = "tool_result"
)

// Record is one transcript line. Fields outside the common header are only
// meaningful for the types that carry them; a permission-mode line has a
// PermissionMode and nothing else, and that is not an error.
//
// Timestamp is zero on the types Claude Code writes without one
// (permission-mode, mode, ai-title, last-prompt). Consumers that need a
// monotonic clock carry the last seen timestamp forward themselves — the
// parser will not invent one.
type Record struct {
	Type       string
	Timestamp  time.Time
	UUID       string
	ParentUUID string
	SessionID  string
	CWD        string
	GitBranch  string
	Version    string
	// IsSidechain marks subagent traffic inside a parent's transcript.
	IsSidechain bool
	IsMeta      bool

	// system
	Subtype      string
	DurationMs   int64
	MessageCount int

	// permission-mode / mode / ai-title
	PermissionMode string
	Mode           string
	AITitle        string

	// Message is set on user and assistant records, nil elsewhere.
	Message *Message
}

// Message is the Anthropic API message embedded in a user or assistant
// record.
type Message struct {
	ID         string
	Role       string
	Model      string
	StopReason string
	Usage      Usage
	Content    []Block
}

// Usage is the token accounting on an assistant message.
//
// Load-bearing: Claude Code writes one API response as several adjacent
// lines — one per content block — each repeating the *same* message id and
// the same Usage object. Summing Usage across records double-counts (~2x).
// Deduping on Message.ID is the consumer's job; the parser reports what the
// line said.
type Usage struct {
	InputTokens         int64
	OutputTokens        int64
	CacheReadTokens     int64
	CacheCreationTokens int64
	Cache5mTokens       int64
	Cache1hTokens       int64

	// Speed is usage.speed — "standard", "fast", or empty on lines written
	// before the field existed. It is billing-relevant, not decoration: a
	// fast-mode response costs 2x a standard one on the models that offer
	// it, so Cost reads this rather than assuming standard.
	Speed string
}

// Block is one content block. Which fields are set depends on Type:
//
//	text         → Text
//	thinking     → Thinking, Signature (Thinking may be empty when the
//	               signature carries redacted reasoning)
//	tool_use     → ID, Name, Input
//	tool_result  → ToolUseID, Content, IsError
//
// Input and Content stay raw and uncapped. Input in particular is the whole
// reason this package exists: an AskUserQuestion's questions and options
// live there, and agentmon's 2KB cap clipped them.
type Block struct {
	Type string

	Text string

	Thinking  string
	Signature string

	// tool_use. ID pairs with a later tool_result's ToolUseID — the pairing
	// agentmon's event stream cannot express, and the one that makes "claude
	// is blocked on a human" visible: a tool_use with no result yet is a
	// call still outstanding, and the gap to its result is how long someone
	// took to answer.
	ID    string
	Name  string
	Input json.RawMessage

	// tool_result
	ToolUseID string
	Content   json.RawMessage
	IsError   bool
}

// rawRecord is the union of top-level fields across observed line types.
// Missing fields stay zero.
type rawRecord struct {
	Type        string          `json:"type"`
	Timestamp   string          `json:"timestamp"`
	UUID        string          `json:"uuid"`
	ParentUUID  string          `json:"parentUuid"`
	SessionID   string          `json:"sessionId"`
	CWD         string          `json:"cwd"`
	GitBranch   string          `json:"gitBranch"`
	Version     string          `json:"version"`
	IsSidechain bool            `json:"isSidechain"`
	IsMeta      bool            `json:"isMeta"`
	Subtype     string          `json:"subtype"`
	DurationMs  int64           `json:"durationMs"`
	MsgCount    int             `json:"messageCount"`
	PermMode    string          `json:"permissionMode"`
	Mode        string          `json:"mode"`
	AITitle     string          `json:"aiTitle"`
	Message     json.RawMessage `json:"message"`
}

type rawMessage struct {
	ID         string `json:"id"`
	Role       string `json:"role"`
	Model      string `json:"model"`
	StopReason string `json:"stop_reason"`
	Usage      struct {
		InputTokens              int64 `json:"input_tokens"`
		OutputTokens             int64 `json:"output_tokens"`
		CacheReadInputTokens     int64 `json:"cache_read_input_tokens"`
		CacheCreationInputTokens int64 `json:"cache_creation_input_tokens"`
		CacheCreation            struct {
			Ephemeral5m int64 `json:"ephemeral_5m_input_tokens"`
			Ephemeral1h int64 `json:"ephemeral_1h_input_tokens"`
		} `json:"cache_creation"`
		Speed string `json:"speed"`
	} `json:"usage"`
	Content json.RawMessage `json:"content"` // string, or []rawBlock
}

type rawBlock struct {
	Type      string          `json:"type"`
	Text      string          `json:"text"`
	Thinking  string          `json:"thinking"`
	Signature string          `json:"signature"`
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Input     json.RawMessage `json:"input"`
	ToolUseID string          `json:"tool_use_id"`
	Content   json.RawMessage `json:"content"`
	IsError   bool            `json:"is_error"`
}

// Parse reads one transcript line. It returns an error only when the line
// is not a JSON object with a type — everything else, including record and
// block types this build has never heard of, parses into whatever fields
// are recognisable.
func Parse(data []byte) (*Record, error) {
	var rr rawRecord
	if err := json.Unmarshal(data, &rr); err != nil {
		return nil, fmt.Errorf("transcript: malformed line: %w", err)
	}
	if rr.Type == "" {
		return nil, fmt.Errorf("transcript: line has no type")
	}
	rec := &Record{
		Type:           rr.Type,
		UUID:           rr.UUID,
		ParentUUID:     rr.ParentUUID,
		SessionID:      rr.SessionID,
		CWD:            rr.CWD,
		GitBranch:      rr.GitBranch,
		Version:        rr.Version,
		IsSidechain:    rr.IsSidechain,
		IsMeta:         rr.IsMeta,
		Subtype:        rr.Subtype,
		DurationMs:     rr.DurationMs,
		MessageCount:   rr.MsgCount,
		PermissionMode: rr.PermMode,
		Mode:           rr.Mode,
		AITitle:        rr.AITitle,
	}
	if rr.Timestamp != "" {
		if t, err := time.Parse(time.RFC3339Nano, rr.Timestamp); err == nil {
			rec.Timestamp = t
		}
	}
	if len(rr.Message) > 0 && string(rr.Message) != "null" {
		rec.Message = parseMessage(rr.Message)
	}
	return rec, nil
}

// parseMessage decodes .message. A message that will not decode yields nil
// rather than failing the record: the header is still worth having.
func parseMessage(raw json.RawMessage) *Message {
	var rm rawMessage
	if json.Unmarshal(raw, &rm) != nil {
		return nil
	}
	m := &Message{
		ID:         rm.ID,
		Role:       rm.Role,
		Model:      rm.Model,
		StopReason: rm.StopReason,
		Usage: Usage{
			InputTokens:         rm.Usage.InputTokens,
			OutputTokens:        rm.Usage.OutputTokens,
			CacheReadTokens:     rm.Usage.CacheReadInputTokens,
			CacheCreationTokens: rm.Usage.CacheCreationInputTokens,
			Cache5mTokens:       rm.Usage.CacheCreation.Ephemeral5m,
			Cache1hTokens:       rm.Usage.CacheCreation.Ephemeral1h,
			Speed:               rm.Usage.Speed,
		},
		Content: parseContent(rm.Content),
	}
	return m
}

// parseContent normalises .content, which Claude Code writes either as a
// bare string (a typed human prompt) or as an array of blocks. The string
// form becomes a single text block so consumers only handle one shape.
func parseContent(raw json.RawMessage) []Block {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		if s == "" {
			return nil
		}
		return []Block{{Type: BlockText, Text: s}}
	}
	var blocks []rawBlock
	if json.Unmarshal(raw, &blocks) != nil {
		return nil
	}
	out := make([]Block, 0, len(blocks))
	for _, b := range blocks {
		out = append(out, Block{
			Type:      b.Type,
			Text:      b.Text,
			Thinking:  b.Thinking,
			Signature: b.Signature,
			ID:        b.ID,
			Name:      b.Name,
			Input:     b.Input,
			ToolUseID: b.ToolUseID,
			Content:   b.Content,
			IsError:   b.IsError,
		})
	}
	return out
}

// Text flattens a message's text blocks, which is what the ask string and
// the drafter's history ring want. Thinking is excluded: it is reasoning,
// not something claude said.
func (m *Message) Text() string {
	if m == nil {
		return ""
	}
	var out string
	for _, b := range m.Content {
		if b.Type != BlockText || b.Text == "" {
			continue
		}
		if out != "" {
			out += "\n"
		}
		out += b.Text
	}
	return out
}

// ToolCalls returns the tool_use blocks of a message, in order.
func (m *Message) ToolCalls() []Block {
	if m == nil {
		return nil
	}
	var out []Block
	for _, b := range m.Content {
		if b.Type == BlockToolUse {
			out = append(out, b)
		}
	}
	return out
}

// ToolResults returns the tool_result blocks of a message, in order.
func (m *Message) ToolResults() []Block {
	if m == nil {
		return nil
	}
	var out []Block
	for _, b := range m.Content {
		if b.Type == BlockToolResult {
			out = append(out, b)
		}
	}
	return out
}

// ResultText renders a tool_result's content — a string, or an array of
// text blocks — to plain text.
func (b Block) ResultText() string {
	if len(b.Content) == 0 {
		return ""
	}
	var s string
	if json.Unmarshal(b.Content, &s) == nil {
		return s
	}
	var blocks []rawBlock
	if json.Unmarshal(b.Content, &blocks) != nil {
		return ""
	}
	var out string
	for _, blk := range blocks {
		if blk.Type != BlockText || blk.Text == "" {
			continue
		}
		if out != "" {
			out += "\n"
		}
		out += blk.Text
	}
	return out
}
