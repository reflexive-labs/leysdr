// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

type recordingsOptions struct {
	kind   string
	freqHz uint64
	since  time.Duration
	limit  int
}

func newRecordingsCommand(app *App) *cobra.Command {
	var (
		o           recordingsOptions
		freq, since string
	)
	cmd := &cobra.Command{
		Use:   "recordings",
		Short: "List the recordings the daemon has kept",
		Long: `recordings reads the daemon's store: what 'ley record' wrote, newest first.
A recording is one directory of files -- 'ley recordings path' says where, so
'open -R "$(ley recordings path <id>)"' reveals it in Finder.

The store is a plain directory. A recording deleted there is gone, and the
daemon does not have to be told; the daemon drops the oldest when the store
passes its cap (leylined --recordings-cap).

--json prints a ListResourcesResponse.`,
		Example: `  ley recordings                       # everything kept, newest first
  ley recordings --kind audio          # just the WAVs
  ley recordings --freq 146.52         # one frequency
  ley recordings show job_01J...       # the manifest: parts, gaps, the radio
  open -R "$(ley recordings path job_01J...)"`,
		GroupID: GroupLooking,
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if o.kind != "" && o.kind != "audio" && o.kind != "iq" {
				return usageErrorf("--kind %q is not a kind of recording; audio and iq are the ones there are", o.kind)
			}
			if freq != "" {
				t, err := resolveDial(freq, "146.52 (MHz)")
				if err != nil {
					return usageErrorf("--freq %v", err)
				}
				o.freqHz = t.Hz
			}
			if since != "" {
				d, err := parseAge(since)
				if err != nil {
					return usageErrorf("--since %v", err)
				}
				o.since = d
			}
			return runRecordings(cmd.Context(), app, o)
		},
	}
	cmd.Flags().StringVar(&o.kind, "kind", "", "only audio or iq recordings")
	cmd.Flags().StringVar(&freq, "freq", "", "only recordings of this frequency or preset, e.g. 146.52")
	cmd.Flags().StringVar(&since, "since", "", "only recordings started more recently than this, e.g. 1h, 30m, 2d")
	cmd.Flags().IntVar(&o.limit, "limit", 0, "at most this many rows, e.g. 20 (default: all of them)")
	cmd.AddCommand(newRecordingsShowCommand(app), newRecordingsPathCommand(app))
	return cmd
}

