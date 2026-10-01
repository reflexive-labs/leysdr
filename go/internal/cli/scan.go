// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

type scanOptions struct {
	rangeInput string
	bandName   string
	minHz      uint64
	maxHz      uint64
	dwellMs    uint32
	minSNR     float64
	sortBySNR  bool
	takeOver   bool
	device     string
	deviceID   string
	// gain is --gain as typed: auto, or dB. Empty leaves the radio where it is.
	gain string
}

func newScanCommand(app *App) *cobra.Command {
	var o scanOptions
	var sortBy string
	cmd := &cobra.Command{
		Use:   "scan [low..high]",
		Short: "Sweep a range and list the signals on it",
		Long: `scan points the radio across a range of frequencies, measures the noise floor
at each stop and reports the carriers that stand above it: where they are,
how wide, and how far over the floor.

The sweep runs in the daemon, which owns the radio for the few seconds it
takes -- so scan will not interrupt someone who is listening. It says who
has the radio instead, and --take-over is the way to insist.

The sweep holds the tuner's gain still for its whole length, because a level
measured against a moving AGC is not a number, and says where it held it.
Without --gain that is wherever the radio was left, so two sweeps of one band
can differ by the last tune's gain; --gain 30 pins it there, and --gain auto
lets the radio's AGC settle and pins that. The radio goes back to its own
setting afterwards.

What it finds is what is sitting on the band while it looks. A row's SEEN
column is the evidence: 8/8 means the signal was there every time scan
looked at that frequency, 1/8 means it caught one burst. Nothing is
filtered on that count -- an intermittent packet is exactly what you might
be scanning for -- so read it rather than trusting the row alone.

WIDTH is the equivalent rectangular width: the width a flat signal with the
same spread would have. It does not grow with signal strength the way the
width of a peak above a threshold does. Below the analysis resolution it
says so rather than quoting a number.

The floor is measured per bin and is far below what a channel meter reads
for the same air, because a channel is thousands of bins wide.

--json prints one Scan object when the sweep finishes and nothing before it:
the answer is the whole scan, not the steps it took to get there. Progress
goes to stderr, where a person can see it and a pipe cannot.`,
		Example: `  ley scan 144M..148M            # the 2 m band
  ley scan --band 2m             # the same, by name
  ley scan 162.4M..162.55M       # the NOAA weather channels
  ley scan 144M..148M --gain 30  # at a known gain, so two sweeps compare
  ley scan 144M..148M --json     # the Scan message, for tools`,
		GroupID: GroupLooking,
		Args:    cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			switch {
			case len(args) == 1 && o.bandName != "":
				return usageErrorf("give a range or --band, not both: a range and a band name say two different things about where to look")
			case len(args) == 1:
				// A range (144M..148M) first; then a band name (gmrs, 2m), so `ley scan gmrs`
				// works. A bare frequency is neither and stays an error -- a scan needs a span.
				if lo, hi, rerr := leyline.ParseUserRange(args[0]); rerr == nil {
					o.minHz, o.maxHz, o.rangeInput = lo, hi, args[0]
				} else if b, berr := leyline.ResolveBand(args[0]); berr == nil {
					o.minHz, o.maxHz, o.rangeInput = b.MinHz, b.MaxHz, b.Name
				} else {
					return usageErrorf("%v, and no band called %q; check with: ley bands", rerr, args[0])
				}
			case o.bandName != "":
				b, err := leyline.ResolveBand(o.bandName)
				if err != nil {
					return usageErrorf("%v", err)
				}
				o.minHz, o.maxHz, o.rangeInput = b.MinHz, b.MaxHz, b.Name
			default:
				return usageErrorf("scan needs a range: ley scan 144M..148M, or ley scan --band 2m; check with: ley bands")
			}
			if o.gain != "" {
				if _, err := leyline.ParseGains(o.gain); err != nil {
					return usageErrorf("--gain %v", err)
				}
			}
			switch sortBy {
			case "freq", "":
				o.sortBySNR = false
			case "snr":
				o.sortBySNR = true
			default:
				return usageErrorf("--sort must be freq or snr")
			}
			s, err := openSession(cmd.Context(), app)
			if err != nil {
				return err
			}
			defer s.close()
			// The daemon takes a device id, not a row number or a prefix, so the selector is
			// resolved here against the same list every other verb uses.
			if o.device != "" {
				d, derr := pickDevice(s.state, o.device)
				if derr != nil {
					return derr
				}
				o.deviceID = d.DeviceId
			}
			// Scan's prose goes to stderr; stdout carries only the table or the JSON.
			s.proseToStderr = true
			return runScan(cmd.Context(), s, o)
		},
	}
	cmd.Flags().StringVar(&o.bandName, "band", "", "sweep a named band instead of a range, e.g. 2m (ley bands lists them)")
	cmd.Flags().Uint32Var(&o.dwellMs, "dwell", 0, "milliseconds to listen at each stop, e.g. 400; longer finds weaker signals (default: the daemon's 250)")
	cmd.Flags().Float64Var(&o.minSNR, "min-snr", 0, "hide anything weaker than this many dB over the noise floor (default: show everything found)")
	cmd.Flags().StringVar(&sortBy, "sort", "freq", "row order: freq or snr")
	cmd.Flags().BoolVar(&o.takeOver, "take-over", false, "sweep even when somebody is using the radio; it is theirs again afterwards")
	cmd.Flags().StringVar(&o.device, "device", "", "which radio: an id (dev_...), id prefix or row number from 'ley devices' (default: the first real radio)")
	cmd.Flags().StringVar(&o.gain, "gain", "", gainHelp+"; held for the whole sweep; default: the gain the radio is on")
	return cmd
}

