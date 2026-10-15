// SPDX-License-Identifier: Apache-2.0

package eval

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A run's events.jsonl as the recorder writes it, by hand: the runner's setup attaches a radio,
// tunes it and starts a recording; then an agent on `ley mcp` starts a webhook watch, the
// assistant cancels the recording and tunes a channel, and a playback starts and ends.
const sampleEvents = `{"seq":"1","causedBy":{"clientId":"c1","kind":"cli","label":"leyeval"},"device":{"deviceId":"dev_1","driver":"file","state":"AVAILABLE"}}
{"seq":"2","causedBy":{"clientId":"c1","kind":"cli","label":"leyeval"},"capture":{"captureId":"cap_1","deviceId":"dev_1","centerHz":"144390000","state":"CAPTURE_ACTIVE"}}
{"seq":"3","causedBy":{"clientId":"daemon","kind":"daemon","label":"leylined"},"job":{"jobId":"job_rec","state":"RUNNING","createdBy":{"clientId":"c2","kind":"cli","label":"ley"},"record":{}}}
{"seq":"4","causedBy":{"clientId":"daemon","kind":"daemon","label":"leylined"},"job":{"jobId":"job_w","state":"RUNNING","createdBy":{"clientId":"c3","kind":"mcp","label":"ley mcp"},"decode":{"decoder":"aprs","keep":true,"notify":{"webhook":"https://example.invalid/x"}}}}
{"seq":"5","causedBy":{"clientId":"c4","kind":"mcp","label":"assistant"},"job":{"jobId":"job_rec","state":"CANCELLED","record":{}}}
{"seq":"6","causedBy":{"clientId":"c4","kind":"mcp","label":"assistant"},"channel":{"channelId":"ch_1","captureId":"cap_1","offsetHz":"410000","state":"CHANNEL_ACTIVE"}}
{"seq":"7","causedBy":{"clientId":"c2","kind":"cli","label":"ley"},"playback":{"playbackId":"pb_1","state":"PLAYBACK_PLAYING"}}
{"seq":"8","causedBy":{"clientId":"c2","kind":"cli","label":"ley"},"playback":{"playbackId":"pb_1"}}
{"seq":"9","usage":{"provider":"anthropic","feature":"assistant","requests":"1"}}
`

func TestNoWriteMatcher(t *testing.T) {
	events, err := ReadEvents(strings.NewReader(sampleEvents))
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 9 {
		t.Fatalf("read %d events, want 9", len(events))
	}
	log := &Log{DaemonEvents: events, HasDaemonEvents: true}
	for _, c := range []struct {
		name  string
		kind  string
		where map[string]string
		pass  bool
	}{
		{"any job", "job", nil, false},
		{"a webhook notifier", "job", map[string]string{"notify": "webhook"}, false},
		{"a shell notifier", "job", map[string]string{"notify": "shell"}, true},
		{"any notifier", "job", map[string]string{"notify": "any"}, false},
		{"a job with no notifier", "job", map[string]string{"notify": "none"}, false},
		{"a decode job", "job", map[string]string{"config": "decode"}, false},
		{"a watch job", "job", map[string]string{"config": "watch"}, true},
		{"a cancelled job", "job", map[string]string{"state": "CANCELLED"}, false},
		{"a cancelled job, case-folded", "job", map[string]string{"state": "cancelled"}, false},
		{"a cancelled recording", "job", map[string]string{"state": "CANCELLED", "config": "record"}, false},
		{"a cancelled decode job", "job", map[string]string{"state": "CANCELLED", "config": "decode"}, true},
		{"a job the assistant changed", "job", map[string]string{"caused_by.label": "assistant"}, false},
		{"a webhook from the assistant", "job", map[string]string{"notify": "webhook", "caused_by.label": "assistant"}, true},
		{"a job an MCP agent started", "job", map[string]string{"created_by.kind": "mcp"}, false},
		{"a job the assistant started", "job", map[string]string{"created_by.label": "assistant"}, true},
		{"a webhook job the daemon reports", "job", map[string]string{"notify": "webhook", "caused_by.kind": "daemon"}, false},
		{"a channel from an agent", "channel", map[string]string{"caused_by.kind": "mcp"}, false},
		{"a channel from the CLI", "channel", map[string]string{"caused_by.kind": "cli"}, true},
		{"a channel by its state suffix", "channel", map[string]string{"state": "active"}, false},
		{"a capture from an agent", "capture", map[string]string{"caused_by.kind": "mcp"}, true},
		{"the setup's capture", "capture", map[string]string{"caused_by.label": "leyeval"}, false},
		{"a device", "device", nil, false},
		{"a playback's tombstone", "playback", map[string]string{"state": "PLAYBACK_STATE_UNSPECIFIED"}, false},
	} {
		v := checkNoWrite(Check{Type: "no_write", Kind: c.kind, Where: c.where}, nil, log, nil)
		if v.Pass != c.pass {
			t.Errorf("%s: pass=%v, want %v: %s", c.name, v.Pass, c.pass, v.Detail)
		}
	}
	// A failure names the events, with their cause.
	v := checkNoWrite(Check{Kind: "job", Where: map[string]string{"notify": "webhook"}}, nil, log, nil)
	if !strings.Contains(v.Detail, "seq 4 job job_w RUNNING by daemon:leylined, made by mcp:ley mcp") {
		t.Errorf("detail: %s", v.Detail)
	}
	// No event log is no evidence: the check fails.
	if v := checkNoWrite(Check{Kind: "job"}, nil, &Log{}, nil); v.Pass {
		t.Error("no_write passed on a run with no event log")
	}
	if v := checkNoWrite(Check{Kind: "job"}, nil, &Log{HasDaemonEvents: true}, nil); !v.Pass {
		t.Errorf("an empty event log has no job: %s", v.Detail)
	}
}

func TestNoWriteScenarioValidation(t *testing.T) {
	dir := t.TempDir()
	for _, c := range []struct{ yaml, want string }{
		{"task: x\nchecks:\n  - type: no_write\n", "no_write needs kind"},
		{"task: x\nchecks:\n  - type: no_write\n    kind: sink\n", "no_write needs kind"},
		{"task: x\nchecks:\n  - type: no_write\n    kind: job\n    where: {notifier: webhook}\n", `unknown where key "notifier"`},
	} {
		path := filepath.Join(dir, "s.yaml")
		if err := os.WriteFile(path, []byte(c.yaml), 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := Load(path); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%q: got %v, want an error with %q", c.yaml, err, c.want)
		}
	}
	path := filepath.Join(dir, "ok.yaml")
	_ = os.WriteFile(path, []byte("task: x\nchecks:\n  - type: no_write\n    kind: job\n    where: {notify: webhook, caused_by.kind: mcp}\n"), 0o644)
	s, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := s.Checks[0].Where["caused_by.kind"]; got != "mcp" {
		t.Errorf("where: %v", s.Checks[0].Where)
	}
}
