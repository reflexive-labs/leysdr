// SPDX-License-Identifier: Apache-2.0

package assistant

import (
	"encoding/json"
	"fmt"
	"strings"
)

// The policy gate decides, before each tool call, whether it runs or waits for the user
// (docs/design/ai.md, "What the assistant may do"). Reads run; a change the user asked for runs
// and is reported; the rows below ask first, and the reason names what will happen. A tool the
// policy never allows (the shell notifier, a key) is not in the model's list at all: the watch
// tool refuses a shell notifier for every agent.

// Policy is the gate's memory: what this conversation started, the last don't-disturb refusal,
// and what the running turn has done.
type Policy struct {
	// ownJobs is every job a call in this conversation started, so cancelling one of them runs.
	ownJobs map[string]bool
	// lastRefusal is the newest refusal that offered take_over, which names who would be
	// silenced.
	lastRefusal string
	// readReceived is set once the conversation has read text received over the air, and stays
	// set: what the model read in one turn is still in its context in the next.
	readReceived bool
	// bookmarkWrites counts the bookmark changes that ran this turn.
	bookmarkWrites int
	// ResolveDecoder turns a decoder name or alias into the decoder's own name, so an alias of
	// the speech decoder is gated as speech. nil leaves names as given.
	ResolveDecoder func(name string) (string, error)
}

// ReceivedReason is the reason every write asks with once the conversation has read received
// text.
const ReceivedReason = "the assistant read text received over the air earlier in this conversation"

// SpeechDecoder is the decoder whose jobs send audio to a paid provider.
const SpeechDecoder = "speech"

// receivedTools return records, whose fields are whatever a transmitter put in them.
var receivedTools = map[string]bool{"query_records": true, "list_entities": true}

// NewPolicy is a gate for a new conversation.
func NewPolicy() *Policy { return &Policy{ownJobs: map[string]bool{}} }

// BeginTurn forgets what the last turn wrote. Received text is not forgotten.
func (p *Policy) BeginTurn() {
	p.bookmarkWrites = 0
}

// Received marks the conversation as having read text it cannot trust: records, or a view
// tool's answer, which may carry decoded text the client shows.
func (p *Policy) Received() { p.readReceived = true }

// row is one policy row: when it asks, and the reason in words.
type row struct {
	name   string
	reason func(p *Policy, tool string, args map[string]any) (string, bool)
}

// rows is the table, in the order the reasons are listed when several apply.
var rows = []row{
	{"take over a radio", func(p *Policy, tool string, args map[string]any) (string, bool) {
		if !boolArg(args, "take_over") {
			return "", false
		}
		return fmt.Sprintf("another channel or client is using the radio: %s; %s with take_over takes it from them", p.whoIsListening(), tool), true
	}},
	{"start a kept job", func(_ *Policy, tool string, args map[string]any) (string, bool) {
		switch tool {
		case "watch", "start_decode_job", "record":
		default:
			return "", false
		}
		if !boolArg(args, "keep") {
			return "", false
		}
		what := strArg(args, "decoder")
		if what == "" {
			what = tool
		}
		return fmt.Sprintf("start a kept %s job that runs on after this conversation ends, until it is cancelled", what), true
	}},
	{"add a webhook notifier", func(_ *Policy, _ string, args map[string]any) (string, bool) {
		n := strings.TrimSpace(strArg(args, "notify"))
		if !strings.HasPrefix(strings.ToLower(n), "webhook:") {
			return "", false
		}
		return fmt.Sprintf("add a webhook notifier: every matching record is sent to %s", strings.TrimSpace(n[len("webhook:"):])), true
	}},
	{"delete a recording", func(_ *Policy, tool string, args map[string]any) (string, bool) {
		if tool != "delete_recording" {
			return "", false
		}
		return fmt.Sprintf("delete the recording %s and its files; this cannot be undone", strArg(args, "recording")), true
	}},
	{"remove a bookmark", func(_ *Policy, tool string, args map[string]any) (string, bool) {
		if tool != "remove_bookmark" {
			return "", false
		}
		return fmt.Sprintf("remove the bookmark %q from your bookmarks", strArg(args, "bookmark")), true
	}},
	{"cancel another client's job", func(p *Policy, tool string, args map[string]any) (string, bool) {
		if tool != "cancel_job" || p.ownJobs[strArg(args, "job")] {
			return "", false
		}
		return fmt.Sprintf("cancel %s, a job the assistant did not start", strArg(args, "job")), true
	}},
	{"import a CHIRP file", func(_ *Policy, tool string, args map[string]any) (string, bool) {
		if tool != "import_chirp" || boolArg(args, "dry_run") {
			return "", false
		}
		return fmt.Sprintf("import every channel in %s into your bookmarks (dry_run would list them first)", strArg(args, "path")), true
	}},
	{"several bookmarks", func(p *Policy, tool string, args map[string]any) (string, bool) {
		if tool != "add_bookmark" || p.bookmarkWrites < 2 {
			return "", false
		}
		return fmt.Sprintf("a third bookmark change this turn: add %q at %s", strArg(args, "name"), strArg(args, "frequency")), true
	}},
	{"paid transcription", func(p *Policy, tool string, args map[string]any) (string, bool) {
		if tool != "start_decode_job" && tool != "watch" {
			return "", false
		}
		name := strArg(args, "decoder")
		canonical, err := p.decoder(name)
		if err != nil {
			// Fail closed: a name that cannot be checked may be the speech decoder's alias.
			return fmt.Sprintf("the assistant could not check whether %q is paid transcription: %v", name, err), true
		}
		if !strings.EqualFold(canonical, SpeechDecoder) {
			return "", false
		}
		// The tools take no recording source, so a speech job here is live: what it sends
		// depends on how often the squelch opens, and it runs until it is stopped.
		return "start paid transcription, live and unbounded: every over the channel hears is sent to the speech provider until the job stops", true
	}},
}