// runScan starts the sweep, follows it on the event stream, and prints what it found.
func runScan(ctx context.Context, s *session, o scanOptions) error {
	scan, final, err := s.sweep(ctx, o)
	if err != nil {
		return err
	}
	if scan == nil {
		// sweep already printed why there is nothing to show.
		return nil
	}
	if final.State == leylinev1.JobState_CANCELLED && !s.app.JSON {
		s.say("stopped early: %s\n", final.StatusDetail)
	}
	if s.app.JSON {
		return s.app.printJSON(scan)
	}
	printScan(s.app, scan, o, scanGainElements(s.state, o.deviceID, scan))
	return nil
}

// sweep starts a once-scan job, follows it to its end and fetches the Scan it produced. A nil
// Scan with a nil error means the sweep ended with nothing to fetch and the reason was already
// printed on stderr: an interrupted sweep the daemon could not report on in time, or a job that
// named no scan. `ley scan` prints what comes back; the MCP adapter's scan tool returns it.
func (s *session) sweep(ctx context.Context, o scanOptions) (*leylinev1.Scan, *leylinev1.Job, error) {
	cfg := &leylinev1.ScanConfig{
		Range:    &leylinev1.FrequencyRange{MinHz: o.minHz, MaxHz: o.maxHz},
		DwellMs:  o.dwellMs,
		Schedule: &leylinev1.ScanConfig_Once{Once: true},
		TakeOver: o.takeOver,
		DeviceId: o.deviceID,
		Gains:    gainWrites(o.gain),
	}
	job, err := s.client.Jobs.StartJob(ctx, &leylinev1.StartJobRequest{Config: &leylinev1.StartJobRequest_Scan{Scan: cfg}})
	if err != nil {
		return nil, nil, err
	}
	st := s.app.ErrStyle
	s.say("sweeping %s to %s\n", leyline.FormatFrequency(o.minHz), leyline.FormatFrequency(o.maxHz))

	progress := newScanProgress(s.app)
	final, err := s.followJob(ctx, job, progress)
	progress.clear()
	if err != nil {
		return nil, nil, err
	}
	// Interrupted: stop the sweep now rather than waiting for the presence grace -- the next thing
	// somebody does after Ctrl-C is usually tune -- and then print what it found before it stopped.
	// An interrupted sweep still has valid measurements for the part that ran.
	read := ctx
	if ctx.Err() != nil {
		c, stop := context.WithTimeout(context.Background(), confirmTimeout)
		defer stop()
		read = c
		if j, cerr := s.client.Jobs.CancelJob(c, &leylinev1.JobRef{JobId: job.JobId}); cerr == nil {
			final = j
		}
	}
	if final.State == leylinev1.JobState_FAILED {
		return nil, final, &ExitError{Code: 1, Message: scanFailure(final, st)}
	}
	id, idErr := scanIDOf(final)
	if idErr != nil {
		// A job that named no scan has nothing to show. Under --json that is a failure, not an
		// empty success: a consumer reading nothing on stdout and exit 0 concludes an empty band.
		if s.app.JSON {
			return nil, final, &ExitError{Code: 1, Message: idErr.Error() + ": " + final.StatusDetail}
		}
		s.say("%s (%s)\n", final.StatusDetail, idErr)
		return nil, final, nil
	}
	scan, err := s.client.Jobs.GetScan(read, &leylinev1.ScanRef{ScanId: id})
	if err != nil {
		// Interrupted, and the daemon was still handing the radio back when we asked. Say so:
		// exiting 0 with an empty screen reads as an empty band.
		if ctx.Err() != nil && !s.app.JSON {
			s.say("stopped before the daemon could report what it found (%s says whether the scan is still running)\n",
				st.Cmd("ley state"))
			return nil, final, nil
		}
		return nil, final, err
	}
	return scan, final, nil
}

