// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"
	"io"
	"math"
	"strings"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
)

// The live meter's bar spans meterFloorDbfs to 0 dBFS, the range a receiver
// reports: a signal at the floor draws nothing, a clipping one fills the bar.
// The floor is fixed rather than measured so the bar does not re-scale while
// it is being watched.
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
	return meterRenderHistory(st, freq, mode, m, squelchDb, nil, onAir{})
}

// meterRenderHistory is meterRender with the signal row's sparkline: history
// is the loudest level of each of the last sparkCells seconds as a fraction
// of the meter's own scale (meterHistory.fracs), oldest first, or nil for a
// meter with no past yet. It is drawn on the signal detail row, so it needs
// the width and the audio level that row needs; a narrow terminal keeps the
// contractual line alone.
func meterRenderHistory(st ui.Style, freq uint64, mode leylinev1.DemodMode, m *leylinev1.Meter, squelchDb float64, history []float64, air onAir) string {
	line := meterLine(freq, mode, m, air)
	gate, ink := meterGate(m, air), st.Warn
	if m.GetSquelchOpen() {
		ink = st.Ok
	}
	line = strings.TrimSuffix(line, gate) + ink(gate)
	// The detail rows carry their own signal bar, so the inline one would
	// duplicate it; the first line keeps only the words.
	if rows := meterDetail(st, m, squelchDb, history); rows != "" {
		return line + "\n" + rows
	}
	bar := meterBar(st, m.GetPowerDbfs(), squelchDb, m.GetSquelchOpen(), meterBarSize(st, ui.Visible(line)))
	if bar == "" {
		return line
	}
	return bar + "  " + line
}

// meterDetailMinWidth is the narrowest terminal that gets the detail rows.
// Under it the contractual line and its bar are the whole meter: two more rows
// of half-width bars would add less than the words already show.
const meterDetailMinWidth = 60

// meterDetail is the rows under the meter line: the signal level at the radio
// and the audio level the listener gets, which differ. A strong unmodulated
// carrier is loud on the first and silent on the second.
//
// It draws only when the daemon actually measured an audio level. NaN means
// "not measured" -- a raw-IQ channel has no audio, and neither does a channel
// whose first block has not landed -- and a row that invents 0.0 dBFS for it
// would be reporting a very loud signal.
func meterDetail(st ui.Style, m *leylinev1.Meter, squelchDb float64, history []float64) string {
	if st.Width < meterDetailMinWidth {
		return ""
	}
	audio := m.GetAudioDbfs()
	if math.IsNaN(audio) || audio == 0 && m.GetAudioPeakDbfs() == 0 {
		return ""
	}
	const label = 9 // "  signal  " / "  audio    ": one left column for both rows
	width := st.Width - label - len(" -100 dBFS") - 2
	if width > meterBarWidth {
		width = meterBarWidth
	}
	if width < minMeterBar {
		return ""
	}
	var b strings.Builder
	b.WriteString("  " + st.Pad(st.Label("signal"), label-2) + " ")
	b.WriteString(meterBar(st, m.GetPowerDbfs(), squelchDb, m.GetSquelchOpen(), width))
	b.WriteString("  " + fmtMeterDb(m.GetPowerDbfs()))
	if snr := m.GetSnrDb(); !math.IsNaN(snr) {
		b.WriteString("  " + st.Muted("snr ") + fmt.Sprintf("%.0f", snr) + st.Muted(" dB"))
	}
	// The last eight seconds, one cell each, so a reader arriving mid-session
	// can see whether the channel has been quiet or is only quiet now. It takes
	// the room left on the row and never wraps it.
	if len(history) > 0 && ui.Visible(b.String())+2+len(history) <= st.Width {
		b.WriteString("  " + levelSparkline(st, history))
	}
	b.WriteString("\n")
	b.WriteString("  " + st.Pad(st.Label("audio"), label-2) + " ")
	// The marker on this row is the peak hold, not the squelch: a squelch
	// threshold is a level on the channel, and this row is not the channel.
	b.WriteString(meterBar(st, audio, m.GetAudioPeakDbfs(), m.GetSquelchOpen(), width))
	b.WriteString("  " + fmtMeterDb(audio))
	if pk := m.GetAudioPeakDbfs(); !math.IsNaN(pk) && pk > meterFloorDbfs {
		b.WriteString("  " + st.Muted("peak ") + fmt.Sprintf("%.0f", pk) + st.Muted(" dBFS"))
	}
	return b.String()
}

// fmtMeterDb is a level as the detail rows write it: right-aligned so the two
// rows' numbers line up, and the absent glyph when nothing was measured.
func fmtMeterDb(db float64) string {
	if math.IsNaN(db) {
		return "     -"
	}
	if math.IsInf(db, -1) || db <= meterFloorDbfs {
		return "  quiet"
	}
	return fmt.Sprintf("%4.0f dBFS", db)
}

// meterBarSize is how many columns are left for the bar once the meter line
// is drawn, capped at meterBarWidth. An unknown width, or a line that
// already fills the terminal, yields no bar rather than a wrapped line: the
// text carries the reading, and the bar is optional.
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

// meterHistorySpan is how far back the signal row's sparkline reaches: one
// cell per second, sparkCells of them.
const meterHistorySpan = sparkCells * time.Second