func runRecordings(ctx context.Context, app *App, o recordingsOptions) error {
	c, err := app.dial(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	// The metadata keys are the frozen ones the daemon filters on by exact string.
	filter := map[string]string{}
	if o.kind != "" {
		filter["kind"] = o.kind
	}
	if o.freqHz != 0 {
		filter["frequency_hz"] = strconv.FormatUint(o.freqHz, 10)
	}
	found, err := c.ListRecordings(ctx, filter)
	if err != nil {
		return app.notRunning(err)
	}
	if o.since > 0 {
		cutoff := time.Now().Add(-o.since).UnixNano()
		kept := found[:0]
		for _, r := range found {
			if r.GetCreatedAtNs() >= cutoff {
				kept = append(kept, r)
			}
		}
		found = kept
	}
	if o.limit > 0 && len(found) > o.limit {
		found = found[:o.limit]
	}
	if app.JSON {
		return app.printJSON(&leylinev1.ListResourcesResponse{Resources: found})
	}
	printRecordingsTable(app, found)
	return nil
}

// printRecordingsTable renders `ley recordings`: newest first, with enough to pick one out.
func printRecordingsTable(app *App, found []*leylinev1.Resource) {
	s := tableStyle(app)
	cols := []column{
		{head: "STARTED"},
		{head: "FREQUENCY"},
		{head: "MODE", drop: 2},
		{head: "KIND", drop: 3},
		{head: "LENGTH"},
		{head: "PARTS", drop: 1},
		{head: "SIZE"},
		{head: "ID", min: 8},
	}
	for _, r := range found {
		m := r.GetMetadata()
		freq := "-"
		if hz, err := strconv.ParseUint(m["frequency_hz"], 10, 64); err == nil && hz > 0 {
			freq = leyline.FormatFrequency(hz)
		}
		add(cols, recordingClock(r.GetCreatedAtNs()), freq, absentIfEmpty(s, m["mode"]),
			absentIfEmpty(s, m["kind"]), recordingLength(m["duration_ms"]),
			absentIfEmpty(s, m["parts"]), recordingSize(r.GetSizeBytes()),
			s.Muted(r.GetOriginatingJobId()))
	}
	_, _ = printColumns(app.Stdout, s, cols, nil)
	if len(found) == 0 {
		fmt.Fprintln(app.Stdout, s.Muted("(no recordings; ley record 146.52 --for 30s makes one)"))
	}
}

func recordingClock(ns int64) string {
	if ns == 0 {
		return "-"
	}
	at := time.Unix(0, ns)
	if time.Since(at) > 20*time.Hour {
		return at.Format("Jan 02 15:04")
	}
	return at.Format("15:04:05")
}

// recordingLength renders how much signal a recording holds, not how long it was running: a gated
// recording's gaps are not part of what it holds.
func recordingLength(ms string) string {
	n, err := strconv.ParseInt(ms, 10, 64)
	if err != nil || n <= 0 {
		return "-"
	}
	return forPhrase(time.Duration(n) * time.Millisecond)
}

func recordingSize(bytes uint64) string {
	switch {
	case bytes >= 1<<30:
		return fmt.Sprintf("%.1f GB", float64(bytes)/float64(1<<30))
	case bytes >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(bytes)/float64(1<<20))
	case bytes >= 1<<10:
		return fmt.Sprintf("%.0f KB", float64(bytes)/float64(1<<10))
	}
	return fmt.Sprintf("%d B", bytes)
}

// ---------- show ----------

func newRecordingsShowCommand(app *App) *cobra.Command {
	return &cobra.Command{
		Use:   "show <id>",
		Short: "Print one recording's manifest",
		Long: `show prints what the daemon wrote beside a recording's files: the radio and
the gain it was made on, the parts with their span on the capture's timeline,
the times nothing was recorded and why, and how it ended.

The id is a job id, an id prefix, or a ley://recordings/ URI.

--json prints the manifest itself, the same document 'recording.json' holds.`,
		Example: `  ley recordings show job_01J...
  ley recordings show job_01J... --json | jq '.parts[].file'`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runRecordingsShow(cmd.Context(), app, args[0])
		},
	}
}

