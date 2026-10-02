// SPDX-License-Identifier: Apache-2.0

package eval

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"strings"
)

// The agent's message log, as `claude -p --output-format stream-json` writes it: one JSON object
// per line. What the grader needs from it is small -- the assistant's prose, every tool call with
// its arguments, every tool result and whether it was an error, and the closing result line with
// its numbers -- and the raw lines are kept beside it, so a reader who wants more has it.

// ToolPrefix is what Claude Code puts in front of an MCP tool's name: server, then tool.
const ToolPrefix = "mcp__leyline__"

// Event is one thing that happened, in order.
type Event struct {
	// Kind is "text" (assistant prose), "tool_use", "tool_result", "init" or "result".
	Kind string `json:"kind"`
	// Text is the prose, for text; the final answer, for result.
	Text string `json:"text,omitempty"`
	// Tool is the tool's name as called (mcp__leyline__scan, Bash), Input its arguments.
	Tool  string          `json:"tool,omitempty"`
	ID    string          `json:"id,omitempty"`
	Input json.RawMessage `json:"input,omitempty"`
	// Result is a tool result's content, flattened to text; IsError says the tool refused.
	Result  string `json:"result,omitempty"`
	IsError bool   `json:"is_error,omitempty"`
	// Servers, for init, is the MCP servers and their status.
	Servers map[string]string `json:"servers,omitempty"`
}

// Log is the whole conversation, with what the closing line reported.
type Log struct {
	Events []Event `json:"events"`
	// Final is the assistant's last answer, where the JSON block is.
	Final      string  `json:"final"`
	Turns      int     `json:"turns"`
	DurationMs int64   `json:"duration_ms"`
	CostUSD    float64 `json:"cost_usd"`
	// Subtype is the result's: "success", or an error such as "error_max_turns".
	Subtype string `json:"subtype"`
	// Usage is the result's token accounting, kept as the agent wrote it.
	Usage json.RawMessage `json:"usage,omitempty"`
	// Lines is the raw stream, one JSON object each, for the transcript and for a replay.
	Lines []string `json:"-"`
}

// ShortTool is a tool's name without the server prefix: "scan".
func ShortTool(name string) string { return strings.TrimPrefix(name, ToolPrefix) }

// IsShell reports whether a tool call left the MCP tools for the host: Bash is the shell, and
// the file tools are the host too.
func IsShell(tool string) bool {
	switch tool {
	case "Bash", "Read", "Write", "Edit", "Glob", "Grep":
		return true
	}
	return false
}

// IsHarness reports a tool call that is the agent's client at work rather than the agent: Claude
// Code defers tool schemas and loads them through ToolSearch before the first real call. It is
// kept in the transcript and left out of every count and budget.
func IsHarness(tool string) bool { return tool == "ToolSearch" }

// ToolCalls is every tool_use event the agent made, in order, the client's own left out.
func (l *Log) ToolCalls() []Event {
	var out []Event
	for _, e := range l.Events {
		if e.Kind == "tool_use" && !IsHarness(e.Tool) {
			out = append(out, e)
		}
	}
	return out
}

// Prose is every assistant text, joined: what the word checks read.
func (l *Log) Prose() string {
	var b strings.Builder
	for _, e := range l.Events {
		if e.Kind == "text" {
			b.WriteString(e.Text)
			b.WriteString("\n")
		}
	}
	if l.Final != "" {
		b.WriteString(l.Final)
	}
	return b.String()
}

// ResultFor is the result of a tool call by id, or nil.
func (l *Log) ResultFor(id string) *Event {
	for i := range l.Events {
		if l.Events[i].Kind == "tool_result" && l.Events[i].ID == id {
			return &l.Events[i]
		}
	}
	return nil
}

// ParseStream reads a stream-json conversation. Lines that are not JSON, or JSON of a kind the
// log does not model, are kept in Lines and otherwise ignored: the agent's stream gains kinds
// over time and a log must never fail to parse because of one.
func ParseStream(r io.Reader) (*Log, error) {
	log := &Log{}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		log.Lines = append(log.Lines, line)
		var head struct {
			Type    string `json:"type"`
			Subtype string `json:"subtype"`
		}
		if err := json.Unmarshal([]byte(line), &head); err != nil {
			continue
		}
		switch head.Type {
		case "system":
			if head.Subtype == "init" {
				log.Events = append(log.Events, parseInit(line))
			}
		case "assistant":
			log.Events = append(log.Events, parseAssistant(line)...)
		case "user":
			log.Events = append(log.Events, parseUser(line)...)
		case "result":
			var res struct {
				Result     string          `json:"result"`
				NumTurns   int             `json:"num_turns"`
				DurationMs int64           `json:"duration_ms"`
				CostUSD    float64         `json:"total_cost_usd"`
				Usage      json.RawMessage `json:"usage"`
			}
			_ = json.Unmarshal([]byte(line), &res)
			log.Final = res.Result
			log.Turns = res.NumTurns
			log.DurationMs = res.DurationMs
			log.CostUSD = res.CostUSD
			log.Subtype = head.Subtype
			log.Usage = res.Usage
			log.Events = append(log.Events, Event{Kind: "result", Text: res.Result})
		}
	}
	if err := sc.Err(); err != nil {
		return log, err
	}
	// A run that never reached a result line (the agent was killed, or the stream is a fragment)
	// still has a final answer: the last prose.
	if log.Final == "" {
		for i := len(log.Events) - 1; i >= 0; i-- {
			if log.Events[i].Kind == "text" {
				log.Final = log.Events[i].Text
				break
			}
		}
	}
	return log, nil
}

