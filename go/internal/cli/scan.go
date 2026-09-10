package cli

import (
	"context"
	"fmt"
	"math"
	"sort"
	"strings"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
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
  ley scan 144M..148M --json     # the Scan message, for tools`,
		GroupID: GroupLooking,
		Args:    cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			switch {
			case len(args) == 1 && o.bandName != "":
				return usageErrorf("give a range or --band, not both: a range and a band name say two different things about where to look")
			case len(args) == 1:
				var err error
				if o.minHz, o.maxHz, err = leyline.ParseUserRange(args[0]); err != nil {
					return usageErrorf("%v", err)
				}
				o.rangeInput = args[0]
			case o.bandName != "":
				b, err := leyline.ResolveBand(o.bandName)
				if err != nil {
					return usageErrorf("%v", err)
				}
				o.minHz, o.maxHz, o.rangeInput = b.MinHz, b.MaxHz, b.Name
			default:
				return usageErrorf("scan needs a range: ley scan 144M..148M, or ley scan --band 2m (ley bands lists them)")
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
			// Everything scan says is for a person; the table and the JSON are the machine's.
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
	return cmd
}

// runScan starts the sweep, follows it on the event stream, and prints what it found.
func runScan(ctx context.Context, s *session, o scanOptions) error {
	cfg := &leylinev1.ScanConfig{
		Range:    &leylinev1.FrequencyRange{MinHz: o.minHz, MaxHz: o.maxHz},
		DwellMs:  o.dwellMs,
		Schedule: &leylinev1.ScanConfig_Once{Once: true},
		TakeOver: o.takeOver,
	}
	job, err := s.client.Jobs.StartJob(ctx, &leylinev1.StartJobRequest{Config: &leylinev1.StartJobRequest_Scan{Scan: cfg}})
	if err != nil {
		return err
	}
	st := s.app.ErrStyle
	s.say("sweeping %s to %s\n", leyline.FormatFrequency(o.minHz), leyline.FormatFrequency(o.maxHz))

	// A scan is not persistent: it belongs to this connection and the daemon ends it when the
	// connection goes. Cancelling explicitly hands the radio back now rather than after the
	// presence grace, which matters when the next thing the user does is tune.
	defer func() {
		if ctx.Err() != nil {
			c, stop := context.WithTimeout(context.Background(), confirmTimeout)
			defer stop()
			_, _ = s.client.Jobs.CancelJob(c, &leylinev1.JobRef{JobId: job.JobId})
		}
	}()

	progress := newScanProgress(s.app)
	final, err := s.followJob(ctx, job, progress)
	progress.clear()
	if err != nil {
		return err
	}
	switch final.State {
	case leylinev1.JobState_FAILED:
		return &ExitError{Code: 1, Message: scanFailure(final, st)}
	case leylinev1.JobState_CANCELLED:
		return nil
	}
	scan, err := s.client.Jobs.GetScan(ctx, &leylinev1.ScanRef{ScanId: scanIDOf(final)})
	if err != nil {
		return err
	}
	if s.app.JSON {
		return s.app.printJSON(scan)
	}
	printScan(s.app, scan, o)
	return nil
}

// followJob renders progress until the job leaves RUNNING, and returns its last state. Job state
// arrives on the event stream every client already drains -- there is no polling here.
func (s *session) followJob(ctx context.Context, job *leylinev1.Job, progress *scanProgress) (*leylinev1.Job, error) {
	last := job
	for {
		select {
		case <-ctx.Done():
			return last, nil
		case ev, ok := <-s.events:
			if !ok {
				return last, <-s.eventErrs
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

// scanIDOf reads the scan's id out of the job's result URI.
func scanIDOf(job *leylinev1.Job) string {
	for _, u := range job.ResultUris {
		if id, ok := strings.CutPrefix(u, "ley://scans/"); ok {
			return id
		}
	}
	return ""
}

// scanFailure turns a failed job into the sentence the user reads. The daemon puts the stable
// code in front of its reason; the reason is the part a person needs.
func scanFailure(job *leylinev1.Job, st ui.Style) string {
	detail := job.StatusDetail
	if code, rest, ok := strings.Cut(detail, ": "); ok && code == strings.ToUpper(code) && code != "" {
		switch code {
		case "DEVICE_BUSY":
			return rest + ". " + st.Cmd("ley scan --take-over") + " sweeps anyway, and hands the radio back afterwards"
		case "BLIND_SPOT":
			return rest + ". " + st.Cmd("ley spectrum") + " draws that span instead, DC spike and all"
		case "NO_DEVICE", "FREQ_OUT_OF_RANGE":
			return rest + ". " + st.Cmd("ley devices") + " lists what is here and what it can tune"
		}
		return rest
	}
	return detail
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
func printScan(app *App, scan *leylinev1.Scan, o scanOptions) {
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
		fmt.Fprintf(app.Stderr, "nothing stood above the noise floor%s\n", floorPhrase(scan))
		fmt.Fprintf(app.Stderr, "a longer look finds weaker signals: %s\n", st.Cmd("ley scan "+scanArg(o)+" --dwell 1000"))
		return
	}
	cols := []column{
		{head: "FREQUENCY", cells: mapDet(rows, func(d *leylinev1.Detection) string { return leyline.FormatFrequency(d.CenterHz) })},
		{head: "WIDTH", cells: mapDet(rows, func(d *leylinev1.Detection) string { return widthCell(d, scan) })},
		{head: "SNR", cells: mapDet(rows, func(d *leylinev1.Detection) string { return fmt.Sprintf("%.0f dB", d.SnrDb) })},
		{head: "SEEN", cells: mapDet(rows, seenCell), min: 4},
		{head: "BAND", cells: mapDet(rows, bandCell), min: 8, drop: 1},
	}
	out, _ := printColumns(app.Stdout, app.Style, cols, nil)
	_ = out
	fmt.Fprintf(app.Stderr, "%s%s\n", plural(len(rows), "signal"), floorPhrase(scan))
	if best := strongest(rows); best != nil {
		fmt.Fprintf(app.Stderr, "  %s\n", st.Cmd("ley listen "+trimZeros(float64(best.CenterHz)/1e6)))
	}
}

func mapDet(rows []*leylinev1.Detection, f func(*leylinev1.Detection) string) []string {
	out := make([]string, len(rows))
	for i, d := range rows {
		out[i] = f(d)
	}
	return out
}

// widthCell prints the equivalent rectangular width, or says the signal is narrower than the
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

// binWidth is the analysis resolution: the span of one step divided by the bins in a row. The
// daemon reports the step it used, and a row is 1024 bins.
func binWidth(scan *leylinev1.Scan) float64 {
	step := float64(scan.GetConfig().GetStepHz())
	if step <= 0 {
		return 0
	}
	// A step advances 0.4 of a span, so the span is the step over 0.4.
	return step / 0.4 / 1024
}

// seenCell is the evidence: how many looks found it, out of how many looked.
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

// presetAt names a preset within half a channel of the frequency.
func presetAt(hz uint64) string {
	for _, p := range leyline.Presets() {
		diff := int64(p.Hz) - int64(hz)
		if diff < 0 {
			diff = -diff
		}
		if diff <= 6_000 {
			return p.Name
		}
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
