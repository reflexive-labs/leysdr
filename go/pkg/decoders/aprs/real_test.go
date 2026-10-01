// SPDX-License-Identifier: Apache-2.0

package aprs_test

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"

	"github.com/reflexive-labs/leysdr/go/pkg/decoders/afsk"
	"github.com/reflexive-labs/leysdr/go/pkg/decoders/aprs"
	"github.com/reflexive-labs/leysdr/go/pkg/decoders/ax25"
)

// TestRealCaptureDecodes runs the chain over off-air recordings of
// 144.39 MHz, 48 kHz S16 mono through the NFM chain. The files are gitignored
// and the test skips without them. It reports what it found and fails only on
// an error, never on a count: 144.39 is quiet where the recordings were made,
// a tone scan shows one of the two files carries a single packet and the other
// carries none, and a test that required more would be testing channel traffic
// rather than the decoder. The measured counts live in the afsk package's doc
// comment.
func TestRealCaptureDecodes(t *testing.T) {
	names := []string{"aprs_144390_auto.s16", "aprs_144390_g40.s16"}
	found := 0
	total := 0
	for _, name := range names {
		path := filepath.Join("..", "..", "..", "..", "rf-captures", name)
		audio, err := readS16(path)
		if os.IsNotExist(err) {
			t.Logf("%s is not here; skipping it", name)
			continue
		}
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		found++

		def := ax25.NewDeframer()
		crcOK, parsed := 0, 0
		afsk.New(48000).Feed(audio, func(bit bool, at int64) {
			def.Feed(bit, at, func(raw []byte, at int64) {
				crcOK++
				f, err := ax25.Parse(raw)
				if err != nil {
					t.Logf("%s: a frame passed the FCS but not the address field: %v", name, err)
					return
				}
				if rec := aprs.Parse(f); rec != nil {
					parsed++
					t.Logf("%s: %.1f s %s", name, float64(at)/48000, f)
				}
			})
		})
		total += crcOK
		t.Logf("%s: %.0f s of audio, %d flag-delimited candidates, %d passed the FCS, %d parsed as APRS",
			name, float64(len(audio))/48000, def.Frames, crcOK, parsed)
	}
	if found == 0 {
		t.Skip("no capture in rf-captures/; nothing to decode")
	}
	if total == 0 {
		t.Log("no frame passed the FCS in any capture, which is what a quiet channel looks like")
	}
}

// readS16 loads a mono 16-bit little-endian PCM file as float32.
func readS16(path string) ([]float32, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	out := make([]float32, len(b)/2)
	for i := range out {
		out[i] = float32(int16(binary.LittleEndian.Uint16(b[2*i:]))) / 32768
	}
	return out, nil
}
