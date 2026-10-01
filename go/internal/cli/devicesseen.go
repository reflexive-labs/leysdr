// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"fmt"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/labels"
	"github.com/reflexive-labs/leysdr/go/pkg/records"
)

// DevicesSnapshot is `ley devices-seen --json`. The device registry is a client-side fold over
// the record log with no proto message of its own -- the daemon serves records, not a device
// table -- so this shape (snake_case) is a documented exception to the proto3 rule; see
// docs/reference/cli.md and docs/design/decoders.md, section 5 ("Registry devices").
type DevicesSnapshot struct {
	Devices []DeviceRow `json:"devices"`
}

// DeviceRow is one discovered transmitter. first_ns and last_ns are wall clock in nanoseconds
// (0 when no anchor dates the record), quiet_s the seconds since it was last heard, and label the
// user-given name joined in from the labels store ("" when unnamed).
type DeviceRow struct {
	DeviceID string  `json:"device_id"`
	Label    string  `json:"label"`
	Protocol string  `json:"protocol"`
	Kind     string  `json:"kind"`
	Seen     int     `json:"seen"`
	FirstNs  int64   `json:"first_ns"`
	LastNs   int64   `json:"last_ns"`
	QuietS   float64 `json:"quiet_s"`
	Summary  string  `json:"summary"`
}

type devicesSeenOptions struct {
	protocol   string
	since      time.Duration
	quietSince time.Duration
}

func newDevicesSeenCommand(app *App) *cobra.Command {
	var (
		o          devicesSeenOptions
		since      string
		quietSince string
	)
	cmd := &cobra.Command{
		Use:   "devices-seen",
		Short: "The transmitters the kept records have heard",
		Long: `devices-seen is the registry: one row per transmitter the kept records
have ever heard, with the name you gave it, how many times it was heard, and
when it was first and last on the air. It is a fold over what 'ley decode
<name> --job' stored, joined with your labels, computed in ley -- the daemon
keeps no device table (docs/design/decoders.md, "The state boundary").

Rows are newest first. FIRST and LAST are ages derived from the capture's
anchors, the way every time in ley is. By default every kept record is
scanned, so absence reaches as far back as the store goes; --since bounds the
scan to a window.

--quiet-since D is the absence question -- which sensors went quiet -- and
shows only transmitters not heard within the last D. --json prints a
{"devices": [...]} object, a client-side shape with no proto message
(docs/reference/cli.md).`,
		Example: `  ley devices-seen                     # everyone heard, newest first
  ley devices-seen --protocol aprs     # one protocol
  ley devices-seen --quiet-since 48h   # which ones went quiet
  ley devices-seen --json | jq -r '.devices[].device_id'`,
		GroupID: GroupLooking,
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			var err error
			if since != "" {
				if o.since, err = parseAge(since); err != nil {
					return usageErrorf("--since %v", err)
				}
			}
			if quietSince != "" {
				if o.quietSince, err = parseAge(quietSince); err != nil {
					return usageErrorf("--quiet-since %v", err)
				}
			}
			return runDevicesSeen(cmd.Context(), app, o)
		},
	}
	cmd.Flags().StringVar(&o.protocol, "protocol", "", "only this protocol, e.g. aprs ('ley decoders' lists them)")
	cmd.Flags().StringVar(&since, "since", "", "only scan records newer than this, e.g. 24h, 2d (default: all kept)")
	cmd.Flags().StringVar(&quietSince, "quiet-since", "", "only transmitters not heard within this, e.g. 48h (absence)")
	_ = cmd.RegisterFlagCompletionFunc("protocol", func(_ *cobra.Command, _ []string, toComplete string) ([]cobra.Completion, cobra.ShellCompDirective) {
		return completeDecoders(app, toComplete)
	})
	return cmd
}

