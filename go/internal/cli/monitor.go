// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

type monitorOptions struct {
	// rangeInput is what the user asked for, spelled as they typed it (a band
	// name resolves to the band's own name), for the hint and summary lines.
	rangeInput string
	minHz      uint64
	maxHz      uint64
	forDur     time.Duration
	minSNR     float64
	minHold    time.Duration
	skirtDb    float64
	takeOver   bool
	device     string
	deviceID   string
}

func newMonitorCommand(app *App) *cobra.Command {
	var o monitorOptions
	var forStr string
	cmd := &cobra.Command{
		Use:   "monitor <band|range>",
		Short: "Park on a band and log the transmissions on it",
		Long: `monitor parks the radio on one band and watches it, then prints a
time-ordered log of the carriers that came and went: when each first
appeared, the span it bracketed (HELD) and how much of that span it was
actually transmitting (ON AIR), and how strong it was at its peak.

HELD and ON AIR are different questions, and the gap between them is the
point. HELD is first-sighting to last, so a carrier seen at the start and
again at the end reads a long HELD even if it was silent between. ON AIR is
the detector's own count of the rows it truly saw the carrier in, so a
strong signal's intermittent intermod reads a wide HELD but a tiny ON AIR,
and a repeater held down reads the two nearly equal.

Unlike scan it does not sweep. It holds one capture on the band and runs
the detector without moving, so it never time-shares and cannot miss a
transmission that starts while it is looking elsewhere. It is the
stationary, report-producing sibling of scan: scan asks what is on a band
right now, monitor asks what came and went over the minutes you watched.

The watch runs in the daemon, which owns the radio for the duration -- so
monitor will not interrupt someone who is listening. It says who has the
radio instead, and --take-over is the way to insist.

A band wider than one capture can watch is refused; scan sweeps a span
that wide. The radio's gain is the daemon's to set, as it is for a scan.

While it watches, each new carrier prints a line on stderr as it is first
heard. The log table is printed on stdout at the end, so a pipe gets the
report and a person gets the running commentary. --json prints one object
per carrier, newest columns and all, when the watch ends.

The log is kept clean by three filters, each off with a 0. --min-snr drops
a carrier whose peak never cleared a few dB over the noise floor, so a
detector's marginal hits do not become rows. --min-hold drops a carrier
held for less than a set time, for when only sustained traffic matters. And
a strong transmitter spills into the channels either side of it: --skirt-db
folds a much weaker carrier one channel over into the strong one it belongs
to, rather than listing the same transmission three times. What each filter
hid is tallied on stderr, because a hidden carrier is not a quiet band.`,
		Example: `  ley monitor gmrs               # watch the GMRS band for a minute
  ley monitor 462.5M..462.75M    # the same range, spelled out
  ley monitor gmrs --for 5m      # a longer radio check
  ley monitor gmrs --json        # the carriers, for tools`,
		GroupID: GroupLooking,
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			// A range (462.5M..462.75M) first; then a band name (gmrs, 2m), so
			// `ley monitor gmrs` works, exactly as scan resolves its positional.
			if lo, hi, rerr := leyline.ParseUserRange(args[0]); rerr == nil {
				o.minHz, o.maxHz, o.rangeInput = lo, hi, args[0]
			} else if b, berr := leyline.ResolveBand(args[0]); berr == nil {
				o.minHz, o.maxHz, o.rangeInput = b.MinHz, b.MaxHz, b.Name
			} else {
				return usageErrorf("%v, and no band called %q (ley bands lists them)", rerr, args[0])
			}
			d, err := parseAge(forStr)
			if err != nil {
				return usageErrorf("--for: %v", err)
			}
			o.forDur = d
			s, err := openSession(cmd.Context(), app)
			if err != nil {
				return err
			}
			defer s.close()
			if o.device != "" {
				dev, derr := pickDevice(s.state, o.device)
				if derr != nil {
					return derr
				}
				o.deviceID = dev.DeviceId
			}
			// The report and the JSON are the machine's; everything monitor says is for a person.
			s.proseToStderr = true
			return runMonitor(cmd.Context(), s, o)
		},
	}
	cmd.Flags().StringVar(&forStr, "for", "60s", "how long to watch before reporting, e.g. 30s, 2m; 0 watches until Ctrl-C")
	cmd.Flags().Float64Var(&o.minSNR, "min-snr", 8, "hide carriers whose peak was weaker than this many dB over the noise floor; --min-snr 0 shows every carrier heard")
	cmd.Flags().DurationVar(&o.minHold, "min-hold", 0, "hide carriers held for less than this, e.g. 2s (default 0: keep even a brief key-up)")
	cmd.Flags().Float64Var(&o.skirtDb, "skirt-db", 25, "fold a carrier this many dB below a stronger neighbour in an adjacent channel into it as a skirt; --skirt-db 0 lists them")
	cmd.Flags().BoolVar(&o.takeOver, "take-over", false, "watch even when somebody is using the radio; it is theirs again afterwards")
	cmd.Flags().StringVar(&o.device, "device", "", "which radio: an id (dev_...), id prefix or row number from 'ley devices' (default: the first real radio)")
	return cmd
}

