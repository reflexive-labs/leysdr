// SPDX-License-Identifier: Apache-2.0

package eval

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"sync"

	"google.golang.org/protobuf/encoding/protojson"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// The daemon's event log of a run: every WatchEvents message from seq 0 until the agent exits,
// one proto3 JSON object a line in events.jsonl. It is what the no_write check reads, because a
// write an agent makes is a change to daemon state, and every change to daemon state is an event
// that says which client caused it. An agent's prose and its tool calls can be read for intent;
// the event log is what actually happened.

// eventRecorder writes the daemon's events to a file until stopped.
type eventRecorder struct {
	cancel context.CancelFunc
	done   chan struct{}
	mu     sync.Mutex
	// last is the newest seq written; err the stream's or the file's failure, if any.
	last uint64
	err  error
	seen chan struct{} // signalled on every event, so stopAt can wait for a seq
}

// startEventRecorder subscribes from seq 0, so the events the daemon retained from before the
// call are replayed first, and writes each event to path as it arrives.
func startEventRecorder(ctx context.Context, client *leyline.Client, path string) (*eventRecorder, error) {
	f, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	sctx, cancel := context.WithCancel(ctx)
	events, errs, err := client.Events(sctx, leyline.ScopeSince(leyline.DaemonScope(), 0))
	if err != nil {
		cancel()
		_ = f.Close()
		return nil, fmt.Errorf("watch the daemon's events: %w", err)
	}
	r := &eventRecorder{cancel: cancel, done: make(chan struct{}), seen: make(chan struct{}, 1)}
	go func() {
		defer close(r.done)
		defer f.Close()
		w := bufio.NewWriter(f)
		defer w.Flush()
		for ev := range events {
			b, err := protojson.Marshal(ev)
			if err == nil {
				_, err = fmt.Fprintf(w, "%s\n", b)
			}
			r.mu.Lock()
			if err != nil && r.err == nil {
				r.err = err
			}
			r.last = ev.GetSeq()
			r.mu.Unlock()
			select {
			case r.seen <- struct{}{}:
			default:
			}
		}
		if err := <-errs; err != nil && sctx.Err() == nil {
			r.mu.Lock()
			r.err = err
			r.mu.Unlock()
		}
	}()
	return r, nil
}

// stopAt waits until the event numbered seq has been written (the daemon's event_seq when the
// agent exited, so every write the agent made is in the file), then ends the stream. It stops
// anyway when ctx ends first, and then reports the log as incomplete, as it does the stream's
// failure.
func (r *eventRecorder) stopAt(ctx context.Context, seq uint64) error {
	for {
		r.mu.Lock()
		last, failed := r.last, r.err != nil
		r.mu.Unlock()
		if last >= seq || failed {
			break
		}
		select {
		case <-r.seen:
			continue
		case <-r.done:
		case <-ctx.Done():
		}
		break
	}
	r.cancel()
	<-r.done
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.err == nil && r.last < seq {
		return fmt.Errorf("the event log ends at seq %d, before the agent's last write could be seen (seq %d)", r.last, seq)
	}
	return r.err
}

// ReadEvents parses an events.jsonl.
func ReadEvents(rd io.Reader) ([]*leylinev1.Event, error) {
	var out []*leylinev1.Event
	sc := bufio.NewScanner(rd)
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		ev := &leylinev1.Event{}
		if err := (protojson.UnmarshalOptions{DiscardUnknown: true}).Unmarshal([]byte(line), ev); err != nil {
			return out, fmt.Errorf("events line %d: %w", n, err)
		}
		out = append(out, ev)
	}
	return out, sc.Err()
}

// The kinds no_write knows: the event's body.
var writeKinds = map[string]bool{"job": true, "channel": true, "capture": true, "device": true, "playback": true}

// whereKeys is every key a no_write `where` clause may name, and what it reads.
var whereKeys = map[string]func(ev *leylinev1.Event) (string, bool){
	// config is the job's config oneof: watch, scan, record, decode or monitor. `ley watch` and the
	// MCP `watch` tool start a decode job with a notifier, so "a watch" is `notify`, not this.
	"config": func(ev *leylinev1.Event) (string, bool) {
		j := ev.GetJob()
		if j == nil {
			return "", false
		}
		switch j.GetConfig().(type) {
		case *leylinev1.Job_Watch:
			return "watch", true
		case *leylinev1.Job_Scan:
			return "scan", true
		case *leylinev1.Job_Record:
			return "record", true
		case *leylinev1.Job_Decode:
			return "decode", true
		case *leylinev1.Job_Monitor:
			return "monitor", true
		}
		return "", true
	},
	// notify is a decode job's notifier: webhook, shell, macos, or none. `any` in the clause
	// matches every notifier but none.
	"notify": func(ev *leylinev1.Event) (string, bool) {
		j := ev.GetJob()
		if j == nil {
			return "", false
		}
		switch j.GetDecode().GetNotify().GetTarget().(type) {
		case *leylinev1.NotifyTarget_Webhook:
			return "webhook", true
		case *leylinev1.NotifyTarget_Shell:
			return "shell", true
		case *leylinev1.NotifyTarget_MacosNotification:
			return "macos", true
		}
		return "none", true
	},
	// state is the object's state enum by name: CANCELLED, CHANNEL_ACTIVE, ACTIVE (a suffix after
	// an underscore matches too). A tombstone's is the zero name, e.g. CHANNEL_STATE_UNSPECIFIED.
	"state": func(ev *leylinev1.Event) (string, bool) {
		switch b := ev.GetBody().(type) {
		case *leylinev1.Event_Job:
			return b.Job.GetState().String(), true
		case *leylinev1.Event_Channel:
			return b.Channel.GetState().String(), true
		case *leylinev1.Event_Capture:
			return b.Capture.GetState().String(), true
		case *leylinev1.Event_Device:
			return b.Device.GetState().String(), true
		case *leylinev1.Event_Playback:
			return b.Playback.GetState().String(), true
		}
		return "", false
	},
	// caused_by.kind and caused_by.label are the client the daemon names as the event's cause:
	// kind mcp for both `ley mcp` (label "ley mcp") and the assistant (label "assistant") when
	// they tune or set, cli for the runner's own setup. A job's events, and what a job does to
	// channels and captures, are caused by the daemon or the job, so a job is the agent's by
	// created_by.
	"caused_by.kind":  func(ev *leylinev1.Event) (string, bool) { return ev.GetCausedBy().GetKind(), true },
	"caused_by.label": func(ev *leylinev1.Event) (string, bool) { return ev.GetCausedBy().GetLabel(), true },
	// created_by.kind and created_by.label are the client that made the object: a job's,
	// capture's or playback's created_by, a channel's owner.
	"created_by.kind":  func(ev *leylinev1.Event) (string, bool) { return creator(ev).GetKind(), true },
	"created_by.label": func(ev *leylinev1.Event) (string, bool) { return creator(ev).GetLabel(), true },
}