func parseInit(line string) Event {
	var init struct {
		Servers []struct {
			Name   string `json:"name"`
			Status string `json:"status"`
		} `json:"mcp_servers"`
	}
	_ = json.Unmarshal([]byte(line), &init)
	ev := Event{Kind: "init", Servers: map[string]string{}}
	for _, s := range init.Servers {
		ev.Servers[s.Name] = s.Status
	}
	return ev
}

// content is one block of a message's content list, in the shapes the stream uses.
type content struct {
	Type      string          `json:"type"`
	Text      string          `json:"text"`
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Input     json.RawMessage `json:"input"`
	ToolUseID string          `json:"tool_use_id"`
	Content   json.RawMessage `json:"content"`
	IsError   bool            `json:"is_error"`
}

func parseAssistant(line string) []Event {
	var msg struct {
		Message struct {
			Content []content `json:"content"`
		} `json:"message"`
	}
	if err := json.Unmarshal([]byte(line), &msg); err != nil {
		return nil
	}
	var out []Event
	for _, c := range msg.Message.Content {
		switch c.Type {
		case "text":
			if strings.TrimSpace(c.Text) != "" {
				out = append(out, Event{Kind: "text", Text: c.Text})
			}
		case "tool_use":
			out = append(out, Event{Kind: "tool_use", Tool: c.Name, ID: c.ID, Input: c.Input})
		}
	}
	return out
}

func parseUser(line string) []Event {
	var msg struct {
		Message struct {
			Content json.RawMessage `json:"content"`
		} `json:"message"`
	}
	if err := json.Unmarshal([]byte(line), &msg); err != nil {
		return nil
	}
	var blocks []content
	if err := json.Unmarshal(msg.Message.Content, &blocks); err != nil {
		return nil // a plain-string user message: the prompt echo, not a tool result
	}
	var out []Event
	for _, c := range blocks {
		if c.Type != "tool_result" {
			continue
		}
		out = append(out, Event{Kind: "tool_result", ID: c.ToolUseID, Result: flatten(c.Content), IsError: c.IsError})
	}
	return out
}

// flatten turns a tool result's content -- a string, or a list of text and image blocks -- into
// text. An image is named, not carried: the transcript says a PNG came back and how big.
func flatten(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	var rawBlocks []json.RawMessage
	if err := json.Unmarshal(raw, &rawBlocks); err != nil {
		return string(raw)
	}
	type block struct {
		Type   string `json:"type"`
		Text   string `json:"text"`
		Source *struct {
			MediaType string `json:"media_type"`
			Data      string `json:"data"`
		} `json:"source"`
		Data     string          `json:"data"`
		MIMEType string          `json:"mimeType"`
		Raw      json.RawMessage `json:"-"`
	}
	blocks := make([]block, 0, len(rawBlocks))
	for _, rb := range rawBlocks {
		var bl block
		_ = json.Unmarshal(rb, &bl)
		bl.Raw = rb
		blocks = append(blocks, bl)
	}
	var b strings.Builder
	for _, bl := range blocks {
		switch bl.Type {
		case "text":
			b.WriteString(bl.Text)
			b.WriteString("\n")
		case "image":
			n := len(bl.Data)
			mime := bl.MIMEType
			if bl.Source != nil {
				n, mime = len(bl.Source.Data), bl.Source.MediaType
			}
			fmt.Fprintf(&b, "[image %s, %d bytes base64]\n", mime, n)
		default:
			// A block kind the log does not model (a tool reference, say): its own JSON, once.
			if blob, err := json.Marshal(bl.Raw); err == nil {
				b.Write(blob)
				b.WriteString("\n")
			}
		}
	}
	return b.String()
}

var jsonBlock = regexp.MustCompile("(?s)```json\\s*(.*?)```")

// Answer is the JSON block the agent ended with: the last ```json fence in the final answer,
// parsed. Nil when there is none, which the json checks report as such.
func (l *Log) Answer() (map[string]any, error) {
	matches := jsonBlock.FindAllStringSubmatch(l.Final, -1)
	if len(matches) == 0 {
		// The prose may hold it when the result line was cut short.
		matches = jsonBlock.FindAllStringSubmatch(l.Prose(), -1)
	}
	if len(matches) == 0 {
		return nil, fmt.Errorf("the answer has no ```json block")
	}
	var out map[string]any
	if err := json.Unmarshal([]byte(matches[len(matches)-1][1]), &out); err != nil {
		return nil, fmt.Errorf("the answer's JSON block does not parse: %w", err)
	}
	return out, nil
}