// monitorCarrier is one carrier the watch heard, timed by the client's own clock: telemetry
// latency is sub-second, which is fine for a radio-check log, and it needs no anchor arithmetic.
type monitorCarrier struct {
	id       string
	centerHz uint64
	bwHz     uint32
	firstS   float64 // seconds after the watch began that this id first arrived
	lastS    float64 // seconds after the watch began that it was last updated
	peakSNR  float64
	// looks is the rows the detector actually saw this carrier in; looksPossible is the rows that
	// covered its frequency. Both are cumulative and grow with every update, so the carrier keeps
	// the largest of each: looks/looksPossible is the fraction of the watch it was truly on air,
	// which HELD (a first-to-last span) is not.
	looks         uint32
	looksPossible uint32
}

// onAirFrac is the fraction of the watch the carrier was actually transmitting: the detector's
// looks over the rows that could have held it. It is 0 when the daemon sent no look counts.
func (c *monitorCarrier) onAirFrac() float64 {
	if c.looksPossible == 0 {
		return 0
	}
	return float64(c.looks) / float64(c.looksPossible)
}

// monitorDrain is how long the report waits after the job completes for detections still in
// flight on the telemetry stream, so a carrier heard at the very end is not lost.
const monitorDrain = 250 * time.Millisecond

// runMonitor starts the watch, folds the detections on the telemetry plane into a transmission
// log, and prints it when the watch ends (the duration elapsed, or the user hit Ctrl-C).
func runMonitor(ctx context.Context, s *session, o monitorOptions) error {
	cfg := &leylinev1.MonitorConfig{
		Range:      &leylinev1.FrequencyRange{MinHz: o.minHz, MaxHz: o.maxHz},
		DurationMs: o.forDur.Milliseconds(),
		DeviceId:   o.deviceID,
		TakeOver:   o.takeOver,
	}
	job, err := s.client.Jobs.StartJob(ctx, &leylinev1.StartJobRequest{Config: &leylinev1.StartJobRequest_Monitor{Monitor: cfg}})
	if err != nil {
		return err
	}
	// Detections arrive on the telemetry plane (type DETECTION), daemon-wide: a monitor's
	// detections stream there just like a scan's, and the client folds them into the log.
	tctx, tcancel := context.WithCancel(ctx)
	defer tcancel()
	msgs, terrs, err := s.client.WatchTelemetry(tctx, &leylinev1.TelemetrySubscription{
		Types: []leylinev1.TelemetryType{leylinev1.TelemetryType_DETECTION},
	})
	if err != nil {
		return err
	}
	if o.forDur > 0 {
		s.say("watching %s to %s for %s\n", leyline.FormatFrequency(o.minHz), leyline.FormatFrequency(o.maxHz), forPhrase(o.forDur))
	} else {
		s.say("watching %s to %s until you stop it (Ctrl-C)\n", leyline.FormatFrequency(o.minHz), leyline.FormatFrequency(o.maxHz))
	}

	carriers := map[string]*monitorCarrier{}
	var order []string
	start := time.Now()
	record := func(d *leylinev1.Detection) {
		now := time.Since(start).Seconds()
		// Match by frequency, not by detection id: the detector's per-row centre estimate wobbles,
		// so one carrier arrives under several ids, and a wide FM carrier's centre wanders tens of
		// kHz. Fold nearby readings into one carrier the way scan does (within the narrower
		// bandwidth, or a few kHz), so a single transmission is one row, not a smear.
		if c := nearestCarrier(carriers, order, d); c != nil {
			c.lastS = now
			// Keep the strongest reading's centre and width, as scan's fold does.
			if d.SnrDb > c.peakSNR {
				c.peakSNR = d.SnrDb
				c.centerHz = d.CenterHz
				c.bwHz = d.BandwidthHz
			}
			// The look counts are cumulative, so the latest update carries the largest of each.
			if d.Looks > c.looks {
				c.looks = d.Looks
			}
			if d.LooksPossible > c.looksPossible {
				c.looksPossible = d.LooksPossible
			}
			return
		}
		id := d.DetectionId
		if id == "" {
			id = fmt.Sprintf("carrier-%d", len(order))
		}
		c := &monitorCarrier{id: id, centerHz: d.CenterHz, bwHz: d.BandwidthHz, firstS: now, lastS: now, peakSNR: d.SnrDb, looks: d.Looks, looksPossible: d.LooksPossible}
		carriers[id] = c
		order = append(order, id)
		// The live feed is running commentary, so it respects the SNR floor a debut is judged
		// against; the skirt fold needs the whole run and is applied to the report at the end.
		if !s.app.JSON && (o.minSNR <= 0 || d.SnrDb >= o.minSNR) {
			// The live feed is stderr, so stdout stays the report a pipe reads.
			fmt.Fprintf(s.app.Stderr, "  %s  %s  %s  %.0f dB\n", mmss(now), leyline.FormatFrequency(d.CenterHz), monitorChannel(d.CenterHz), d.SnrDb)
		}
	}

	last := job
	interrupted := false
	poll := time.NewTicker(2 * time.Second)
	defer poll.Stop()
	events := s.events
follow:
	for last.State == leylinev1.JobState_RUNNING {
		select {
		case <-ctx.Done():
			interrupted = true
			break follow
		case <-poll.C:
			// A backstop, not the mechanism: job state arrives on the event stream, but a stream
			// can end cleanly or drop an event, and without this the watch would never return.
			j, gerr := s.client.Jobs.GetJob(ctx, &leylinev1.JobRef{JobId: job.JobId})
			if gerr != nil {
				if ctx.Err() != nil {
					interrupted = true
					break follow
				}
				return gerr
			}
			last = j
		case ev, ok := <-events:
			if !ok {
				if e := <-s.eventErrs; e != nil {
					return e
				}
				j, gerr := s.client.Jobs.GetJob(ctx, &leylinev1.JobRef{JobId: job.JobId})
				if gerr != nil {
					if ctx.Err() != nil {
						interrupted = true
					}
					break follow
				}
				last = j
				break follow
			}
			if b, isJob := ev.Body.(*leylinev1.Event_Job); isJob && b.Job.JobId == job.JobId {
				last = b.Job
			} else {
				s.apply(ev)
			}
		case m, ok := <-msgs:
			if !ok {
				msgs = nil
				continue
			}
			if d := m.GetDetection(); d != nil {
				record(d)
			}
		case _, ok := <-terrs:
			if !ok {
				terrs = nil
			}
		}
	}

	// Interrupted: stop the watch now rather than waiting out its duration -- the next thing the
	// user does after Ctrl-C is usually tune -- and then print what it heard before it stopped.
	if interrupted {
		c, stop := context.WithTimeout(context.Background(), confirmTimeout)
		defer stop()
		if j, cerr := s.client.Jobs.CancelJob(c, &leylinev1.JobRef{JobId: job.JobId}); cerr == nil {
			last = j
		}
	} else {
		// A carrier heard at the very end may still be in flight on the telemetry stream when the
		// job event says COMPLETED: give those a moment to arrive before drawing the log.
		deadline := time.After(monitorDrain)
	drain:
		for {
			select {
			case m, ok := <-msgs:
				if !ok {
					break drain
				}
				if d := m.GetDetection(); d != nil {
					record(d)
				}
			case <-deadline:
				break drain
			}
		}
	}
	tcancel()

	if last.State == leylinev1.JobState_FAILED {
		return &ExitError{Code: 1, Message: monitorFailure(last, s.app.ErrStyle)}
	}
	watched := o.forDur
	if watched == 0 || interrupted {
		watched = time.Since(start)
	}
	if s.app.JSON {
		return printMonitorJSON(s.app, o, order, carriers, watched)
	}
	printMonitorReport(s.app, o, order, carriers, watched)
	return nil
}

