// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bufio"
	"context"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/session"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/records"
)

// EntityRow is one row of `ley track --json`, and EntitySnapshot the object printed per redraw.
// The entity table is a client-side fold with no proto message of its own -- the daemon serves
// records, not entities -- so this shape (snake_case) is part of the documented exception to the
// proto3 rule; see docs/reference/cli.md.
type EntitySnapshot struct {
	Entities []EntityRow `json:"entities"`
}

// EntityRow carries what the table shows plus the timebase behind it: age_s is how long since
// the row was last heard, and last_sample_index where on the capture's timeline that was.
type EntityRow struct {
	DeviceID        string       `json:"device_id"`
	Protocol        string       `json:"protocol"`
	Kind            string       `json:"kind"`
	Summary         string       `json:"summary"`
	Seen            int          `json:"seen"`
	AgeS            float64      `json:"age_s"`
	LastSampleIndex uint64       `json:"last_sample_index"`
	Position        *EntityPoint `json:"position"`
	// HeardSlices is the HEARD column's series: records from this station in each of eight
	// equal slices of the table's window (the decoder's silence timeout), oldest first.
	HeardSlices []int `json:"heard_slices"`
}

// EntityPoint is a row's last known position, null when the protocol never carried one.
type EntityPoint struct {
	Latitude  float64 `json:"latitude"`
	Longitude float64 `json:"longitude"`
}

type trackOptions struct {
	protocol string
	since    time.Duration
	rate     float64
	count    int
	// attach subscribes to an existing decoder's records without starting one, for the case
	// where a decode job is already running and track should only render it.
	attach   bool
	device   string
	deviceID string
	takeOver bool
}

func newTrackCommand(app *App) *cobra.Command {
	var (
		o     trackOptions
		since string
	)
	cmd := &cobra.Command{
		Use:   "track <protocol>",
		Short: "A live table of the transmitters a protocol is hearing",
		Long: `track folds a protocol's records into one row per transmitter and redraws
the table as packets arrive: who is out there, how long ago each one was
heard, how many times, where it said it was, and what it last said.

track runs the decoder itself: it starts one for the protocol (the same job
'ley decode' would, ended when track exits) unless one is already running for
it, in which case it renders that one rather than starting a second on the
radio. --attach never starts a decoder; it only folds what is already being
decoded, and shows an empty table until something is.

The fold is ley's own, over the records the daemon streams -- the entity table
is never daemon state, so a second 'ley track' sees the same picture from the
same records. A station silent for longer than the decoder's own timeout
('entity_silence_s' in 'ley decoders --json') drops off the table, because a
row that never ages says a transmitter is still there when it left hours ago.
--since seeds the table from the records kept jobs have already written.

On a terminal the table is redrawn in place; piped, one table is printed per
tick. --json prints one {"entities": [...]} object per tick as NDJSON -- a
client-side shape with no proto message, documented in docs/reference/cli.md.`,
		Example: `  ley track aprs               # start decoding and show who is out there
  ley track aircraft           # (once an ADS-B decoder is installed)
  ley track aprs --since 1h    # seed from what was kept, then follow
  ley track aprs --attach      # only fold a decoder someone already started
  ley track aprs --json --count 1 | jq '.entities | length'`,
		GroupID: GroupLooking,
		Args:    cobra.ExactArgs(1),
		ValidArgsFunction: func(_ *cobra.Command, args []string, toComplete string) ([]cobra.Completion, cobra.ShellCompDirective) {
			if len(args) != 0 {
				return nil, cobra.ShellCompDirectiveNoFileComp
			}
			return completeDecoders(app, toComplete)
		},
		RunE: func(cmd *cobra.Command, args []string) error {
			o.protocol = args[0]
			if since != "" {
				var err error
				if o.since, err = parseAge(since); err != nil {
					return usageErrorf("--since %v", err)
				}
			}
			if o.rate <= 0 || o.rate > 20 {
				return usageErrorf("--rate must be above 0 and at most 20 redraws a second")
			}
			return runTrack(cmd.Context(), app, o)
		},
	}
	cmd.Flags().StringVar(&since, "since", "", "seed the table from kept records this recent, e.g. 1h, 2d")
	cmd.Flags().Float64Var(&o.rate, "rate", 2, "redraws a second, e.g. 4 (at most 20)")
	cmd.Flags().IntVar(&o.count, "count", 0, "stop after this many redraws, e.g. 1 (default: until Ctrl-C)")
	cmd.Flags().BoolVar(&o.attach, "attach", false, "do not start a decoder; only fold one that is already running")
	cmd.Flags().StringVar(&o.device, "device", "", "which radio: an id (dev_...), id prefix or row number from 'ley devices' (default: the first real radio)")
	cmd.Flags().BoolVar(&o.takeOver, "take-over", false, "start the decoder even when somebody is using the radio; it is theirs again afterwards")
	return cmd
}

