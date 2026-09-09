package cli

import (
	"fmt"
	"io"
	"math"
	"strings"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
)

// The live meter's bar spans meterFloorDbfs to 0 dBFS, the range a receiver
// reports: a signal at the floor draws nothing, a clipping one fills the bar.
// The floor is fixed rather than measured so the bar does not re-scale under
// the reader while they watch it.
const meterFloorDbfs = -90.0

// Bar sizing. The bar leads the line, so it keeps one column whatever the
// gate word ("audio" or "muted, waiting for a signal") does to the length
// behind it. Below minMeterBar columns there is no room to say anything
// useful and the meter is the plain line alone.
const (
	meterBarWidth = 16
	minMeterBar   = 8
)

// meterRender is the live meter as a person sees it: a level bar scaled
// floor-to-0 dBFS with a marker at the squelch threshold, then the plain
// line of meterLine (contractual, character for character) with its gate
// word inked. squelchDb is the channel's threshold; NaN (squelch off) draws
// no marker. With a plain style this is meterLine plus the bar, and with a
// zero-width style it is meterLine alone.
func meterRender(st ui.Style, freq uint64, mode leylinev1.DemodMode, m *leylinev1.Meter, squelchDb float64) string {
	line := meterLine(freq, mode, m)
	gate := "muted, waiting for a signal"
	ink := st.Warn
	if m.GetSquelchOpen() {
		gate, ink = "audio", st.Ok
	}
	line = strings.TrimSuffix(line, gate) + ink(gate)
	bar := meterBar(st, m.GetPowerDbfs(), squelchDb, m.GetSquelchOpen(), meterBarSize(st, ui.Visible(line)))
	if bar == "" {
		return line
	}
	return bar + "  " + line
}

// meterBarSize is how many columns are left for the bar once the meter line
// is drawn, capped at meterBarWidth. An unknown width, or a line that
// already fills the terminal, yields no bar rather than a wrapped line: the
// words are the meter, the bar is the polish.
func meterBarSize(st ui.Style, lineWidth int) int {
	if st.Width <= 0 {
		return 0
	}
	spare := st.Width - lineWidth - 2
	if spare < minMeterBar {
		return 0
	}
	if spare > meterBarWidth {
		return meterBarWidth
	}
	return spare
}

// meterBar draws width columns of level from meterFloorDbfs to 0 dBFS. The
// filled run is Ok while audio is passing and plain while it is not; the
// unfilled run is Muted scaffolding; the marker takes the cell the squelch
// threshold falls in, plain so it reads against either run.
func meterBar(st ui.Style, powerDb, squelchDb float64, open bool, width int) string {
	if width <= 0 {
		return ""
	}
	g := st.Glyphs()
	cells := []rune(st.Bar(meterFrac(powerDb), width))
	if i, ok := meterCell(squelchDb, width); ok {
		cells[i] = g.Marker
	}
	// Ink runs of like cells together, so the bar carries at most three
	// escape sequences however wide it is.
	var b strings.Builder
	for i := 0; i < len(cells); {
		j := i
		for j < len(cells) && cells[j] == cells[i] {
			j++
		}
		run := string(cells[i:j])
		switch {
		case cells[i] == g.Marker:
			b.WriteString(run)
		case cells[i] == g.BarEmpty:
			b.WriteString(st.Muted(run))
		case open:
			b.WriteString(st.Ok(run))
		default:
			b.WriteString(run)
		}
		i = j
	}
	return b.String()
}

// meterPipeInterval is how often the meter is repeated when its stream is
// not a terminal: enough to see the level move in a log, few enough that a
// long session does not fill a disk with it.
const meterPipeInterval = time.Second

// meterSink writes the live meter to one stream. On a terminal it redraws in
// place, padding to the previous line's visible width so a shorter line
// leaves no residue. Off a terminal there is nothing to redraw -- a
// carriage return in a file collapses the whole session onto one unreadable
// line -- so it writes whole lines, at most one per meterPipeInterval.
type meterSink struct {
	w     io.Writer
	style ui.Style
	tty   bool
	// lastLen is the visible width of the line on screen (terminal only).
	lastLen int
	// last is when a line was last written (pipe only).
	last time.Time
}

// line renders one meter for this sink. The bar belongs to the terminal:
// off one, every line stands alone in a log and the words are the record, so
// the meter is exactly the contractual meterLine string.
func (m *meterSink) line(freq uint64, mode leylinev1.DemodMode, mt *leylinev1.Meter, squelchDb float64) string {
	st := m.style
	if !m.tty {
		st.Width = 0
	}
	return meterRender(st, freq, mode, mt, squelchDb)
}

// write shows one rendered meter line.
func (m *meterSink) write(line string) {
	if !m.tty {
		now := time.Now()
		if !m.last.IsZero() && now.Sub(m.last) < meterPipeInterval {
			return
		}
		m.last = now
		fmt.Fprintln(m.w, line)
		return
	}
	pad := m.lastLen - ui.Visible(line)
	if pad < 0 {
		pad = 0
	}
	fmt.Fprintf(m.w, "\r%s%s", line, strings.Repeat(" ", pad))
	m.lastLen = ui.Visible(line)
}

// clear removes the drawn meter so another line can take the terminal's
// last row. Off a terminal the meter's lines are already whole, so there is
// nothing to erase.
func (m *meterSink) clear() {
	if !m.tty || m.lastLen == 0 {
		return
	}
	fmt.Fprintf(m.w, "\r%s\r", strings.Repeat(" ", m.lastLen))
	m.lastLen = 0
}

// meterFrac places a level on the floor-to-0 dBFS scale.
func meterFrac(db float64) float64 {
	if math.IsNaN(db) {
		return 0
	}
	return (db - meterFloorDbfs) / -meterFloorDbfs
}

// meterCell is the bar cell a level falls in, and whether it is on the bar
// at all: an off (NaN) or out-of-scale squelch has no marker to draw.
func meterCell(db float64, width int) (int, bool) {
	if math.IsNaN(db) || db < meterFloorDbfs || db > 0 {
		return 0, false
	}
	i := int(meterFrac(db) * float64(width))
	if i >= width {
		i = width - 1
	}
	return i, true
}
