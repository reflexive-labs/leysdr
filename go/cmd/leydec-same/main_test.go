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
	"github.com/reflexive-labs/leysdr/go/pkg/decoders/same"
	"github.com/reflexive-labs/leysdr/go/pkg/plugin"
)

// TestManifestMatchesTheFile keeps the manifest this binary prints identical to
// decoders/same/manifest.json, which is what the daemon's registry reads.
func TestManifestMatchesTheFile(t *testing.T) {
	data, err := os.ReadFile("../../../decoders/same/manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	var fromFile leylinev1.DecoderManifest
	if err := protojson.Unmarshal(data, &fromFile); err != nil {
		t.Fatalf("decoders/same/manifest.json does not parse: %v", err)
	}
	if !proto.Equal(&fromFile, manifest()) {
		t.Errorf("the built manifest and decoders/same/manifest.json differ:\nfile:  %v\nbuilt: %v",
			&fromFile, manifest())
	}
}

const torHeader = "ZCZC-WXR-TOR-048113-048121-048139+0045-1421550-KFWS/NWS-"

// TestPluginDecodesAMessage runs the whole plugin the way the daemon does: a
// descriptor, then frames of audio carrying three header copies and three EOMs,
// records out. The three copies must dedupe to one record.
func TestPluginDecodesAMessage(t *testing.T) {
	const audioRate, captureRate = 48000, 2_400_000
	mod := same.NewModulator(audioRate, 0.5)
	var audio []float32
	audio = mod.Silence(audio, audioRate/10)
	audio = mod.Message(audio, torHeader, 3)
	audio = mod.Silence(audio, audioRate/10)

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
	if len(got) != 1 {
		t.Fatalf("got %d records, want 1 (three copies dedupe to one)", len(got))
	}
	rec := got[0]
	if rec.Protocol != "same" || rec.DeviceId != "KFWS/NWS" || rec.Kind != "alert" {
		t.Errorf("record says protocol %q device %q kind %q", rec.Protocol, rec.DeviceId, rec.Kind)
	}
	if rec.Fields["event"].GetText() != "TOR" || rec.Fields["fips"].GetText() != "48113,48121,48139" {
		t.Errorf("event/fips = %q/%q", rec.Fields["event"].GetText(), rec.Fields["fips"].GetText())
	}
	if rec.Validity.GetEndNs() <= rec.Validity.GetStartNs() {
		t.Errorf("validity window is not positive: %d..%d", rec.Validity.GetStartNs(), rec.Validity.GetEndNs())
	}
	if rec.Time.GetCaptureId() != "cap_test" {
		t.Errorf("time is not on the capture's timeline: %v", rec.Time)
	}
	if string(rec.Raw) != torHeader {
		t.Errorf("raw = %q, want the header", rec.Raw)
	}
}

func appendF32(dst []byte, v float32) []byte {
	b := math.Float32bits(v)
	return append(dst, byte(b), byte(b>>8), byte(b>>16), byte(b>>24))
}
