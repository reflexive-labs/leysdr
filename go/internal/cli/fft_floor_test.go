// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"math"
	"testing"
)

// medianDb answers NaN for an empty row and encoding/json refuses to marshal
// one, so a decode bug would stop the stream with an error rather than emit a
// row saying it measured nothing.
func TestFloorOfIsAlwaysMarshalable(t *testing.T) {
	for _, tc := range []struct {
		name string
		in   []float64
		want float64
	}{
		{"a real row", []float64{-90, -80, -70}, -80},
		{"empty", nil, 0},
		{"all NaN", []float64{math.NaN(), math.NaN()}, 0},
	} {
		got := floorOf(tc.in)
		if math.IsNaN(got) || math.IsInf(got, 0) {
			t.Errorf("%s: %v is not marshalable", tc.name, got)
		}
		if got != tc.want {
			t.Errorf("%s: got %v, want %v", tc.name, got, tc.want)
		}
	}
}

// The floor is carried so the two commands agree about where the noise floor
// is for the same row.
func TestFFTAndSpectrumAgreeOnTheFloor(t *testing.T) {
	bins := []float64{-95, -91, -88, -30, -92, -90, -89}
	fft := FFTRow{Bins: bins, FloorDb: floorOf(bins)}
	spectrum := SpectrumRow{FFTRow: FFTRow{Bins: bins, FloorDb: medianDb(bins)}}
	if fft.FloorDb != spectrum.FloorDb {
		t.Errorf("fft says %v, spectrum says %v", fft.FloorDb, spectrum.FloorDb)
	}
}