// monitorChannel names the GMRS/preset channel on a frequency, or "-" when none sits there.
func monitorChannel(hz uint64) string {
	if p := presetAt(hz); p != "" {
		return p
	}
	return "-"
}

// mmss renders seconds-since-start as mm:ss, the log's TIME column and its live-feed lines.
func mmss(sec float64) string {
	if sec < 0 {
		sec = 0
	}
	total := int(sec + 0.5)
	return fmt.Sprintf("%d:%02d", total/60, total%60)
}

// forPhrase renders a watch duration in plain words: "45 s", "1 min", "2 min 30 s".
func forPhrase(d time.Duration) string {
	secs := int(d.Round(time.Second).Seconds())
	if secs < 60 {
		return fmt.Sprintf("%d s", secs)
	}
	m, s := secs/60, secs%60
	if s == 0 {
		return fmt.Sprintf("%d min", m)
	}
	return fmt.Sprintf("%d min %d s", m, s)
}

// monitorArg re-spells what the user asked for, for a hint or a summary line.
func monitorArg(o monitorOptions) string {
	if o.rangeInput != "" {
		return o.rangeInput
	}
	return trimZeros(float64(o.minHz)/1e6) + ".." + trimZeros(float64(o.maxHz)/1e6)
}

// nearestCarrier returns the tracked carrier closest to a detection within the merge tolerance, or
// nil for a genuinely new one. Nearest rather than first, so a detection between two channels folds
// into the closer.
func nearestCarrier(carriers map[string]*monitorCarrier, order []string, d *leylinev1.Detection) *monitorCarrier {
	var best *monitorCarrier
	var bestDiff uint64
	for _, id := range order {
		c := carriers[id]
		diff := absDiff(c.centerHz, d.CenterHz)
		if diff <= mergeTol(c.bwHz, d.BandwidthHz) && (best == nil || diff < bestDiff) {
			best, bestDiff = c, diff
		}
	}
	return best
}