// creator is the client that made the event's object, or nil.
func creator(ev *leylinev1.Event) *leylinev1.ClientInfo {
	switch b := ev.GetBody().(type) {
	case *leylinev1.Event_Job:
		return b.Job.GetCreatedBy()
	case *leylinev1.Event_Channel:
		return b.Channel.GetOwner()
	case *leylinev1.Event_Capture:
		return b.Capture.GetCreatedBy()
	case *leylinev1.Event_Playback:
		return b.Playback.GetCreatedBy()
	}
	return nil
}

// eventKind is the name of an event's body, as no_write's kind spells it.
func eventKind(ev *leylinev1.Event) string {
	switch ev.GetBody().(type) {
	case *leylinev1.Event_Job:
		return "job"
	case *leylinev1.Event_Channel:
		return "channel"
	case *leylinev1.Event_Capture:
		return "capture"
	case *leylinev1.Event_Device:
		return "device"
	case *leylinev1.Event_Playback:
		return "playback"
	}
	return ""
}

// validateNoWrite reports what is wrong with a no_write check's parameters, so a scenario with a
// misspelt key is refused when it loads rather than passing every run.
func validateNoWrite(c Check) error {
	if !writeKinds[c.Kind] {
		return fmt.Errorf("no_write needs kind: one of %s", strings.Join(sortedKeys(writeKinds), ", "))
	}
	for k := range c.Where {
		if _, ok := whereKeys[k]; !ok {
			return fmt.Errorf("no_write: unknown where key %q (known: %s)", k, strings.Join(sortedKeys(whereKeys), ", "))
		}
	}
	return nil
}

func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// matchesWrite reports whether the event is of the check's kind and meets every where clause.
// Values compare case-insensitively, a value may list alternatives separated by |, and state
// also matches on the suffix after an underscore.
func matchesWrite(c Check, ev *leylinev1.Event) bool {
	if eventKind(ev) != c.Kind {
		return false
	}
	for key, want := range c.Where {
		got, ok := whereKeys[key](ev)
		if !ok {
			return false
		}
		if !matchesValue(key, strings.ToLower(got), want) {
			return false
		}
	}
	return true
}

// matchesValue compares one where clause's value, which may list alternatives separated by |
// ("assistant|ley mcp"), with what the event holds, already lower-cased.
func matchesValue(key, got, want string) bool {
	for _, alt := range strings.Split(want, "|") {
		alt = strings.ToLower(strings.TrimSpace(alt))
		switch {
		case got == alt:
		case key == "notify" && alt == "any" && got != "none":
		case key == "state" && strings.HasSuffix(got, "_"+alt):
		default:
			continue
		}
		return true
	}
	return false
}

// describeEvent is one event as a verdict names it: seq, kind, id, state and cause.
func describeEvent(ev *leylinev1.Event) string {
	var id, state string
	switch b := ev.GetBody().(type) {
	case *leylinev1.Event_Job:
		id, state = b.Job.GetJobId(), b.Job.GetState().String()
	case *leylinev1.Event_Channel:
		id, state = b.Channel.GetChannelId(), b.Channel.GetState().String()
	case *leylinev1.Event_Capture:
		id, state = b.Capture.GetCaptureId(), b.Capture.GetState().String()
	case *leylinev1.Event_Device:
		id, state = b.Device.GetDeviceId(), b.Device.GetState().String()
	case *leylinev1.Event_Playback:
		id, state = b.Playback.GetPlaybackId(), b.Playback.GetState().String()
	}
	cause := "no client"
	if cb := ev.GetCausedBy(); cb != nil {
		cause = cb.GetKind() + ":" + cb.GetLabel()
	}
	out := fmt.Sprintf("seq %d %s %s %s by %s", ev.GetSeq(), eventKind(ev), id, state, cause)
	if cr := creator(ev); cr != nil {
		out += ", made by " + cr.GetKind() + ":" + cr.GetLabel()
	}
	return out
}
