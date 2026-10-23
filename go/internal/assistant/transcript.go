// SPDX-License-Identifier: Apache-2.0

package assistant

import (
	"bytes"
	"encoding/json"
	"os"
	"strings"
)

// The worker's model transcript on disk (WorkerStart.transcript_path): one Message per line as
// JSON, appended as the conversation goes, so a worker the daemon starts again for the same
// conversation (after the idle sweep stopped the last one, or after a restart) gives the model the
// exact context it had. Only the worker reads it. The daemon names the file, in a directory only
// the user can read, and the worker creates it 0600.
//
// A message the loop extends in memory (the user's text after a turn's tool results) is written
// as a second line with the same role, and a load joins them back. A line cut short by a crash is
// skipped.
//
// The user's grants for the rest of the conversation are kept in the same file, one line each
// with the role "grant", which is never a message: a load hands them to the gate and leaves them
// out of what the model is sent. The transcript is where a resumed worker already looks, it goes
// with the conversation when the daemon removes it, and the append below already keeps a line
// whole, so a grant needs no file or format of its own.

// redactedKey stands in for the key wherever a line would have carried it.
const redactedKey = "[key]"

// cutShortResult is what the model is told of a call the transcript holds no result for: the
// worker that made it was stopped before the call finished.
const cutShortResult = "the conversation was interrupted before this call finished"

// GrantRole is the role of a transcript line that holds a grant rather than a message.
const GrantRole = "grant"

// grantLine is a grant as the transcript keeps it.
type grantLine struct {
	Role  string `json:"role"`
	Grant Grant  `json:"grant"`
}

// AppendGrant adds g to the transcript at path as one line.
func AppendGrant(path string, g Grant) error {
	line, err := json.Marshal(grantLine{Role: GrantRole, Grant: g})
	if err != nil {
		return err
	}
	return appendLine(path, line)
}

// AppendTranscript adds m to the transcript at path as one line, with secret, as it stands and
// JSON-escaped, replaced.
func AppendTranscript(path string, m Message, secret string) error {
	line, err := json.Marshal(m)
	if err != nil {
		return err
	}
	if secret != "" {
		line = bytes.ReplaceAll(line, []byte(secret), []byte(redactedKey))
		if escaped, err := json.Marshal(secret); err == nil {
			line = bytes.ReplaceAll(line, escaped[1:len(escaped)-1], []byte(redactedKey))
		}
	}
	return appendLine(path, line)
}

// appendLine adds one line to the file at path, creating it 0600.
func appendLine(path string, line []byte) error {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		return err
	}
	// A line a crash left torn has no newline; without one first, this line would join it and be
	// skipped with it on the next load.
	if fi, err := f.Stat(); err == nil && fi.Size() > 0 {
		last := make([]byte, 1)
		if _, err := f.ReadAt(last, fi.Size()-1); err == nil && last[0] != '\n' {
			line = append([]byte{'\n'}, line...)
		}
	}
	// One write, so a crash leaves at most this line torn.
	_, werr := f.Write(append(line, '\n'))
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	return werr
}

// LoadTranscript reads the transcript at path as the model is to be sent it: consecutive lines of
// one role joined, anything before the first user message dropped, and a tool call left without
// its result given one that says it was cut short, since the Messages API refuses a tool_use with
// no tool_result after it. skipped counts the lines that were neither a message nor a grant.
func LoadTranscript(path string) (messages []Message, skipped int, err error) {
	messages, _, skipped, err = loadTranscript(path)
	return messages, skipped, err
}

// loadTranscript is LoadTranscript, and the grants the file holds, in the order they were made.
func loadTranscript(path string) (messages []Message, grants []Grant, skipped int, err error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, 0, err
	}
	for _, line := range bytes.Split(raw, []byte("\n")) {
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		var m struct {
			Message
			Grant *Grant `json:"grant"`
		}
		if json.Unmarshal(line, &m) != nil {
			skipped++
			continue
		}
		if m.Role == GrantRole && m.Grant != nil && m.Grant.CallID != "" {
			grants = append(grants, *m.Grant)
			continue
		}
		if (m.Role != "user" && m.Role != "assistant") || len(m.Content) == 0 {
			skipped++
			continue
		}
		if len(messages) == 0 && m.Role != "user" {
			skipped++
			continue
		}
		if n := len(messages); n > 0 && messages[n-1].Role == m.Role {
			messages[n-1].Content = append(messages[n-1].Content, m.Content...)
			continue
		}
		messages = append(messages, m.Message)
	}
	return answerDanglingCalls(messages), grants, skipped, nil
}

