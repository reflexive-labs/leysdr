// SPDX-License-Identifier: Apache-2.0

package leyline

import (
	"errors"
	"testing"
)

// ParseTone accepts CHIRP's spellings and nothing else: a standard CTCSS tone with one decimal,
// a DCS code as D, three octal digits and the polarity letter. What it prints back is the
// spelling it read, and Words is what a table shows.
func TestParseTone(t *testing.T) {
	cases := []struct {
		in    string
		words string
		ctcss float64
		dcs   int
		inv   bool
	}{
		{"100.0", "PL 100.0", 100.0, 0, false},
		{"67.0", "PL 67.0", 67.0, 0, false},
		{"254.1", "PL 254.1", 254.1, 0, false},
		{"69.3", "PL 69.3", 69.3, 0, false},
		{"D023N", "DCS 023", 0, 0o023, false},
		{"D754I", "DCS 754 inverted", 0, 0o754, true},
	}
	for _, c := range cases {
		got, err := ParseTone(c.in)
		if err != nil {
			t.Errorf("ParseTone(%q): %v", c.in, err)
			continue
		}
		if got.CTCSSHz != c.ctcss || got.DCSCode != c.dcs || got.DCSInverted != c.inv {
			t.Errorf("ParseTone(%q) = %+v", c.in, got)
		}
		if got.String() != c.in {
			t.Errorf("ParseTone(%q).String() = %q, want the spelling it read", c.in, got.String())
		}
		if got.Words() != c.words {
			t.Errorf("ParseTone(%q).Words() = %q, want %q", c.in, got.Words(), c.words)
		}
	}
	for _, bad := range []string{"100", "100.05", "100.00", "D023", "PL 100.0", "023N", "D999N", "D024N", "d023n", "D023X", "", " 100.0", "100.1"} {
		_, err := ParseTone(bad)
		if err == nil {
			t.Errorf("ParseTone(%q): expected error", bad)
			continue
		}
		if !errors.Is(err, ErrTone) || err.Error() != "tone must be a CTCSS tone such as 100.0 or a DCS code such as D023N" {
			t.Errorf("ParseTone(%q) = %v, want the shared sentence", bad, err)
		}
	}
}

// The CTCSS table is CHIRP's fifty tones: the 38 EIA tones and the twelve extras every current
// radio menu offers, each spelled with one decimal so the table can be matched as strings.
func TestCTCSSTable(t *testing.T) {
	if len(CTCSSTones) != 50 {
		t.Fatalf("CTCSSTones has %d entries, want 50", len(CTCSSTones))
	}
	for i := 1; i < len(CTCSSTones); i++ {
		if CTCSSTones[i] <= CTCSSTones[i-1] {
			t.Errorf("CTCSSTones is not ascending at %d: %v then %v", i, CTCSSTones[i-1], CTCSSTones[i])
		}
	}
	for _, hz := range CTCSSTones {
		tone, err := ParseTone(Tone{CTCSSHz: hz}.String())
		if err != nil || tone.CTCSSHz != hz {
			t.Errorf("tone %v does not round-trip through String: %+v, %v", hz, tone, err)
		}
	}
}
