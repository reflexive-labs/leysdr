// SPDX-License-Identifier: Apache-2.0

package main

import (
	"math"
	"math/cmplx"
	"testing"

	"github.com/reflexive-labs/leysdr/go/pkg/dcs"
)

// The DCS fixtures carry the word they say, at the deviation they say: discriminate the IQ,
// average each bit period (which also cancels most of the 1 kHz voice tone), slice at zero and
// compare with the encoder. The second word is read so the low-pass has settled.
func TestDCSFixtureCarriesItsWord(t *testing.T) {
	const rate = 240_000.0
	for _, tc := range []struct {
		code     int
		inverted bool
		decodes  int
	}{{0o23, false, 0o23}, {0o23, true, 0o47}, {0o754, false, 0o754}} {
		src := dcsFixture(rate, tc.code, tc.inverted)
		perBit := rate / dcs.BitRate
		n := int(3 * dcs.WordBits * perBit)
		x := make([]complex128, n)
		// Two blocks, so the filter and phase state are carried across a block boundary.
		src.fill(x[:n/3], 0)
		src.fill(x[n/3:], int64(n/3))
		inst := make([]float64, n)
		for i := 1; i < n; i++ {
			inst[i] = cmplx.Phase(x[i]*cmplx.Conj(x[i-1])) * rate / (2 * math.Pi)
		}
		var got dcs.Word
		peak := 0.0
		for b := range dcs.WordBits {
			lo, hi := int(float64(dcs.WordBits+b)*perBit), int(float64(dcs.WordBits+b+1)*perBit)
			sum := 0.0
			for _, v := range inst[lo:hi] {
				sum += v - src.carrierHz
			}
			mean := sum / float64(hi-lo)
			peak = math.Max(peak, math.Abs(mean))
			if mean > 0 {
				got[b] = 1
			}
		}
		if want := dcs.Encode(tc.code, tc.inverted); got != want {
			t.Errorf("%s inverted=%v: sliced %s, want %s", dcs.Format(tc.code), tc.inverted, got, want)
		}
		if code, inv, ok := dcs.Decode(got); !ok || inv || code != tc.decodes {
			t.Errorf("%s inverted=%v: decodes as %s inverted=%v ok=%v, want %s normal",
				dcs.Format(tc.code), tc.inverted, dcs.Format(code), inv, ok, dcs.Format(tc.decodes))
		}
		// A bit's mean sits a little under the 550 Hz peak (the low-pass rounds each edge), and the
		// voice tone's residue over one bit adds or takes up to about 100 Hz.
		if peak < 450 || peak > 700 {
			t.Errorf("%s: loudest bit mean %.0f Hz, want about %d", dcs.Format(tc.code), peak, dcsDeviationHz)
		}
	}
}

// The expectations are what the decoder rule reads, in the contract's octal-as-decimal.
func TestDCSExpectations(t *testing.T) {
	for name, want := range map[string]struct {
		code int
		inv  bool
	}{"nfm_dcs": {23, false}, "nfm_dcs_inverted": {47, false}, "nfm_dcs_754": {754, false}} {
		f := findFixture(name)
		if f == nil {
			t.Fatalf("%s missing from the catalog", name)
		}
		sa := f.expect(refRate)[0].SubAudible
		if sa == nil || !sa.Detect || sa.ToneHz != 0 || sa.DCSCode != want.code || sa.DCSInverted != want.inv {
			t.Errorf("%s: sub_audible %+v, want dcs_code %d inverted %v, detect, no tone", name, sa, want.code, want.inv)
		}
	}
}
