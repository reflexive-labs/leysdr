// SPDX-License-Identifier: Apache-2.0

package modes

import (
	"fmt"
	"math"
	"math/rand/v2"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

const testRate = 2_400_000

var testFlights = []Flight{
	{Addr: 0xA1B2C3, Callsign: "LEY101", Squawk: "1200", Lat: 37.70, Lon: -122.30, AltFt: 3500, GSKn: 180, TrackDeg: 300, VRFpm: 1500},
	{Addr: 0xA4F001, Callsign: "LEY202", Squawk: "4521", Lat: 37.55, Lon: -122.10, AltFt: 36000, GSKn: 470, TrackDeg: 95},
	{Addr: 0xC0FFEE, Callsign: "LEY303", Squawk: "7000", Lat: 37.90, Lon: -122.60, AltFt: 11000, GSKn: 290, TrackDeg: 160, VRFpm: -2000},
}

// synth renders transmissions into complex baseband at testRate: each aircraft on its own
// carrier offset and phase, at amp, over complex Gaussian noise of RMS sigma.
func synth(tx []Transmission, durationS, amp, sigma float64, seed uint64) []complex64 {
	n := int(durationS * testRate)
	env := make([]float64, n)
	carrier := make([]float64, n) // the carrier offset of whoever is on the air, cycles per sample
	for _, t := range tx {
		start := t.T * testRate
		Render(t.Msg, testRate, start, env, 0)
		f := float64(int(t.Addr%7)-3) * 40_000 / testRate
		for k := int(start); k < int(start+FrameUs(t.Msg)*2.4)+2 && k < n; k++ {
			carrier[k] = f
		}
	}
	rng := rand.New(rand.NewPCG(seed, 1090))
	out := make([]complex64, n)
	for k := range out {
		ph := 2 * math.Pi * carrier[k] * float64(k)
		re := amp*env[k]*math.Cos(ph) + sigma*rng.NormFloat64()/math.Sqrt2
		im := amp*env[k]*math.Sin(ph) + sigma*rng.NormFloat64()/math.Sqrt2
		out[k] = complex(float32(re), float32(im))
	}
	return out
}

// decodeAll runs a Decoder over iq in 4096-sample blocks, as the daemon delivers them.
func decodeAll(iq []complex64, emit func(Frame, *leylinev1.DecodeRecord)) *Decoder {
	d := NewDecoder(testRate)
	d.Reset(0)
	for i := 0; i < len(iq); i += 4096 {
		d.Feed(iq[i:min(i+4096, len(iq))], emit)
	}
	return d
}

// The schedule's replies never overlap: a fixture with garbled replies would test garbling.
func TestScheduleDoesNotOverlap(t *testing.T) {
	tx := Schedule(testFlights, 20)
	for i := 1; i < len(tx); i++ {
		if gap := tx[i].T - tx[i-1].T; gap < 130e-6 {
			t.Fatalf("replies at %.6f and %.6f s overlap", tx[i-1].T, tx[i].T)
		}
	}
}

// Three aircraft at 20 dB over the noise decode back to their tracks: every reply, each
// position within 20 m of where the flight was, the callsigns, speeds, altitudes and squawks.
func TestSyntheticTracksDecode(t *testing.T) {
	const dur = 6.0
	tx := Schedule(testFlights, dur)
	iq := synth(tx, dur, 1, 0.1, 1)
	flights := map[string]Flight{}
	for _, f := range testFlights {
		flights[fmt.Sprintf("%06X", f.Addr)] = f
	}
	var recs, positions int
	got := map[string]map[string]bool{}
	decodeAll(iq, func(fr Frame, rec *leylinev1.DecodeRecord) {
		recs++
		f, ok := flights[rec.GetDeviceId()]
		if !ok {
			t.Errorf("a record from %s, which is not flying", rec.GetDeviceId())
			return
		}
		ts := float64(fr.End)/testRate - FrameUs(fr.Msg)*1e-6
		fields := rec.GetFields()
		if got[rec.GetDeviceId()] == nil {
			got[rec.GetDeviceId()] = map[string]bool{}
		}
		got[rec.GetDeviceId()][rec.GetKind()] = true
		if p := rec.GetPosition(); p != nil {
			positions++
			lat, lon, alt := f.At(ts)
			if d := distanceKm(p.GetLatitude(), p.GetLongitude(), lat, lon); d > 0.02 {
				t.Errorf("%s at %.3f s: %.5f, %.5f is %.0f m from the track", f.Callsign, ts, p.GetLatitude(), p.GetLongitude(), d*1000)
			}
			if math.Abs(p.GetAltitudeM()-alt*0.3048) > 13 {
				t.Errorf("%s altitude %.0f m, want %.0f", f.Callsign, p.GetAltitudeM(), alt*0.3048)
			}
		}
		switch rec.GetKind() {
		case KindIdentification:
			if fields["callsign"].GetText() != f.Callsign {
				t.Errorf("callsign %q, want %q", fields["callsign"].GetText(), f.Callsign)
			}
		case KindVelocity:
			if math.Abs(fields["ground_speed_kn"].GetNumber()-f.GSKn) > 1 || math.Abs(fields["track_deg"].GetNumber()-f.TrackDeg) > 0.5 {
				t.Errorf("%s velocity %v", f.Callsign, fields)
			}
		case KindSurveillance:
			if sq := fields["squawk"].GetText(); sq != "" && sq != f.Squawk {
				t.Errorf("%s squawk %s, want %s", f.Callsign, sq, f.Squawk)
			}
		}
	})
	if recs != len(tx) {
		t.Errorf("%d records from %d replies", recs, len(tx))
	}
	// Each flight's first position is one frame alone; every later one is decoded.
	if want := 11 * len(testFlights); positions != want {
		t.Errorf("%d positions decoded, want %d", positions, want)
	}
	for id, kinds := range got {
		if len(kinds) != 4 {
			t.Errorf("%s: kinds %v, want all four", id, kinds)
		}
	}
}

// TestSNRSweep reports the share of replies decoded at each pulse-to-noise ratio (the pulse's
// power over the noise power in the 2.4 MHz band). The assertion is loose, so a regression is
// caught without the test flaking on the tail. A reply is 56 or 112 bits that must all be right,
// and at 10 dB the bit error rate at the right phase is about 2.6%, near what the magnitudes
// allow when a half-bit is 1.2 samples, so few whole replies survive there.
func TestSNRSweep(t *testing.T) {
	const dur = 3.0
	tx := Schedule(testFlights, dur)
	for _, snr := range []float64{20, 15, 12, 10, 8, 6} {
		iq := synth(tx, dur, 1, math.Pow(10, -snr/20), uint64(snr))
		var n int
		decodeAll(iq, func(Frame, *leylinev1.DecodeRecord) { n++ })
		t.Logf("SNR %2.0f dB: %3d/%d", snr, n, len(tx))
		if snr == 15 && n < len(tx)*95/100 {
			t.Errorf("at 15 dB only %d of %d replies decoded", n, len(tx))
		}
	}
}

// A position needs a pair: one frame alone gives none, and a pair more than 10 s apart gives
// none either.
func TestPositionNeedsAPair(t *testing.T) {
	f := testFlights[0]
	d := NewDecoder(testRate)
	feed := func(at float64, odd bool) *leylinev1.DecodeRecord {
		lat, lon, alt := f.At(at)
		msg := EncodeAirbornePosition(f.Addr, alt, lat, lon, odd)
		return d.handle(Frame{Msg: msg, Addr: f.Addr, End: int64(at * testRate)})
	}
	if r := feed(0, false); r.GetPosition() != nil {
		t.Error("one even frame gave a position")
	}
	if r := feed(11, true); r.GetPosition() != nil {
		t.Error("an odd frame 11 s after the even gave a position")
	}
	r := feed(12, false)
	if r.GetPosition() == nil {
		t.Fatal("a pair 1 s apart gave no position")
	}
	// The next frame decodes locally against that position.
	if r := feed(12.5, false); r.GetPosition() == nil {
		t.Error("a frame 0.5 s after a position was not decoded locally")
	}
}

// Sixty seconds of noise make no record.
func TestNoiseMakesNoRecord(t *testing.T) {
	if testing.Short() {
		t.Skip("60 s of noise at 2.4 MSPS")
	}
	rng := rand.New(rand.NewPCG(7, 60))
	d := NewDecoder(testRate)
	d.Reset(0)
	iq := make([]complex64, 4096)
	var recs int
	for done := 0; done < 60*testRate; done += len(iq) {
		for k := range iq {
			iq[k] = complex(float32(rng.NormFloat64()*0.05), float32(rng.NormFloat64()*0.05))
		}
		d.Feed(iq, func(_ Frame, rec *leylinev1.DecodeRecord) {
			recs++
			t.Errorf("noise decoded as %v", rec)
		})
	}
	st := d.Stats()
	t.Logf("60 s of noise: %d candidates, %d frames", st.Candidates, st.Frames)
}

// BenchmarkDemod measures the decoder on 2 s of three aircraft over noise, delivered in
// 4096-sample blocks; it reports samples a second, which must stay well above 2.4 M.
func BenchmarkDemod(b *testing.B) {
	const dur = 2.0
	iq := synth(Schedule(testFlights, dur), dur, 1, 0.3, 3)
	b.ResetTimer()
	for range b.N {
		decodeAll(iq, func(Frame, *leylinev1.DecodeRecord) {})
	}
	b.ReportMetric(float64(len(iq))*float64(b.N)/b.Elapsed().Seconds(), "samples/s")
}
