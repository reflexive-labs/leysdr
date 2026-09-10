package cli

import (
	"math"
	"strings"
	"testing"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"google.golang.org/protobuf/proto"
)

const (
	otherCap  = "cap_TEST"
	otherChan = "chan_TEST"
	otherSink = "sink_TEST"
	otherDev  = "dev_TEST"
)

// liveSession is a session mid-listen: our own capture, channel and sink, with
// the mirror holding all three.
func liveSession() *session {
	cap := &leylinev1.Capture{
		CaptureId: otherCap, DeviceId: otherDev, CenterHz: 146_620_000, SampleRate: 2_400_000,
		State: leylinev1.CaptureState_CAPTURE_ACTIVE,
		Gains: []*leylinev1.GainState{{Element: "TUNER", Auto: true}},
	}
	ch := &leylinev1.Channel{
		ChannelId: otherChan, CaptureId: otherCap, OffsetHz: 0, BandwidthHz: 12500,
		Mode: leylinev1.DemodMode_NFM, SquelchDb: -31, State: leylinev1.ChannelState_CHANNEL_ACTIVE,
	}
	sk := &leylinev1.Sink{
		SinkId: otherSink, ChannelId: otherChan, State: leylinev1.SinkState_SINK_ACTIVE,
		Kind: &leylinev1.Sink_SystemAudio{SystemAudio: &leylinev1.SystemAudioSink{Volume: proto.Float64(1)}},
	}
	dev := &leylinev1.DeviceDescriptor{DeviceId: otherDev, Model: "R820T", State: leylinev1.DeviceState_IN_USE}
	st := ui.Style{}
	return &session{
		app:     &App{Style: st, ErrStyle: st},
		state:   &leylinev1.GetStateResponse{Devices: []*leylinev1.DeviceDescriptor{dev}, Captures: []*leylinev1.Capture{cap}, Channels: []*leylinev1.Channel{ch}, Sinks: []*leylinev1.Sink{sk}},
		capture: cap, channel: ch, sink: sk, device: dev,
	}
}

func byCLI() *leylinev1.ClientInfo {
	return &leylinev1.ClientInfo{ClientId: "cli_OTHER", Kind: "cli", Label: "ley"}
}

// say folds an event the way live() does -- previous copy first, then apply --
// and returns the sentence and whether the session must end.
func say(t *testing.T, s *session, body any) (string, bool) {
	t.Helper()
	ev := &leylinev1.Event{Seq: s.seq + 1, CausedBy: byCLI()}
	switch b := body.(type) {
	case *leylinev1.Capture:
		ev.Body = &leylinev1.Event_Capture{Capture: b}
	case *leylinev1.Channel:
		ev.Body = &leylinev1.Event_Channel{Channel: b}
	case *leylinev1.Sink:
		ev.Body = &leylinev1.Event_Sink{Sink: b}
	case *leylinev1.DeviceDescriptor:
		ev.Body = &leylinev1.Event_Device{Device: b}
	default:
		t.Fatalf("unhandled body %T", body)
	}
	before := s.beforeEvent(ev)
	if !s.apply(ev) {
		t.Fatal("event was not folded")
	}
	return s.changeLine(before, ev)
}

// clone copies an object so a test can change one field of it.
func clone[T proto.Message](m T) T { return proto.Clone(m).(T) }

// The papercut itself: every interactive write in any terminal stamps the
// capture's don't-disturb clock, so a 'ley set mode am' three rooms away used
// to print a full capture dump alongside the channel one.
func TestAnActivityStampSaysNothing(t *testing.T) {
	s := liveSession()
	c := clone(s.capture)
	c.Activity = &leylinev1.CaptureActivity{LastInteractiveWriteNs: 1234, LiveAudioSinks: 1}
	if line, _ := say(t, s, c); line != "" {
		t.Errorf("a listener cannot act on an activity clock: %q", line)
	}
}

func TestCaptureChangesThatMatter(t *testing.T) {
	for _, tc := range []struct {
		name string
		edit func(*leylinev1.Capture)
		want string
	}{
		{"retune", func(c *leylinev1.Capture) { c.CenterHz = 146_700_000 }, "another terminal retuned the radio to 146.700 MHz"},
		{"rate", func(c *leylinev1.Capture) { c.SampleRate = 1_024_000 }, "another terminal set the sample rate to 1.024 MHz"},
		{"gain", func(c *leylinev1.Capture) { c.Gains = []*leylinev1.GainState{{Element: "TUNER", Db: 30.0}} }, "another terminal set the gain to 30.0 dB"},
		{"detached", func(c *leylinev1.Capture) { c.State = leylinev1.CaptureState_CAPTURE_DETACHED }, "another terminal left the radio detached"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := liveSession()
			c := clone(s.capture)
			tc.edit(c)
			line, ended := say(t, s, c)
			if line != tc.want {
				t.Errorf("got  %q\nwant %q", line, tc.want)
			}
			if ended {
				t.Error("a capture change does not end the session")
			}
		})
	}
}

