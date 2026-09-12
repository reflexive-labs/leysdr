package cli

import (
	"bufio"
	"fmt"
	"math"
	"strings"
	"time"
)

// How the live chart behaves in time.
const (
	// chartTickInterval is how often the status line is refreshed while no
	// row has arrived.
	chartTickInterval = 250 * time.Millisecond
	// chartWaitNote is how long stdout may stay empty before the person is
	// told, on stderr, that nothing has arrived yet.
	chartWaitNote = time.Second
	// chartNoteFor is how long a scale change stays on the status line.
	chartNoteFor = 3 * time.Second
	// chartFirstRow is how long a one-shot waits for its only row before
	// saying that nothing came. --watch waits for ever, and says so.
	chartFirstRow = 10 * time.Second
)

// Terminal control the live chart needs. These are the only escapes ley
// writes: move up, erase to end of line, and hide/show the cursor. They are
// written to stdout only when it is a terminal and --watch is redrawing.
const (
	ansiEraseLine   = "\x1b[K"
	ansiHideCursor  = "\x1b[?25l"
	ansiShowCursor  = "\x1b[?25h"
	ansiCursorUpFmt = "\x1b[%dA"
)

// chartWriter puts charts on the screen: appended when piped, redrawn in
// place on a terminal, always with a status line that says whether the stream
// is alive.
type chartWriter struct {
	app    *App
	out    *bufio.Writer
	redraw bool // in-place redraw (a --watch run on a terminal)
	watch  bool
	rate   float64
	// height is the terminal's row count, 0 when unknown. A block taller than
	// the screen cannot be redrawn in place at all: cursor-up clamps at the
	// top, so the first lines are stranded and every later redraw compounds it.
	height int
	// scrolling is set once a frame has been appended rather than redrawn, so
	// the status line stops trying to overwrite something that has moved.
	scrolling bool
	// toldWhy reports that the reason for scrolling has been said once.
	toldWhy bool

	start     time.Time
	last      time.Time // when the last row arrived
	frames    int
	lines     int // lines the block on screen occupies
	note      string
	noteUntil time.Time
	warned    bool
	hidden    bool
}

// newChartWriter fits a writer to one run: watch says the run redraws rather
// than printing once, and rate is how many frames a second the daemon means to
// send, which is what silence is measured against.
func newChartWriter(app *App, out *bufio.Writer, watch bool, rate float64) *chartWriter {
	return &chartWriter{
		app:    app,
		out:    out,
		redraw: watch && !app.JSON && app.IsTTY(),
		watch:  watch,
		rate:   rate,
		height: app.Style.Height,
		start:  time.Now(),
	}
}

// frame writes one rendered chart. On a terminal it overwrites the previous
// one, erasing each line as it goes so a shorter chart cannot leave the tail
// of a longer one behind; piped, charts are appended with a blank line
// between them, which is what scripts already read.
func (w *chartWriter) frame(text, note string) {
	w.row()
	if note != "" {
		w.note, w.noteUntil = note, w.last.Add(chartNoteFor)
	}
	if !w.redraw {
		w.out.WriteString(text)
		if w.watch {
			w.out.WriteString("\n")
		}
		return
	}
	if !w.hidden {
		w.out.WriteString(ansiHideCursor)
		w.hidden = true
	}
	lines := strings.Split(strings.TrimSuffix(text, "\n"), "\n")
	// The block is the chart plus its status line, and redrawing it needs one
	// row of headroom: after writing N lines the cursor sits on the next one,
	// and moving back N only lands on the first line if all N+1 were on screen.
	if !w.fits(len(lines) + 1) {
		w.scroll(lines)
		return
	}
	w.up()
	for _, l := range lines {
		w.out.WriteString(l + ansiEraseLine + "\n")
	}
	w.out.WriteString(w.status() + ansiEraseLine + "\n")
	w.lines = len(lines) + 1
	w.scrolling = false
}

// fits reports whether a block of n lines can be redrawn in place. An unknown
// height keeps the old behaviour: it is no worse than before, and on a terminal
// that will not report its size there is nothing better to do.
func (w *chartWriter) fits(n int) bool {
	return w.height <= 0 || n <= w.height
}