// followJob renders progress until the job leaves RUNNING, and returns its last state. Job state
// arrives on the event stream every client already drains -- there is no polling here.
func (s *session) followJob(ctx context.Context, job *leylinev1.Job, progress *scanProgress) (*leylinev1.Job, error) {
	last := job
	// A backstop, not the mechanism: job state arrives on the event stream. But a stream can end
	// cleanly (a daemon reload) or drop an event (the fan-out buffer is bounded and says so), and
	// without this the verb would either report a running sweep as finished or wait for ever.
	poll := time.NewTicker(2 * time.Second)
	defer poll.Stop()
	for {
		select {
		case <-ctx.Done():
			return last, nil
		case <-poll.C:
			j, err := s.client.Jobs.GetJob(ctx, &leylinev1.JobRef{JobId: job.JobId})
			if err != nil {
				if ctx.Err() != nil {
					return last, nil
				}
				return last, err
			}
			last = j
			if !s.app.JSON {
				progress.show(last.StatusDetail)
			}
			if last.State != leylinev1.JobState_RUNNING {
				return last, nil
			}
		case ev, ok := <-s.events:
			if !ok {
				// The stream ended. pump reports a clean EOF as a nil error, so nothing here can
				// distinguish "the daemon went away" from "the daemon finished with us" -- ask.
				if err := <-s.eventErrs; err != nil {
					return last, err
				}
				j, err := s.client.Jobs.GetJob(ctx, &leylinev1.JobRef{JobId: job.JobId})
				if err != nil {
					if ctx.Err() != nil {
						return last, nil
					}
					return last, err
				}
				if j.State == leylinev1.JobState_RUNNING {
					return j, fmt.Errorf("the daemon closed the event stream while the scan was still running; ley daemon status says whether it is still there")
				}
				return j, nil
			}
			b, isJob := ev.Body.(*leylinev1.Event_Job)
			if !isJob || b.Job.JobId != job.JobId {
				s.apply(ev)
				continue
			}
			last = b.Job
			if last.State != leylinev1.JobState_RUNNING {
				// The terminal detail is the summary, and the summary is printed properly
				// below; showing it here too would say the same thing twice.
				return last, nil
			}
			if !s.app.JSON {
				progress.show(last.StatusDetail)
			}
		}
	}
}

// scanGainElements is the gain elements of the radio a sweep ran on, for the summary's gain words.
// A Scan does not name its device, so this is the one asked for, else the only device whose
// elements are the stages the scan reports; nil when that is not one device, and the words then
// print a switch's level rather than on or off.
func scanGainElements(st *leylinev1.GetStateResponse, deviceID string, scan *leylinev1.Scan) []*leylinev1.GainElement {
	if deviceID != "" || scan.GetConfig().GetDeviceId() != "" {
		return deviceGainElements(st, cmp.Or(deviceID, scan.GetConfig().GetDeviceId()))
	}
	var found []*leylinev1.GainElement
	matches := 0
	for _, d := range st.GetDevices() {
		els := d.GetGainElements()
		if len(els) == 0 || len(els) != len(scan.GetGains()) {
			continue
		}
		same := true
		for _, g := range scan.GetGains() {
			same = same && gainElement(els, g.GetElement()) != nil
		}
		if same {
			found, matches = els, matches+1
		}
	}
	if matches != 1 {
		return nil
	}
	return found
}

