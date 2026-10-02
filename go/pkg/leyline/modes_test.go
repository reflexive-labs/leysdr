// SPDX-License-Identifier: Apache-2.0

package leyline

import (
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

func TestFullScaleDeviationHz(t *testing.T) {
	cases := []struct {
		mode leylinev1.DemodMode
		bw   uint32
		want uint32
	}{
		{leylinev1.DemodMode_NFM, 12_500, 2_500},
		{leylinev1.DemodMode_NFM, 25_000, 5_000},
		{leylinev1.DemodMode_NFM, 6_000, 2_500},  // clamped up: nothing deviates less
		{leylinev1.DemodMode_NFM, 40_000, 5_000}, // clamped down at narrowband's widest
		{leylinev1.DemodMode_NFM, 0, 2_500},      // an unset bandwidth reads as the default channel
		{leylinev1.DemodMode_NFM, 12_502, 2_500}, // rounded as the engine rounds, not truncated:
		{leylinev1.DemodMode_NFM, 12_503, 2_501}, // 2500.6 is 2501 on the wire
		{leylinev1.DemodMode_NFM, 13_333, 2_667}, // 2666.6 is 2667
		{leylinev1.DemodMode_WFM, 200_000, 75_000},
		{leylinev1.DemodMode_AM, 10_000, 0},
		{leylinev1.DemodMode_LSB, 2_800, 0},
		{leylinev1.DemodMode_CW, 500, 0},
	}
	for _, tc := range cases {
		if got := FullScaleDeviationHz(tc.mode, tc.bw); got != tc.want {
			t.Errorf("FullScaleDeviationHz(%v, %d) = %d, want %d", tc.mode, tc.bw, got, tc.want)
		}
	}
}

func TestParseMode(t *testing.T) {
	for in, want := range map[string]leylinev1.DemodMode{
		"nfm": leylinev1.DemodMode_NFM, "AM": leylinev1.DemodMode_AM, "Wfm": leylinev1.DemodMode_WFM,
		"usb": leylinev1.DemodMode_USB, "lsb": leylinev1.DemodMode_LSB, "cw": leylinev1.DemodMode_CW,
		"raw_iq": leylinev1.DemodMode_RAW_IQ, "RAW-IQ": leylinev1.DemodMode_RAW_IQ,
	} {
		got, err := ParseMode(in)
		if err != nil || got != want {
			t.Errorf("ParseMode(%q) = %v %v, want %v", in, got, err, want)
		}
		if back, err := ParseMode(ModeName(got)); err != nil || back != got {
			t.Errorf("ModeName round-trip for %v failed: %q", got, ModeName(got))
		}
	}
	if _, err := ParseMode("dsb"); err == nil {
		t.Error("ParseMode(dsb): expected error")
	}
}
