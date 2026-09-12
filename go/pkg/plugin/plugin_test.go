// SPDX-License-Identifier: Apache-2.0

package plugin_test

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"math"
	"testing"

	"google.golang.org/protobuf/encoding/protodelim"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/plugin"
)

// echoDecoder emits one record per frame carrying what it was handed, so the
// test can check the SDK rather than a demodulator.
type echoDecoder struct {
	rate  uint32
	seen  [][]float32
	gaps  int
	capID string
}

func (d *echoDecoder) Start(desc *leylinev1.StreamDescriptor) { d.capID = desc.GetStreamId() }

func (d *echoDecoder) Feed(samples []float32, at *leylinev1.SampleTime, gap *leylinev1.Gap, emit func(*leylinev1.DecodeRecord)) {
	d.seen = append(d.seen, append([]float32{}, samples...))
	if gap != nil {
		d.gaps++
	}
	emit(&leylinev1.DecodeRecord{
		Protocol: "test",
		DeviceId: d.capID,
		Time:     plugin.SampleTimeAt(at, len(samples), float64(d.rate), 240000),
	})
}

func descriptor(format leylinev1.AudioSampleFormat) *leylinev1.StreamDescriptor {
	return &leylinev1.StreamDescriptor{
		StreamId: "str_1",
		Kind:     leylinev1.StreamKind_AUDIO,
		Policy:   leylinev1.DeliveryPolicy_GAP_MARKED,
		Params: &leylinev1.StreamDescriptor_Audio{
			Audio: &leylinev1.AudioParams{SampleRate: 48000, Format: format},
		},
		SpanHz: 240000,
	}
}

func TestRunReadsFramesAndWritesRecords(t *testing.T) {
	var in bytes.Buffer
	mustMarshal(t, &in, descriptor(leylinev1.AudioSampleFormat_F32))
	payload := make([]byte, 0, 12)
	for _, v := range []float32{0.5, -0.5, 1} {
		payload = binary.LittleEndian.AppendUint32(payload, math.Float32bits(v))
	}
	mustMarshal(t, &in, &leylinev1.Frame{
		StreamId: "str_1", Seq: 1, Payload: payload,
		Time: &leylinev1.SampleTime{CaptureId: "cap_1", SampleIndex: 1000},
	})
	mustMarshal(t, &in, &leylinev1.Frame{
		StreamId: "str_1", Seq: 2, Payload: payload,
		Time: &leylinev1.SampleTime{CaptureId: "cap_1", SampleIndex: 2000},
		Gap:  &leylinev1.Gap{FromSample: 1015, ToSample: 2000},
	})

	var out bytes.Buffer
	var dec *echoDecoder
	err := plugin.RunStreams(context.Background(), &in, &out, func(rate uint32) plugin.Decoder {
		dec = &echoDecoder{rate: rate}
		return dec
	})
	if err != nil {
		t.Fatal(err)
	}
	if dec.rate != 48000 {
		t.Errorf("decoder built for %d Hz, want 48000", dec.rate)
	}
	if dec.capID != "str_1" {
		t.Errorf("Start was not called with the descriptor: %q", dec.capID)
	}
	if len(dec.seen) != 2 {
		t.Fatalf("decoder saw %d frames, want 2", len(dec.seen))
	}
	want := []float32{0.5, -0.5, 1}
	for i, got := range dec.seen[0] {
		if got != want[i] {
			t.Errorf("sample %d = %v, want %v", i, got, want[i])
		}
	}
	if dec.gaps != 1 {
		t.Errorf("saw %d gaps, want 1", dec.gaps)
	}

	recs := readRecords(t, out.Bytes())
	if len(recs) != 2 {
		t.Fatalf("got %d records, want 2", len(recs))
	}
	// Three audio samples at 48 kHz are fifteen capture samples at 240 kHz.
	if got := recs[0].Time.GetSampleIndex(); got != 1015 {
		t.Errorf("record time = %d, want 1015", got)
	}
	if got := recs[0].Time.GetCaptureId(); got != "cap_1" {
		t.Errorf("record capture = %q, want cap_1", got)
	}
}

func TestRunConvertsS16(t *testing.T) {
	var in bytes.Buffer
	mustMarshal(t, &in, descriptor(leylinev1.AudioSampleFormat_S16))
	payload := binary.LittleEndian.AppendUint16(nil, uint16(int16(16384)))
	payload = binary.LittleEndian.AppendUint16(payload, uint16(0x8000))
	mustMarshal(t, &in, &leylinev1.Frame{StreamId: "str_1", Seq: 1, Payload: payload})

	var dec *echoDecoder
	var out bytes.Buffer
	if err := plugin.RunStreams(context.Background(), &in, &out, func(rate uint32) plugin.Decoder {
		dec = &echoDecoder{rate: rate}
		return dec
	}); err != nil {
		t.Fatal(err)
	}
	got := dec.seen[0]
	if len(got) != 2 || got[0] != 0.5 || got[1] != -1 {
		t.Errorf("S16 conversion gave %v, want [0.5 -1]", got)
	}
}

func TestRunRefusesADescriptorWithoutAudio(t *testing.T) {
	var in bytes.Buffer
	mustMarshal(t, &in, &leylinev1.StreamDescriptor{StreamId: "str_1", Kind: leylinev1.StreamKind_FFT})
	err := plugin.RunStreams(context.Background(), &in, &bytes.Buffer{}, func(uint32) plugin.Decoder {
		t.Error("the decoder should not have been built")
		return nil
	})
	if err == nil {
		t.Error("a descriptor with no audio params should be an error")
	}
}

func TestRunStopsAtEndOfInput(t *testing.T) {
	var in bytes.Buffer
	mustMarshal(t, &in, descriptor(leylinev1.AudioSampleFormat_F32))
	if err := plugin.RunStreams(context.Background(), &in, &bytes.Buffer{}, func(rate uint32) plugin.Decoder {
		return &echoDecoder{rate: rate}
	}); err != nil {
		t.Errorf("the daemon closing stdin is how a job ends, not a failure: %v", err)
	}
}

func TestSampleTimeAtScalesToTheCaptureRate(t *testing.T) {
	at := &leylinev1.SampleTime{CaptureId: "cap_1", SampleIndex: 100}
	got := plugin.SampleTimeAt(at, 480, 48000, 2_400_000)
	if got.GetSampleIndex() != 100+24000 {
		t.Errorf("sample index = %d, want %d", got.GetSampleIndex(), 100+24000)
	}
	if plugin.SampleTimeAt(nil, 10, 48000, 48000) != nil {
		t.Error("a frame with no time stamps no record")
	}
}

func mustMarshal(t *testing.T, w *bytes.Buffer, m proto.Message) {
	t.Helper()
	if _, err := protodelim.MarshalTo(w, m); err != nil {
		t.Fatal(err)
	}
}

func readRecords(t *testing.T, data []byte) []*leylinev1.DecodeRecord {
	t.Helper()
	r := bufio.NewReader(bytes.NewReader(data))
	var out []*leylinev1.DecodeRecord
	for {
		var rec leylinev1.DecodeRecord
		if err := protodelim.UnmarshalFrom(r, &rec); err != nil {
			return out
		}
		out = append(out, &rec)
	}
}