// scanIDOf reads the scan's id out of the job's result URI. A job that named no
// ley://scans/ resource has nothing to fetch, and saying which URIs it did name
// is what tells a prefix slip apart from a sweep that produced no scan.
func scanIDOf(job *leylinev1.Job) (string, error) {
	for _, u := range job.ResultUris {
		if id, ok := strings.CutPrefix(u, "ley://scans/"); ok && id != "" {
			return id, nil
		}
	}
	if len(job.ResultUris) > 0 {
		return "", fmt.Errorf("the daemon named no scan, only %s", strings.Join(job.ResultUris, ", "))
	}
	return "", errors.New("the daemon named no scan")
}

// scanFailure turns a failed job into the error line the user reads. The daemon reports the
// cause in job.error: ley branches on the code, and status_detail is the human-readable reason.
func scanFailure(job *leylinev1.Job, st ui.Style) string {
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
		return detail + ". " + st.Cmd("ley scan --take-over") + " sweeps anyway, and hands the radio back afterwards"
	case leyline.CodeBlindSpot:
		return detail + ". " + st.Cmd("ley spectrum") + " draws that span instead, DC spike and all"
	case leyline.CodeNoDevice, leyline.CodeFreqOutOfRange:
		return detail + ". " + st.Cmd("ley devices") + " lists what is here and what it can tune"
	}
	// docs/reference/cli.md: an error line keeps the daemon's stable code unless ley has a plainer
	// sentence for it. The cases above are the plainer sentences; everything else keeps it.
	return detail + " [" + code + "]"
}

// scanProgress is the one line a sweep leaves on stderr while it runs, rewritten in place on a
// terminal and printed once per step when stderr is a pipe.
type scanProgress struct {
	app  *App
	last string
	tty  bool
	on   bool
}

func newScanProgress(app *App) *scanProgress {
	return &scanProgress{app: app, tty: app.IsErrTTY() && !app.JSON}
}

func (p *scanProgress) show(detail string) {
	// "starting" is the detail a job carries before it has done anything; it tells the reader
	// nothing they did not know from typing the command.
	if detail == "" || detail == "starting" || detail == p.last || p.app.JSON {
		return
	}
	p.last = detail
	if !p.tty {
		fmt.Fprintln(p.app.Stderr, detail)
		return
	}
	fmt.Fprintf(p.app.Stderr, "\r\033[K%s", p.app.ErrStyle.Muted(detail))
	p.on = true
}

func (p *scanProgress) clear() {
	if p.on {
		fmt.Fprint(p.app.Stderr, "\r\033[K")
		p.on = false
	}
}

