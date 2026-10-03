// SPDX-License-Identifier: Apache-2.0

package main

import (
	"math"
	"math/rand/v2"
)

// voiceAudioRate is the rate the voice source synthesises at. Its band ends at 3 kHz, so 16 kHz
// leaves the filters room, and the IQ-rate modulator interpolates between samples.
const voiceAudioRate = 16_000.0

// biquad is a direct-form-I second-order section.
type biquad struct {
	b0, b1, b2, a1, a2 float64
	x1, x2, y1, y2     float64
}

func (f *biquad) step(x float64) float64 {
	y := f.b0*x + f.b1*f.x1 + f.b2*f.x2 - f.a1*f.y1 - f.a2*f.y2
	f.x2, f.x1, f.y2, f.y1 = f.x1, x, f.y1, y
	return y
}

// butterworth is a second-order Butterworth low-pass (or high-pass) at fc, by the bilinear
// transform.
func butterworth(fc, rate float64, high bool) biquad {
	k := math.Tan(math.Pi * fc / rate)
	q := 1 / math.Sqrt2
	norm := 1 / (1 + k/q + k*k)
	f := biquad{a1: 2 * (k*k - 1) * norm, a2: (1 - k/q + k*k) * norm}
	if high {
		f.b0, f.b1, f.b2 = norm, -2*norm, norm
	} else {
		f.b0 = k * k * norm
		f.b1, f.b2 = 2*f.b0, f.b0
	}
	return f
}

// voice is speech-shaped noise: white noise band-limited to 300-3000 Hz, under an envelope of
// syllables (100-260 ms each, a short dip between them) grouped into phrases of 4-12 syllables
// with a 250-900 ms pause after each. On a waterfall a carrier keyed with it shows the irregular
// spread of a voice, where a test tone shows one line and its sidebands. It is not speech and
// carries nothing a listener could follow.
//
// Everything comes from seed, so a fixture is the same on every run. Samples are made in order;
// asking for an earlier one starts the stream over from the seed.
type voice struct {
	seed uint64

	rng            *rand.Rand
	hp, lp1, lp2   biquad
	idx            int64 // index of the next sample next() returns
	segLeft, seg   int   // samples left in, and length of, the current envelope segment
	syllable       bool  // the segment is a syllable rather than a dip or pause
	syllablesLeft  int   // syllables before the phrase ends
	syllableHeight float64
}

// voiceRMS is the level the band-limited noise is scaled to inside a syllable, before the
// limiter: about a third of full deviation on average, with peaks reaching it.
const voiceRMS = 0.35

func (v *voice) reset() {
	v.rng = rand.New(rand.NewPCG(v.seed, 0x766f696365))
	v.hp = butterworth(300, voiceAudioRate, true)
	v.lp1 = butterworth(3000, voiceAudioRate, false)
	v.lp2 = butterworth(3000, voiceAudioRate, false)
	v.idx, v.segLeft, v.seg, v.syllable, v.syllablesLeft = 0, 0, 0, false, 0
}

func (v *voice) ms(lo, hi float64) int {
	return int((lo + (hi-lo)*v.rng.Float64()) / 1000 * voiceAudioRate)
}

// nextSegment chooses the envelope's next segment: a syllable, the dip after it, or the pause
// that ends a phrase.
func (v *voice) nextSegment() {
	switch {
	case !v.syllable && v.syllablesLeft > 0:
		v.syllable = true
		v.syllablesLeft--
		v.seg = v.ms(100, 260)
		v.syllableHeight = 0.6 + 0.4*v.rng.Float64()
	case v.syllable && v.syllablesLeft > 0:
		v.syllable = false
		v.seg = v.ms(20, 80)
	default:
		// The end of a phrase: a pause, then a new phrase.
		v.syllable = false
		v.seg = v.ms(250, 900)
		v.syllablesLeft = 4 + v.rng.IntN(9)
	}
	v.segLeft = v.seg
}

// envelope is the current segment's level at its current position.
func (v *voice) envelope() float64 {
	if !v.syllable {
		return 0
	}
	t := float64(v.seg-v.segLeft) / float64(v.seg)
	return v.syllableHeight * math.Sin(math.Pi*t)
}

// next returns the next audio sample, in -1..1.
func (v *voice) next() float64 {
	if v.rng == nil {
		v.reset()
	}
	if v.segLeft <= 0 {
		v.nextSegment()
	}
	env := v.envelope()
	v.segLeft--
	v.idx++
	// White noise of unit variance keeps about 2700/8000 of its power in the band.
	x := v.lp2.step(v.lp1.step(v.hp.step(v.rng.NormFloat64())))
	return math.Tanh(env * x * voiceRMS / math.Sqrt(2700/(voiceAudioRate/2)))
}

// voiceAt reads a voice at an IQ rate: it interpolates linearly between the audio samples either
// side of IQ sample n.
type voiceAt struct {
	v         *voice
	rate      float64
	prev, cur float64
	curIdx    int64 // the audio index cur holds; -1 before the first sample
}

func newVoiceAt(seed uint64, rate float64) *voiceAt {
	return &voiceAt{v: &voice{seed: seed}, rate: rate, curIdx: -1}
}

