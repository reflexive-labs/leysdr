// SPDX-License-Identifier: Apache-2.0

package main

import (
	"testing"

	"github.com/dpup/leysdr/go/pkg/decoders/same"
)

// TestSAMEFixtureDecodes runs the same_alert fixture through the reference NFM
// chain and the SAME decoder, so the sidecar's decode expectation is measured
// rather than claimed: one record, from the station it names.
func TestSAMEFixtureDecodes(t *testing.T) {
	const rate = 2_400_000
	const dur = 2.0
	f := findFixture("same_alert")
	if f == nil {
		t.Fatal("the same_alert fixture is missing from the catalog")
	}
	src := f.build(rate)
	iq := make([]complex128, int(rate*dur))
	noise := newNoise(1)
	const block = 1 << 16
	for i := 0; i < len(iq); i += block {
		blk := iq[i:min(i+block, len(iq))]
		noise.fill(blk, int64(i))
		for _, s := range src {
			s.fill(blk, int64(i))
		}
	}

	exp := f.expect(rate)[0]
	res, err := referenceChain(iq, rate, exp.Mode, exp.OffsetHz, exp.BandwidthHz)
	if err != nil {
		t.Fatal(err)
	}
	audio := make([]float32, len(res.audio))
	for i, v := range res.audio {
		audio[i] = float32(v)
	}

	var headers []string
	same.New(res.audioRate).Feed(audio, func(fr same.Frame) {
		if fr.Header {
			headers = append(headers, fr.Text)
		}
	})

	if exp.Decode == nil {
		t.Fatal("the fixture states no decode expectation")
	}
	if len(headers) != exp.Decode.Records {
		t.Fatalf("decoded %d headers (%v), want %d", len(headers), headers, exp.Decode.Records)
	}
	m, err := same.Parse(headers[0])
	if err != nil {
		t.Fatalf("the decoded header did not parse: %v", err)
	}
	if m.Callsign != exp.Decode.DeviceIDs[0] {
		t.Errorf("callsign %q, want %q", m.Callsign, exp.Decode.DeviceIDs[0])
	}
	if m.Event != "RWT" {
		t.Errorf("event %q, want RWT", m.Event)
	}
}

// TestGenerateSkipsSAMEWhenTooShort checks the guard that keeps a half-second
// file from expecting an alert it cannot hold.
func TestGenerateSkipsSAMEWhenTooShort(t *testing.T) {
	o := genOptions{out: t.TempDir(), rate: 2_400_000, duration: 0.5, seed: 1, only: []string{"same_alert"}}
	if err := generate(o, nil); err == nil {
		t.Error("asking for same_alert at 0.5 s should be an error")
	}
}
