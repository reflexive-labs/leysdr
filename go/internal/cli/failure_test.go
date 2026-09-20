// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"strings"
	"testing"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

// The rows and gains here are the app's (app/Tests/LeylineClientTests/FailureStateTests.swift),
// so the two clients are held to one answer.
func TestFailureWords(t *testing.T) {
	tuner := []*leylinev1.GainElement{{
		Name: "TUNER", MinDb: 0, MaxDb: 49.6, SupportsAuto: true,
		ValidDb: []float64{0, 0.9, 1.4, 2.7, 3.7, 7.7, 8.7, 12.5, 14.4, 15.7, 16.6, 19.7, 20.7, 22.9},
	}}
	row := func(floor, peak float64) []float64 {
		r := make([]float64, 256)
		for i := range r {
			r[i] = floor
		}
		r[100] = peak
		return r
	}
	manual := func(db float64) []*leylinev1.GainState {
		return []*leylinev1.GainState{{Element: "TUNER", Db: db}}
	}
	auto := []*leylinev1.GainState{{Element: "TUNER", Db: 0, Auto: true}}
	// A quarter second at 2.4 MSPS with this many samples at the rails.
	level := func(clipped uint64) *leylinev1.CaptureLevel {
		return &leylinev1.CaptureLevel{CaptureId: "cap_1", ClippedSamples: clipped, TotalSamples: 600_000, PeakDbfs: -0.5}
	}

	cases := []struct {
		name  string
		bins  []float64
		level *leylinev1.CaptureLevel
		gains []*leylinev1.GainState
		want  string
	}{
		{"a healthy band", row(-64, -30), nil, nil, ""},
		{"a peak at the rule's edge", row(-64, -49), nil, nil, ""},
		{"an empty row", nil, nil, nil, ""},
		// Without a level the loudest bin stands in for the converter (an older daemon).
		{"within 3 dB of full scale", row(-64, -3), nil, nil, "A signal is within 3 dB of full scale: the loudest bin reads -3 dBFS. Lower the gain before the radio clips."},
		{"full scale on auto", row(-64, -3), nil, auto, "with the gain on auto. Take the gain by hand and lower it"},
		{"full scale at the lowest gain", row(-64, -3), nil, manual(0), "at the lowest gain. Move the antenna away"},
		{"over full scale", row(-64, 1), nil, nil, "A signal is within 3 dB of full scale"},
		{"just under the margin", row(-64, -3.5), nil, nil, ""},
		// With one, the level is the authority: a clean interval under a bin at full scale is
		// a strong carrier with nothing wrong, and a clipping one is named however the bins read.
		{"a full-scale bin under a clean level", row(-64, 1), level(0), nil, ""},
		{"a clipping radio", row(-64, -30), level(600), nil, "The radio is clipping: 600 of 600000 samples (0.1 %) hit the converter's rails. Lower the gain."},
		{"clipping on auto", row(-64, -30), level(6000), auto, "The radio is clipping: 6000 of 600000 samples (1.0 %) hit the converter's rails with the gain on auto. Take the gain by hand and lower it."},
		{"clipping at the lowest gain", row(-64, -30), level(6000), manual(0), "hit the converter's rails at the lowest gain. Move the antenna away from the transmitter, or add attenuation."},
		{"clipping with no row", nil, level(6000), nil, "The radio is clipping"},
		{"a fraction just over the floor keeps its digits", row(-64, -30), level(66), nil, "66 of 600000 samples (0.01 %)"},
		{"one sample at a rail is not clipping", row(-64, -30), level(1), nil, ""},
		{"the floor itself is not clipping", row(-64, -30), level(60), nil, ""},
		{"a clean level leaves the floor rule alone", row(-64, -55), level(0), nil, "Nothing is above the noise"},
		{"nothing above the floor", row(-64, -55), nil, nil, "Nothing is above the noise: no bin is 15 dB above the floor (-64 dBFS). Check the antenna; FM broadcast is the band most antennas hear."},
		{"nothing above the floor at the lowest gain", row(-64, -55), nil, manual(0), "Nothing is above the noise: no bin is 15 dB above the floor (-64 dBFS), and the gain is at its lowest. Turn it up, or set it to auto."},
		{"auto is never the minimum", row(-64, -55), nil, auto, "Check the antenna"},
		{"one step up the table is not the minimum", row(-64, -55), nil, manual(0.9), "Check the antenna"},
	}
	for _, c := range cases {
		got := failureWords(c.bins, c.level, c.gains, tuner)
		if c.want == "" && got != "" {
			t.Errorf("%s: said %q, want nothing", c.name, got)
		}
		if c.want != "" && !strings.Contains(got, c.want) {
			t.Errorf("%s: said %q, want %q", c.name, got, c.want)
		}
	}
}
