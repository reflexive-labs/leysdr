// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bufio"
	"bytes"
	"cmp"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/reflexive-labs/leysdr/go/pkg/decoders/afsk"
	"github.com/reflexive-labs/leysdr/go/pkg/decoders/ais"
	"github.com/reflexive-labs/leysdr/go/pkg/decoders/aprs"
	"github.com/reflexive-labs/leysdr/go/pkg/decoders/ax25"
	"github.com/reflexive-labs/leysdr/go/pkg/iqfile"
)

// maxSceneBytes is the size a scene fixture is kept under: they are generated on each machine
// that takes the shots and cached there, never committed.
const maxSceneBytes = 300_000_000

// sceneSetNames is the scenes set in catalog order.
var sceneSetNames = []string{
	"scene_2m", "scene_net", "scene_scan", "scene_aprs", "scene_ais",
	"scene_gmrs", "scene_vhf20", "scene_wx", "scene_wx_on", "scene_club",
}

// The check scenes' fixtures put their stations where the app's band table has them: GMRS
// channels 1, 5 and 21; 2 m, MURS 1 and 4, marine 16 and NOAA WX2 in one capture; WX2 and WX1.
// Every keyed station keys inside the loop, scene_gmrs's at least three times.
func TestCheckSceneStations(t *testing.T) {
	at := func(center float64, cs []sceneCarrier) []float64 {
		var out []float64
		for _, c := range cs {
			out = append(out, center+c.offsetHz)
		}
		return out
	}
	cases := []struct {
		name     string
		carriers []sceneCarrier
		center   float64
		duration float64
		minKeys  int
		want     []float64
	}{
		{"scene_gmrs", sceneGMRSCarriers(), sceneGMRSCenterHz, sceneGMRSDurationS, 3, []float64{462_662_500, 462_562_500, 462_700_000}},
		{"scene_vhf20", sceneVHF20Carriers(), sceneVHF20CenterHz, sceneVHF20DurationS, 1, []float64{146_520_000, 146_940_000, 151_820_000, 154_570_000, 156_800_000, 162_400_000}},
		{"scene_wx_on", sceneWXCarriers(), sceneWXCenterHz, sceneWXDurationS, 0, []float64{162_400_000, 162_550_000}},
		{"scene_club", sceneClubCarriers(), sceneClubCenterHz, sceneClubDurationS, 2, []float64{146_940_000, 146_940_000}},
	}
	for _, c := range cases {
		if got := at(c.center, c.carriers); !slices.Equal(got, c.want) {
			t.Errorf("%s stations at %v, want %v", c.name, got, c.want)
		}
		f := findFixture(c.name)
		if f.metadata["frequency_hz"] != hz(c.want[0]) {
			t.Errorf("%s opens on %s, want its first station", c.name, f.metadata["frequency_hz"])
		}
		for i, s := range c.carriers {
			if s.segs == nil {
				continue
			}
			if len(s.segs) < c.minKeys || len(s.segs) == 0 {
				t.Errorf("%s station %d keys %d times", c.name, i, len(s.segs))
			}
			for _, seg := range s.segs {
				if seg.startS <= 0 || seg.endS >= c.duration {
					t.Errorf("%s station %d over [%.2f, %.2f] is outside the %.0f s loop", c.name, i, seg.startS, seg.endS, c.duration)
				}
			}
		}
	}
	// The silent weather capture has no station, and its channels read the floor.
	wx := findFixture("scene_wx")
	if len(wx.build(sceneWXRate)) != 0 || wx.centerHz != sceneWXCenterHz {
		t.Error("scene_wx is not the floor alone on the weather channels")
	}
}

// Every scene is in the scenes set, is cu8, fits its own rate and stays under the size bound.
func TestSceneCatalog(t *testing.T) {
	want := sceneSetNames
	var got []string
	for i := range catalog {
		f := &catalog[i]
		if f.set != sceneSet {
			if strings.HasPrefix(f.name, "scene_") {
				t.Errorf("%s is outside the scenes set", f.name)
			}
			continue
		}
		got = append(got, f.name)
		if f.sampleFormat() != iqfile.FormatCU8 || f.fixedRate == 0 || f.fixedDurationS == 0 {
			t.Errorf("%s: format %s, rate %.0f, duration %.0f; a scene is cu8 at its own rate and length",
				f.name, f.sampleFormat(), f.fixedRate, f.fixedDurationS)
		}
		if !f.fits(f.fixedRate) {
			t.Errorf("%s does not fit in its own %.0f Hz", f.name, f.fixedRate)
		}
		if size := f.fixedRate * f.fixedDurationS * 2; size > maxSceneBytes {
			t.Errorf("%s is %.0f MB, over %d MB", f.name, size/1e6, maxSceneBytes/1_000_000)
		}
		if len(f.expect(f.fixedRate)) == 0 {
			t.Errorf("%s has no expectations for leyfix check to verify", f.name)
		}
	}
	if !slices.Equal(got, want) {
		t.Errorf("scenes set is %v, want %v", got, want)
	}
	if f := findFixture("scene_2m"); f.label != "NESDR SMArt v5" {
		t.Errorf("scene_2m label %q", f.label)
	}
}