// meterHistory is the meter's recent past: every level the daemon reported
// in the last meterHistorySpan, so the sparkline is drawn from measurements
// rather than from a decay the client makes up.
type meterHistory struct {
	at []time.Time
	db []float64
}

// add records one reported level and forgets everything older than the span.
func (h *meterHistory) add(db float64, now time.Time) {
	h.at = append(h.at, now)
	h.db = append(h.db, db)
	cutoff := now.Add(-meterHistorySpan)
	i := 0
	for i < len(h.at) && h.at[i].Before(cutoff) {
		i++
	}
	h.at, h.db = h.at[i:], h.db[i:]
}

// fracs is the loudest level in each of the last sparkCells one-second
// slices ending now, on the meter's floor-to-0 dBFS scale, oldest first. A
// second with no report is 0: nothing was measured, so nothing is drawn.
// It is nil until the first level lands, so a meter with no past draws none.
func (h *meterHistory) fracs(now time.Time) []float64 {
	if len(h.at) == 0 {
		return nil
	}
	out := make([]float64, sparkCells)
	set := make([]bool, sparkCells)
	start := now.Add(-meterHistorySpan)
	for i, t := range h.at {
		s := int(t.Sub(start) / time.Second)
		if s < 0 {
			continue
		}
		if s >= sparkCells {
			s = sparkCells - 1
		}
		if f := meterFrac(h.db[i]); !set[s] || f > out[s] {
			out[s], set[s] = f, true
		}
	}
	return out
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
	// lastRows and lastLens describe the block currently on screen, so the next
	// write can step back over it and pad each row to what it is replacing.
	lastRows int
	lastLens []int
	// last is when a line was last written (pipe only).
	last time.Time
	// history is the levels of the last few seconds, for the signal row's
	// sparkline; now is the clock it is timed on, nil for time.Now.
	history meterHistory
	now     func() time.Time
}

// line renders one meter for this sink. The bar belongs to the terminal:
// off one, every line stands alone in a log and the words are the record, so
// the meter is exactly the contractual meterLine string.
func (m *meterSink) line(freq uint64, mode leylinev1.DemodMode, mt *leylinev1.Meter, squelchDb float64, air onAir) string {
	st := m.style
	if !m.tty {
		st.Width = 0
	}
	now := time.Now()
	if m.now != nil {
		now = m.now()
	}
	m.history.add(mt.GetPowerDbfs(), now)
	return meterRenderHistory(st, freq, mode, mt, squelchDb, m.history.fracs(now), air)
}

// write shows one rendered meter, which may be several lines. The first line
// is always the contractual meterLine; any further lines are detail rows that
// a terminal wide enough has room for.
//
// Off a terminal every write is whole lines at meterPipeInterval, and only the
// first: a log wants the record, not the bars, and repeating a three-line block
// once a second fills a file with scaffolding.
func (m *meterSink) write(block string) {
	lines := strings.Split(block, "\n")
	if !m.tty {
		now := time.Now()
		if !m.last.IsZero() && now.Sub(m.last) < meterPipeInterval {
			return
		}
		m.last = now
		fmt.Fprintln(m.w, lines[0])
		return
	}
	// Step back over the rows drawn last time before redrawing, so the block
	// stays in place instead of scrolling. Each row is padded to what stood
	// there before, so a shorter row leaves no residue.
	if m.lastRows > 1 {
		fmt.Fprintf(m.w, "\x1b[%dA", m.lastRows-1)
	}
	for i, line := range lines {
		pad := 0
		if i < len(m.lastLens) {
			pad = m.lastLens[i] - ui.Visible(line)
		}
		if pad < 0 {
			pad = 0
		}
		nl := "\n"
		if i == len(lines)-1 {
			nl = ""
		}
		fmt.Fprintf(m.w, "\r%s%s%s", line, strings.Repeat(" ", pad), nl)
	}
	// A block that shrank -- the daemon stopped measuring audio, so the detail
	// rows went away -- leaves rows on screen that this write did not touch.
	// Blank them and come back up, or the old bars sit there frozen for the
	// rest of the session.
	if extra := m.lastRows - len(lines); extra > 0 {
		for i := len(lines); i < m.lastRows; i++ {
			fmt.Fprintf(m.w, "\n\r%s", strings.Repeat(" ", m.lastLens[i]))
		}
		fmt.Fprintf(m.w, "\x1b[%dA\r", extra)
	}
	m.lastLens = m.lastLens[:0]
	for _, line := range lines {
		m.lastLens = append(m.lastLens, ui.Visible(line))
	}
	m.lastRows = len(lines)
}

// clear removes the drawn meter so another line can take the terminal's
// last rows. Off a terminal the meter's lines are already whole, so there is
// nothing to erase.
func (m *meterSink) clear() {
	if !m.tty || m.lastRows == 0 {
		return
	}
	if m.lastRows > 1 {
		fmt.Fprintf(m.w, "\x1b[%dA", m.lastRows-1)
	}
	for i, n := range m.lastLens {
		nl := "\n"
		if i == len(m.lastLens)-1 {
			nl = ""
		}
		fmt.Fprintf(m.w, "\r%s%s", strings.Repeat(" ", n), nl)
	}
	if m.lastRows > 1 {
		fmt.Fprintf(m.w, "\x1b[%dA", m.lastRows-1)
	}
	fmt.Fprint(m.w, "\r")
	m.lastRows = 0
	m.lastLens = m.lastLens[:0]
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
