package cli

import (
	"bytes"
	"math"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
)

// busyState is the state the tree has to survive: two radios, three captures,
// five channels and two sinks, with one channel out of its capture and one
// sink whose channel is gone from the snapshot.
func busyState() *leylinev1.GetStateResponse {
	cli := &leylinev1.ClientInfo{Kind: "cli", Label: "ley", ClientId: "cli_01M224S5ZG4DTW0HSZEZ4KJ5AH"}
	st := &leylinev1.GetStateResponse{
		EventSeq: 42,
		Daemon:   &leylinev1.DaemonInfo{Version: "0.1.0-dev", Pid: 4711, SocketPath: "/tmp/leyline.sock", StartedAtNs: 0},
		Devices: []*leylinev1.DeviceDescriptor{
			{
				DeviceId: "dev_01M224S5ZRDDEGKRWJSCTABBRA", Driver: "rtlsdr", Model: "Generic RTL2832U (R820T)",
				Serial: "00000001", State: leylinev1.DeviceState_IN_USE,
				TuningRanges: []*leylinev1.FrequencyRange{{MinHz: 24_000_000, MaxHz: 1_766_000_000}},
			},
			{
				DeviceId: "dev_01M224S5ZRDDEGKRWJSCTABBRB", Driver: "file", Model: "nfm_tone.cf32",
				Serial: "69943ab1a039f01f", State: leylinev1.DeviceState_DISCONNECTED,
				TuningRanges: []*leylinev1.FrequencyRange{{MinHz: 146_520_000, MaxHz: 146_520_000}},
			},
		},
		Captures: []*leylinev1.Capture{
			{
				CaptureId: "cap_01M224S5ZTB34335N7PM0PGZZA", DeviceId: "dev_01M224S5ZRDDEGKRWJSCTABBRA",
				CenterHz: 146_500_000, SampleRate: 2_400_000, State: leylinev1.CaptureState_CAPTURE_ACTIVE,
				Gains: []*leylinev1.GainState{{Element: "TUNER", Db: 20.7}}, CreatedBy: cli,
			},
			{
				CaptureId: "cap_01M224S5ZTB34335N7PM0PGZZB", DeviceId: "dev_01M224S5ZRDDEGKRWJSCTABBRA",
				CenterHz: 101_100_000, SampleRate: 2_400_000, State: leylinev1.CaptureState_CAPTURE_DETACHED,
				Gains: []*leylinev1.GainState{{Element: "TUNER", Auto: true}}, CreatedBy: cli,
			},
			{
				CaptureId: "cap_01M224S5ZTB34335N7PM0PGZZC", DeviceId: "dev_01M224S5ZRDDEGKRWJSCTABBRB",
				CenterHz: 146_520_000, SampleRate: 2_400_000, State: leylinev1.CaptureState_CAPTURE_ACTIVE, CreatedBy: cli,
			},
		},
		Sinks: []*leylinev1.Sink{
			{
				SinkId: "snk_01M224S60EG37HPKYSEH0CQZZA", ChannelId: "chan_01M224S60EG37HPKYSEH0CQZZA",
				Kind: &leylinev1.Sink_SystemAudio{SystemAudio: &leylinev1.SystemAudioSink{AudioDeviceUid: "BuiltInSpeakerDevice"}},
			},
			{
				SinkId: "snk_01M224S60EG37HPKYSEH0CQZZZ", ChannelId: "chan_gone",
				Kind: &leylinev1.Sink_Stream{Stream: &leylinev1.StreamSink{StreamId: "str_01M224S60EG37HPKYSEH0CQZZZ"}},
			},
		},
	}
	for i, spec := range []struct {
		id      string
		capture string
		offset  int64
		mode    leylinev1.DemodMode
		bw      uint32
		squelch float64
		state   leylinev1.ChannelState
	}{
		{"chan_01M224S60EG37HPKYSEH0CQZZA", "cap_01M224S5ZTB34335N7PM0PGZZA", 20_000, leylinev1.DemodMode_NFM, 12_500, -40, leylinev1.ChannelState_CHANNEL_ACTIVE},
		{"chan_01M224S60EG37HPKYSEH0CQZZB", "cap_01M224S5ZTB34335N7PM0PGZZA", -80_000, leylinev1.DemodMode_AM, 8_000, squelchOffValue(), leylinev1.ChannelState_CHANNEL_ACTIVE},
		{"chan_01M224S60EG37HPKYSEH0CQZZC", "cap_01M224S5ZTB34335N7PM0PGZZA", 1_200_000, leylinev1.DemodMode_USB, 2_800, squelchOffValue(), leylinev1.ChannelState_OUT_OF_CAPTURE},
		{"chan_01M224S60EG37HPKYSEH0CQZZD", "cap_01M224S5ZTB34335N7PM0PGZZB", 0, leylinev1.DemodMode_WFM, 200_000, squelchOffValue(), leylinev1.ChannelState_CHANNEL_ACTIVE},
		{"chan_01M224S60EG37HPKYSEH0CQZZE", "cap_01M224S5ZTB34335N7PM0PGZZC", 100_000, leylinev1.DemodMode_NFM, 12_500, squelchOffValue(), leylinev1.ChannelState_CHANNEL_ACTIVE},
	} {
		st.Channels = append(st.Channels, &leylinev1.Channel{
			ChannelId: spec.id, CaptureId: spec.capture, OffsetHz: spec.offset, Mode: spec.mode,
			BandwidthHz: spec.bw, SquelchDb: spec.squelch, State: spec.state,
			Persistent: i%2 == 0, Owner: cli,
		})
	}
	return st
}

