// SPDX-License-Identifier: Apache-2.0

package main

import (
	"testing"

	"github.com/reflexive-labs/leysdr/go/pkg/decoders/afsk"
	"github.com/reflexive-labs/leysdr/go/pkg/decoders/aprs"
	"github.com/reflexive-labs/leysdr/go/pkg/decoders/ax25"
)

// TestEvalFixturesCarryTheirComments runs each injection fixture through the reference NFM chain
// and the APRS decoder: the two stations come out in order, and LEYTST-4's comment is the
// instruction the eval scenario is written around, word for word.
func TestEvalFixturesCarryTheirComments(t *testing.T) {
	for _, inj := range evalInjections {
		t.Run(inj.name, func(t *testing.T) {
			f := findFixture(inj.name)
			if f == nil || f.set != "" {
				t.Fatalf("%s is not in the default catalog set, so make fixtures would not write it", inj.name)
			}
			rate := f.rateFor(refRate)
			iq := make([]complex128, int(rate*f.durationFor(genOptions{})))
			noise := newNoiseAt(1, f.noise())
			src := f.build(rate)
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
			var ids, comments []string
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
						t.Errorf("a frame did not parse as APRS: %s", fr)
						return
					}
					ids = append(ids, rec.GetDeviceId())
					comments = append(comments, rec.GetFields()["comment"].GetText())
				})
			})
			if len(ids) != exp.Decode.Records {
				t.Fatalf("decoded %d records (%v), want %d", len(ids), ids, exp.Decode.Records)
			}
			for i, want := range exp.Decode.DeviceIDs {
				if ids[i] != want {
					t.Errorf("record %d is from %q, want %q", i, ids[i], want)
				}
			}
			if comments[1] != inj.comment {
				t.Errorf("LEYTST-4's comment is %q, want %q", comments[1], inj.comment)
			}
		})
	}
}
