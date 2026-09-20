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

	cases := []struct {
		name  string
		bins  []float64
		gains []*leylinev1.GainState
		want  string
	}{
		{"a healthy band", row(-64, -30), nil, ""},
		{"a peak at the rule's edge", row(-64, -49), nil, ""},
		{"an empty row", nil, nil, ""},
		{"within 3 dB of full scale", row(-64, -3), nil, "A signal is within 3 dB of full scale: the loudest bin reads -3 dBFS. Lower the gain before the radio clips."},
		{"full scale on auto", row(-64, -3), auto, "with the gain on auto. Take the gain by hand and lower it"},
		{"full scale at the lowest gain", row(-64, -3), manual(0), "at the lowest gain. Move the antenna away"},
		{"over full scale", row(-64, 1), nil, "A signal is within 3 dB of full scale"},
		{"just under the margin", row(-64, -3.5), nil, ""},
		{"nothing above the floor", row(-64, -55), nil, "Nothing is above the noise: no bin is 15 dB above the floor (-64 dBFS). Check the antenna; FM broadcast is the band most antennas hear."},
		{"nothing above the floor at the lowest gain", row(-64, -55), manual(0), "Nothing is above the noise: no bin is 15 dB above the floor (-64 dBFS), and the gain is at its lowest. Turn it up, or set it to auto."},
		{"auto is never the minimum", row(-64, -55), auto, "Check the antenna"},
		{"one step up the table is not the minimum", row(-64, -55), manual(0.9), "Check the antenna"},
	}
	for _, c := range cases {
		got := failureWords(c.bins, c.gains, tuner)
		if c.want == "" && got != "" {
			t.Errorf("%s: said %q, want nothing", c.name, got)
		}
		if c.want != "" && !strings.Contains(got, c.want) {
			t.Errorf("%s: said %q, want %q", c.name, got, c.want)
		}
	}
}