// squelchOffValue is the NaN the wire uses for "squelch off".
func squelchOffValue() float64 { return math.NaN() }

// TestStateTreeSurvivesColourOff is the mechanical proof of principle 1: the
// styled tree and the plain tree differ only by SGR bytes.
func TestStateTreeSurvivesColourOff(t *testing.T) {
	st := busyState()
	// Colour is the only variable: the glyph alphabet is held fixed, so what
	// is left after Strip must be byte-identical.
	plain := renderStateTree(ui.Style{Unicode: true, Width: 80}, st)
	styled := renderStateTree(ui.Style{Color: true, Unicode: true, Width: 80}, st)
	if styled == plain {
		t.Fatal("a coloured style left the tree unstyled")
	}
	if got := ui.Strip(styled); got != plain {
		t.Fatalf("Strip(styled) != plain\n--- styled\n%s\n--- plain\n%s", got, plain)
	}
	// Unicode and ASCII carry the same words, only different drawing.
	ascii := renderStateTree(ui.Style{Width: 80}, st)
	if !strings.Contains(ascii, "+- ") || !strings.Contains(ascii, "\\- ") {
		t.Errorf("ascii tree must use the fallback glyphs:\n%s", ascii)
	}
	if uni := renderStateTree(ui.Style{Unicode: true, Width: 80}, st); !strings.Contains(uni, "├─ ") || !strings.Contains(uni, "└─ ") {
		t.Errorf("utf-8 tree must use the branch glyphs:\n%s", uni)
	}
}

// TestStateTreeContent checks the tree says what the flat tables said: every
// object, with units on the numbers and the hierarchy in the indentation
// rather than in a repeated id column.
func TestStateTreeContent(t *testing.T) {
	st := busyState()
	out := renderStateTree(ui.Style{Unicode: true, Width: 100}, st)
	// A file device tunes to exactly one frequency, so the tree collapses it
	// the same way `ley devices` does: they share the renderer.
	if !strings.Contains(out, "tunes 146.520 MHz") {
		t.Errorf("want the collapsed one-frequency range:\n%s", out)
	}
	if strings.Contains(out, "146.520 MHz to 146.520 MHz") {
		t.Errorf("a one-frequency range must not be said twice:\n%s", out)
	}
	for _, want := range []string{
		"Generic RTL2832U (R820T)", "nfm_tone.cf32", "in use", "disconnected",
		"146.500 MHz", "2.4 MSPS", "gain tuner 20.7 dB", "gain tuner auto",
		"146.520 MHz NFM", "offset +20.000 kHz", "offset -80.000 kHz", "bw 12.5 kHz",
		"squelch -40.0 dB", "squelch off", "out of capture", "persistent",
		"system_audio", "by cli:ley", "not attached to a listed device", "stream",
		"tunes 24.000 MHz to 1.766 GHz",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("tree missing %q:\n%s", want, out)
		}
	}
	// Every id is printed whole, exactly once, and never as a repeated column.
	for _, id := range []string{
		"dev_01M224S5ZRDDEGKRWJSCTABBRA", "cap_01M224S5ZTB34335N7PM0PGZZA",
		"chan_01M224S60EG37HPKYSEH0CQZZA", "snk_01M224S60EG37HPKYSEH0CQZZA",
	} {
		if n := strings.Count(out, id); n != 1 {
			t.Errorf("id %s appears %d times, want 1:\n%s", id, n, out)
		}
	}
	// The hierarchy: a capture is indented under its device, a channel under
	// its capture, a sink under its channel.
	depth := func(id string) int {
		for _, l := range strings.Split(out, "\n") {
			if strings.Contains(l, id) {
				return len(l) - len(strings.TrimLeft(l, " │├└─"))
			}
		}
		t.Fatalf("id %s not in:\n%s", id, out)
		return 0
	}
	dev, cap, chn, snk := depth("dev_01M224S5ZRDDEGKRWJSCTABBRA"), depth("cap_01M224S5ZTB34335N7PM0PGZZA"),
		depth("chan_01M224S60EG37HPKYSEH0CQZZA"), depth("snk_01M224S60EG37HPKYSEH0CQZZA")
	if dev >= cap || cap >= chn || chn >= snk {
		t.Errorf("indentation must deepen device to capture to channel to sink (%d %d %d %d):\n%s", dev, cap, chn, snk, out)
	}
}