// decoder is the decoder's own name for a name or alias.
func (p *Policy) decoder(name string) (string, error) {
	if p.ResolveDecoder == nil || name == "" {
		return name, nil
	}
	return p.ResolveDecoder(name)
}

// Check is the gate for one call. An empty reason runs it; otherwise the call waits for the user,
// and the reason lists every row that applies. isWrite comes from the tool's annotations.
func (p *Policy) Check(tool string, args map[string]any, isWrite bool) string {
	var reasons []string
	for _, r := range rows {
		if reason, asks := r.reason(p, tool, args); asks {
			reasons = append(reasons, reason)
		}
	}
	if p.readReceived && isWrite {
		reasons = append(reasons, ReceivedReason)
	}
	return strings.Join(reasons, "; ")
}

// Ran updates the gate after a call ran (refused calls are not passed): bookmark changes, the jobs
// this conversation owns, a refusal that names who is listening, and received text.
func (p *Policy) Ran(tool string, args map[string]any, res Result) {
	if res.IsError {
		if strings.Contains(res.Text, "take_over") {
			p.lastRefusal = res.Text
		}
		return
	}
	// A refusal names who was listening then; after any call that worked, the radio may have
	// changed hands, so a later take_over must not name them.
	p.lastRefusal = ""
	switch tool {
	case "add_bookmark", "remove_bookmark":
		p.bookmarkWrites++
	case "import_chirp":
		if !boolArg(args, "dry_run") {
			p.bookmarkWrites++
		}
	}
	if id := jobID(res.JSON); id != "" {
		switch tool {
		case "start_decode_job", "watch", "scan", "record":
			p.ownJobs[id] = true
		}
	}
	if receivedTools[tool] || hasRecords(res.JSON) {
		p.readReceived = true
	}
}

// IsReceived reports whether a result carries text received over the air.
func IsReceived(tool string, res Result) bool {
	return !res.IsError && (receivedTools[tool] || hasRecords(res.JSON))
}

// whoIsListening is the part of the last refusal that names the channels and clients, without the
// remedy it ends with.
func (p *Policy) whoIsListening() string {
	text := strings.TrimSpace(p.lastRefusal)
	if text == "" {
		return "the assistant did not try without take_over first, so who is listening is not known"
	}
	for _, cut := range []string{"Call again", "take_over"} {
		if i := strings.Index(text, cut); i > 0 {
			text = text[:i]
		}
	}
	return strings.TrimRight(strings.TrimSpace(text), ".")
}

// jobID is a result's top-level jobId, the job a call started.
func jobID(raw string) string {
	var j struct {
		JobID string `json:"jobId"`
	}
	if json.Unmarshal([]byte(raw), &j) != nil {
		return ""
	}
	return j.JobID
}

// hasRecords reports a RecordPage-shaped result: decoded records under a top-level "records".
func hasRecords(raw string) bool {
	var page map[string]json.RawMessage
	if json.Unmarshal([]byte(raw), &page) != nil {
		return false
	}
	_, ok := page["records"]
	return ok
}

func boolArg(args map[string]any, key string) bool {
	b, _ := args[key].(bool)
	return b
}

func strArg(args map[string]any, key string) string {
	switch v := args[key].(type) {
	case string:
		return v
	case nil:
		return ""
	default:
		return fmt.Sprint(v)
	}
}
