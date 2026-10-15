// SPDX-License-Identifier: Apache-2.0

package assistant

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"time"
)

// ScriptEnv names the file the Scripted model plays. When it is set, the worker plays the script
// whatever the provider, so every test of the loop runs without a key or a network.
const ScriptEnv = "LEY_ASSISTANT_SCRIPT"

// RecordEnv names a file the Scripted model appends what it is sent to: one JSON array of the
// messages per call, so a test can read the context a call carried.
const RecordEnv = "LEY_ASSISTANT_RECORD"

// scriptLine is one response in a script: text, a tool call, or both; sleep_ms delays it, so a
// test can stop a turn while the model is "thinking"; usage is what it reports.
type scriptLine struct {
	Text    string          `json:"text"`
	Tool    string          `json:"tool"`
	Args    json.RawMessage `json:"args"`
	SleepMs int             `json:"sleep_ms"`
	// StopReason overrides the stop reason, so a test can play a response cut at max_tokens.
	StopReason string `json:"stop_reason"`
	Usage      *Usage `json:"usage"`
}

// Scripted is the Model every test uses: a file of JSON lines, one response each, played in
// order across the whole conversation. Once the lines run out, every response is the text "done".
// A worker that resumes a conversation skips the lines its transcript already holds the
// responses of, so a conversation carried on across workers plays on through one script.
type Scripted struct {
	mu    sync.Mutex
	lines []scriptLine
	next  int
	// Record is the file each call's messages are appended to; empty records nothing.
	Record string
}

// Skip moves the script on past the first n lines.
func (s *Scripted) Skip(n int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.next = n
}

// LoadScript reads a script. A blank line is skipped; a line that is not JSON is refused with its
// number.
func LoadScript(path string) (*Scripted, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("the assistant script: %w", err)
	}
	s := &Scripted{}
	sc := bufio.NewScanner(bytes.NewReader(raw))
	sc.Buffer(make([]byte, 0, 64<<10), 4<<20)
	for n := 1; sc.Scan(); n++ {
		line := bytes.TrimSpace(sc.Bytes())
		if len(line) == 0 {
			continue
		}
		var l scriptLine
		if err := json.Unmarshal(line, &l); err != nil {
			return nil, fmt.Errorf("the assistant script %s, line %d: %w", path, n, err)
		}
		s.lines = append(s.lines, l)
	}
	return s, sc.Err()
}

// Respond plays the next line, after recording the messages it was sent.
func (s *Scripted) Respond(ctx context.Context, _ string, _ []ToolDef, messages []Message) (Response, error) {
	if err := s.record(messages); err != nil {
		return Response{}, err
	}
	s.mu.Lock()
	l := scriptLine{Text: "done"}
	n := s.next
	if n < len(s.lines) {
		l = s.lines[n]
	}
	s.next++
	s.mu.Unlock()
	if l.SleepMs > 0 {
		select {
		case <-ctx.Done():
			return Response{}, ctx.Err()
		case <-time.After(time.Duration(l.SleepMs) * time.Millisecond):
		}
	}
	resp := Response{StopReason: "end_turn"}
	if l.Usage != nil {
		resp.Usage = *l.Usage
	}
	if l.Text != "" {
		resp.Content = append(resp.Content, Block{Type: "text", Text: l.Text})
	}
	if l.Tool != "" {
		args := l.Args
		if len(args) == 0 {
			args = json.RawMessage("{}")
		}
		resp.Content = append(resp.Content, Block{Type: "tool_use", ID: fmt.Sprintf("toolu_s%d", n+1), Name: l.Tool, Input: args})
		resp.StopReason = "tool_use"
	}
	if l.StopReason != "" {
		resp.StopReason = l.StopReason
	}
	return resp, nil
}

// record appends the messages as one line to Record.
func (s *Scripted) record(messages []Message) error {
	if s.Record == "" {
		return nil
	}
	line, err := json.Marshal(messages)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(s.Record, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		return fmt.Errorf("the assistant record: %w", err)
	}
	_, err = f.Write(append(line, '\n'))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}