// `make fixtures` (no --set) never writes a scene, and --set scenes writes only scenes. A dry
// run writes nothing and prints one sidecar per fixture.
func TestSceneSetSelection(t *testing.T) {
	var out bytes.Buffer
	dir := filepath.Join(t.TempDir(), "never")
	if err := generate(genOptions{out: dir, rate: refRate, duration: 1, seed: 1, dryRun: true}, &out); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out.String(), "scene_") {
		t.Errorf("the default set includes a scene:\n%s", out.String())
	}
	out.Reset()
	if err := generate(genOptions{out: dir, rate: refRate, duration: 1, seed: 1, dryRun: true, set: sceneSet}, &out); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Errorf("a dry run created %s", dir)
	}
	var names []string
	sc := bufio.NewScanner(&out)
	sc.Buffer(nil, 1<<20)
	for sc.Scan() {
		var line struct {
			Name    string         `json:"name"`
			File    string         `json:"file"`
			Sidecar iqfile.Sidecar `json:"sidecar"`
		}
		if err := json.Unmarshal(sc.Bytes(), &line); err != nil {
			t.Fatalf("%v: %s", err, sc.Text())
		}
		names = append(names, line.Name)
		if line.File != line.Name+".cu8" || line.Sidecar.Format != "cu8" || len(line.Sidecar.Generator) == 0 {
			t.Errorf("%s: file %s, sidecar %+v", line.Name, line.File, line.Sidecar)
		}
	}
	if !slices.Equal(names, sceneSetNames) {
		t.Errorf("--set scenes printed %v", names)
	}
	if err := generate(genOptions{out: dir, rate: refRate, duration: 1, set: "nope", dryRun: true}, &out); err == nil {
		t.Error("an unknown set should be refused")
	}
}

// Every scene_2m carrier keys at least three times, the hero's schedule is the one the site's
// on_air wait and transmission log were staged on, and 146.550 overlaps it in part. scene_net is
// the net the recording shot needs: eight overs of 4 to 30 s, 6 to 8 s apart, including across
// the loop's join.
func TestSceneSchedules(t *testing.T) {
	carriers := scene2mCarriers()
	for i, c := range carriers {
		keying := c.keying()
		if len(keying) < 3 {
			t.Errorf("scene_2m carrier %d keys %d times, want at least 3", i, len(keying))
		}
		for j, s := range keying {
			if s.startS < 0.5 || s.endS > scene2mDurationS-0.5 || s.endS <= s.startS {
				t.Errorf("scene_2m carrier %d over %d is [%.2f, %.2f]", i, j, s.startS, s.endS)
			}
			if j > 0 && s.startS-keying[j-1].endS < 1 {
				t.Errorf("scene_2m carrier %d overs %d and %d are %.2f s apart", i, j-1, j, s.startS-keying[j-1].endS)
			}
		}
	}
	hero := carriers[0]
	if hero.offsetHz != 120_000 || hero.toneHz != 100.0 || hero.voiceSeed != 21 ||
		!slices.Equal(hero.segs, []keySegment{{0.6, 7.21}, {10.86, 17.85}, {21.85, 29.78}, {32.72, 41.56}}) {
		t.Errorf("the hero is %+v", hero)
	}
	var wide *sceneCarrier
	for i := range carriers {
		if carriers[i].offsetHz == 150_000 {
			wide = &carriers[i]
		}
	}
	if wide == nil {
		t.Fatal("no carrier on 146.550")
	}
	partial := 0
	for _, w := range wide.segs {
		for _, h := range hero.segs {
			overlap := min(w.endS, h.endS) - max(w.startS, h.startS)
			if overlap > 0 && overlap < min(w.endS-w.startS, h.endS-h.startS) {
				partial++
			}
		}
	}
	if partial < 3 {
		t.Errorf("146.550 overlaps the hero in part %d times, want at least 3", partial)
	}
	segs := sceneNetCarrier().segs
	if len(segs) != 8 {
		t.Fatalf("scene_net has %d overs, want 8", len(segs))
	}
	for i, s := range segs {
		if l := s.endS - s.startS; l < 4 || l > 30 {
			t.Errorf("scene_net over %d lasts %.1f s", i, l)
		}
		next := sceneNetDurationS + segs[0].startS // the first over again, after the join
		if i+1 < len(segs) {
			next = segs[i+1].startS
		}
		if gap := next - s.endS; gap < 6 || gap > 8 {
			t.Errorf("scene_net gap after over %d is %.1f s", i, gap)
		}
	}
}