func (s *voiceAt) at(n int64) float64 {
	t := float64(n) * voiceAudioRate / s.rate
	a := int64(t)
	if a < s.curIdx-1 {
		s.v.reset()
		s.curIdx = -1
	}
	for s.curIdx < a+1 {
		s.prev = s.cur
		s.cur = s.v.next()
		s.curIdx++
	}
	frac := t - float64(a)
	return s.prev + frac*(s.cur-s.prev)
}

// fmVoice is a voice FM-modulated onto a carrier with a CTCSS tone or a DCS word under it, or
// neither: the transmission a handheld or a repeater makes. Keyed in overs by the keyed source,
// it is what a scene fixture's carriers are.
type fmVoice struct {
	rate, carrierHz, devHz, dbfs float64
	voiceSeed                    uint64
	// subToneHz is a CTCSS tone at subDevHz, 0 for none.
	subToneHz float64
	// dcsCode is a DCS code at subDevHz (octal, as dcs.Encode takes it), used when dcsSet.
	dcsCode  int
	dcsSet   bool
	subDevHz float64

	audio *voiceAt
	dcs   *dcsShaper
	phase float64
}

func (s *fmVoice) fill(dst []complex128, n0 int64) {
	if s.audio == nil {
		s.audio = newVoiceAt(s.voiceSeed, s.rate)
		if s.dcsSet {
			s.dcs = &dcsShaper{rate: s.rate, code: s.dcsCode}
		}
	}
	a := ampFromDBFS(s.dbfs)
	wc := 2 * math.Pi * s.carrierHz / s.rate
	wd := 2 * math.Pi * s.devHz / s.rate
	ws := 2 * math.Pi * s.subToneHz / s.rate
	wsd := 2 * math.Pi * s.subDevHz / s.rate
	ph := s.phase
	for i := range dst {
		n := n0 + int64(i)
		dev := wc + wd*s.audio.at(n)
		switch {
		case s.dcs != nil:
			dev += wsd * s.dcs.next(n)
		case s.subToneHz != 0:
			dev += wsd * math.Sin(ws*float64(n))
		}
		ph += dev
		if ph > math.Pi {
			ph -= 2 * math.Pi
		} else if ph < -math.Pi {
			ph += 2 * math.Pi
		}
		dst[i] += complex(a*math.Cos(ph), a*math.Sin(ph))
	}
	s.phase = ph
}

func (s *fmVoice) describe() map[string]any {
	d := map[string]any{
		"type": "nfm_voice", "carrier_hz": s.carrierHz, "deviation_hz": s.devHz,
		"dbfs": s.dbfs, "voice_seed": s.voiceSeed, "voice_band_hz": []float64{300, 3000},
	}
	switch {
	case s.dcsSet:
		d["sub_deviation_hz"] = s.subDevHz
		(&dcsShaper{code: s.dcsCode}).describe(d)
	case s.subToneHz != 0:
		d["sub_tone_hz"] = s.subToneHz
		d["sub_deviation_hz"] = s.subDevHz
	}
	return d
}

// span is Carson's rule over both deviations and the top of the voice band.
func (s *fmVoice) span() (float64, float64) {
	return s.carrierHz, 2 * (s.devHz + s.subDevHz + 3000)
}

// pulsed keys another source for widthS at the start of every periodS: a carrier too brief to
// be on for a whole look, the case a scan's SEEN column exists for.
type pulsed struct {
	inner           source
	rate            float64
	periodS, widthS float64
	scratch         []complex128
}

func (s *pulsed) fill(dst []complex128, n0 int64) {
	if cap(s.scratch) < len(dst) {
		s.scratch = make([]complex128, len(dst))
	}
	blk := s.scratch[:len(dst)]
	clear(blk)
	s.inner.fill(blk, n0)
	for i := range dst {
		if math.Mod(float64(n0+int64(i))/s.rate, s.periodS) < s.widthS {
			dst[i] += blk[i]
		}
	}
}

func (s *pulsed) describe() map[string]any {
	return map[string]any{"type": "pulsed", "period_s": s.periodS, "width_s": s.widthS, "carrier": s.inner.describe()}
}

func (s *pulsed) span() (float64, float64) { return s.inner.span() }

// overs lays out a station's transmissions between startS and endS: each over lasts minS to
// maxS, each gap gapMinS to gapMaxS, all drawn from seed. The last over ends before endS, so a
// looping player sees a gap at the join as well.
func overs(seed uint64, startS, endS, minS, maxS, gapMinS, gapMaxS float64) []keySegment {
	rng := rand.New(rand.NewPCG(seed, 0x6f76657273))
	var segs []keySegment
	t := startS
	for {
		length := minS + (maxS-minS)*rng.Float64()
		if t+length > endS {
			return segs
		}
		segs = append(segs, keySegment{startS: round2(t), endS: round2(t + length)})
		t += length + gapMinS + (gapMaxS-gapMinS)*rng.Float64()
	}
}

// round2 rounds to 10 ms, so a sidecar's segments read as times rather than float noise.
func round2(v float64) float64 { return math.Round(v*100) / 100 }