func runTrack(ctx context.Context, app *App, o trackOptions) error {
	c, err := app.dial(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	// A friendly name (vessels -> ais) becomes the canonical protocol before track starts or
	// subscribes: records carry the canonical name, so a subscription on the alias would see none.
	if name, _, rerr := c.ResolveDecoder(ctx, o.protocol); rerr == nil {
		o.protocol = name
	}
	if o.device != "" {
		st, serr := c.State(ctx)
		if serr != nil {
			return app.notRunning(serr)
		}
		d, derr := pickDevice(st, o.device)
		if derr != nil {
			return derr
		}
		o.deviceID = d.GetDeviceId()
	}
	silence := trackSilence(ctx, c, o.protocol)
	window := trackWindow(silence)
	// Unless --attach, track runs the decoder itself, so `ley track aprs` is one command. A decoder
	// already running for the protocol is rendered rather than duplicated: two viewers do not mean
	// two demods on the radio (docs/design/decoders.md, the state boundary -- the fold is still
	// ours; only the decode job is shared).
	if !o.attach {
		id, serr := ensureDecoder(ctx, app, c, o)
		if serr != nil {
			return serr
		}
		if id != "" {
			// Free the radio as soon as track exits rather than waiting out the presence grace.
			defer func() {
				cctx, ccl := session.CleanupContext(ctx, 2*time.Second)
				defer ccl()
				_, _ = c.Jobs.CancelJob(cctx, &leylinev1.JobRef{JobId: id})
			}()
		}
	}
	table := records.NewTable()
	if err := seedTrack(ctx, c, table, o); err != nil {
		return err
	}
	sctx, stop := context.WithCancel(ctx)
	defer stop()
	recs, errs, err := c.SubscribeRecords(sctx, leyline.RecordScopeProtocol(o.protocol))
	if err != nil {
		return app.notRunning(err)
	}
	how := "a row drops off after " + ageWord(silence) + " of silence"
	if silence <= 0 {
		how = "rows never drop off; HEARD covers the last " + ageWord(window)
	}
	if o.attach {
		how = "folding what is already being decoded; " + how
	}
	fmt.Fprintf(app.Stderr, "tracking %s. %s\n", o.protocol, app.ErrStyle.Muted(how))

	out := bufio.NewWriter(app.Stdout)
	defer out.Flush()
	w := newChartWriter(app, out, true, o.rate)
	defer w.finish()
	tick := time.NewTicker(time.Duration(float64(time.Second) / o.rate))
	defer tick.Stop()
	draws := 0
	for {
		select {
		case <-ctx.Done():
			return nil
		case err := <-errs:
			if err != nil && ctx.Err() == nil {
				return err
			}
			return nil
		case rec, ok := <-recs:
			if !ok {
				return nil
			}
			table.Apply(rec)
		case <-tick.C:
			table.Expire(time.Now(), silence)
			if app.JSON {
				if err := printEntitySnapshot(app, table, window); err != nil {
					return err
				}
				w.row()
			} else {
				w.frame(renderTrack(app, table, window), "")
			}
			out.Flush()
			draws++
			if o.count > 0 && draws >= o.count {
				return nil
			}
		}
	}
}

// ensureDecoder makes sure a decoder is producing the protocol's records, and returns the id of a
// job track started (empty when it attached to one already running, which is not track's to stop).
func ensureDecoder(ctx context.Context, app *App, c *leyline.Client, o trackOptions) (string, error) {
	if runningDecodeJob(ctx, c, o.protocol) != nil {
		return "", nil
	}
	job, err := c.StartDecode(ctx, &leylinev1.DecodeConfig{
		Decoder:  o.protocol,
		DeviceId: o.deviceID,
		TakeOver: o.takeOver,
	})
	if err != nil {
		return "", trackDecodeFailure(app, o, err)
	}
	return job.GetJobId(), nil
}

// runningDecodeJob is a decode job already producing this protocol, so track renders it rather
// than starting a second demod on the radio. A best-effort read: on any error track starts its own.
func runningDecodeJob(ctx context.Context, c *leyline.Client, protocol string) *leylinev1.Job {
	jobs, err := c.ListJobs(ctx)
	if err != nil {
		return nil
	}
	for _, j := range jobs {
		d, ok := j.GetConfig().(*leylinev1.Job_Decode)
		if !ok || d.Decode.GetDecoder() != protocol {
			continue
		}
		if s := j.GetState(); s == leylinev1.JobState_RUNNING || s == leylinev1.JobState_DEGRADED {
			return j
		}
	}
	return nil
}

// trackDecodeFailure turns the daemon's refusal to start a decoder into the sentence to act on,
// the way decode does, but pointing back at track.
func trackDecodeFailure(app *App, o trackOptions, err error) error {
	st := app.ErrStyle
	switch leyline.Code(err) {
	case leyline.CodeDecoderNotFound:
		return &friendlyError{msg: fmt.Sprintf("there is no decoder called %q. %s lists the ones installed", o.protocol, st.Cmd("ley decoders")), cause: err}
	case leyline.CodeDeviceBusy:
		msg := leylineMessage(err, "the radio is busy")
		return &friendlyError{msg: msg + ". " + st.Cmd("ley track "+o.protocol+" --take-over") + " starts anyway, or " + st.Cmd("ley track "+o.protocol+" --attach") + " folds a decoder already running", cause: err}
	case leyline.CodeDecoderFailed:
		msg := leylineMessage(err, "the decoder would not start")
		return &friendlyError{msg: msg + ". " + st.Cmd("ley daemon logs") + " carries what the plugin wrote", cause: err}
	}
	return err
}

// trackSilence is the decoder's own entity timeout, which decides when a row expires. A protocol
// the daemon has no manifest for keeps the design doc's default.
func trackSilence(ctx context.Context, c *leyline.Client, protocol string) time.Duration {
	const fallback = 30 * time.Minute
	resp, err := c.ListDecoders(ctx)
	if err != nil {
		return fallback
	}
	for _, m := range resp.GetDecoders() {
		if m.GetName() == protocol && m.GetEntitySilenceS() > 0 {
			return time.Duration(m.GetEntitySilenceS()) * time.Second
		}
	}
	return fallback
}

// seedTrack fills the table from the store before the live stream starts, so a track run against
// a protocol that has been decoded before does not open on an empty screen.
func seedTrack(ctx context.Context, c *leyline.Client, table *records.Table, o trackOptions) error {
	if o.since <= 0 {
		return nil
	}
	page, err := c.QueryRecords(ctx, &leylinev1.RecordQuery{
		Protocol: o.protocol, SinceNs: time.Now().Add(-o.since).UnixNano(),
	})
	if err != nil {
		return err
	}
	for _, a := range page.GetAnchors() {
		table.Anchor(a.GetAnchor())
	}
	// The page is newest first and the fold's "last heard" is the order records arrive in, so
	// they are applied oldest first.
	recs := page.GetRecords()
	for i := len(recs) - 1; i >= 0; i-- {
		table.Apply(recs[i])
	}
	return nil
}

// tableNow is the clock the table's ages and HEARD cells are measured on: the table's own when a
// test holds it still, the wall clock otherwise, so a row's age and its sparkline agree.
func tableNow(table *records.Table) time.Time {
	if table.Now != nil {
		return table.Now()
	}
	return time.Now()
}

// trackDefaultWindow is the span the HEARD column covers when the decoder's manifest declares
// no silence timeout, so rows never expire and there is no window to inherit. Ten minutes: a
// beaconing APRS station lands in it a few times and a one-off packet is still one cell.
const trackDefaultWindow = 10 * time.Minute

// trackWindow is the span the HEARD sparkline covers: the decoder's silence timeout, which is
// exactly the memory the table keeps, or the default when it keeps everything.
func trackWindow(silence time.Duration) time.Duration {
	if silence > 0 {
		return silence
	}
	return trackDefaultWindow
}

// heardSlices counts a station's records in each of sparkCells equal slices of the window
// ending now, oldest first: the HEARD column's series, and the JSON's heard_slices.
func heardSlices(e *records.Entity, now time.Time, window time.Duration) []int {
	times := make([]float64, 0, len(e.Heard))
	for _, t := range e.HeardSince(now.Add(-window)) {
		times = append(times, (window - now.Sub(t)).Seconds())
	}
	return sliceCounts(times, window.Seconds(), sparkCells)
}

// heardCell draws heardSlices: one ramp step per record, full at sparkCells, so the scale is
// held and one packet reads the same on every row and every redraw.
func heardCell(st ui.Style, counts []int) string {
	fracs := make([]float64, len(counts))
	for i, n := range counts {
		fracs[i] = math.Min(1, float64(n)/sparkCells)
	}
	return sparkline(st, fracs)
}

// renderTrack draws the entity table: who, how long ago, how often, when across the window,
// where, and what they said.
func renderTrack(app *App, table *records.Table, window time.Duration) string {
	s := tableStyle(app)
	cols := []column{
		{head: "DEVICE", min: 8},
		{head: "LAST HEARD"},
		{head: "SEEN", right: true},
		// HEARD is SEEN spread across the window, an eighth per cell, so a station that
		// beacons every minute and one that spoke once read differently at a glance. The
		// header carries the window so a piped table still says what a cell covers.
		{head: "HEARD (" + ageWord(window) + ")", drop: 3},
		{head: "POSITION", min: 10, drop: 2, hideEmpty: true},
		{head: "LAST", min: 16, drop: 1},
	}
	now := tableNow(table)
	rows := table.Rows()
	for _, e := range rows {
		add(cols, e.DeviceID, ageWord(now.Sub(e.LastHeard)), fmt.Sprint(e.Count),
			heardCell(s, heardSlices(e, now, window)),
			absentIfEmpty(s, records.FormatPosition(e.Position)), absentIfEmpty(s, e.Summary))
	}
	var b strings.Builder
	_, _ = printColumns(&b, s, cols, nil)
	if len(rows) == 0 {
		b.WriteString(s.Muted("(nothing heard yet)\n"))
	}
	return b.String()
}

// ageWord is how long ago, coarsened the way a person says it.
func ageWord(d time.Duration) string {
	switch {
	case d < time.Second:
		return "now"
	case d < time.Minute:
		return fmt.Sprintf("%d s", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%d m", int(d.Minutes()))
	default:
		return fmt.Sprintf("%d h", int(d.Hours()))
	}
}

// printEntitySnapshot writes one NDJSON line per redraw: the table as it stands.
func printEntitySnapshot(app *App, table *records.Table, window time.Duration) error {
	return app.printArray(entitySnapshot(table, window))
}

// entitySnapshot is the table as the `ley track --json` object: one row per
// entity, ages and HEARD slices measured on the table's clock.
func entitySnapshot(table *records.Table, window time.Duration) EntitySnapshot {
	now := tableNow(table)
	snap := EntitySnapshot{Entities: []EntityRow{}}
	for _, e := range table.Rows() {
		row := EntityRow{
			DeviceID: e.DeviceID, Protocol: e.Protocol, Kind: e.Kind, Summary: e.Summary,
			Seen: e.Count, AgeS: now.Sub(e.LastHeard).Seconds(),
			LastSampleIndex: e.LastSeen.GetSampleIndex(),
			HeardSlices:     heardSlices(e, now, window),
		}
		if e.Position != nil {
			row.Position = &EntityPoint{Latitude: e.Position.GetLatitude(), Longitude: e.Position.GetLongitude()}
		}
		snap.Entities = append(snap.Entities, row)
	}
	return snap
}