// printScan renders the table and the summary. The table is stdout (it is the answer); the
// summary sentence and the next command are stderr.
func printScan(app *App, scan *leylinev1.Scan, o scanOptions, els []*leylinev1.GainElement) {
	rows := make([]*leylinev1.Detection, 0, len(scan.Detections))
	for _, d := range scan.Detections {
		if o.minSNR > 0 && d.SnrDb < o.minSNR {
			continue
		}
		rows = append(rows, d)
	}
	sort.SliceStable(rows, func(i, j int) bool {
		if o.sortBySNR {
			return rows[i].SnrDb > rows[j].SnrDb
		}
		return rows[i].CenterHz < rows[j].CenterHz
	})
	st := app.ErrStyle
	if len(rows) == 0 {
		// Rows hidden by --min-snr get a different message from an empty sweep, because the
		// remedy differs: a longer dwell will not bring back a row --min-snr filtered out.
		if hidden := len(scan.Detections); hidden > 0 {
			fmt.Fprintf(app.Stderr, "%s below %.0f dB, so nothing to show%s\n",
				plural(hidden, "signal"), o.minSNR, floorPhrase(scan))
			fmt.Fprintf(app.Stderr, "drop the filter to see them: %s\n", st.Cmd("ley scan "+scanArg(o)))
			return
		}
		fmt.Fprintf(app.Stderr, "nothing stood above the noise floor%s%s\n", floorPhrase(scan), gainPhrase(scan, els))
		fmt.Fprintf(app.Stderr, "a longer look finds weaker signals: %s\n", st.Cmd("ley scan "+scanArg(o)+" --dwell 1000"))
		coverageNote(app, scan, o)
		return
	}
	cols := []column{
		{head: "FREQUENCY", cells: mapDet(rows, func(d *leylinev1.Detection) string { return leyline.FormatFrequency(d.CenterHz) })},
		{head: "WIDTH", cells: mapDet(rows, func(d *leylinev1.Detection) string { return widthCell(d, scan) })},
		// The unit sits in the header (section 5) and the number takes the level ramp from
		// --min-snr upward, as the peak list under ley spectrum does, so chart and table agree.
		{head: "SNR (dB)", cells: mapDet(rows, func(d *leylinev1.Detection) string {
			return snrInk(tableStyle(app), o.minSNR, d.SnrDb, fmt.Sprintf("%.0f", d.SnrDb))
		}), right: true},
		{head: "SEEN", cells: mapDet(rows, seenCell), min: 4, right: true},
		{head: "BAND", cells: mapDet(rows, bandCell), min: 8, drop: 1, hideEmpty: true},
	}
	// tableStyle, not app.Style: off a terminal the width is unknown rather than 80, and fitting
	// to 80 would silently drop the BAND column out of a piped table.
	_, _ = printColumns(app.Stdout, tableStyle(app), cols, nil)
	fmt.Fprintf(app.Stderr, "%s%s%s\n", plural(len(rows), "signal"), floorPhrase(scan), gainPhrase(scan, els))
	unconfirmedNote(app, rows)
	coverageNote(app, scan, o)
	if best := strongest(rows); best != nil {
		fmt.Fprintf(app.Stderr, "  %s\n", st.Cmd("ley listen "+trimZeros(float64(best.CenterHz)/1e6)))
	}
}

// coverageNote prints the range the sweep actually covered when that differs from the request.
// Without it the table would imply coverage that was never measured. Causes: a radio that cannot
// reach the whole request, a request partly inside the tuner's blind spot, or a stopped sweep.
func coverageNote(app *App, scan *leylinev1.Scan, o scanOptions) {
	c := scan.GetCovered()
	if c == nil || c.MaxHz <= c.MinHz {
		return
	}
	const slack = 1000 // Hz; edge rounding within this is not reported as a gap
	if c.MinHz <= o.minHz+slack && c.MaxHz+slack >= o.maxHz {
		return
	}
	fmt.Fprintf(app.Stderr, "covered %s to %s of the %s to %s asked for\n",
		leyline.FormatFrequency(c.MinHz), leyline.FormatFrequency(c.MaxHz),
		leyline.FormatFrequency(o.minHz), leyline.FormatFrequency(o.maxHz))
}

func mapDet(rows []*leylinev1.Detection, f func(*leylinev1.Detection) string) []string {
	out := make([]string, len(rows))
	for i, d := range rows {
		out[i] = f(d)
	}
	return out
}

// widthCell prints the equivalent rectangular width, or notes the signal is narrower than the
// analysis can resolve rather than inventing a figure for it.
func widthCell(d *leylinev1.Detection, scan *leylinev1.Scan) string {
	res := binWidth(scan)
	if res > 0 && float64(d.BandwidthHz) < res {
		return "under " + leyline.FormatFrequency(uint64(math.Round(res)))
	}
	if d.BandwidthHz == 0 {
		return "-"
	}
	return leyline.FormatFrequency(uint64(d.BandwidthHz))
}

// binWidth is the analysis resolution: how finely the sweep looked, which is what every dB it
// reports is per. The daemon states it; deriving it from step_hz meant knowing the geometry
// constants and the bin count, and got it 25% wrong when either changed.
func binWidth(scan *leylinev1.Scan) float64 { return float64(scan.GetResolutionHz()) }