func runRecordingsShow(ctx context.Context, app *App, ref string) error {
	c, err := app.dial(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	jobID, err := resolveRecordingID(ctx, c, ref)
	if err != nil {
		return err
	}
	dir, err := c.ResolveLocalPath(ctx, leyline.RecordingURI(jobID))
	if err != nil {
		return recordingNotFound(app, ref, err)
	}
	manifest, err := leyline.ReadRecordingManifest(dir)
	if err != nil {
		return fmt.Errorf("the recording's manifest could not be read (%s): %w", dir, err)
	}
	if app.JSON {
		// The manifest as it is on disk, not a re-rendering of it: the daemon owns the format, and
		// a client that reconstructed it would drift from what Finder shows.
		raw, rerr := os.ReadFile(filepath.Join(dir, "recording.json"))
		if rerr != nil {
			return rerr
		}
		var doc json.RawMessage
		if uerr := json.Unmarshal(raw, &doc); uerr != nil {
			return uerr
		}
		var buf bytes.Buffer
		if ierr := json.Compact(&buf, doc); ierr != nil {
			return ierr
		}
		_, werr := fmt.Fprintf(app.Stdout, "%s\n", buf.Bytes())
		return werr
	}
	printRecordingManifest(app, manifest, dir)
	return nil
}

func printRecordingManifest(app *App, m *leyline.RecordingManifest, dir string) {
	s := app.Style
	out := app.Stdout
	what := m.Kind
	if m.Kind == "audio" && m.Mode != "" {
		what = m.Mode + " audio"
	}
	// One fact per line, each led by a label word, as `ley tune`'s banner is.
	fmt.Fprintln(out, leadLabel(s, "Recording", fmt.Sprintf("%s %s, %s",
		leyline.FormatFrequency(m.FrequencyHz), what, m.Format)))
	// The manifest's own byte count is the samples; the SIZE column of `ley recordings` is what the
	// directory takes on disk, sidecars included, which is the bigger and different number.
	fmt.Fprintln(out, leadLabel(s, "Holds    ", fmt.Sprintf("%s of signal in %s, %s of samples",
		forPhrase(time.Duration(m.DurationMs())*time.Millisecond),
		plural(len(m.Parts), "part"), recordingSize(m.Bytes))))
	if !m.StartedAt().IsZero() {
		when := m.StartedAt().Format("2006-01-02 15:04:05")
		if m.EndedBy != "" {
			when += ", " + endedByPhrase(s, m.EndedBy)
		}
		fmt.Fprintln(out, leadLabel(s, "Started  ", when))
	}
	if m.Device != nil && m.Device.Model != "" {
		radio := m.Device.Model + " (" + m.Device.Driver + ")"
		if len(m.Gains) > 0 {
			radio += fmt.Sprintf(", %s gain %.1f dB", m.Gains[0].Element, m.Gains[0].ValueDB)
		}
		fmt.Fprintln(out, leadLabel(s, "Radio    ", radio))
	}
	if m.Gate != nil {
		gate := fmt.Sprintf("%s, %d ms pre-roll, %s hang, %s", m.Gate.Kind, m.Gate.PreRollMs,
			forPhrase(time.Duration(m.Gate.HangMs)*time.Millisecond),
			plural(m.SquelchOpens(), "transmission"))
		fmt.Fprintln(out, leadLabel(s, "Gate     ", gate))
	}
	fmt.Fprintln(out, s.Muted(dir))
	if len(m.Parts) > 0 {
		cols := []column{
			{head: "PART"},
			{head: "STARTED"},
			{head: "LENGTH"},
			{head: "PEAK", drop: 1},
			{head: "OVERS", drop: 2},
			{head: "FILE", min: 12},
		}
		for _, p := range m.Parts {
			started := "-"
			if at, ok := m.PartStartedAt(p); ok {
				started = at.Format("15:04:05")
			}
			length := "-"
			if m.SampleRate > 0 {
				length = forPhrase(time.Duration(float64(p.Samples) / float64(m.SampleRate) * float64(time.Second)))
			}
			peak := "-"
			if p.PeakDBFS != nil {
				peak = fmt.Sprintf("%.1f dBFS", *p.PeakDBFS)
			}
			overs := "-"
			if p.SquelchOpens > 0 {
				overs = strconv.Itoa(p.SquelchOpens)
			}
			add(cols, strconv.Itoa(p.Part), started, length, peak, overs, p.File)
		}
		fmt.Fprintln(out)
		_, _ = printColumns(out, tableStyle(app), cols, nil)
	}
	// Gaps where nothing was recorded are listed here rather than hidden inside a file, so the
	// recording's timeline matches the air (AGENTS.md invariant 5).
	if len(m.Gaps) > 0 && m.SampleRate > 0 {
		fmt.Fprintf(out, "\n%s\n", s.Muted(plural(len(m.Gaps), "gap")+" where nothing was recorded:"))
		for _, g := range m.Gaps {
			span := float64(g.ToSample-g.FromSample) / float64(anchorRate(m))
			fmt.Fprintf(out, "  %s  %s\n", forPhrase(time.Duration(span*float64(time.Second))), s.Muted(g.Reason))
		}
	}
	// One command for either kind: play tunes raw samples back as a radio, and hands an audio
	// part to the machine's own player.
	if len(m.Parts) > 0 {
		st := app.ErrStyle
		fmt.Fprintf(app.Stderr, "%s %s\n", st.Muted("Listen:"), st.Cmd("ley play "+m.JobID))
	}
}

// endedByPhrase inks how a recording ended: a recording that ran out of disk or died with its
// daemon is not the same outcome as one that reached its duration, and the ink shows which.
func endedByPhrase(s ui.Style, endedBy string) string {
	switch endedBy {
	case "duration", "quiet", "cancelled", "channel ended":
		return s.Ok("ended by " + endedBy)
	case "restart":
		return s.Warn("ended by a daemon restart")
	case "store full", "error":
		return s.Err("ended by " + endedBy)
	}
	return "ended by " + endedBy
}

// anchorRate is the capture rate the manifest's sample indices are counted at.
func anchorRate(m *leyline.RecordingManifest) uint64 {
	for _, a := range m.Anchors {
		if a.SampleRate > 0 {
			return a.SampleRate
		}
	}
	return m.SampleRate
}

// ---------- path ----------

func newRecordingsPathCommand(app *App) *cobra.Command {
	var part int
	cmd := &cobra.Command{
		Use:   "path <id>",
		Short: "Print where a recording is on this machine",
		Long: `path prints the recording's directory, or one part's file with --part, and
nothing else, so it composes:

  open -R "$(ley recordings path job_01J...)"      reveal it in Finder
  afplay "$(ley recordings path job_01J... --part 1)"

Without --json the path is printed alone, so it composes into a shell command.
With --json it is a LocalPath object ({"path": "..."}), which is the shape the
contract carries and what every other --json output in ley is.`,
		Example: `  ley recordings path job_01J...
  open -R "$(ley recordings path job_01J...)"
  ley recordings path job_01J... --part 2 --json | jq -r .path`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runRecordingsPath(cmd.Context(), app, args[0], part)
		},
	}
	cmd.Flags().IntVar(&part, "part", 0, "print this part's samples file instead of the directory, e.g. 1")
	return cmd
}

