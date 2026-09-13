// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"fmt"
	"math"
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
appeared, how long it held the channel, and how strong it was at its peak.

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
per carrier, newest columns and all, when the watch ends.`,
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
	cmd.Flags().Float64Var(&o.minSNR, "min-snr", 0, "hide carriers whose peak was weaker than this many dB over the noise floor (default: show every carrier heard)")
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
		if d.DetectionId == "" {
			return
		}
		now := time.Since(start).Seconds()
		c, seen := carriers[d.DetectionId]
		if !seen {
			c = &monitorCarrier{id: d.DetectionId, centerHz: d.CenterHz, bwHz: d.BandwidthHz, firstS: now, lastS: now, peakSNR: d.SnrDb}
			carriers[d.DetectionId] = c
			order = append(order, d.DetectionId)
			if !s.app.JSON {
				// The live feed is stderr, so stdout stays the report a pipe reads.
				fmt.Fprintf(s.app.Stderr, "  %s  %s  %s  %.0f dB\n", mmss(now), leyline.FormatFrequency(d.CenterHz), monitorChannel(d.CenterHz), d.SnrDb)
			}
			return
		}
		c.lastS = now
		c.centerHz = d.CenterHz
		c.bwHz = d.BandwidthHz
		if d.SnrDb > c.peakSNR {
			c.peakSNR = d.SnrDb
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
		return printMonitorJSON(s.app, o, order, carriers)
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

// printMonitorReport draws the transmission log on stdout, sorted by first appearance, and the
// summary sentence on stderr. --min-snr hides a carrier whose peak never cleared the threshold.
func printMonitorReport(app *App, o monitorOptions, order []string, carriers map[string]*monitorCarrier, watched time.Duration) {
	st := app.ErrStyle
	rows := make([]*monitorCarrier, 0, len(order))
	hidden := 0
	for _, id := range order {
		c := carriers[id]
		if o.minSNR > 0 && c.peakSNR < o.minSNR {
			hidden++
			continue
		}
		rows = append(rows, c)
	}
	if len(rows) == 0 {
		if hidden > 0 {
			// Hiding what was heard is not the same answer as hearing nothing, and the remedy
			// differs: a longer watch will not bring back a carrier --min-snr filtered out.
			fmt.Fprintf(app.Stderr, "%s below %.0f dB, so nothing to show\n", plural(hidden, "carrier"), o.minSNR)
			fmt.Fprintf(app.Stderr, "drop the filter to see them: %s\n", st.Cmd("ley monitor "+monitorArg(o)))
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
}

// heldCell is how long the carrier held the channel, observed by the client. A single sighting
// has no measurable span, so it reads "under 1 s" rather than "0 s".
func heldCell(c *monitorCarrier) string {
	held := c.lastS - c.firstS
	if held < 1 {
		return "under 1 s"
	}
	return fmt.Sprintf("%.0f s", held)
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
	DetectionID string  `json:"detection_id"`
	CenterHz    uint64  `json:"center_hz"`
	Channel     string  `json:"channel"`
	FirstS      float64 `json:"first_s"`
	HeldS       float64 `json:"held_s"`
	PeakSnrDb   float64 `json:"peak_snr_db"`
	BandwidthHz uint32  `json:"bandwidth_hz"`
}

// printMonitorJSON writes one NDJSON object per carrier, in first-appearance order, at the end.
func printMonitorJSON(app *App, o monitorOptions, order []string, carriers map[string]*monitorCarrier) error {
	round := func(x float64) float64 { return math.Round(x*10) / 10 }
	for _, id := range order {
		c := carriers[id]
		if o.minSNR > 0 && c.peakSNR < o.minSNR {
			continue
		}
		ch := monitorChannel(c.centerHz)
		if ch == "-" {
			ch = ""
		}
		if err := app.printArray(monitorCarrierJSON{
			DetectionID: c.id, CenterHz: c.centerHz, Channel: ch,
			FirstS: round(c.firstS), HeldS: round(c.lastS - c.firstS), PeakSnrDb: c.peakSNR, BandwidthHz: c.bwHz,
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
