// SPDX-License-Identifier: Apache-2.0

package main

import (
	"errors"
	"fmt"
	"io"
	"math"
	"path/filepath"
	"slices"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/decoders/modes"
	"github.com/reflexive-labs/leysdr/go/pkg/iqfile"
)

// decodeADSB runs the file at path through the ADS-B decoder in 4096-sample blocks and returns
// the records and their reply end times in seconds.
func decodeADSB(t *testing.T, path, format string, rate float64) ([]*leylinev1.DecodeRecord, []float64) {
	t.Helper()
	r, err := iqfile.Open(path, format)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	d := modes.NewDecoder(rate)
	d.Reset(0)
	var recs []*leylinev1.DecodeRecord
	var ends []float64
	buf := make([]complex64, 4096)
	for {
		n, err := r.Read(buf)
		d.Feed(buf[:n], func(f modes.Frame, rec *leylinev1.DecodeRecord) {
			recs = append(recs, rec)
			ends = append(ends, float64(f.End)/rate)
		})
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	return recs, ends
}

// adsb_burst decodes to every reply in its schedule, the two aircraft in the order its expect
// entry names, positions included.
func TestADSBBurstDecodes(t *testing.T) {
	f := findFixture("adsb_burst")
	if f == nil {
		t.Fatal("the adsb_burst fixture is missing from the catalog")
	}
	path := filepath.Join(t.TempDir(), "adsb_burst.cf32")
	if err := generateOne(f, genOptions{rate: refRate, duration: 1, seed: 1}, path); err != nil {
		t.Fatal(err)
	}
	exp := f.expect(sceneADSBRate)[0].Decode
	recs, _ := decodeADSB(t, path, iqfile.FormatCF32, sceneADSBRate)
	var ids []string
	var positions int
	for _, r := range recs {
		if !slices.Contains(ids, r.GetDeviceId()) {
			ids = append(ids, r.GetDeviceId())
		}
		if r.GetPosition() != nil {
			positions++
		}
	}
	if len(recs) != exp.Records || !slices.Equal(ids, exp.DeviceIDs) {
		t.Errorf("decoded %d records from %v, want %d from %v", len(recs), ids, exp.Records, exp.DeviceIDs)
	}
	if positions != len(adsbBurstFlights) {
		t.Errorf("%d positions, want one per aircraft (the second of its two frames)", positions)
	}
}

// scene_adsb's traffic, cut to five seconds and through the cu8 round trip, decodes back to its
// tracks: every reply, each position within 20 m of where its flight was.
func TestSceneADSBDecodes(t *testing.T) {
	const dur = 5
	scene := findFixture("scene_adsb")
	if scene == nil || scene.centerHz != 1_090_000_000 || scene.fixedRate != 2_400_000 {
		t.Fatalf("scene_adsb is not at 1090 MHz and 2.4 MSPS: %+v", scene)
	}
	f := &fixture{
		name: "short_adsb", centerHz: scene.centerHz, format: iqfile.FormatCU8, fixedRate: sceneADSBRate,
		fixedDurationS: dur, noiseDBFS: sceneNoiseDBFS,
		build: func(rate float64) []source {
			s := sceneADSBSource(rate)
			s.durationS = dur
			return []source{s}
		},
		expect: func(float64) []iqfile.Expect { return nil },
	}
	path := filepath.Join(t.TempDir(), "short_adsb.cu8")
	if err := generateOne(f, genOptions{seed: 1}, path); err != nil {
		t.Fatal(err)
	}
	recs, ends := decodeADSB(t, path, iqfile.FormatCU8, sceneADSBRate)
	if want := len(modes.Schedule(sceneADSBFlights, dur)); len(recs) != want {
		t.Errorf("decoded %d records, want %d", len(recs), want)
	}
	flights := map[string]modes.Flight{}
	for _, fl := range sceneADSBFlights {
		flights[fmt.Sprintf("%06X", fl.Addr)] = fl
	}
	var positions int
	for i, r := range recs {
		fl, ok := flights[r.GetDeviceId()]
		if !ok {
			t.Fatalf("a record from %s, which is not flying", r.GetDeviceId())
		}
		p := r.GetPosition()
		if p == nil {
			continue
		}
		positions++
		lat, lon, _ := fl.At(ends[i] - 112e-6 - 8e-6)
		dLat, dLon := (p.GetLatitude()-lat)*111_320, (p.GetLongitude()-lon)*111_320*math.Cos(lat*math.Pi/180)
		if math.Hypot(dLat, dLon) > 20 {
			t.Errorf("%s: %.5f, %.5f is %.0f m from its track", fl.Callsign, p.GetLatitude(), p.GetLongitude(), math.Hypot(dLat, dLon))
		}
	}
	// Ten positions each in 5 s; the first of each aircraft is one frame alone.
	if want := 9 * len(sceneADSBFlights); positions != want {
		t.Errorf("%d positions, want %d", positions, want)
	}
}
