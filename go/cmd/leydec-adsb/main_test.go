// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"math"
	"os"
	"testing"

	"google.golang.org/protobuf/encoding/protodelim"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/decoders/modes"
	"github.com/reflexive-labs/leysdr/go/pkg/plugin"
)

// TestManifestMatchesTheFile keeps the manifest this binary prints identical to
// decoders/adsb/manifest.json, which is what the daemon's registry reads.
func TestManifestMatchesTheFile(t *testing.T) {
	data, err := os.ReadFile("../../../decoders/adsb/manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	var fromFile leylinev1.DecoderManifest
	if err := protojson.Unmarshal(data, &fromFile); err != nil {
		t.Fatalf("decoders/adsb/manifest.json does not parse as a DecoderManifest: %v", err)
	}
	if !proto.Equal(&fromFile, manifest()) {
		t.Errorf("the built manifest and decoders/adsb/manifest.json differ:\nfile:  %v\nbuilt: %v",
			&fromFile, manifest())
	}
}

// TestPluginDecodesIQ runs the whole plugin the way the daemon does: an IQ descriptor, then
// frames of cf32 at 2.4 MSPS carrying one aircraft's replies, records out, each stamped with the
// sample just past its reply on the capture's timeline.
func TestPluginDecodesIQ(t *testing.T) {
	const rate, base = 2_400_000, 1_000_000
	f := modes.Flight{Addr: 0xABC123, Callsign: "LEY42", Squawk: "1200", Lat: 37.6, Lon: -122.4, AltFt: 5000, GSKn: 200, TrackDeg: 45}
	const dur = 1.2
	tx := modes.Schedule([]modes.Flight{f}, dur)
	env := make([]float64, int(dur*rate))
	for _, x := range tx {
		modes.Render(x.Msg, rate, x.T*rate, env, 0)
	}

	var in bytes.Buffer
	mustMarshal(t, &in, &leylinev1.StreamDescriptor{
		StreamId: "str_iq", Kind: leylinev1.StreamKind_IQ, Policy: leylinev1.DeliveryPolicy_GAP_MARKED,
		Params:   &leylinev1.StreamDescriptor_Iq{Iq: &leylinev1.IqParams{SampleRate: rate, Format: leylinev1.SampleFormat_CF32}},
		CenterHz: 1_090_000_000, SpanHz: rate,
	})
	const block = 4096
	for i := 0; i < len(env); i += block {
		var payload []byte
		for _, v := range env[i:min(i+block, len(env))] {
			payload = binary.LittleEndian.AppendUint32(payload, math.Float32bits(float32(0.5*v+0.01)))
			payload = binary.LittleEndian.AppendUint32(payload, math.Float32bits(0.01))
		}
		mustMarshal(t, &in, &leylinev1.Frame{
			StreamId: "str_iq", Seq: uint64(i/block) + 1, Payload: payload,
			Time: &leylinev1.SampleTime{CaptureId: "cap_1", SampleIndex: base + uint64(i)},
		})
	}
	var out bytes.Buffer
	if err := plugin.RunIQStreams(t.Context(), &in, &out, func(r uint32) plugin.IQDecoder { return newDecoder(r) }); err != nil {
		t.Fatal(err)
	}
	recs := readRecords(t, out.Bytes())
	if len(recs) != len(tx) {
		t.Fatalf("%d records from %d replies", len(recs), len(tx))
	}
	var positions int
	for i, r := range recs {
		if r.GetProtocol() != "adsb" || r.GetDeviceId() != "ABC123" {
			t.Errorf("record %d is %s/%s", i, r.GetProtocol(), r.GetDeviceId())
		}
		end := base + uint64(math.Ceil((tx[i].T+modes.FrameUs(tx[i].Msg)*1e-6)*rate))
		if got := r.GetTime(); got.GetCaptureId() != "cap_1" || got.GetSampleIndex() < end-1 || got.GetSampleIndex() > end+1 {
			t.Errorf("record %d stamped %v, want about sample %d", i, got, end)
		}
		if !bytes.Equal(r.GetRaw(), tx[i].Msg) {
			t.Errorf("record %d raw %X, want %X", i, r.GetRaw(), tx[i].Msg)
		}
		if r.GetPosition() != nil {
			positions++
		}
	}
	if positions == 0 {
		t.Error("no position decoded")
	}
}

// TestPluginRefusesACaptureItCannotDecode: a capture centred 600 kHz off 1090 MHz at 2.4 MSPS
// (the decoders-take-over scene's file radio), or one too slow for a reply, is refused with the
// sentence the job shows, rather than read and left silent.
func TestPluginRefusesACaptureItCannotDecode(t *testing.T) {
	for _, c := range []struct {
		centre uint64
		rate   uint32
		want   string
	}{
		{1_090_600_000, 2_400_000, "the capture is centred on 1090.600 MHz, too far from 1090.000 MHz for a reply to fit in it"},
		{1_090_000_000, 1_024_000, "the capture runs at 1.024 MSPS; a Mode S reply needs at least 2 MSPS"},
	} {
		var in bytes.Buffer
		mustMarshal(t, &in, &leylinev1.StreamDescriptor{
			StreamId: "str_iq", Kind: leylinev1.StreamKind_IQ, Policy: leylinev1.DeliveryPolicy_GAP_MARKED,
			Params:   &leylinev1.StreamDescriptor_Iq{Iq: &leylinev1.IqParams{SampleRate: uint64(c.rate), Format: leylinev1.SampleFormat_CF32}},
			CenterHz: c.centre, SpanHz: uint64(c.rate),
		})
		err := plugin.RunIQStreams(t.Context(), &in, &bytes.Buffer{}, func(r uint32) plugin.IQDecoder { return newDecoder(r) })
		var refused *plugin.InputRefusedError
		if !errors.As(err, &refused) || refused.Reason != c.want {
			t.Errorf("centre %d at %d S/s: got %v, want the refusal %q", c.centre, c.rate, err, c.want)
		}
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