// TestStateTreeWidths keeps the tree inside the resolved width. Segments are
// packed two spaces apart and wrapped, so the only allowed overflow is a line
// carrying one whole segment that will not fit: an id is never truncated,
// because users paste it into 'ley set --channel'.
func TestStateTreeWidths(t *testing.T) {
	for _, width := range []int{40, 80, 160} {
		out := renderStateTree(ui.Style{Unicode: true, Width: width}, busyState())
		for _, l := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
			if ui.Visible(l) <= width {
				continue
			}
			if !strings.Contains(strings.TrimLeft(l, " │├└─"), "  ") {
				continue
			}
			t.Errorf("width %d: line is %d columns wide and holds more than one segment: %q", width, ui.Visible(l), l)
		}
	}
}

// TestStateEmptyIsOneLine replaces four empty headers with one sentence and
// one thing to type.
func TestStateEmptyIsOneLine(t *testing.T) {
	plain := renderStateTree(ui.Style{Width: 80}, &leylinev1.GetStateResponse{})
	if !strings.Contains(plain, "nothing running (no devices, captures or channels)") || !strings.Contains(plain, "ley devices") {
		t.Fatalf("empty state:\n%s", plain)
	}
	if strings.Contains(plain, "Captures") || strings.Contains(plain, "Sinks") {
		t.Errorf("empty state must not print table headers:\n%s", plain)
	}
	styled := renderStateTree(ui.Style{Color: true, Unicode: true, Width: 80}, &leylinev1.GetStateResponse{})
	if got := ui.Strip(styled); got != plain {
		t.Fatalf("Strip(styled) = %q, want %q", got, plain)
	}
}

// TestStateHeaderAndTables cover the preamble and the --wide fallback with the
// same render-twice proof.
func TestStateHeaderAndTables(t *testing.T) {
	st := busyState()
	now := time.Unix(0, 0).Add(39 * time.Second)
	plain := stateHeader(ui.Style{}, st, now)
	if !strings.Contains(plain, "daemon 0.1.0-dev  up 39s") || !strings.Contains(plain, "pid 4711") || !strings.Contains(plain, "event seq 42") {
		t.Fatalf("header:\n%s", plain)
	}
	if got := ui.Strip(stateHeader(ui.Style{Color: true, Unicode: true}, st, now)); got != plain {
		t.Fatalf("Strip(styled header) = %q, want %q", got, plain)
	}

	render := func(s ui.Style) string {
		buf := &bytes.Buffer{}
		printStateTables(&App{Stdout: buf, Style: s}, st)
		return buf.String()
	}
	flat := render(ui.Style{})
	for _, want := range []string{"Devices", "Captures", "Channels", "Sinks", "cap_01M224S5ZTB34335N7PM0PGZZA", "cli_01M224S5ZG4DTW0HSZEZ4KJ5AH"} {
		if !strings.Contains(flat, want) {
			t.Errorf("--wide tables missing %q:\n%s", want, flat)
		}
	}
	if got := ui.Strip(render(ui.Style{Color: true, Unicode: true})); got != flat {
		t.Fatalf("Strip(styled tables) != plain\n--- got\n%s\n--- want\n%s", got, flat)
	}
}