func TestChannelChangesReadAsSentences(t *testing.T) {
	for _, tc := range []struct {
		name string
		edit func(*leylinev1.Channel)
		want string
	}{
		{"mode", func(c *leylinev1.Channel) { c.Mode = leylinev1.DemodMode_AM }, "another terminal set the mode to AM"},
		{"filter", func(c *leylinev1.Channel) { c.BandwidthHz = 25000 }, "another terminal set the filter to 25.000 kHz"},
		{"squelch", func(c *leylinev1.Channel) { c.SquelchDb = -20 }, "another terminal set the squelch to -20 dBFS"},
		{"squelch off", func(c *leylinev1.Channel) { c.SquelchDb = math.NaN() }, "another terminal turned the squelch off"},
		{"moved", func(c *leylinev1.Channel) { c.OffsetHz = 100_000 }, "another terminal moved this channel to 146.720 MHz"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := liveSession()
			c := clone(s.channel)
			tc.edit(c)
			line, ended := say(t, s, c)
			if line != tc.want {
				t.Errorf("got  %q\nwant %q", line, tc.want)
			}
			if ended {
				t.Error("a knob does not end the session")
			}
		})
	}
}

// Two knobs in one write is one sentence, not two lines.
func TestSeveralChangesReadAsOneSentence(t *testing.T) {
	s := liveSession()
	c := clone(s.channel)
	c.Mode, c.BandwidthHz = leylinev1.DemodMode_AM, 25000
	line, _ := say(t, s, c)
	if line != "another terminal set the mode to AM and the filter to 25.000 kHz" {
		t.Errorf("got %q", line)
	}
	s = liveSession()
	c = clone(s.channel)
	c.Mode, c.BandwidthHz, c.SquelchDb = leylinev1.DemodMode_AM, 25000, -20
	line, _ = say(t, s, c)
	if want := "another terminal set the mode to AM, the filter to 25.000 kHz and the squelch to -20 dBFS"; line != want {
		t.Errorf("got  %q\nwant %q", line, want)
	}
}

// The line the user actually saw as "channel ... STATE_UNSPECIFIED ...": the
// daemon's tombstone. It says the channel is gone, and the session cannot
// carry on drawing a meter for it.
func TestATombstoneEndsTheSession(t *testing.T) {
	s := liveSession()
	c := clone(s.channel)
	c.State = leylinev1.ChannelState_CHANNEL_STATE_UNSPECIFIED
	line, ended := say(t, s, c)
	if line != "another terminal stopped this channel" {
		t.Errorf("got %q", line)
	}
	if !ended {
		t.Error("a destroyed channel must end the live session")
	}
	if strings.Contains(line, "UNSPECIFIED") {
		t.Errorf("the enum name is not a sentence: %q", line)
	}
}

func TestOutOfCaptureAndBack(t *testing.T) {
	s := liveSession()
	c := clone(s.channel)
	c.State = leylinev1.ChannelState_OUT_OF_CAPTURE
	line, ended := say(t, s, c)
	if !strings.HasPrefix(line, "another terminal retuned the radio away from this channel") {
		t.Errorf("got %q", line)
	}
	if ended {
		t.Error("out-of-capture is recoverable; it does not end the session")
	}
	back := clone(c)
	back.State = leylinev1.ChannelState_CHANNEL_ACTIVE
	if line, _ := say(t, s, back); line != "another terminal brought the radio back to this channel" {
		t.Errorf("got %q", line)
	}
}

// Somebody else's knob is their business; their channel arriving on or leaving
// the capture we share is not, because it moves the radio's load.
func TestOtherChannelsOnlyReportComingAndGoing(t *testing.T) {
	s := liveSession()
	theirs := &leylinev1.Channel{
		ChannelId: "chan_THEIRS", CaptureId: otherCap, OffsetHz: -100_000, BandwidthHz: 12500,
		Mode: leylinev1.DemodMode_NFM, State: leylinev1.ChannelState_CHANNEL_ACTIVE,
	}
	if line, _ := say(t, s, theirs); line != "another terminal opened a channel at 146.520 MHz (NFM)" {
		t.Errorf("opened: got %q", line)
	}
	knob := clone(theirs)
	knob.Mode = leylinev1.DemodMode_AM
	if line, _ := say(t, s, knob); line != "" {
		t.Errorf("somebody else's mode is not our news: %q", line)
	}
	gone := clone(knob)
	gone.State = leylinev1.ChannelState_CHANNEL_STATE_UNSPECIFIED
	line, ended := say(t, s, gone)
	if line != "another terminal closed the channel at 146.520 MHz" {
		t.Errorf("closed: got %q", line)
	}
	if ended {
		t.Error("somebody else's channel ending is not ours ending")
	}
}

