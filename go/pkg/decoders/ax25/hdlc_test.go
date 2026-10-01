// SPDX-License-Identifier: Apache-2.0

package ax25_test

import (
	"bytes"
	"testing"

	"github.com/reflexive-labs/leysdr/go/pkg/decoders/ax25"
)

// run pushes a bit stream through a deframer and returns the frames it accepted.
func run(bits []bool) ([][]byte, *ax25.Deframer) {
	d := ax25.NewDeframer()
	var out [][]byte
	for _, b := range bits {
		d.Feed(b, 0, func(raw []byte, _ int64) {
			out = append(out, append([]byte{}, raw...))
		})
	}
	return out, d
}

func ui(info []byte) []byte {
	return ax25.BuildUI(ax25.Address{Call: "APRS"}, ax25.Address{Call: "LEYTST", SSID: 1},
		[]ax25.Address{{Call: "WIDE1", SSID: 1}}, 0xF0, info)
}

func TestEncodeDeframeRoundTrip(t *testing.T) {
	cases := []struct {
		name string
		info []byte
	}{
		{"plain", []byte("!3745.60N/12225.00W>test position")},
		// 0xFE is 01111111 least significant bit first minus the top bit: its
		// five low ones end at a byte boundary, so the stuffed zero lands
		// between two bytes and a deframer that counts within a byte fails here.
		{"five ones at a byte boundary", []byte{0x1F, 0xF8, 0x1F, 0xF8}},
		{"a byte of ones", []byte{0xFF, 0xFF, 0xFF}},
		{"a flag in the payload", []byte{0x7E, 0x7E, 0x7E}},
		{"zeros", []byte{0x00, 0x00, 0x00, 0x00}},
		{"one info byte", []byte{0x41}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			frame := ui(c.info)
			got, d := run(ax25.Encode(frame, 8))
			if len(got) != 1 {
				t.Fatalf("got %d frames (candidates %d, bad %d), want 1", len(got), d.Frames, d.Bad)
			}
			if !bytes.Equal(got[0], frame) {
				t.Errorf("round trip changed the frame:\n got %x\nwant %x", got[0], frame)
			}
		})
	}
}

// TestEncodeStuffsAfterFiveOnes checks the stuffing itself rather than its
// round trip: no run of more than five ones may survive outside a flag.
func TestEncodeStuffsAfterFiveOnes(t *testing.T) {
	bits := ax25.Encode(ui([]byte{0xFF, 0xFF, 0xFF}), 1)
	// Drop the opening and closing flags, each eight bits.
	body := bits[8 : len(bits)-8]
	run := 0
	for i, b := range body {
		if b {
			run++
			if run > 5 {
				t.Fatalf("six ones in a row at bit %d of the stuffed body", i)
			}
			continue
		}
		run = 0
	}
}

func TestDeframerRejectsABadFCS(t *testing.T) {
	frame := ui([]byte("bad checksum"))
	bits := ax25.Encode(frame, 4)
	// Flip a bit in the middle of the body, well clear of the flags.
	bits[len(bits)/2] = !bits[len(bits)/2]
	got, d := run(bits)
	if len(got) != 0 {
		t.Errorf("a frame with a flipped bit was accepted: %x", got[0])
	}
	if d.Frames == 0 || d.Bad == 0 {
		t.Errorf("candidates %d, bad %d: the failure should have been counted", d.Frames, d.Bad)
	}
}

func TestDeframerReadsBackToBackFrames(t *testing.T) {
	a, b := ui([]byte("first")), ui([]byte("second"))
	bits := append(ax25.Encode(a, 4), ax25.Encode(b, 1)...)
	got, _ := run(bits)
	if len(got) != 2 || !bytes.Equal(got[0], a) || !bytes.Equal(got[1], b) {
		t.Fatalf("got %d frames, want the two that were sent", len(got))
	}
}

// TestDeframerIgnoresAnAbort checks that seven ones throw the partial frame
// away rather than letting it run into the next one.
func TestDeframerIgnoresAnAbort(t *testing.T) {
	frame := ui([]byte("after the abort"))
	var bits []bool
	bits = append(bits, false, true, true, true, true, true, true, false) // flag
	for i := 0; i < 40; i++ {
		bits = append(bits, i%3 == 0)
	}
	for i := 0; i < 9; i++ { // an abort: more than six ones
		bits = append(bits, true)
	}
	bits = append(bits, ax25.Encode(frame, 4)...)
	got, _ := run(bits)
	if len(got) != 1 || !bytes.Equal(got[0], frame) {
		t.Fatalf("got %d frames, want the one that followed the abort", len(got))
	}
}

func TestDeframerResetDropsAPartialFrame(t *testing.T) {
	frame := ui([]byte("interrupted"))
	bits := ax25.Encode(frame, 4)
	d := ax25.NewDeframer()
	n := 0
	for i, b := range bits {
		if i == len(bits)-20 {
			d.Reset()
		}
		d.Feed(b, 0, func([]byte, int64) { n++ })
	}
	if n != 0 {
		t.Errorf("a frame survived a reset in the middle of it")
	}
}
