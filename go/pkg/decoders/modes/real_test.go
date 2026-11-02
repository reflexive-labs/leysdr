// SPDX-License-Identifier: Apache-2.0

package modes

import (
	"encoding/binary"
	"io"
	"math"
	"os"
	"sort"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// realCapture is the antenna recording the decoder was measured on: 10 s at 1090 MHz, 2.4 MSPS,
// cf32, an RTL-SDR at 40 dB gain, 2026-11-02. It is not in the repository (rf-captures/ is
// ignored); LEYDEC_ADSB_CAPTURE names another copy.
const realCapture = "/Users/pupius/Projects/Solo/leysdr/rf-captures/adsb-1090-g40-antenna2.cf32"

// TestRealCapture decodes the antenna recording, skipping the first 0.5 s while the tuner
// settles. The aircraft ACEB61 was climbing out near the receiver; 19 of its extended squitters
// were decoded by a separate script before this package existed, and this decoder makes 27
// records from it, 9 of them positions.
func TestRealCapture(t *testing.T) {
	path := os.Getenv("LEYDEC_ADSB_CAPTURE")
	if path == "" {
		path = realCapture
	}
	f, err := os.Open(path)
	if err != nil {
		t.Skipf("no capture to decode (%v)", err)
	}
	defer f.Close()
	const rate = 2_400_000
	if _, err := f.Seek(rate/2*8, io.SeekStart); err != nil {
		t.Fatal(err)
	}
	d := NewDecoder(rate)
	d.Reset(rate / 2)
	byID := map[string]int{}
	kinds := map[string]int{}
	var positions []*leylinev1.Position
	buf := make([]byte, 4096*8)
	iq := make([]complex64, 4096)
	start := time.Now()
	var samples int
	for {
		n, err := io.ReadFull(f, buf)
		n /= 8
		for i := range n {
			re := math.Float32frombits(binary.LittleEndian.Uint32(buf[8*i:]))
			im := math.Float32frombits(binary.LittleEndian.Uint32(buf[8*i+4:]))
			iq[i] = complex(re, im)
		}
		samples += n
		d.Feed(iq[:n], func(_ Frame, rec *leylinev1.DecodeRecord) {
			byID[rec.GetDeviceId()]++
			kinds[rec.GetKind()]++
			if rec.GetPosition() != nil {
				positions = append(positions, rec.GetPosition())
			}
		})
		if err != nil {
			break
		}
	}
	el := time.Since(start)
	st := d.Stats()
	t.Logf("%d samples (%.1f s) in %v: %.1f MSPS; %d candidates, %d frames (%d corrected)",
		samples, float64(samples)/rate, el, float64(samples)/el.Seconds()/1e6, st.Candidates, st.Frames, st.Corrected)
	ids := make([]string, 0, len(byID))
	for id := range byID {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		t.Logf("  %s: %d records", id, byID[id])
	}
	t.Logf("kinds %v", kinds)
	for _, p := range positions {
		t.Logf("  position %.5f, %.5f alt %.0f m", p.GetLatitude(), p.GetLongitude(), p.GetAltitudeM())
	}
	if byID["ACEB61"] < 15 {
		t.Errorf("%d records from ACEB61, want at least 15", byID["ACEB61"])
	}
}
