package cli

import (
	"fmt"
	"math"
	"time"
)

// The bands a meter carries, on the ISO centres audio equipment has used for
// decades: nine octaves across the audible range, and the third-octave set for
// a screen wide enough to draw twenty-five bars. The narrow set is the six
// speech lives in, which is what survives when the width takes the rest.
var (
	levelsOctaveHz = []float64{63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000}
	levelsNarrowHz = []float64{125, 250, 500, 1000, 2000, 4000}
	levelsThirdHz  = []float64{
		63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000,
		1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000,
	}
)

// How wide a band is, as the ratio of its edges to its centre: a full octave
// spans a factor of two, a third of an octave the cube root of two.
var (
	levelsOctaveEdge = math.Sqrt2
	levelsThirdEdge  = math.Pow(2, 1.0/6)
)

// levelsBand is one bar of the meter: the centre it is named by and the edges
// of the row's bins that belong to it.
type levelsBand struct {
	centerHz, loHz, hiHz float64
}

// levelsBands builds the bands around a set of centres.
func levelsBands(centres []float64, edge float64) []levelsBand {
	out := make([]levelsBand, len(centres))
	for i, hz := range centres {
		out[i] = levelsBand{centerHz: hz, loHz: hz / edge, hiHz: hz * edge}
	}
	return out
}

// levelsBandLabel names a band the way an equaliser does: hertz below a
// kilohertz, kilohertz above it, and as few digits as say which band it is.
func levelsBandLabel(hz float64) string {
	if hz < 1000 {
		return fmt.Sprintf("%g", hz)
	}
	return fmt.Sprintf("%gk", hz/1000)
}

// levelsWindowEnbw is the equivalent noise bandwidth of the Hann window the
// daemon transforms through, in bins. A Hann-windowed tone is not one bin: it
// leaks into its neighbours at a quarter of the power each, so the bins of a
// band carry about one and a half times the power that is really in it, and
// the sum has to be divided by that before it is read as a level. It corrects
// broadband power by the same factor, because the same window spread it.
const levelsWindowEnbw = 1.5

// levelsBandDb is the level of one band of a spectrum row: the bins whose
// centres fall inside it, summed in power, corrected for the window and said
// in dB again. Levels are energy, and energy adds where dB do not, so a band
// of two equal bins reads 3 dB over either of them -- which is what the band
// actually carries.
//
// A band narrower than a bin still has a level: the bin its centre falls in,
// because a meter with a blank bar at 63 Hz would read as silence there rather
// than as a row too coarse to split it.
func levelsBandDb(bins []float64, binHz float64, b levelsBand) float64 {
	if len(bins) == 0 || binHz <= 0 {
		return scopeMinDbfs
	}
	// The edge belongs to the band above it, so neighbouring bands never count
	// one bin twice between them.
	sum, n := 0.0, 0
	for i := max(int(math.Ceil(b.loHz/binHz)), 0); i < len(bins); i++ {
		if float64(i)*binHz >= b.hiHz {
			break
		}
		sum += math.Pow(10, bins[i]/10)
		n++
	}
	if n > 0 {
		sum /= levelsWindowEnbw
	} else {
		// The band the row cannot split is its centre bin as it stands: the
		// correction hands a tone back the power it leaked into neighbours,
		// and where only one bin is counted that peak is already the level.
		i := int(math.Round(b.centerHz / binHz))
		if i < 0 || i >= len(bins) {
			return scopeMinDbfs
		}
		sum = math.Pow(10, bins[i]/10)
	}
	db := 10 * math.Log10(sum)
	if math.IsNaN(db) || db < scopeMinDbfs {
		return scopeMinDbfs
	}
	return db
}