func runDevicesSeen(ctx context.Context, app *App, o devicesSeenOptions) error {
	c, err := app.dial(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	q := &leylinev1.RecordQuery{Protocol: o.protocol}
	if o.since > 0 {
		q.SinceNs = time.Now().Add(-o.since).UnixNano()
	}
	page, err := c.QueryRecords(ctx, q)
	if err != nil {
		return app.notRunning(err)
	}
	reg := records.NewRegistry()
	for _, a := range page.GetAnchors() {
		reg.Anchor(a)
	}
	// Records arrive newest first; the fold decides first and last by wall time, so the order they
	// are applied in does not matter.
	for _, rec := range page.GetRecords() {
		reg.Apply(rec)
	}
	store, err := labels.Open(labels.ResolvePath(app.LookupEnv))
	if err != nil {
		return fmt.Errorf("cannot read the labels file: %w", err)
	}
	now := time.Now()
	rows := selectDevices(reg.Rows(), o.quietSince, now)
	if app.JSON {
		return app.printArray(devicesSnapshot(rows, store, now))
	}
	printDevicesTable(app, rows, store, now, o.quietSince > 0)
	return nil
}

// selectDevices applies --quiet-since: with it, only transmitters silent for longer than the
// window survive, and one with no datable last-seen is dropped because its quiet time cannot be
// computed without a wall time.
func selectDevices(devices []*records.Device, quiet time.Duration, now time.Time) []*records.Device {
	if quiet <= 0 {
		return devices
	}
	out := make([]*records.Device, 0, len(devices))
	for _, d := range devices {
		if d.LastWall.IsZero() || now.Sub(d.LastWall) <= quiet {
			continue
		}
		out = append(out, d)
	}
	return out
}

// printDevicesTable renders `ley devices-seen`: the transmitter, its label, how often it was heard,
// and how long ago it was first and last heard.
func printDevicesTable(app *App, devices []*records.Device, store *labels.Store, now time.Time, quiet bool) {
	s := tableStyle(app)
	cols := []column{
		{head: "DEVICE", min: 8},
		{head: "LABEL", min: 6, drop: 2, hideEmpty: true},
		{head: "PROTOCOL", drop: 3},
		{head: "KIND", drop: 1},
		{head: "SEEN", right: true},
		{head: "FIRST"},
		{head: "LAST"},
		{head: "SUMMARY", min: 12, drop: 1},
	}
	for _, d := range devices {
		add(cols, d.DeviceID, absentIfEmpty(s, deviceLabel(store, d.DeviceID)),
			absentIfEmpty(s, d.Protocol), absentIfEmpty(s, d.Kind), fmt.Sprint(d.Count),
			deviceAge(d.FirstWall, now), deviceAge(d.LastWall, now),
			absentIfEmpty(s, d.Summary))
	}
	_, _ = printColumns(app.Stdout, s, cols, nil)
	if len(devices) == 0 {
		if quiet {
			fmt.Fprintln(app.Stdout, s.Muted("(nothing has gone quiet within the window)"))
			return
		}
		fmt.Fprintln(app.Stdout, s.Muted("(no devices seen; ley decode <name> --job keeps records, and devices-seen reads them)"))
	}
}

// deviceLabel is the name a device was given, or empty when it has none.
func deviceLabel(store *labels.Store, id string) string {
	if l, ok := store.Get(id); ok {
		return l.Name
	}
	return ""
}

// deviceAge is how long ago a wall time was, or the absent glyph when no anchor dated it: ley
// does not make up times it cannot derive from an anchor (AGENTS.md invariant 5).
func deviceAge(at, now time.Time) string {
	if at.IsZero() {
		return "-"
	}
	return ageWord(now.Sub(at))
}

// devicesSnapshot is the --json rows: the registry joined with the labels store.
func devicesSnapshot(devices []*records.Device, store *labels.Store, now time.Time) DevicesSnapshot {
	snap := DevicesSnapshot{Devices: []DeviceRow{}}
	for _, d := range devices {
		row := DeviceRow{
			DeviceID: d.DeviceID, Label: deviceLabel(store, d.DeviceID), Protocol: d.Protocol,
			Kind: d.Kind, Seen: d.Count, Summary: d.Summary,
		}
		if !d.FirstWall.IsZero() {
			row.FirstNs = d.FirstWall.UnixNano()
		}
		if !d.LastWall.IsZero() {
			row.LastNs = d.LastWall.UnixNano()
			row.QuietS = now.Sub(d.LastWall).Seconds()
		}
		snap.Devices = append(snap.Devices, row)
	}
	return snap
}
