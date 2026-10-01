// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"testing"

	"github.com/reflexive-labs/leysdr/go/pkg/decoders/ais"
)

// TestAISFixtureDecodes runs the ais_burst fixture through the reference NFM
// chain and the AIS decoder, so the sidecar's decode expectation is a
// measurement rather than a claim: two records, from the two vessels it names,
// in order.
func TestAISFixtureDecodes(t *testing.T) {
	const rate = 2_400_000
	f := findFixture("ais_burst")
	if f == nil {
		t.Fatal("the ais_burst fixture is missing from the catalog")
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
	def := ais.NewDeframer()
	ais.New(res.audioRate).Feed(audio, func(bit bool, at int64) {
		def.Feed(bit, at, func(raw []byte, _ int64) {
			m, err := ais.Parse(raw)
			if err != nil {
				t.Errorf("a frame passed the FCS but did not parse: %v", err)
				return
			}
			got = append(got, m.Record().DeviceId)
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

// TestGenerateSkipsAISWhenTooShort checks the guard that keeps a half-second
// file from expecting records it cannot hold.
func TestGenerateSkipsAISWhenTooShort(t *testing.T) {
	var out bytes.Buffer
	o := genOptions{out: t.TempDir(), rate: 2_400_000, duration: 0.5, seed: 1}
	if err := generate(o, &out); err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(out.Bytes(), []byte("skip ais_burst")) {
		t.Errorf("ais_burst should have been skipped at 0.5 s; output was:\n%s", out.String())
	}
	o.only = []string{"ais_burst"}
	if err := generate(o, &bytes.Buffer{}); err == nil {
		t.Error("asking for ais_burst at 0.5 s should be an error")
	}
}
