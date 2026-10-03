// SPDX-License-Identifier: Apache-2.0

package main

import (
	"math/cmplx"
	"math/rand/v2"
	"testing"
)

// The streamed stage 1 is the in-memory one: fed in blocks of any size, including blocks
// shorter than the filter and than one decimation step, it produces the samples the mix and
// the decimating filter produce over the whole array, to rounding (arm64 fuses the
// multiply-adds differently in the two loops).
func TestStage1Streams(t *testing.T) {
	rng := rand.New(rand.NewPCG(3, 4))
	x := make([]complex128, 20_000)
	for i := range x {
		x[i] = complex(rng.NormFloat64(), rng.NormFloat64())
	}
	for _, tc := range []struct {
		rate float64
		mode string
	}{{2_400_000, "NFM"}, {240_000, "NFM"}, {240_000, "WFM"}, {1_000_000, "USB"}} {
		p, err := planChain(tc.rate, tc.mode, 25_000, 12_500)
		if err != nil {
			t.Fatal(err)
		}
		want := mixNCO(x, p.nco, tc.rate)
		if p.taps1 != nil {
			want = firDecimate(want, p.taps1, p.d1)
		}
		for _, block := range []int{len(x), 4096, 1000, 7, 1} {
			s := p.stage1()
			for i := 0; i < len(x); i += block {
				s.feed(x[i:min(i+block, len(x))])
			}
			if len(s.out) != len(want) {
				t.Fatalf("%s at %.0f, blocks of %d: %d outputs, want %d", tc.mode, tc.rate, block, len(s.out), len(want))
			}
			for i := range want {
				if cmplx.Abs(s.out[i]-want[i]) > 1e-12*(1+cmplx.Abs(want[i])) {
					t.Fatalf("%s at %.0f, blocks of %d: output %d is %v, want %v", tc.mode, tc.rate, block, i, s.out[i], want[i])
				}
			}
		}
	}
}
