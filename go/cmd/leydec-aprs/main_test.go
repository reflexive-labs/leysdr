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
	"github.com/reflexive-labs/leysdr/go/pkg/decoders/ax25"
	"github.com/reflexive-labs/leysdr/go/pkg/plugin"
)

// TestManifestMatchesTheFile keeps the manifest this binary prints identical to
// decoders/aprs/manifest.json, which is what the daemon's registry reads. The
// file is the source of truth; this test is what stops the two drifting.
func TestManifestMatchesTheFile(t *testing.T) {
	data, err := os.ReadFile("../../../decoders/aprs/manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	var fromFile leylinev1.DecoderManifest
	if err := protojson.Unmarshal(data, &fromFile); err != nil {
		t.Fatalf("decoders/aprs/manifest.json does not parse as a DecoderManifest: %v", err)
	}
	if !proto.Equal(&fromFile, manifest()) {
		t.Errorf("the built manifest and decoders/aprs/manifest.json differ:\nfile:  %v\nbuilt: %v",
			&fromFile, manifest())
	}
}

// TestPluginDecodesAStreamOfFrames runs the whole plugin the way the daemon
// does: a descriptor, then frames of audio on stdin, records out.
func TestPluginDecodesAStreamOfFrames(t *testing.T) {
	const audioRate, captureRate = 48000, 240000
	mod := afsk.NewModulator(audioRate, 0.5)
	var audio []float32
	audio = mod.Silence(audio, audioRate/10)
	for _, info := range []string{
		"!4903.50N/07201.75W-Test 001234",
		">on the air",
	} {
		frame := ax25.BuildUI(ax25.Address{Call: "APRS"}, ax25.Address{Call: "LEYTST", SSID: 1},
			[]ax25.Address{{Call: "WIDE1", SSID: 1}}, 0xF0, []byte(info))
		audio = mod.Modulate(audio, afsk.NRZI(ax25.Encode(frame, 24)))
		audio = mod.Silence(audio, audioRate/10)
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
	// 1024 samples a frame, which is the order the daemon delivers audio in.
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
	err := plugin.RunStreams(context.Background(), &in, &out, func(rate uint32) plugin.Decoder {
		if rate != audioRate {
			t.Errorf("decoder built for %d Hz, want %d", rate, audioRate)
		}
		return newDecoder(float64(rate))
	})
	if err != nil {
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
	if got[0].Kind != "position" || got[1].Kind != "status" {
		t.Errorf("kinds %q, %q; want position, status", got[0].Kind, got[1].Kind)
	}
	for _, rec := range got {
		if rec.Protocol != "aprs" || rec.DeviceId != "LEYTST-1" {
			t.Errorf("record says protocol %q device %q", rec.Protocol, rec.DeviceId)
		}
		if rec.Time.GetCaptureId() != "cap_test" {
			t.Errorf("time is not on the capture's timeline: %v", rec.Time)
		}
		// Every packet is inside the audio, so its sample index is inside the
		// capture-rate span the audio covers.
		if hi := uint64(float64(len(audio)) * captureRate / audioRate); rec.Time.GetSampleIndex() > hi {
			t.Errorf("sample index %d is past the end of the audio (%d)", rec.Time.GetSampleIndex(), hi)
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
