// SPDX-License-Identifier: Apache-2.0

package session

import (
	"context"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

func captureEvent(seq uint64, c *leylinev1.Capture) *leylinev1.Event {
	return &leylinev1.Event{Seq: seq, Body: &leylinev1.Event_Capture{Capture: c}}
}

// TestApplySkipsWhatTheMirrorAlreadyHolds: an event at or below the newest seq folded is stale,
// a newer one replaces the object by id, and the tombstone (state unset) removes it.
func TestApplySkipsWhatTheMirrorAlreadyHolds(t *testing.T) {
	c := &leylinev1.Capture{CaptureId: "cap_1", CenterHz: 146_000_000, State: leylinev1.CaptureState_CAPTURE_ACTIVE}
	s := &Session{State: &leylinev1.GetStateResponse{EventSeq: 10, Captures: []*leylinev1.Capture{c}}, seq: 10}
	s.Capture = c

	moved := &leylinev1.Capture{CaptureId: "cap_1", CenterHz: 147_000_000, State: leylinev1.CaptureState_CAPTURE_ACTIVE}
	if s.Apply(captureEvent(10, moved)) {
		t.Fatal("an event at the snapshot's seq is already reflected and must be skipped")
	}
	if !s.Apply(captureEvent(11, moved)) || s.Capture.CenterHz != 147_000_000 || s.State.Captures[0].CenterHz != 147_000_000 {
		t.Fatalf("a newer event replaces the capture: tracked %v, mirror %v", s.Capture, s.State.Captures)
	}
	gone := &leylinev1.Capture{CaptureId: "cap_1"}
	if !s.Apply(captureEvent(12, gone)) || len(s.State.Captures) != 0 {
		t.Fatalf("the tombstone leaves the mirror: %v", s.State.Captures)
	}
	rejected := &leylinev1.Event{Seq: 1, Body: &leylinev1.Event_WriteRejected{WriteRejected: &leylinev1.WriteRejected{Tag: 1}}}
	if !s.Apply(rejected) {
		t.Fatal("a WriteRejected is not state and is never stale")
	}
}

// TestCleanupContextOutlivesItsParent: cleanup RPCs run after the run's context has ended.
func TestCleanupContextOutlivesItsParent(t *testing.T) {
	parent, cancel := context.WithCancel(t.Context())
	cancel()
	ctx, stop := CleanupContext(parent, ConfirmTimeout)
	defer stop()
	if ctx.Err() != nil {
		t.Fatalf("cleanup context is done with its parent: %v", ctx.Err())
	}
	if _, ok := ctx.Deadline(); !ok {
		t.Fatal("cleanup context has no deadline")
	}
}
