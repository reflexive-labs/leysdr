// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bufio"
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
	"github.com/dpup/leysdr/go/pkg/records"
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

The fold is ley's own, over the records the daemon streams -- no decoding
moves client-side. A station silent for longer than the decoder's own
timeout ('entity_silence_s' in 'ley decoders --json') drops off the table,
because a row that never ages says a transmitter is still there when it left
hours ago.

track shows what is being decoded now: it needs a decode job running, which
'ley decode <protocol>' or 'ley decode <protocol> --job' starts. --since
seeds the table from the records kept jobs have already written.

On a terminal the table is redrawn in place; piped, one table is printed per
tick. --json prints one {"entities": [...]} object per tick as NDJSON -- a
client-side shape with no proto message, documented in docs/reference/cli.md.`,
		Example: `  ley decode aprs --job        # in one terminal: keep decoding
  ley track aprs               # in another: who is out there?
  ley track aprs --since 1h    # seed from what was kept, then follow
  ley track aprs --json --count 1 | jq '.entities | length'`,
		GroupID: GroupLooking,
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			o.protocol = args[0]
			if since != "" {
				var err error
				if o.since, err = parseAge(since); err != nil {
					return usageErrorf("--since: %v", err)
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
	return cmd
}

func runTrack(ctx context.Context, app *App, o trackOptions) error {
	c, err := app.dial(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	silence := trackSilence(ctx, c, o.protocol)
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
	fmt.Fprintf(app.Stderr, "tracking %s. %s\n", o.protocol,
		app.ErrStyle.Muted("a row drops off after "+ageWord(silence)+" of silence"))

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
				if err := printEntitySnapshot(app, table); err != nil {
					return err
				}
				w.row()
			} else {
				w.frame(renderTrack(app, table), "")
			}
			out.Flush()
			draws++
			if o.count > 0 && draws >= o.count {
				return nil
			}
		}
	}
}

// trackSilence is the decoder's own entity timeout, which is the only honest answer to "when
// should a row go". A protocol the daemon has no manifest for keeps the design doc's default.
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

// renderTrack draws the entity table: who, how long ago, how often, where, and what they said.
func renderTrack(app *App, table *records.Table) string {
	s := tableStyle(app)
	cols := []column{
		{head: "DEVICE", min: 8},
		{head: "LAST HEARD"},
		{head: "SEEN"},
		{head: "POSITION", min: 10, drop: 2},
		{head: "LAST", min: 16, drop: 1},
	}
	now := time.Now()
	rows := table.Rows()
	for _, e := range rows {
		add(cols, e.DeviceID, ageWord(now.Sub(e.LastHeard)), fmt.Sprint(e.Count),
			absentIfEmpty(s, records.FormatPosition(e.Position)), absentIfEmpty(s, e.Summary))
	}
	var b strings.Builder
	_, _ = printColumns(&b, s, cols, nil)
	if len(rows) == 0 {
		b.WriteString(s.Muted("(nothing heard yet; ley decode " + firstProtocol(table) + " must be running)\n"))
	}
	return b.String()
}

// firstProtocol names the protocol for the empty table's hint, from whatever the fold has seen.
func firstProtocol(table *records.Table) string {
	for _, e := range table.Rows() {
		if e.Protocol != "" {
			return e.Protocol
		}
	}
	return "<protocol>"
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
func printEntitySnapshot(app *App, table *records.Table) error {
	now := time.Now()
	snap := EntitySnapshot{Entities: []EntityRow{}}
	for _, e := range table.Rows() {
		row := EntityRow{
			DeviceID: e.DeviceID, Protocol: e.Protocol, Kind: e.Kind, Summary: e.Summary,
			Seen: e.Count, AgeS: now.Sub(e.LastHeard).Seconds(),
			LastSampleIndex: e.LastSeen.GetSampleIndex(),
		}
		if e.Position != nil {
			row.Position = &EntityPoint{Latitude: e.Position.GetLatitude(), Longitude: e.Position.GetLongitude()}
		}
		snap.Entities = append(snap.Entities, row)
	}
	return app.printArray(snap)
}