// scroll appends a block that is too tall to redraw, and says why once. Left
// silent, a chart that suddenly started scrolling would look like a bug rather
// than a window that is too short.
func (w *chartWriter) scroll(lines []string) {
	if !w.toldWhy {
		w.toldWhy = true
		fmt.Fprintf(w.app.Stderr, "%s\n", w.app.ErrStyle.Muted(fmt.Sprintf(
			"the chart is %d rows and this terminal has %d, so it scrolls instead of redrawing; a taller window redraws in place",
			len(lines)+1, w.height)))
	}
	if w.hidden {
		w.out.WriteString(ansiShowCursor)
		w.hidden = false
	}
	for _, l := range lines {
		w.out.WriteString(l + ansiEraseLine + "\n")
	}
	w.out.WriteString(w.status() + ansiEraseLine + "\n")
	// Nothing on screen is ours to overwrite any more.
	w.lines = 0
	w.scrolling = true
}

// row records that the daemon delivered one. --json writes its own line and
// draws nothing, but the stream is alive and must not be reported as stalled.
func (w *chartWriter) row() {
	w.frames++
	w.last = time.Now()
}

// footer writes the one-shot's next-step line under the chart.
func (w *chartWriter) footer(text string) {
	if text != "" {
		w.out.WriteString(text)
	}
}

// idle runs between rows. On a terminal it keeps the status line honest
// (elapsed, or how long the stream has been silent); everywhere else it makes
// sure a stream that never produces a row says so on stderr rather than
// hanging with no output at all.
func (w *chartWriter) idle() {
	if w.frames == 0 && !w.warned && time.Since(w.start) > chartWaitNote {
		w.warned = true
		fmt.Fprintln(w.app.Stderr, w.app.ErrStyle.Muted("waiting for the first spectrum row from the daemon"))
	}
	if !w.redraw {
		return
	}
	if w.lines == 0 && w.frames == 0 && time.Since(w.start) < chartWaitNote {
		return
	}
	if !w.hidden {
		w.out.WriteString(ansiHideCursor)
		w.hidden = true
	}
	// A scrolling run has no anchored status line to refresh; its status is
	// printed with each block and rewriting it here would append a line a
	// second for as long as the run lasts.
	if w.scrolling {
		return
	}
	if w.lines > 0 {
		fmt.Fprintf(w.out, ansiCursorUpFmt, 1)
	}
	w.out.WriteString(w.status() + ansiEraseLine + "\n")
	if w.lines == 0 {
		w.lines = 1
	}
	w.out.Flush()
}

// up moves the cursor back to the top of the block on screen.
func (w *chartWriter) up() {
	if w.lines > 0 {
		fmt.Fprintf(w.out, ansiCursorUpFmt, w.lines)
	}
}

// status is the live chart's last line: how many rows have been drawn, how
// fast, for how long, and whether the stream has gone quiet.
func (w *chartWriter) status() string {
	st := w.app.Style
	if w.frames == 0 {
		return st.Warn("waiting for data")
	}
	if since := time.Since(w.last); since > w.stallAfter() {
		return st.Warn(fmt.Sprintf("stream stalled %.1f s ago", since.Seconds()))
	}
	text := fmt.Sprintf("frame %d  %.1f/s  %.0f s elapsed", w.frames, w.rate, time.Since(w.start).Seconds())
	if w.note != "" && time.Now().Before(w.noteUntil) {
		text += "  " + w.note
	}
	return st.Muted(text)
}

// stallAfter is how much silence counts as a stall: three rows' worth, and
// never less than a second and a half.
func (w *chartWriter) stallAfter() time.Duration {
	if w.rate <= 0 {
		return 3 * time.Second
	}
	d := time.Duration(3 / math.Max(w.rate, 0.1) * float64(time.Second))
	if d < 1500*time.Millisecond {
		d = 1500 * time.Millisecond
	}
	return d
}

// finish restores the terminal: the cursor comes back whatever ended the run,
// Ctrl-C included.
func (w *chartWriter) finish() {
	if w.hidden {
		w.out.WriteString(ansiShowCursor)
		w.hidden = false
	}
	w.out.Flush()
}