// The meter's scale: fine where the working range is, coarse below it. Six dB
// a row from 0 to -24 gives a voice at -20 four rows of resolution; ten dB a
// row from there keeps the floor on screen at all. It is held, never fitted to
// the data, so a bar of a given height means the same dB tomorrow.
const (
	levelsTopDb     = 0.0
	levelsKneeDb    = -24.0
	levelsFloorDb   = -60.0
	levelsFineDb    = 6.0
	levelsCoarseDb  = 10.0
	levelsHorizonDb = -18.0
)

// levelsMarks are the numbers the gutter writes: what a meter is read against,
// -18 dBFS among them because that is the alignment level every professional
// meter carries and the horizon the eye reads the rest against.
var levelsMarks = []float64{0, -6, -12, -18, -24, -30, -40, -50, -60}

// levelsRows is the scale in its own units, where one unit is one row of the
// fine part: it is the piecewise ruler both the bars and the gutter are drawn
// with, so a mark and a bar of the same level land in the same place.
func levelsRows(db float64) float64 {
	if db >= levelsKneeDb {
		return (db - levelsKneeDb) / levelsFineDb
	}
	return (db - levelsKneeDb) / levelsCoarseDb
}

// levelsFrac is a level as a fraction of the meter's height, 0 at the floor
// and 1 at full scale. Anything outside the scale is drawn at its end: a bar
// that ran off the top would say less than a bar pinned to it.
func levelsFrac(db float64) float64 {
	if math.IsNaN(db) {
		return 0
	}
	bottom, top := levelsRows(levelsFloorDb), levelsRows(levelsTopDb)
	return math.Max(0, math.Min(1, (levelsRows(db)-bottom)/(top-bottom)))
}

// Ballistics: what makes a meter alive rather than a bar chart that flickers.
// Attack is instant, so a bar never lags the sound; release is slow enough
// that a syllable leaves a trail the eye can follow. The cap hangs on the
// loudest of the last second and a half and then sinks, which is how a person
// reads a peak off a moving bar. All of it is presentation over the daemon's
// rows: nothing smoothed is ever reported as a measurement.
const (
	levelsReleaseDbPerS = 20.0
	levelsCapHold       = 1500 * time.Millisecond
	levelsCapFallDbPerS = 10.0
	levelsOverHold      = 2 * time.Second
)

// levelsBar is one bar between frames: where it stands, where its cap hangs,
// and how long an overload stays lit.
type levelsBar struct {
	db      float64
	cap     float64
	capHeld time.Duration
	over    time.Duration
}

// levelsStill is a bar drawn as one row measured it: at the level, with no cap
// hanging over it, because a cap is the loudest of a second and a half and a
// still covers one row.
func levelsStill(db float64) levelsBar {
	if math.IsNaN(db) {
		db = scopeMinDbfs
	}
	b := levelsBar{db: db, cap: scopeMinDbfs}
	// An overload is a fact about the row, not a trail: the latch exists to
	// hold a flash long enough to read, and a still is already still.
	if db >= levelsTopDb {
		b.over = levelsOverHold
	}
	return b
}

// newLevelsBar starts a bar at silence, so the first frame rises to the signal
// rather than falling out of a level nobody measured.
func newLevelsBar() levelsBar {
	return levelsBar{db: scopeMinDbfs, cap: scopeMinDbfs}
}

// update moves a bar on by one frame of dt towards the row's level.
func (b *levelsBar) update(db float64, dt time.Duration) {
	if math.IsNaN(db) {
		db = scopeMinDbfs
	}
	s := math.Max(dt.Seconds(), 0)
	if db >= b.db {
		b.db = db
	} else {
		b.db = math.Max(db, b.db-levelsReleaseDbPerS*s)
	}
	if db >= b.cap {
		b.cap, b.capHeld = db, 0
	} else if b.capHeld += dt; b.capHeld > levelsCapHold {
		b.cap = math.Max(b.db, b.cap-levelsCapFallDbPerS*s)
	}
	switch {
	case db >= levelsTopDb:
		b.over = levelsOverHold
	case b.over > dt:
		b.over -= dt
	default:
		b.over = 0
	}
}
