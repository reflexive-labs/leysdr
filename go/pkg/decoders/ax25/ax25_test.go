// SPDX-License-Identifier: Apache-2.0

package ax25_test

import (
	"testing"

	"github.com/reflexive-labs/leysdr/go/pkg/decoders/ax25"
)

// TestFCSCheckValue pins the FCS against the published check value for
// CRC-16/X-25: the string "123456789" gives 0x906E. Every other number in this
// package depends on that one being right.
func TestFCSCheckValue(t *testing.T) {
	if got := ax25.FCS([]byte("123456789")); got != 0x906E {
		t.Errorf("FCS(123456789) = %#04x, want 0x906e", got)
	}
}

func TestCheckFCS(t *testing.T) {
	frame := ax25.BuildUI(
		ax25.Address{Call: "APRS"}, ax25.Address{Call: "N0CALL", SSID: 9},
		[]ax25.Address{{Call: "WIDE1", SSID: 1}}, 0xF0, []byte("!4903.50N/07201.75W-Test"))
	sum := ax25.FCS(frame)
	with := append(append([]byte{}, frame...), byte(sum), byte(sum>>8))
	if !ax25.CheckFCS(with) {
		t.Error("a frame with its own FCS appended did not check out")
	}
	with[3] ^= 0x02 // one bit of the destination callsign
	if ax25.CheckFCS(with) {
		t.Error("a corrupted frame passed the FCS check")
	}
}

func TestAddressRoundTrip(t *testing.T) {
	cases := []ax25.Address{
		{Call: "APRS"},
		{Call: "N0CALL", SSID: 9},
		{Call: "WIDE2", SSID: 2, Repeated: true},
		{Call: "N0CALL", SSID: 15},
	}
	for _, want := range cases {
		enc := ax25.EncodeAddress(want, true)
		frame := append(ax25.EncodeAddress(ax25.Address{Call: "APRS"}, false), enc...)
		frame = append(frame, 0x03, 0xF0)
		got, err := ax25.Parse(frame)
		if err != nil {
			t.Fatalf("%v: %v", want, err)
		}
		if got.Source != want {
			t.Errorf("round trip gave %+v, want %+v", got.Source, want)
		}
	}
}

func TestParseTNC2Form(t *testing.T) {
	frame := ax25.BuildUI(
		ax25.Address{Call: "APN0A0"}, ax25.Address{Call: "N0CALL", SSID: 1},
		[]ax25.Address{{Call: "WIDE1", SSID: 1, Repeated: true}, {Call: "WIDE2", SSID: 1}},
		0xF0, []byte("=4903.50N/07201.75W"))
	f, err := ax25.Parse(frame)
	if err != nil {
		t.Fatal(err)
	}
	const want = "N0CALL-1>APN0A0,WIDE1-1*,WIDE2-1:=4903.50N/07201.75W"
	if f.String() != want {
		t.Errorf("String() = %q, want %q", f.String(), want)
	}
	if !f.UI() {
		t.Error("a control byte of 0x03 is a UI frame")
	}
	if f.PID != 0xF0 {
		t.Errorf("PID = %#02x, want 0xf0", f.PID)
	}
}

func TestParseRejectsShortFrames(t *testing.T) {
	if _, err := ax25.Parse(make([]byte, 12)); err == nil {
		t.Error("a 12-byte frame cannot hold two addresses and should be refused")
	}
	// Every address byte has its extension bit clear, so the field never ends.
	noEnd := make([]byte, 80)
	if _, err := ax25.Parse(noEnd); err == nil {
		t.Error("an address field with no end should be refused")
	}
}