// mergeTol is scan's rule: two readings are the same carrier when their centres are within the
// narrower one's half-width, or a few kHz for anything narrow -- so channels 12.5 kHz apart stay
// distinct while a wide carrier's wandering centre folds together.
func mergeTol(aBw, bBw uint32) uint64 {
	narrow := aBw
	if bBw < narrow {
		narrow = bBw
	}
	tol := uint64(5_000)
	if half := uint64(narrow) / 2; half > tol {
		tol = half
	}
	return tol
}

func absDiff(a, b uint64) uint64 {
	if a > b {
		return a - b
	}
	return b - a
}

// monitorHidden counts, by reason, the carriers a filter left out of the log, so the report can
// say what it dropped and how to see it. Hiding what was heard is a different answer from an empty
// band, and each reason has its own remedy.
type monitorHidden struct {
	weak  int // peak never cleared --min-snr
	brief int // held for less than --min-hold
	skirt int // an adjacent channel's spill from a much stronger carrier
}

func (h monitorHidden) any() bool { return h.weak+h.brief+h.skirt > 0 }

// skirtSpanHz is how far an adjacent-channel skirt can sit from the carrier it belongs to: the
// carrier's own width, but at least one channel over, so a strong signal's spill into the next slot
// folds while a genuine carrier two channels away does not.
func skirtSpanHz(aBw uint32) uint64 {
	span := uint64(aBw)
	if span < 30_000 {
		span = 30_000
	}
	return span
}

// filterMonitorCarriers picks the carriers the log shows and tallies why the rest were left out.
// Two absolute floors first -- a carrier must clear --min-snr and have been held at least
// --min-hold -- then skirt suppression against the survivors: a carrier that sits in an adjacent
// channel to one at least --skirt-db stronger is that carrier's spill, not a transmission of its
// own. It is dropped, not merged, because its span already matches the carrier it belongs to.
func filterMonitorCarriers(order []string, carriers map[string]*monitorCarrier, o monitorOptions) ([]*monitorCarrier, monitorHidden) {
	var hidden monitorHidden
	survivors := make([]*monitorCarrier, 0, len(order))
	for _, id := range order {
		c := carriers[id]
		if o.minSNR > 0 && c.peakSNR < o.minSNR {
			hidden.weak++
			continue
		}
		if o.minHold > 0 && (c.lastS-c.firstS) < o.minHold.Seconds() {
			hidden.brief++
			continue
		}
		survivors = append(survivors, c)
	}
	if o.skirtDb <= 0 {
		return survivors, hidden
	}
	rows := make([]*monitorCarrier, 0, len(survivors))
	for _, c := range survivors {
		if isSkirtOf(c, survivors, o.skirtDb) {
			hidden.skirt++
			continue
		}
		rows = append(rows, c)
	}
	return rows, hidden
}

