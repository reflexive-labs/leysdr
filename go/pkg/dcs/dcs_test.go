// SPDX-License-Identifier: Apache-2.0

package dcs

import (
	"slices"
	"strings"
	"testing"
)

// word parses 23 characters of 0 and 1 in transmitted order.
func word(t *testing.T, s string) Word {
	t.Helper()
	s = strings.ReplaceAll(s, " ", "")
	if len(s) != WordBits {
		t.Fatalf("word %q is %d bits", s, len(s))
	}
	var w Word
	for i, c := range s {
		w[i] = byte(c - '0')
	}
	return w
}

// The two words a handheld sent on 2026-09-23 (rf-captures/ht-dcs-023.cf32 and
// ht-dcs-754.cf32), as sliced from the keyed span in transmitted order, positive deviation a one.
// The receiver's alignment was arbitrary, so each is a rotation of the word as framed.
const (
	heard023 = "10010000001110001101111"
	heard754 = "10011111000001000110111"
)

// The encoder reproduces the parity the handheld sent. This is the check that the polynomial, the
// bit order and the place of the fixed bits are the ones on the air.
func TestEncodeMatchesTheHandheld(t *testing.T) {
	for _, tc := range []struct {
		code       int
		heard      string
		rotate     int
		framed     string
		parity     string
		parityBits uint16
	}{
		{0o23, heard023, 22, "110010000 001 11000110111", "11000110111", 0b11000110111},
		{0o754, heard754, 15, "001101111 001 11110000010", "11110000010", 0b11110000010},
	} {
		framed := word(t, tc.framed)
		if got := word(t, tc.heard).Rotate(tc.rotate); got != framed {
			t.Errorf("%s: the heard word rotated by %d is %s, want %s", Format(tc.code), tc.rotate, got, framed)
		}
		enc := Encode(tc.code, false)
		if enc != framed {
			t.Errorf("Encode(%s) = %s, want %s as the handheld sent it", Format(tc.code), enc, framed)
		}
		if got := enc.String()[12:]; got != tc.parity {
			t.Errorf("%s parity %s, want %s", Format(tc.code), got, tc.parity)
		}
		if got := Parity(tc.code); got != tc.parityBits {
			t.Errorf("Parity(%s) = %011b, want %011b", Format(tc.code), got, tc.parityBits)
		}
		if !word(t, tc.heard).Valid() {
			t.Errorf("the heard %s word is not a codeword under 0x%X", Format(tc.code), Poly)
		}
	}
}

// Every rotation of a codeword divides exactly, as a cyclic code's does, and so does its
// complement: which is why the inverted stream is also valid and the receiver needs no framing.
func TestEveryRotationAndComplementIsACodeword(t *testing.T) {
	for _, code := range Codes {
		w := Encode(code, false)
		for k := range WordBits {
			if !w.Rotate(k).Valid() || !w.Rotate(k).Complement().Valid() {
				t.Fatalf("%s rotated %d: not a codeword in both polarities", Format(code), k)
			}
		}
	}
	w := Encode(0o23, false)
	w[5] ^= 1
	if w.Valid() {
		t.Error("a word with one bit flipped must fail the parity check")
	}
}

// The alias facts the two takes showed: the fixed bits do not
// frame a word, and the standard list is what picks the code.
func TestAliases(t *testing.T) {
	oct := func(cs []int) []string {
		out := make([]string, len(cs))
		for i, c := range cs {
			out[i] = Format(c)
		}
		slices.Sort(out)
		return out
	}
	for _, tc := range []struct {
		code          int
		normal, inver []string
	}{
		{0o23, []string{"023", "340", "766"}, []string{"047", "375", "707"}},
		{0o754, []string{"076", "203", "754"}, []string{"060", "116", "737"}},
	} {
		w := Encode(tc.code, false)
		if got := oct(w.Reads()); !slices.Equal(got, tc.normal) {
			t.Errorf("%s normal reads %v, want %v", Format(tc.code), got, tc.normal)
		}
		if got := oct(w.Complement().Reads()); !slices.Equal(got, tc.inver) {
			t.Errorf("%s inverted reads %v, want %v", Format(tc.code), got, tc.inver)
		}
	}
	for _, c := range []int{0o76, 0o203, 0o340, 0o766} {
		if IsStandard(c) {
			t.Errorf("%s is a rotation alias and must not be on the list", Format(c))
		}
	}
	if !IsStandard(0o116) || !IsStandard(0o47) {
		t.Error("116 and 047 are standard codes: the 754N/116I and 023N/047I pairs")
	}
}

