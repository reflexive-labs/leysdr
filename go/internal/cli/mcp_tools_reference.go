// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/google/jsonschema-go/jsonschema"
	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/spf13/cobra"
)

// The reference tools: the tables `ley bands` and `ley presets` print and the `ley help` topics.
// All three are client-local data that never reaches the daemon, so they read nothing and
// change nothing. The tables run their verbs as they stand, once for the text and once with
// --json for the JSON, so the tool cannot say anything the verb would not.

func (srv *mcpServer) registerReferenceTools() {
	mcp.AddTool(srv.server, &mcp.Tool{
		Name: "list_bands",
		Description: "The bands ley knows by name, with the mode and bandwidth tune uses in each and how many plan channels each has (ley bands). " +
			"Given query (a frequency, a preset or a band name), it answers that one: which band, and what tune would do there; a band name also lists its plan channels. " +
			"Returns the array 'ley bands --json' prints, or the one object 'ley bands <query> --json' prints; client-local data, not a proto message.",
		Annotations: toolReadOnly,
	}, srv.listBands)
	mcp.AddTool(srv.server, &mcp.Tool{
		Name: "list_presets",
		Description: "The names tune and every frequency argument accept in place of a number (wx3, marine16, cb19, calling...), with the frequency and mode each stands for (ley presets). " +
			"Returns the array 'ley presets --json' prints; client-local data, not a proto message.",
		Annotations: toolReadOnly,
	}, srv.listPresets)
	mcp.AddTool(srv.server, &mcp.Tool{
		Name: "help",
		Description: "A 'ley help' topic: the longer explanations the verbs point at (squelch and the dBFS scale, how to write a frequency, which mode where, gain and overload, presets, a glossary). " +
			"With no topic it lists them. Returns {name, summary, text}, or {topics: [{name, summary}]}.",
		Annotations: toolReadOnly,
		InputSchema: helpSchema(),
	}, srv.help)
}

// localVerb runs a client-local verb twice, as a person would see it and with --json, and returns
// the text beside the JSON. It is only for verbs that read: a verb that writes would write twice.
func (srv *mcpServer) localVerb(ctx context.Context, build func(*App) *cobra.Command, args ...string) (string, json.RawMessage, error) {
	run := func(asJSON bool) (string, string, error) {
		app, out, errb := srv.toolApp()
		app.JSON = asJSON
		cmd := build(app)
		// A nil argument list makes cobra read the process's own arguments.
		cmd.SetArgs(append([]string{}, args...))
		cmd.SetOut(out)
		cmd.SetErr(errb)
		cmd.SilenceErrors, cmd.SilenceUsage = true, true
		err := cmd.ExecuteContext(ctx)
		return out.String(), errb.String(), err
	}
	text, notes, err := run(false)
	if err != nil {
		return "", nil, toolError(err)
	}
	raw, _, err := run(true)
	if err != nil {
		return "", nil, toolError(err)
	}
	return notes + text, json.RawMessage(strings.TrimSpace(raw)), nil
}

type listBandsArgs struct {
	Query string `json:"query,omitempty" jsonschema:"one frequency, preset or band name to look up, e.g. 146.52, wx3, 2m or noaa (default: the whole table)"`
}

func (srv *mcpServer) listBands(ctx context.Context, _ *mcp.CallToolRequest, in listBandsArgs) (*mcp.CallToolResult, any, error) {
	var args []string
	if in.Query != "" {
		args = []string{in.Query}
	}
	text, raw, err := srv.localVerb(ctx, newBandsCommand, args...)
	if err != nil {
		return nil, nil, err
	}
	return jsonResult(text, raw), nil, nil
}

func (srv *mcpServer) listPresets(ctx context.Context, _ *mcp.CallToolRequest, _ mcpNoArgs) (*mcp.CallToolResult, any, error) {
	text, raw, err := srv.localVerb(ctx, newPresetsCommand)
	if err != nil {
		return nil, nil, err
	}
	return jsonResult(text, raw), nil, nil
}

type helpArgs struct {
	Topic string `json:"topic,omitempty"`
}

// helpSchema names the topics in the topic field's description, from the table `ley help` reads.
func helpSchema() *jsonschema.Schema {
	sch, err := jsonschema.For[helpArgs](&jsonschema.ForOptions{})
	if err != nil {
		panic(fmt.Sprintf("mcp: the help schema: %v", err))
	}
	sch.Properties["topic"].Description = "the topic: " + strings.Join(topicNames(), ", ") + " (default: list them)"
	return sch
}

func topicNames() []string {
	names := make([]string, 0, len(topics))
	for _, t := range topics {
		names = append(names, t.name)
	}
	return names
}

// helpTopic is the help tool's JSON for one topic; the list is these without the text.
type helpTopic struct {
	Name    string `json:"name"`
	Summary string `json:"summary"`
	Text    string `json:"text,omitempty"`
}

func (srv *mcpServer) help(_ context.Context, _ *mcp.CallToolRequest, in helpArgs) (*mcp.CallToolResult, any, error) {
	if in.Topic == "" {
		list := make([]helpTopic, 0, len(topics))
		for _, t := range topics {
			list = append(list, helpTopic{Name: t.name, Summary: t.short})
		}
		raw, err := json.Marshal(map[string]any{"topics": list})
		if err != nil {
			return nil, nil, err
		}
		return jsonResult("Help topics (help with topic: <name>):\n"+topicList(), raw), nil, nil
	}
	t := topicByName(in.Topic)
	if t == nil {
		return nil, nil, fmt.Errorf("there is no help topic called %q; the topics are %s", in.Topic, strings.Join(topicNames(), ", "))
	}
	text := t.text()
	raw, err := json.Marshal(helpTopic{Name: t.name, Summary: t.short, Text: text})
	if err != nil {
		return nil, nil, err
	}
	return jsonResult(text, raw), nil, nil
}