// isSkirtOf reports whether c is an adjacent-channel skirt of a stronger carrier among peers: one
// at least skirtDb stronger whose centre is within a skirt's reach of c's. Only a weaker carrier is
// ever a skirt, so this never drops the real signal.
func isSkirtOf(c *monitorCarrier, peers []*monitorCarrier, skirtDb float64) bool {
	for _, a := range peers {
		if a == c {
			continue
		}
		if a.peakSNR-c.peakSNR >= skirtDb && absDiff(a.centerHz, c.centerHz) <= skirtSpanHz(a.bwHz) {
			return true
		}
	}
	return false
}

// printMonitorReport draws the transmission log on stdout, sorted by first appearance, and the
// summary sentence on stderr. The filters (weak, brief and skirt) leave carriers off the log and
// are tallied on stderr, so hiding what was heard never reads as an empty band.
func printMonitorReport(app *App, o monitorOptions, order []string, carriers map[string]*monitorCarrier, watched time.Duration) {
	st := app.ErrStyle
	rows, hidden := filterMonitorCarriers(order, carriers, o)
	if len(rows) == 0 {
		if hidden.any() {
			// Hiding what was heard is not the same answer as hearing nothing, and the remedy
			// differs: a longer watch will not bring back a carrier a filter left out.
			fmt.Fprintf(app.Stderr, "%s heard, all filtered out (%s)\n", plural(hiddenTotal(hidden), "carrier"), hiddenReasons(hidden, o))
			fmt.Fprintf(app.Stderr, "drop the filters to see them: %s\n", st.Cmd("ley monitor "+monitorArg(o)+" --min-snr 0 --skirt-db 0"))
			return
		}
		fmt.Fprintf(app.Stderr, "nothing heard on %s in %s\n", monitorArg(o), forPhrase(watched))
		return
	}
	cols := []column{
		{head: "TIME", cells: mapCarrier(rows, func(c *monitorCarrier) string { return mmss(c.firstS) })},
		{head: "FREQUENCY", cells: mapCarrier(rows, func(c *monitorCarrier) string { return leyline.FormatFrequency(c.centerHz) })},
		{head: "CHANNEL", cells: mapCarrier(rows, func(c *monitorCarrier) string { return monitorChannel(c.centerHz) })},
		{head: "HELD", cells: mapCarrier(rows, heldCell)},
		{head: "ON AIR", cells: mapCarrier(rows, func(c *monitorCarrier) string { return onAirCell(c, watched) })},
		{head: "PEAK SNR", cells: mapCarrier(rows, func(c *monitorCarrier) string { return fmt.Sprintf("%.0f dB", c.peakSNR) })},
	}
	_, _ = printColumns(app.Stdout, tableStyle(app), cols, nil)
	best := rows[0]
	for _, c := range rows {
		if c.peakSNR > best.peakSNR {
			best = c
		}
	}
	label := monitorChannel(best.centerHz)
	if label == "-" {
		label = leyline.FormatFrequency(best.centerHz)
	}
	fmt.Fprintf(app.Stderr, "%s over %s; strongest %s (%s) at %.0f dB\n",
		plural(len(rows), "carrier"), forPhrase(watched), label, trimZeros(float64(best.centerHz)/1e6), best.peakSNR)
	if hidden.any() {
		fmt.Fprintf(app.Stderr, "%s not shown (%s); %s\n",
			plural(hiddenTotal(hidden), "carrier"), hiddenReasons(hidden, o), st.Cmd("ley monitor "+monitorArg(o)+" --min-snr 0 --skirt-db 0"))
	}
}

func hiddenTotal(h monitorHidden) int { return h.weak + h.brief + h.skirt }

// hiddenReasons spells the filter drops in plain words, naming the flag that controls each so the
// remedy is obvious: a weak carrier and a skirt are hidden for different reasons and come back
// different ways.
func hiddenReasons(h monitorHidden, o monitorOptions) string {
	var parts []string
	if h.weak > 0 {
		parts = append(parts, fmt.Sprintf("%d below %.0f dB", h.weak, o.minSNR))
	}
	if h.brief > 0 {
		parts = append(parts, fmt.Sprintf("%d held under %s", h.brief, forPhrase(o.minHold)))
	}
	if h.skirt > 0 {
		parts = append(parts, fmt.Sprintf("%s of a stronger carrier", plural(h.skirt, "skirt")))
	}
	return strings.Join(parts, ", ")
}