// Decode applies the daemon's rule at any alignment, and names the code the handheld was set to.
func TestDecodeTheHandheld(t *testing.T) {
	for _, tc := range []struct {
		heard string
		code  int
	}{{heard023, 0o23}, {heard754, 0o754}} {
		w := word(t, tc.heard)
		for k := range WordBits {
			code, inv, ok := Decode(w.Rotate(k))
			if !ok || code != tc.code || inv {
				t.Fatalf("Decode(%s rotated %d) = %s inverted=%v ok=%v, want %s normal", tc.heard, k, Format(code), inv, ok, Format(tc.code))
			}
		}
	}
}

// Every standard code's inverted word reads as exactly one other standard code in the received
// polarity, so the rule that prefers the received polarity names the partner, normal. 023 sent
// inverted decodes as 047 and 754 inverted as 116; no word decodes with inverted true.
func TestListIsClosedUnderInversion(t *testing.T) {
	for _, code := range Codes {
		var partners []int
		for _, c := range Encode(code, true).Reads() {
			if IsStandard(c) {
				partners = append(partners, c)
			}
		}
		if len(partners) != 1 {
			t.Fatalf("%s inverted reads %d standard codes, want exactly one", Format(code), len(partners))
		}
		got, inv, ok := Decode(Encode(code, true))
		if !ok || inv || got != partners[0] {
			t.Errorf("Decode(%s inverted) = %s inverted=%v ok=%v, want %s normal", Format(code), Format(got), inv, ok, Format(partners[0]))
		}
		if back, _, _ := Decode(Encode(partners[0], true)); back != code {
			t.Errorf("%s and %s must pair both ways, got %s", Format(code), Format(partners[0]), Format(back))
		}
		if c, inv, ok := Decode(Encode(code, false)); !ok || inv || c != code {
			t.Errorf("Decode(%s) = %s inverted=%v ok=%v", Format(code), Format(c), inv, ok)
		}
	}
	for want, code := range map[int]int{0o47: 0o23, 0o116: 0o754} {
		if got, _, _ := Decode(Encode(code, true)); got != want {
			t.Errorf("%s inverted decodes as %s, want %s", Format(code), Format(got), Format(want))
		}
	}
}

// A word that is no standard code in either polarity names none.
func TestDecodeRefusesAnUnlistedWord(t *testing.T) {
	var zero Word
	if _, _, ok := Decode(zero); ok {
		t.Error("an all-zero word carries no 001 and must not decode")
	}
	w := Encode(0o23, false)
	w[3] ^= 1
	if c, _, ok := Decode(w); ok {
		t.Errorf("a word with a bit error decoded as %s; the rule corrects nothing", Format(c))
	}
}

func TestCodeList(t *testing.T) {
	if len(Codes) != 104 {
		t.Fatalf("%d codes, want 104", len(Codes))
	}
	if !slices.IsSorted(Codes) {
		t.Error("Codes must be sorted: IsStandard searches it")
	}
	for _, c := range Codes {
		if c <= 0 || c > 0o777 {
			t.Errorf("code %o out of range", c)
		}
	}
}

func TestWireIsOctalAsDecimal(t *testing.T) {
	for code, wire := range map[int]uint32{0o23: 23, 0o754: 754, 0o116: 116, 0o7: 7, 0: 0} {
		if got := Wire(code); got != wire {
			t.Errorf("Wire(%o) = %d, want %d", code, got, wire)
		}
		if got, ok := FromWire(wire); !ok || got != code {
			t.Errorf("FromWire(%d) = %o %v, want %o", wire, got, ok, code)
		}
	}
	for _, bad := range []uint32{8, 19, 780, 1000} {
		if _, ok := FromWire(bad); ok {
			t.Errorf("FromWire(%d) must fail", bad)
		}
	}
	if Format(0o23) != "023" || Format(0o754) != "754" {
		t.Error("Format pads to three octal digits")
	}
}