// Without SinkState an attach and a detach were byte-identical, so a session
// could not tell that its audio had just been taken away.
func TestTheSinkTombstoneIsTheOnlyWayToTellAudioStopped(t *testing.T) {
	s := liveSession()
	vol := clone(s.sink)
	vol.GetSystemAudio().Volume = proto.Float64(0.5)
	if line, _ := say(t, s, vol); line != "another terminal set the volume to 0.50" {
		t.Errorf("volume: got %q", line)
	}
	mute := clone(vol)
	mute.GetSystemAudio().Volume = proto.Float64(0)
	if line, _ := say(t, s, mute); line != "another terminal muted the audio" {
		t.Errorf("mute: got %q", line)
	}
	gone := clone(mute)
	gone.State = leylinev1.SinkState_SINK_STATE_UNSPECIFIED
	line, ended := say(t, s, gone)
	if !strings.HasPrefix(line, "another terminal stopped the audio") {
		t.Errorf("detach: got %q", line)
	}
	if ended {
		t.Error("losing audio is not losing the channel")
	}
}

func TestTheRadioLeavingIsNews(t *testing.T) {
	s := liveSession()
	d := clone(s.device)
	d.State = leylinev1.DeviceState_DISCONNECTED
	if line, _ := say(t, s, d); !strings.HasPrefix(line, "another terminal unplugged the radio") {
		t.Errorf("got %q", line)
	}
	other := &leylinev1.DeviceDescriptor{DeviceId: "dev_ELSEWHERE", State: leylinev1.DeviceState_DISCONNECTED}
	if line, _ := say(t, s, other); line != "" {
		t.Errorf("another radio is not this session's news: %q", line)
	}
}

// The words name the client the way a person would, and never carry its id.
func TestWhoChangedNamesTheKind(t *testing.T) {
	for kind, want := range map[string]string{
		"cli": "another terminal", "app": "the app", "mcp": "an agent",
		"job": "a job", "daemon": "the daemon", "weird": "ley",
	} {
		if got := whoChanged(&leylinev1.ClientInfo{ClientId: "cli_01ABC", Kind: kind, Label: "ley"}); got != want {
			t.Errorf("%s: got %q want %q", kind, got, want)
		}
	}
	if got := whoChanged(nil); got != "something" {
		t.Errorf("nil: got %q", got)
	}
}

// No sentence carries a ULID: the ids are on stdout, where a script reads them.
func TestNoSentenceCarriesAnID(t *testing.T) {
	s := liveSession()
	for _, edit := range []func() any{
		func() any { c := clone(s.capture); c.CenterHz = 146_700_000; return c },
		func() any { c := clone(s.channel); c.Mode = leylinev1.DemodMode_AM; return c },
		func() any {
			c := clone(s.channel)
			c.State = leylinev1.ChannelState_CHANNEL_STATE_UNSPECIFIED
			return c
		},
		func() any { k := clone(s.sink); k.State = leylinev1.SinkState_SINK_STATE_UNSPECIFIED; return k },
		func() any { d := clone(s.device); d.State = leylinev1.DeviceState_DISCONNECTED; return d },
	} {
		fresh := liveSession()
		line, _ := say(t, fresh, edit())
		for _, prefix := range []string{"cap_", "chan_", "sink_", "dev_", "cli_"} {
			if strings.Contains(line, prefix) {
				t.Errorf("%q carries an id (%s)", line, prefix)
			}
		}
	}
}

// A destroyed capture and an unplugged one are different events: only the
// tombstone (state unset) leaves the mirror, and it is not a state to print.
func TestACaptureTombstoneLeavesTheMirror(t *testing.T) {
	s := liveSession()
	lost := clone(s.capture)
	lost.State = leylinev1.CaptureState_CAPTURE_DETACHED
	if line, _ := say(t, s, lost); line != "another terminal left the radio detached" {
		t.Errorf("detached: got %q", line)
	}
	if len(s.state.Captures) != 1 {
		t.Fatalf("a detached capture rebinds and stays in the mirror: %v", s.state.Captures)
	}
	gone := clone(lost)
	gone.State = leylinev1.CaptureState_CAPTURE_STATE_UNSPECIFIED
	line, _ := say(t, s, gone)
	if line != "another terminal stopped this radio" {
		t.Errorf("destroyed: got %q", line)
	}
	if strings.Contains(line, "unspecified") {
		t.Errorf("the enum name is not a sentence: %q", line)
	}
	if len(s.state.Captures) != 0 {
		t.Errorf("a destroyed capture must leave the mirror: %v", s.state.Captures)
	}
}