// heldCell is the span from first to last sighting: how long the carrier bracketed the watch, not
// how long it transmitted (that is ON AIR). A single sighting has no measurable span, so it reads
// "under 1 s" rather than "0 s".
func heldCell(c *monitorCarrier) string {
	return secsCell(c.lastS - c.firstS)
}

// onAirCell is how long the carrier was actually transmitting: its on-air fraction of the watch
// times the watch's length. Beside HELD it separates a carrier that occupied the channel from one
// that only flickered across a long span -- a strong signal's intermod reads a wide HELD but a
// tiny ON AIR. It is "?" when the daemon sent no look counts, since 0 s would be a false claim.
func onAirCell(c *monitorCarrier, watched time.Duration) string {
	if c.looksPossible == 0 {
		return "?"
	}
	return secsCell(c.onAirFrac() * watched.Seconds())
}

// secsCell renders a span of seconds for a table cell, reading "under 1 s" below a second.
func secsCell(s float64) string {
	if s < 1 {
		return "under 1 s"
	}
	return fmt.Sprintf("%.0f s", s)
}

func mapCarrier(rows []*monitorCarrier, f func(*monitorCarrier) string) []string {
	out := make([]string, len(rows))
	for i, c := range rows {
		out[i] = f(c)
	}
	return out
}

// monitorCarrierJSON is one line of `ley monitor --json`: a client-side fold with no proto
// message, so the shape is snake_case and documented in docs/reference/cli.md, like track's.
type monitorCarrierJSON struct {
	DetectionID   string  `json:"detection_id"`
	CenterHz      uint64  `json:"center_hz"`
	Channel       string  `json:"channel"`
	FirstS        float64 `json:"first_s"`
	HeldS         float64 `json:"held_s"`
	OnAirS        float64 `json:"on_air_s"`
	Looks         uint32  `json:"looks"`
	LooksPossible uint32  `json:"looks_possible"`
	PeakSnrDb     float64 `json:"peak_snr_db"`
	BandwidthHz   uint32  `json:"bandwidth_hz"`
}

// printMonitorJSON writes one NDJSON object per carrier, in first-appearance order, at the end.
func printMonitorJSON(app *App, o monitorOptions, order []string, carriers map[string]*monitorCarrier, watched time.Duration) error {
	round := func(x float64) float64 { return math.Round(x*10) / 10 }
	rows, _ := filterMonitorCarriers(order, carriers, o)
	for _, c := range rows {
		ch := monitorChannel(c.centerHz)
		if ch == "-" {
			ch = ""
		}
		if err := app.printArray(monitorCarrierJSON{
			DetectionID: c.id, CenterHz: c.centerHz, Channel: ch,
			FirstS: round(c.firstS), HeldS: round(c.lastS - c.firstS),
			OnAirS: round(c.onAirFrac() * watched.Seconds()), Looks: c.looks, LooksPossible: c.looksPossible,
			PeakSnrDb: c.peakSNR, BandwidthHz: c.bwHz,
		}); err != nil {
			return err
		}
	}
	return nil
}

// monitorFailure turns a failed watch into the sentence the user reads: the daemon's code is what
// ley branches on, its status_detail the prose a person needs, mirrored on scanFailure.
func monitorFailure(job *leylinev1.Job, st ui.Style) string {
	detail := job.StatusDetail
	code := job.GetError().GetCode()
	if code == "" {
		return detail
	}
	if detail == "" {
		detail = job.GetError().GetMessage()
	}
	switch code {
	case leyline.CodeDeviceBusy:
		return detail + ". " + st.Cmd("ley monitor --take-over") + " watches anyway, and hands the radio back afterwards"
	case leyline.CodeInvalidArgument:
		return detail + ". " + st.Cmd("ley scan") + " sweeps a span too wide for one capture"
	case leyline.CodeNoDevice, leyline.CodeFreqOutOfRange:
		return detail + ". " + st.Cmd("ley devices") + " lists what is here and what it can tune"
	}
	return detail + " [" + code + "]"
}