// The voice is speech-shaped: its power is in 300-3000 Hz, it pauses, and a seed gives the
// same samples every time, including after the stream is restarted.
func TestVoice(t *testing.T) {
	const n = 10 * voiceAudioRate
	v := &voice{seed: 7}
	x := make([]float64, int(n))
	silent := 0
	for i := range x {
		x[i] = v.next()
		if !v.syllable {
			silent++
		}
	}
	if frac := float64(silent) / n; frac < 0.15 || frac > 0.6 {
		t.Errorf("the voice is silent for %.0f%% of 10 s, want pauses between phrases", 100*frac)
	}
	// Power by band, from one long FFT.
	size := 1 << 17
	buf := make([]complex128, size)
	for i := range buf {
		buf[i] = complex(x[i], 0)
	}
	fft(buf)
	var in, all float64
	for k := 1; k < size/2; k++ {
		p := real(buf[k])*real(buf[k]) + imag(buf[k])*imag(buf[k])
		hz := float64(k) * voiceAudioRate / float64(size)
		all += p
		if hz >= 250 && hz <= 3300 {
			in += p
		}
	}
	if in/all < 0.9 {
		t.Errorf("%.0f%% of the voice's power is in 250-3300 Hz, want at least 90%%", 100*in/all)
	}
	w := &voice{seed: 7}
	for i := range 1000 {
		if got := w.next(); got != x[i] {
			t.Fatalf("seed 7 sample %d is %v, then %v", i, x[i], got)
		}
	}
	// Reading backwards restarts from the seed rather than returning a stale sample.
	at := newVoiceAt(7, 48_000)
	first := at.at(3000)
	_ = at.at(90_000)
	if again := at.at(3000); again != first {
		t.Errorf("sample 3000 read %v, then %v after a later one", first, again)
	}
}

// A short scene built from the same parts as scene_2m and scene_net -- voice under CTCSS and
// DCS, keyed in overs, at the scenes' floor, written as cu8 -- passes leyfix check, so the
// expectations the real scenes carry are ones the checker can verify through the cu8
// quantisation.
func TestShortSceneChecks(t *testing.T) {
	carriers := []sceneCarrier{
		{offsetHz: 0, dbfs: -18, voiceSeed: 31, dcsCode: 0o23, segs: []keySegment{{0.5, 3}, {4.5, 7}}},
		{offsetHz: 120_000, dbfs: -30, voiceSeed: 21, toneHz: 100.0, segs: []keySegment{{1, 2.5}, {5, 6}}},
	}
	f := &fixture{
		name: "short_scene", centerHz: 147_180_000, set: sceneSet, format: iqfile.FormatCU8,
		fixedRate: 480_000, fixedDurationS: 8, noiseDBFS: sceneNoiseDBFS,
		build: func(rate float64) []source { return sources(rate, carriers) },
		expect: func(float64) []iqfile.Expect {
			return []iqfile.Expect{carriers[0].expect(true), carriers[1].expect(false)}
		},
	}
	path := filepath.Join(t.TempDir(), "short_scene.cu8")
	if err := generateOne(f, genOptions{rate: refRate, duration: 1, seed: 1}, path); err != nil {
		t.Fatal(err)
	}
	if st, err := os.Stat(path); err != nil || st.Size() != 2*480_000*8 {
		t.Fatalf("cu8 file: %v, %v", st, err)
	}
	results, err := checkFile(iqfile.SidecarPath(path))
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range results {
		if !r.pass {
			t.Errorf("FAIL [%d] %s", r.index, r.detail)
		}
	}
}

// decodeAt runs a generated scene file's channel through the reference chain and returns the
// audio and its rate.
func decodeAt(t *testing.T, path string, e iqfile.Expect) ([]float32, float64) {
	t.Helper()
	sc, err := iqfile.ReadSidecar(path)
	if err != nil {
		t.Fatal(err)
	}
	res, err := streamChain(path, sc, e)
	if err != nil {
		t.Fatal(err)
	}
	audio := make([]float32, len(res.audio))
	for i, v := range res.audio {
		audio[i] = float32(v)
	}
	return audio, res.audioRate
}

