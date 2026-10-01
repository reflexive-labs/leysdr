// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"testing"

	"github.com/reflexive-labs/leysdr/go/pkg/decoders/afsk"
	"github.com/reflexive-labs/leysdr/go/pkg/decoders/aprs"
	"github.com/reflexive-labs/leysdr/go/pkg/decoders/ax25"
)

// TestAPRSFixtureDecodes runs the fixture through the reference NFM chain and
// the decoder, so the sidecar's decode expectation is a measurement rather
// than a claim: three records, from the three stations it names, in order.
func TestAPRSFixtureDecodes(t *testing.T) {
	const rate = 2_400_000
	f := findFixture("aprs_afsk")
	if f == nil {
		t.Fatal("the aprs_afsk fixture is missing from the catalog")
	}
	src := f.build(rate)
	iq := make([]complex128, int(rate))
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

	var got []string
	def := ax25.NewDeframer()
	afsk.New(res.audioRate).Feed(audio, func(bit bool, at int64) {
		def.Feed(bit, at, func(raw []byte, _ int64) {
			fr, err := ax25.Parse(raw)
			if err != nil {
				t.Errorf("a frame passed the FCS but not the address field: %v", err)
				return
			}
			rec := aprs.Parse(fr)
			if rec == nil {
				t.Errorf("a frame decoded but did not parse as APRS: %s", fr)
				return
			}
			got = append(got, rec.DeviceId)
		})
	})

	if exp.Decode == nil {
		t.Fatal("the fixture states no decode expectation")
	}
	if len(got) != exp.Decode.Records {
		t.Fatalf("decoded %d records (%v), want %d", len(got), got, exp.Decode.Records)
	}
	for i, want := range exp.Decode.DeviceIDs {
		if got[i] != want {
			t.Errorf("record %d is from %q, want %q", i, got[i], want)
		}
	}
}

// TestGenerateSkipsAPRSWhenTooShort checks the guard that keeps a half-second
// file from expecting three packets it cannot hold.
func TestGenerateSkipsAPRSWhenTooShort(t *testing.T) {
	var out bytes.Buffer
	o := genOptions{out: t.TempDir(), rate: 2_400_000, duration: 0.5, seed: 1}
	if err := generate(o, &out); err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(out.Bytes(), []byte("skip aprs_afsk")) {
		t.Errorf("aprs_afsk should have been skipped at 0.5 s; output was:\n%s", out.String())
	}
	o.only = []string{"aprs_afsk"}
	if err := generate(o, &bytes.Buffer{}); err == nil {
		t.Error("asking for aprs_afsk at 0.5 s should be an error")
	}
}
