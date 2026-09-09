package cli

import (
	"testing"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

// An Anchor event is the capture's sample-timebase bookkeeping. It reaches
// --json like every other event, but a person watching a live verb has
// nothing to do with it, so the live view drops it.
func TestHumanEventDropsAnchor(t *testing.T) {
	anchor := &leylinev1.Event{Body: &leylinev1.Event_Anchor{Anchor: &leylinev1.CaptureAnchor{CaptureId: "cap_x", SampleRate: 2400000}}}
	if humanEvent(anchor) {
		t.Error("an anchor event must not reach the live human view")
	}
	ch := &leylinev1.Event{Body: &leylinev1.Event_Channel{Channel: &leylinev1.Channel{ChannelId: "chan_x"}}}
	if !humanEvent(ch) {
		t.Error("a channel event is exactly what the live view is for")
	}
}
