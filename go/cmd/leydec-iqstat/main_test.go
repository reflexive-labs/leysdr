// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"math"
	"os"
	"testing"

	"google.golang.org/protobuf/encoding/protodelim"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/plugin"
)

// TestManifestMatchesTheFile keeps the manifest this binary prints identical to
// decoders/iqstat/manifest.json, which is what the daemon's registry reads.
func TestManifestMatchesTheFile(t *testing.T) {
	data, err := os.ReadFile("../../../decoders/iqstat/manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	var fromFile leylinev1.DecoderManifest
	if err := protojson.Unmarshal(data, &fromFile); err != nil {
		t.Fatalf("decoders/iqstat/manifest.json does not parse: %v", err)
	}
	if !proto.Equal(&fromFile, manifest()) {
		t.Errorf("the built manifest and decoders/iqstat/manifest.json differ:\nfile:  %v\nbuilt: %v",
			&fromFile, manifest())
	}
}

// TestPluginEmitsBlockPower runs the whole plugin the way the daemon does: an
// IQ descriptor, then a frame of cf32 samples, a "power" record out. With a
// sample rate of 4 a block is two samples; four unit-magnitude samples make two
// blocks, each of mean power 1 and so 0 dBFS.
func TestPluginEmitsBlockPower(t *testing.T) {
	const rate, center = 4, 100_000_000
	var in bytes.Buffer
	mustMarshal(t, &in, &leylinev1.StreamDescriptor{
		StreamId: "str_iq",
		Kind:     leylinev1.StreamKind_IQ,
		Policy:   leylinev1.DeliveryPolicy_GAP_MARKED,
		Params:   &leylinev1.StreamDescriptor_Iq{Iq: &leylinev1.IqParams{SampleRate: rate, Format: leylinev1.SampleFormat_CF32}},
		CenterHz: center,
		SpanHz:   rate,
	})
	var payload []byte
	for i := 0; i < 4; i++ { // four samples I=1, Q=0 -> |x|^2 = 1
		payload = binary.LittleEndian.AppendUint32(payload, math.Float32bits(1))
		payload = binary.LittleEndian.AppendUint32(payload, math.Float32bits(0))
	}
	mustMarshal(t, &in, &leylinev1.Frame{
		StreamId: "str_iq", Seq: 1, Payload: payload,
		Time: &leylinev1.SampleTime{CaptureId: "cap_1", SampleIndex: 500},
	})

	var out bytes.Buffer
	if err := plugin.RunIQStreams(context.Background(), &in, &out, func(r uint32) plugin.IQDecoder {
		return newDecoder(r)
	}); err != nil {
		t.Fatal(err)
	}

	recs := readRecords(t, out.Bytes())
	if len(recs) != 2 {
		t.Fatalf("got %d records, want 2 (a block is two samples at rate 4)", len(recs))
	}
	r := recs[0]
	if r.GetProtocol() != "iqstat" || r.GetKind() != "power" {
		t.Errorf("record is %q/%q, want iqstat/power", r.GetProtocol(), r.GetKind())
	}
	if got := r.GetFields()["power_dbfs"].GetNumber(); math.Abs(got) > 1e-6 {
		t.Errorf("power_dbfs = %v, want 0 (mean |x|^2 = 1)", got)
	}
	if got := r.GetFields()["sample_rate"].GetInteger(); got != rate {
		t.Errorf("sample_rate = %d, want %d", got, rate)
	}
	if got := r.GetFields()["samples"].GetInteger(); got != 2 {
		t.Errorf("samples = %d, want 2", got)
	}
	if got := r.GetFields()["center_hz"].GetInteger(); got != center {
		t.Errorf("center_hz = %d, want %d", got, center)
	}
	if got := r.GetTime().GetSampleIndex(); got != 502 {
		t.Errorf("record time = %d, want 502 (500 + a two-sample block)", got)
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