// The scene_aprs transmitter, at a period short enough for a unit test, decodes to its seven
// stations in order after the cu8 round trip.
func TestSceneAPRSDecodes(t *testing.T) {
	const rate = 960_000
	f := &fixture{
		name: "short_aprs", centerHz: 144_390_000, format: iqfile.FormatCU8, fixedRate: rate,
		fixedDurationS: 4, noiseDBFS: sceneNoiseDBFS,
		build: func(rate float64) []source {
			return []source{aprsStationsSource(rate, 4, sceneAPRSStations)}
		},
		expect: func(float64) []iqfile.Expect { return nil },
	}
	path := filepath.Join(t.TempDir(), "short_aprs.cu8")
	if err := generateOne(f, genOptions{seed: 1}, path); err != nil {
		t.Fatal(err)
	}
	scene := findFixture("scene_aprs")
	exp := scene.expect(rate)[0]
	audio, audioRate := decodeAt(t, path, exp)
	var got []string
	def := ax25.NewDeframer()
	afsk.New(audioRate).Feed(audio, func(bit bool, at int64) {
		def.Feed(bit, at, func(raw []byte, _ int64) {
			fr, err := ax25.Parse(raw)
			if err != nil {
				t.Errorf("a frame passed the FCS but not the address field: %v", err)
				return
			}
			rec := aprs.Parse(fr)
			if rec == nil {
				t.Errorf("a frame did not parse as APRS: %s", fr)
				return
			}
			got = append(got, rec.DeviceId)
		})
	})
	if !slices.Equal(got, exp.Decode.DeviceIDs) || len(got) != exp.Decode.Records {
		t.Errorf("decoded %v, want %v", got, exp.Decode.DeviceIDs)
	}
}

// The scene_ais vessels, at a short period, decode to the MMSIs its expect entry names.
func TestSceneAISDecodes(t *testing.T) {
	const rate = 960_000
	f := &fixture{
		name: "short_ais", centerHz: 162_000_000, format: iqfile.FormatCU8, fixedRate: rate,
		fixedDurationS: 1, noiseDBFS: sceneNoiseDBFS,
		build: func(rate float64) []source {
			return []source{sceneAISSource(rate, 1)}
		},
		expect: func(float64) []iqfile.Expect { return nil },
	}
	path := filepath.Join(t.TempDir(), "short_ais.cu8")
	if err := generateOne(f, genOptions{seed: 1}, path); err != nil {
		t.Fatal(err)
	}
	for _, exp := range findFixture("scene_ais").expect(rate) {
		audio, audioRate := decodeAt(t, path, exp)
		var got []string
		def := ais.NewDeframer()
		ais.New(audioRate).Feed(audio, func(bit bool, at int64) {
			def.Feed(bit, at, func(raw []byte, _ int64) {
				m, err := ais.Parse(raw)
				if err != nil {
					t.Errorf("a frame passed the FCS but did not parse: %v", err)
					return
				}
				got = append(got, m.Record().DeviceId)
			})
		})
		if !slices.Equal(got, exp.Decode.DeviceIDs) {
			t.Errorf("channel %+.0f Hz decoded %v, want %v", exp.OffsetHz, got, exp.Decode.DeviceIDs)
		}
	}
}

// scene_club's two stations share 146.940 MHz and key in turns, never together, under PL 127.3
// and PL 100.0; its one channel expects their overs in time order and no single tone.
func TestSceneClubKeysTwoTonesInTurns(t *testing.T) {
	cs := sceneClubCarriers()
	if len(cs) != 2 || cs[0].toneHz != 127.3 || cs[1].toneHz != 100.0 {
		t.Fatalf("scene_club stations %+v, want PL 127.3 then PL 100.0", cs)
	}
	var all []keySegment
	for _, c := range cs {
		all = append(all, c.segs...)
	}
	slices.SortFunc(all, func(a, b keySegment) int { return cmp.Compare(a.startS, b.startS) })
	for i := 1; i < len(all); i++ {
		if all[i].startS < all[i-1].endS+2 {
			t.Errorf("overs %v and %v are under 2 s apart", all[i-1], all[i])
		}
	}
	e := sceneClubExpect()
	if e.SubAudible != nil {
		t.Error("scene_club's channel expects one tone, but it carries two")
	}
	if e.Record == nil || len(e.Record.Segments) != len(all) {
		t.Fatalf("scene_club's record expectation %+v, want %d overs", e.Record, len(all))
	}
	for i, s := range e.Record.Segments {
		if s.StartS != all[i].startS || s.EndS != all[i].endS {
			t.Errorf("record over %d is %+v, want %v", i, s, all[i])
		}
	}
}
