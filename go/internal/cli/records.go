// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
	"github.com/dpup/leysdr/go/pkg/records"
)

type recordsOptions struct {
	protocol string
	jobID    string
	deviceID string
	kind     string
	since    time.Duration
	near     *leylinev1.Position
	radiusM  float64
	inEffect bool
	limit    uint32
}

func newRecordsCommand(app *App) *cobra.Command {
	var (
		o      recordsOptions
		since  string
		near   string
		radius string
	)
	cmd := &cobra.Command{
		Use:   "records",
		Short: "Search the records kept decode jobs have written",
		Long: `records reads the daemon's store: what the decoders heard while a kept job
was running ('ley decode <name> --job' starts one). A job without --job keeps
nothing, so an empty table usually means no kept job has run.

Rows are newest first. TIME is wall clock derived from the capture's anchor,
the way every time in ley is; a record whose capture the daemon no longer has
an anchor for shows no time rather than a guessed one.

--since takes a duration: 90s, 30m, 1h, 2d. --near takes a latitude and a
longitude ('37.76,-122.42') and --radius a distance with its unit (10km, 500m,
5nm, 3mi); together they ask for records from a place.

--json prints a RecordPage: the records and the anchors that date them.`,
		Example: `  ley records                              # everything kept, newest first
  ley records --protocol aprs --since 1h   # the last hour of APRS
  ley records --device-id LEYTST-1         # one transmitter
  ley records --near 37.76,-122.42 --radius 10km
  ley records --json | jq -r '.records[].deviceId'`,
		GroupID: GroupLooking,
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			var err error
			if since != "" {
				if o.since, err = parseAge(since); err != nil {
					return usageErrorf("--since %v", err)
				}
			}
			if near != "" {
				if o.near, err = parseLatLon(near); err != nil {
					return usageErrorf("--near %v", err)
				}
			}
			if radius != "" {
				if o.radiusM, err = parseDistance(radius); err != nil {
					return usageErrorf("--radius %v", err)
				}
			}
			switch {
			case o.near != nil && o.radiusM == 0:
				return usageErrorf("--near needs --radius: a point without a distance says nothing about which records to keep (try --radius 10km)")
			case o.near == nil && o.radiusM > 0:
				return usageErrorf("--radius needs --near: a distance without a point has nothing to measure from (try --near 37.76,-122.42)")
			}
			return runRecords(cmd.Context(), app, o)
		},
	}
	cmd.Flags().StringVar(&o.protocol, "protocol", "", "only this protocol, e.g. aprs ('ley decoders' lists them)")
	cmd.Flags().StringVar(&o.jobID, "job-id", "", "only this job's records: a job id from 'ley jobs --wide'")
	cmd.Flags().StringVar(&o.deviceID, "device-id", "", "only this transmitter, e.g. LEYTST-1 (the id the protocol gives it, not a radio)")
	cmd.Flags().StringVar(&o.kind, "kind", "", "only this kind of record, e.g. position, weather, status")
	cmd.Flags().StringVar(&since, "since", "", "only records newer than this, e.g. 1h, 30m, 2d")
	cmd.Flags().StringVar(&near, "near", "", "only records from around here: LAT,LON, e.g. 37.76,-122.42 (needs --radius)")
	cmd.Flags().StringVar(&radius, "radius", "", "how far around --near to look: 10km, 500m, 5nm, 3mi")
	cmd.Flags().BoolVar(&o.inEffect, "in-effect", false, "only records whose validity window covers now (alerts, warnings)")
	cmd.Flags().Uint32Var(&o.limit, "limit", 0, "at most this many rows, e.g. 50 (default: the daemon's 1000)")
	return cmd
}