// unconfirmedNote lists the rows detected in fewer than half their looks: a burst, or a floor
// fluctuation that one look caught. The SEEN column shows it too, but a reader adding up a band
// needs the sentence, and an agent otherwise sweeps again to learn what the column meant.
func unconfirmedNote(app *App, rows []*leylinev1.Detection) {
	var weak []string
	for _, d := range rows {
		if d.LooksPossible > 1 && d.Looks*2 < d.LooksPossible {
			weak = append(weak, fmt.Sprintf("%s (%s)", leyline.FormatFrequency(d.CenterHz), seenCell(d)))
		}
	}
	if len(weak) == 0 {
		return
	}
	fmt.Fprintf(app.Stderr, "seen by fewer than half the looks, so a burst or the floor moving rather than a carrier that stayed: %s. A longer dwell settles it.\n",
		strings.Join(weak, ", "))
}

// seenCell is how many looks detected the row, out of how many looks were taken.
func seenCell(d *leylinev1.Detection) string {
	if d.LooksPossible == 0 {
		return "-"
	}
	return fmt.Sprintf("%d/%d", d.Looks, d.LooksPossible)
}

// bandCell names the band and, when one sits on the frequency, the preset. Client-local tables,
// the same ones `ley bands` and `ley presets` print: presentation over the daemon's measurement.
func bandCell(d *leylinev1.Detection) string {
	var parts []string
	if b := leyline.BandFor(d.CenterHz); b != nil {
		parts = append(parts, b.Name)
	}
	if p := presetAt(d.CenterHz); p != "" {
		parts = append(parts, "("+p+")")
	}
	if len(parts) == 0 {
		return "-"
	}
	return strings.Join(parts, " ")
}

// presetAt names the plan channel on a frequency, by the word every table prints (wx3, ch18,
// marine16): the nearest within 6 kHz, a tie to the earlier plan entry, which is ChannelAt's rule
// and the app's (the plan's KTD2). Empty when nothing sits there.
func presetAt(hz uint64) string {
	if _, c, ok := leyline.ChannelAt(hz); ok {
		return c.Aliases[0]
	}
	return ""
}

func strongest(rows []*leylinev1.Detection) *leylinev1.Detection {
	var best *leylinev1.Detection
	for _, d := range rows {
		if best == nil || d.SnrDb > best.SnrDb {
			best = d
		}
	}
	return best
}

// floorPhrase names the noise floor the SNRs were measured against, and the bin it is per --
// without the bin width the number means nothing, because a wider bin holds more noise.
func floorPhrase(scan *leylinev1.Scan) string {
	if len(scan.NoiseFloor) == 0 {
		return ""
	}
	vals := make([]float64, 0, len(scan.NoiseFloor))
	for _, s := range scan.NoiseFloor {
		if !math.IsNaN(s.FloorDbfs) && !math.IsInf(s.FloorDbfs, 0) {
			vals = append(vals, s.FloorDbfs)
		}
	}
	if len(vals) == 0 {
		return ""
	}
	sort.Float64s(vals)
	median := vals[len(vals)/2]
	if bw := binWidth(scan); bw > 0 {
		return fmt.Sprintf(", floor %.0f dBFS per %s bin", median, leyline.FormatFrequency(uint64(math.Round(bw))))
	}
	return fmt.Sprintf(", floor %.0f dBFS", median)
}

// gainPhrase names the gain the sweep ran at, in the words every screen uses (stageGainWords). A
// sweep pins the tuner for its duration, because SNR measured against a moving AGC is meaningless.
// Two scans of the same band are comparable only at the same gain, so the gain is printed beside
// the floor.
func gainPhrase(scan *leylinev1.Scan, els []*leylinev1.GainElement) string {
	var gains []*leylinev1.GainState
	for _, g := range scan.GetGains() {
		if math.IsNaN(g.GetDb()) || math.IsInf(g.GetDb(), 0) {
			continue
		}
		gains = append(gains, g)
	}
	if len(gains) == 0 {
		return ""
	}
	return ", " + stageGainWords(gains, els)
}

// scanArg re-spells what the user asked for, for a hint line.
func scanArg(o scanOptions) string {
	if o.bandName != "" {
		return "--band " + o.bandName
	}
	if o.rangeInput != "" {
		return o.rangeInput
	}
	return trimZeros(float64(o.minHz)/1e6) + ".." + trimZeros(float64(o.maxHz)/1e6)
}

func trimZeros(mhz float64) string {
	s := strings.TrimRight(strings.TrimRight(fmt.Sprintf("%.3f", mhz), "0"), ".")
	if s == "" {
		return "0"
	}
	return s
}
