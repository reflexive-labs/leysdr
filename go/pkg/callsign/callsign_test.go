// SPDX-License-Identifier: Apache-2.0

package callsign

import (
	"slices"
	"testing"
)

func TestFind(t *testing.T) {
	for _, tc := range []struct {
		text string
		want []string
	}{
		{"whiskey six alpha bravo charlie", []string{"W6ABC"}},
		{"kilo delta two x-ray yankee zulu", []string{"KD2XYZ"}},
		{"W6ABC", []string{"W6ABC"}},
		{"this is W6ABC, over", []string{"W6ABC"}},
		{"CQ CQ this is Whiskey Six Alpha Bravo Charlie calling", []string{"W6ABC"}},
		{"W 6 A B C", []string{"W6ABC"}},
		{"kilo kilo niner zulu", []string{"KK9Z"}},
		{"november zero oh alpha", nil},
		{"november oh alpha", []string{"N0A"}},
		{"whiskey six alpha bravo charlie slash papa", []string{"W6ABC"}},
		{"W6ABC/M mobile", []string{"W6ABC"}},
		{"two echo zero alpha bravo", []string{"2E0AB"}},
		{"whiskey six alpha bravo charlie. kilo delta two x-ray yankee zulu.", []string{"W6ABC", "KD2XYZ"}},
		{"W6ABC and W6ABC again", []string{"W6ABC"}},
		{"see you at six alpha", nil},
		{"the net starts at seven, see you there", nil},
		{"roger that, good copy, see you later", nil},
		{"I have a radio", nil},
		{"this is W6ABC, kilo delta two x-ray yankee zulu", []string{"W6ABC", "KD2XYZ"}},
		{"W6ABC, W7XYZ", []string{"W6ABC", "W7XYZ"}},
		{"W6ABC; W7XYZ", []string{"W6ABC", "W7XYZ"}},
		{"meet at B2B later", nil},
		{"C3PO said so", nil},
		{"I 6 B", nil},
		{"india six bravo charlie", nil},
		{"N0CALL testing", nil},
		{"N0A", nil},
		{"G4ABC and M0XY", []string{"G4ABC", "M0XY"}},
		{"", nil},
	} {
		if got := Find(tc.text); !slices.Equal(got, tc.want) {
			t.Errorf("Find(%q) = %v, want %v (normalised %q)", tc.text, got, tc.want, Normalise(tc.text))
		}
	}
}

func TestNormalise(t *testing.T) {
	for _, tc := range []struct{ text, want string }{
		{"this is whiskey six alpha bravo charlie", "this is W6ABC"},
		{"see you at six alpha", "see you at 6A"},
		{"kilo six number two", "K62"},
		{"call number two", "call number 2"},
		{"a word with no callsign", "a word with no callsign"},
	} {
		if got := Normalise(tc.text); got != tc.want {
			t.Errorf("Normalise(%q) = %q, want %q", tc.text, got, tc.want)
		}
	}
}
