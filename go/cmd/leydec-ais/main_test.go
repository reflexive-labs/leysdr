// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bufio"
	"bytes"
	"context"
	"math"
	"os"
	"testing"

	"google.golang.org/protobuf/encoding/protodelim"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/decoders/afsk"
	"github.com/reflexive-labs/leysdr/go/pkg/decoders/ais"
	"github.com/reflexive-labs/leysdr/go/pkg/plugin"
)

// TestManifestMatchesTheFile keeps the manifest this binary prints identical to
// decoders/ais/manifest.json, which is what the daemon's registry reads.
func TestManifestMatchesTheFile(t *testing.T) {
	data, err := os.ReadFile("../../../decoders/ais/manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	var fromFile leylinev1.DecoderManifest
	if err := protojson.Unmarshal(data, &fromFile); err != nil {
		t.Fatalf("decoders/ais/manifest.json does not parse as a DecoderManifest: %v", err)
	}
	if !proto.Equal(&fromFile, manifest()) {
		t.Errorf("the built manifest and decoders/ais/manifest.json differ:\nfile:  %v\nbuilt: %v",
			&fromFile, manifest())
	}
}

// type1 packs a minimal Type 1 position report, MSB first.
func type1(mmsi uint32, latDeg, lonDeg float64) []byte {
	var bits []bool
	put := func(v uint64, w int) {
		for k := w - 1; k >= 0; k-- {
			bits = append(bits, v>>uint(k)&1 != 0)
		}
	}
	mask := func(v int64, w int) uint64 { return uint64(v) & (1<<uint(w) - 1) }
	put(1, 6) // type
	put(0, 2) // repeat
	put(uint64(mmsi), 30)
	put(0, 4)            // nav status
	put(mask(128, 8), 8) // rate of turn: n/a
	put(0, 10)           // SOG
	put(0, 1)            // accuracy
	put(mask(int64(math.Round(lonDeg*600000)), 28), 28)
	put(mask(int64(math.Round(latDeg*600000)), 27), 27)
	put(0, 12)  // COG
	put(511, 9) // heading n/a
	put(0, 6+2+3+1+19)
	out := make([]byte, (len(bits)+7)/8)
	for i, b := range bits {
		if b {
			out[i/8] |= 1 << (7 - uint(i%8))
		}
	}
	return out
}

// TestPluginDecodesAStreamOfFrames runs the whole plugin the way the daemon
// does: a descriptor, then frames of GMSK audio on stdin, records out.
func TestPluginDecodesAStreamOfFrames(t *testing.T) {
	const audioRate, captureRate = 48000, 2_400_000
	mod := ais.NewModulator(audioRate, 0.9)
	audio := make([]float32, audioRate/10)
	for _, m := range []struct {
		mmsi     uint32
		lat, lon float64
	}{
		{367123450, 47.6, -122.3},
		{211378120, 53.5, 8.1},
	} {
		audio = mod.Modulate(audio, afsk.NRZI(ais.EncodeFrame(type1(m.mmsi, m.lat, m.lon), 4)))
		audio = append(audio, make([]float32, audioRate/10)...)
	}

	var in bytes.Buffer
	desc := &leylinev1.StreamDescriptor{
		StreamId: "str_test",
		Kind:     leylinev1.StreamKind_AUDIO,
		Policy:   leylinev1.DeliveryPolicy_GAP_MARKED,
		Params: &leylinev1.StreamDescriptor_Audio{Audio: &leylinev1.AudioParams{
			SampleRate: audioRate, Format: leylinev1.AudioSampleFormat_F32,
		}},
		SpanHz: captureRate,
	}
	if _, err := protodelim.MarshalTo(&in, desc); err != nil {
		t.Fatal(err)
	}
	const block = 1024
	for i := 0; i < len(audio); i += block {
		end := min(i+block, len(audio))
		payload := make([]byte, 0, (end-i)*4)
		for _, s := range audio[i:end] {
			payload = appendF32(payload, s)
		}
		f := &leylinev1.Frame{
			StreamId: "str_test",
			Seq:      uint64(i/block) + 1,
			Time: &leylinev1.SampleTime{
				CaptureId:   "cap_test",
				SampleIndex: uint64(float64(i) * captureRate / audioRate),
			},
			Payload: payload,
		}
		if _, err := protodelim.MarshalTo(&in, f); err != nil {
			t.Fatal(err)
		}
	}

	var out bytes.Buffer
	if err := plugin.RunStreams(context.Background(), &in, &out, func(rate uint32) plugin.Decoder {
		return newDecoder(float64(rate))
	}); err != nil {
		t.Fatal(err)
	}

	var got []*leylinev1.DecodeRecord
	r := bufio.NewReader(bytes.NewReader(out.Bytes()))
	for {
		var rec leylinev1.DecodeRecord
		if err := protodelim.UnmarshalFrom(r, &rec); err != nil {
			break
		}
		got = append(got, &rec)
	}
	if len(got) != 2 {
		t.Fatalf("got %d records, want 2", len(got))
	}
	if got[0].DeviceId != "367123450" || got[1].DeviceId != "211378120" {
		t.Errorf("device ids %q, %q", got[0].DeviceId, got[1].DeviceId)
	}
	for _, rec := range got {
		if rec.Protocol != "ais" || rec.Kind != "position" || rec.Position == nil {
			t.Errorf("record protocol=%q kind=%q pos=%v", rec.Protocol, rec.Kind, rec.Position)
		}
		if rec.Time.GetCaptureId() != "cap_test" {
			t.Errorf("time is not on the capture's timeline: %v", rec.Time)
		}
	}
	if got[0].Time.GetSampleIndex() >= got[1].Time.GetSampleIndex() {
		t.Error("the two records are stamped out of order")
	}
}

func appendF32(dst []byte, v float32) []byte {
	b := math.Float32bits(v)
	return append(dst, byte(b), byte(b>>8), byte(b>>16), byte(b>>24))
}