func runRecords(ctx context.Context, app *App, o recordsOptions) error {
	c, err := app.dial(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	q := &leylinev1.RecordQuery{
		Protocol: o.protocol, JobId: o.jobID, DeviceId: o.deviceID, Kind: o.kind,
		Near: o.near, RadiusM: o.radiusM, InEffect: o.inEffect, Limit: o.limit,
	}
	if o.since > 0 {
		q.SinceNs = time.Now().Add(-o.since).UnixNano()
	}
	page, err := c.QueryRecords(ctx, q)
	if err != nil {
		return app.notRunning(err)
	}
	if app.JSON {
		return app.printJSON(page)
	}
	printRecordTable(app, page)
	return nil
}

// printRecordTable renders `ley records`: newest first, with what was said last on the right.
func printRecordTable(app *App, page *leylinev1.RecordPage) {
	s := tableStyle(app)
	cols := []column{
		{head: "TIME"},
		{head: "PROTOCOL", drop: 2},
		{head: "DEVICE", min: 8},
		{head: "KIND", drop: 1},
		{head: "SUMMARY", min: 16},
	}
	for _, rec := range page.GetRecords() {
		add(cols, recordTime(rec, page.GetAnchors()), absentIfEmpty(s, rec.GetProtocol()),
			absentIfEmpty(s, rec.GetDeviceId()), absentIfEmpty(s, rec.GetKind()),
			absentIfEmpty(s, records.Summary(rec)))
	}
	_, _ = printColumns(app.Stdout, s, cols, nil)
	if len(page.GetRecords()) == 0 {
		fmt.Fprintln(app.Stdout, s.Muted("(no records; ley decode <name> --job keeps what it hears)"))
		return
	}
	if page.GetTruncated() {
		fmt.Fprintf(app.Stderr, "%s\n", app.ErrStyle.Muted("more records matched than were returned; --limit asks for more"))
	}
}

// recordTime is the record's wall clock through the page's anchors. A record no anchor covers
// shows the absent glyph: a time nobody anchored would be a clock ley invented.
func recordTime(rec *leylinev1.DecodeRecord, anchors []*leylinev1.RecordAnchor) string {
	at, ok := leyline.RecordWallTime(rec, anchors)
	if !ok {
		return "-"
	}
	if time.Since(at) > 20*time.Hour {
		return at.Format("Jan 02 15:04")
	}
	return at.Format("15:04:05")
}

// parseAge reads a duration the way a person writes one: 90s, 30m, 1h, 2d. Go's own parser has
// no day, and a day is the unit somebody asking "what did I hear yesterday" reaches for.
func parseAge(s string) (time.Duration, error) {
	if days, ok := strings.CutSuffix(strings.TrimSpace(s), "d"); ok {
		n, err := strconv.ParseFloat(days, 64)
		if err != nil || n < 0 {
			return 0, fmt.Errorf("%q is not a duration; try 1h, 30m or 2d", s)
		}
		return time.Duration(n * 24 * float64(time.Hour)), nil
	}
	d, err := time.ParseDuration(strings.TrimSpace(s))
	if err != nil || d < 0 {
		return 0, fmt.Errorf("%q is not a duration; try 1h, 30m or 2d", s)
	}
	return d, nil
}

// parseLatLon reads "37.76,-122.42": degrees, north and east positive, as Position carries them.
func parseLatLon(s string) (*leylinev1.Position, error) {
	lat, lon, ok := strings.Cut(strings.TrimSpace(s), ",")
	if !ok {
		return nil, fmt.Errorf("%q is not a latitude and longitude; try 37.76,-122.42", s)
	}
	la, err1 := strconv.ParseFloat(strings.TrimSpace(lat), 64)
	lo, err2 := strconv.ParseFloat(strings.TrimSpace(lon), 64)
	if err1 != nil || err2 != nil {
		return nil, fmt.Errorf("%q is not a latitude and longitude; try 37.76,-122.42", s)
	}
	if la < -90 || la > 90 || lo < -180 || lo > 180 {
		return nil, fmt.Errorf("%q is off the globe: latitude is -90 to 90 and longitude -180 to 180", s)
	}
	return &leylinev1.Position{Latitude: la, Longitude: lo}, nil
}

// distanceUnits are what --radius accepts, longest suffix first so "nm" is not read as "m".
var distanceUnits = []struct {
	suffix string
	metres float64
}{
	{"km", 1000},
	{"nm", 1852},
	{"mi", 1609.344},
	{"m", 1},
}

// parseDistance reads a radius with its unit. A bare number is refused rather than assumed:
// 10 could be ten metres or ten kilometres, and guessing either silently is a wrong answer.
func parseDistance(s string) (float64, error) {
	t := strings.TrimSpace(strings.ToLower(s))
	for _, u := range distanceUnits {
		num, ok := strings.CutSuffix(t, u.suffix)
		if !ok {
			continue
		}
		n, err := strconv.ParseFloat(strings.TrimSpace(num), 64)
		if err != nil || n <= 0 {
			return 0, fmt.Errorf("%q is not a distance; try 10km, 500m, 5nm or 3mi", s)
		}
		return n * u.metres, nil
	}
	return 0, fmt.Errorf("%q has no unit; a distance needs one: 10km, 500m, 5nm or 3mi", s)
}
