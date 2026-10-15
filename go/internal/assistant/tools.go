// SPDX-License-Identifier: Apache-2.0

package assistant

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// UndoTool is the tool the worker adds to the server's: it puts back what the last tune or set
// changed, from the values read before the write.
const UndoTool = "undo"

const undoDescription = "put back the last tuning or setting the assistant changed: the values a set replaced, or stop the channel a tune made. Takes no arguments; each call undoes one more."

// Tools is the `ley mcp` server driven in process: the same tool table, guards and refusals an
// agent on `ley mcp` gets, reached over an in-memory MCP session instead of stdio.
type Tools struct {
	cs *mcp.ClientSession
	// defs is what the model is offered: the server's tools, then the view tools, then undo.
	defs []ToolDef
	// readOnly is the server's tools that only read, from their annotations.
	readOnly map[string]bool
	// server is the server's tools by name, view the view tools.
	server, view map[string]bool
	// instructions is the server's own note to an agent, which goes into the system prompt.
	instructions string
	// Dropped is each view tool left out, and why.
	Dropped []string
}

// viewToolName is what the Messages API accepts as a tool name.
var viewToolName = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)

// Result is one tool call's outcome: the prose and the JSON the server returned, as two strings.
type Result struct {
	Text    string
	JSON    string
	IsError bool
}

// ForModel is the result as the model reads it: the prose, then the JSON.
func (r Result) ForModel() string {
	return strings.TrimSpace(strings.TrimRight(r.Text, "\n") + "\n" + r.JSON)
}

// NewTools connects an in-memory MCP client to server and builds the model's tool list.
func NewTools(ctx context.Context, server *mcp.Server, viewTools []*leylinev1.ViewTool) (*Tools, error) {
	st, ct := mcp.NewInMemoryTransports()
	if _, err := server.Connect(ctx, st, nil); err != nil {
		return nil, fmt.Errorf("the tool server: %w", err)
	}
	cs, err := mcp.NewClient(&mcp.Implementation{Name: "ley-assistant", Version: "1"}, nil).Connect(ctx, ct, nil)
	if err != nil {
		return nil, fmt.Errorf("the tool server: %w", err)
	}
	t := &Tools{cs: cs, readOnly: map[string]bool{}, server: map[string]bool{}, view: map[string]bool{}}
	if init := cs.InitializeResult(); init != nil {
		t.instructions = init.Instructions
	}
	listed, err := cs.ListTools(ctx, nil)
	if err != nil {
		_ = cs.Close()
		return nil, fmt.Errorf("the tool server's tools: %w", err)
	}
	for _, tool := range listed.Tools {
		schema, err := json.Marshal(tool.InputSchema)
		if err != nil {
			_ = cs.Close()
			return nil, fmt.Errorf("the %s tool's schema: %w", tool.Name, err)
		}
		t.defs = append(t.defs, ToolDef{Name: tool.Name, Description: tool.Description, InputSchema: schema})
		t.server[tool.Name] = true
		if tool.Annotations != nil && tool.Annotations.ReadOnlyHint {
			t.readOnly[tool.Name] = true
		}
	}
	for _, v := range viewTools {
		switch name := v.GetName(); {
		case !viewToolName.MatchString(name):
			t.Dropped = append(t.Dropped, fmt.Sprintf("%q: a tool name is 1 to 64 letters, digits, _ or -", name))
			continue
		case t.server[name] || name == UndoTool:
			t.Dropped = append(t.Dropped, fmt.Sprintf("%s: a client cannot take the name of a radio tool or undo", name))
			continue
		case t.view[name]:
			t.Dropped = append(t.Dropped, fmt.Sprintf("%s: declared twice", name))
			continue
		}
		schema := json.RawMessage(v.GetInputSchemaJson())
		if !json.Valid(schema) || len(schema) == 0 {
			schema = json.RawMessage(`{"type":"object"}`)
		}
		t.defs = append(t.defs, ToolDef{Name: v.GetName(), Description: v.GetDescription(), InputSchema: schema})
		t.view[v.GetName()] = true
	}
	t.defs = append(t.defs, ToolDef{Name: UndoTool, Description: undoDescription, InputSchema: json.RawMessage(`{"type":"object","properties":{}}`)})
	return t, nil
}

// Defs is the model's tool list.
func (t *Tools) Defs() []ToolDef { return t.defs }

// IsView reports whether name is a view tool a client answers.
func (t *Tools) IsView(name string) bool { return t.view[name] }

// IsServer reports whether name is one of the server's tools.
func (t *Tools) IsServer(name string) bool { return t.server[name] }

// IsWrite reports whether a call changes something: every server tool not annotated read-only,
// and undo. A view tool moves the client's own view and is not a write.
func (t *Tools) IsWrite(name string) bool {
	return name == UndoTool || (t.server[name] && !t.readOnly[name])
}

// Close ends the session.
func (t *Tools) Close() error { return t.cs.Close() }

// Call runs one server tool. A protocol failure comes back as an error result, because to the
// model it is one more tool that did not work.
func (t *Tools) Call(ctx context.Context, name string, args json.RawMessage) Result {
	if len(args) == 0 {
		args = json.RawMessage("{}")
	}
	res, err := t.cs.CallTool(ctx, &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		return Result{Text: err.Error(), IsError: true}
	}
	return splitResult(res)
}

// splitResult takes the server's two text blocks apart: the prose a verb would print, then the
// proto3 JSON (mcp.go, jsonResult). An image block (snapshot's PNG) is left out; the model reads
// the row's numbers instead.
func splitResult(res *mcp.CallToolResult) Result {
	var texts []string
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			texts = append(texts, tc.Text)
		}
	}
	out := Result{IsError: res.IsError}
	if n := len(texts); n > 0 {
		last := strings.TrimSpace(texts[n-1])
		if last != "" && strings.ContainsAny(last[:1], "{[") && json.Valid([]byte(last)) {
			out.JSON = last
			texts = texts[:n-1]
		}
	}
	out.Text = strings.TrimRight(strings.Join(texts, ""), "\n")
	return out
}