// answerDanglingCalls gives every tool_use a tool_result in the user message after it, adding the
// message when there is none. The results go first in that message, as the API wants them.
func answerDanglingCalls(messages []Message) []Message {
	for i := 0; i < len(messages); i++ {
		if messages[i].Role != "assistant" {
			continue
		}
		answered := map[string]bool{}
		if i+1 < len(messages) {
			for _, b := range messages[i+1].Content {
				if b.Type == "tool_result" {
					answered[b.ToolUseID] = true
				}
			}
		}
		var missing []Block
		for _, b := range messages[i].Content {
			if b.Type == "tool_use" && !answered[b.ID] {
				missing = append(missing, Block{Type: "tool_result", ToolUseID: b.ID, Content: cutShortResult, IsError: true})
			}
		}
		if len(missing) == 0 {
			continue
		}
		if i+1 < len(messages) {
			messages[i+1].Content = append(missing, messages[i+1].Content...)
			continue
		}
		messages = append(messages, Message{Role: "user", Content: missing})
	}
	return messages
}

// resume loads the transcript a worker before this one kept, and takes up what it implies: the
// call numbering, the received-text taint, the user's grants, and where a scripted model's lines
// go on from. A file that is missing or unreadable is logged and the conversation goes on from an
// empty transcript and no grants.
func (w *worker) resume() {
	path := w.start.GetTranscriptPath()
	if path == "" {
		w.logf("told to resume with no transcript path; starting from an empty transcript")
		return
	}
	messages, grants, skipped, err := loadTranscript(path)
	if err != nil {
		w.logf("cannot read the transcript (%v); starting from an empty one", err)
		return
	}
	for _, g := range grants {
		w.policy.Grant(g)
	}
	if skipped > 0 {
		w.logf("skipped %d unreadable lines of %s", skipped, path)
	}
	w.transcript = messages
	responses := 0
	for _, m := range messages {
		if m.Role == "assistant" {
			responses++
		}
		for _, b := range m.Content {
			switch {
			case b.Type == "tool_use":
				w.calls++
			case b.Type == "tool_result" && strings.HasPrefix(b.Content, ReceivedPrefix):
				w.policy.Received()
			}
		}
	}
	if s, ok := w.model.(interface{ Skip(int) }); ok {
		s.Skip(responses)
	}
	w.logf("resumed from %d messages, %d of them the model's, and %d grants", len(messages), responses, len(grants))
}

// recordGrant keeps g in the transcript file, so a worker started later for the conversation
// holds it too.
func (w *worker) recordGrant(g Grant) {
	path := w.start.GetTranscriptPath()
	if path == "" {
		return
	}
	if err := AppendGrant(path, g); err != nil {
		// The grant holds for this worker; a later one would ask again.
		w.logf("cannot keep the grant from %s in the transcript: %v", g.CallID, err)
	}
}

// record adds m to the transcript in memory, joining the last message when both are the user's
// (a turn stopped before the model answered leaves one), and appends it to the file.
func (w *worker) record(m Message) {
	if n := len(w.transcript); n > 0 && m.Role == "user" && w.transcript[n-1].Role == "user" {
		w.transcript[n-1].Content = append(w.transcript[n-1].Content, m.Content...)
	} else {
		w.transcript = append(w.transcript, m)
	}
	path := w.start.GetTranscriptPath()
	if path == "" {
		return
	}
	if err := AppendTranscript(path, m, w.secret); err != nil && !w.transcriptFailed {
		// Once: the conversation goes on, and only a later worker would miss the context.
		w.transcriptFailed = true
		w.logf("cannot append to the transcript: %v", err)
	}
}
