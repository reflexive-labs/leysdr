// SPDX-License-Identifier: Apache-2.0

package plugin_test

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"strings"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/plugin"
)

// pickyIQDecoder refuses a capture that is not centred on 1090 MHz, the way leydec-adsb does.
type pickyIQDecoder struct{ fed int }

func (d *pickyIQDecoder) Start(desc *leylinev1.StreamDescriptor) {
	if desc.GetCenterHz() != 1_090_000_000 {
		plugin.RefuseInput("the capture is centred on %d Hz, not 1090000000", desc.GetCenterHz())
	}
}

func (d *pickyIQDecoder) FeedIQ([]complex64, *leylinev1.SampleTime, *leylinev1.Gap, func(*leylinev1.DecodeRecord)) {
	d.fed++
}

// A RefuseInput from Start ends the run with an *InputRefusedError carrying the sentence, before
// any frame reaches the decoder.
func TestRefuseInputFromStartEndsTheRun(t *testing.T) {
	var in bytes.Buffer
	mustMarshal(t, &in, iqDescriptor())
	mustMarshal(t, &in, &leylinev1.Frame{StreamId: "str_iq", Seq: 1, Payload: iqPayload(1, 2)})
	dec := &pickyIQDecoder{}
	err := plugin.RunIQStreams(t.Context(), &in, &bytes.Buffer{}, func(uint32) plugin.IQDecoder { return dec })
	var refused *plugin.InputRefusedError
	if !errors.As(err, &refused) {
		t.Fatalf("RunIQStreams returned %v, want an *InputRefusedError", err)
	}
	if want := "the capture is centred on 100000000 Hz, not 1090000000"; refused.Reason != want {
		t.Errorf("reason %q, want %q", refused.Reason, want)
	}
	if dec.fed != 0 {
		t.Errorf("the decoder was fed %d frames after refusing its input", dec.fed)
	}
}

// The factory may refuse too: an audio decoder that cannot run at the rate it is given.
func TestRefuseInputFromTheFactoryEndsTheRun(t *testing.T) {
	var in bytes.Buffer
	mustMarshal(t, &in, descriptor(leylinev1.AudioSampleFormat_F32))
	err := plugin.RunStreams(t.Context(), &in, &bytes.Buffer{}, func(rate uint32) plugin.Decoder {
		plugin.RefuseInput("audio at %d Hz is too slow", rate)
		return nil
	})
	var refused *plugin.InputRefusedError
	if !errors.As(err, &refused) || refused.Reason != "audio at 48000 Hz is too slow" {
		t.Fatalf("RunStreams returned %v, want the factory's refusal", err)
	}
}

// Any other panic is the decoder's own and is not turned into a refusal.
func TestAnotherPanicIsNotARefusal(t *testing.T) {
	var in bytes.Buffer
	mustMarshal(t, &in, iqDescriptor())
	defer func() {
		if p := recover(); p != "boom" {
			t.Errorf("recovered %v, want the decoder's own panic", p)
		}
	}()
	_ = plugin.RunIQStreams(t.Context(), &in, &bytes.Buffer{}, func(uint32) plugin.IQDecoder { panic("boom") })
	t.Error("the panic did not reach the caller")
}

// MainIQ exits InputRefusedExit with the sentence as its last line on stderr, which is what the
// daemon reads (docs/reference/writing-a-decoder.md, "The wire"). The test runs itself as the
// plugin.
func TestMainIQExitsThreeWithTheReasonLast(t *testing.T) {
	if os.Getenv("PLUGIN_REFUSE_HELPER") == "1" {
		plugin.MainIQ(&leylinev1.DecoderManifest{Name: "picky"}, func(uint32) plugin.IQDecoder { return &pickyIQDecoder{} })
		return
	}
	var in bytes.Buffer
	mustMarshal(t, &in, iqDescriptor())
	cmd := exec.Command(os.Args[0], "-test.run=^TestMainIQExitsThreeWithTheReasonLast$")
	cmd.Env = append(os.Environ(), "PLUGIN_REFUSE_HELPER=1")
	cmd.Stdin = &in
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	err := cmd.Run()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != plugin.InputRefusedExit {
		t.Fatalf("the plugin ended with %v, want exit status %d; stderr: %s", err, plugin.InputRefusedExit, stderr.String())
	}
	lines := strings.Split(strings.TrimRight(stderr.String(), "\n"), "\n")
	if last := lines[len(lines)-1]; last != "the capture is centred on 100000000 Hz, not 1090000000" {
		t.Errorf("last stderr line %q", last)
	}
}