func runRecordingsPath(ctx context.Context, app *App, ref string, part int) error {
	c, err := app.dial(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	jobID, err := resolveRecordingID(ctx, c, ref)
	if err != nil {
		return err
	}
	uri := leyline.RecordingURI(jobID)
	if part > 0 {
		uri = leyline.RecordingPartURI(jobID, part)
	}
	path, err := c.ResolveLocalPath(ctx, uri)
	if err != nil {
		return recordingNotFound(app, ref, err)
	}
	if app.JSON {
		return app.printJSON(&leylinev1.LocalPath{Path: path})
	}
	fmt.Fprintln(app.Stdout, path)
	return nil
}

// resolveRecordingID reads the id out of what the user typed: a job id, a URI, or an id prefix
// matched against the store. A prefix that matches more than one is a usage error listing them,
// rather than an arbitrary pick.
func resolveRecordingID(ctx context.Context, c *leyline.Client, ref string) (string, error) {
	if id, _, ok := leyline.ParseRecordingURI(ref); ok {
		return id, nil
	}
	if strings.HasPrefix(ref, "job_") && len(ref) == len("job_")+26 {
		return ref, nil
	}
	found, err := c.ListRecordings(ctx, nil)
	if err != nil {
		return "", err
	}
	var matches []string
	for _, r := range found {
		if strings.HasPrefix(r.GetOriginatingJobId(), ref) {
			matches = append(matches, r.GetOriginatingJobId())
		}
	}
	switch len(matches) {
	case 1:
		return matches[0], nil
	case 0:
		return "", usageErrorf("no recording called %s; ley recordings lists them", ref)
	}
	return "", usageErrorf("%s names %d recordings (%s); give the whole id", ref, len(matches), strings.Join(matches, ", "))
}

// recordingNotFound turns the daemon's JOB_NOT_FOUND into the sentence a reader acts on: a
// recording's id is its job's, so a missing one is a job the daemon never had.
func recordingNotFound(app *App, ref string, err error) error {
	if leyline.Code(err) == leyline.CodeJobNotFound {
		return &friendlyError{
			msg:   fmt.Sprintf("no recording called %s. %s lists the ones the daemon has", ref, app.ErrStyle.Cmd("ley recordings")),
			cause: err,
		}
	}
	return err
}
