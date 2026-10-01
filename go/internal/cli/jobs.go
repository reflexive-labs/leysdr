// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

func newJobsCommand(app *App) *cobra.Command {
	var wide bool
	cmd := &cobra.Command{
		Use:   "jobs",
		Short: "List the work the daemon is doing in the background",
		Long: `jobs lists the daemon's background work -- sweeps started by 'ley scan'
and decoders started by 'ley decode' -- with what each one is doing and how
far it has got. The daemon keeps the last sixteen finished jobs and forgets
them on restart.

A sweep, and a decode job without --job, belongs to the terminal that
started it, so a Ctrl-C there stops it. 'ley jobs cancel' is how to stop one
from somewhere else: another terminal, a script that started a scan with
--json and moved on, or a 'ley decode --job' that is still running. A job
can be named by its id, an unambiguous id prefix, or its row number here.

--json prints a ListJobsResponse; 'ley jobs cancel --json' prints the Job
in the state the daemon left it.`,
		Example: `  ley jobs                 # what is the daemon working on?
  ley jobs --wide          # the same, with the job ids
  ley jobs cancel 1        # stop the first job listed
  ley jobs cancel job_01J...   # stop that one, by id`,
		GroupID: GroupLooking,
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runJobs(cmd.Context(), app, wide)
		},
	}
	cmd.Flags().BoolVar(&wide, "wide", false, "add the job id column")
	cmd.AddCommand(newJobsCancelCommand(app))
	return cmd
}

func runJobs(ctx context.Context, app *App, wide bool) error {
	c, err := app.dial(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	jobs, err := c.ListJobs(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	if app.JSON {
		// The library hands back the jobs in row order; the wire shape a client reads is still
		// the response message the RPC is named for.
		return app.printJSON(&leylinev1.ListJobsResponse{Jobs: jobs})
	}
	printJobTable(app, jobs, wide)
	return nil
}

// newJobsCancelCommand stops one job. Cancelling a job that has already finished is not an
// error, since the job is stopped either way, so it prints the state the daemon reports and
// exits 0.
func newJobsCancelCommand(app *App) *cobra.Command {
	return &cobra.Command{
		Use:   "cancel <job>",
		Short: "Stop a running job",
		Long: `cancel stops a job the daemon is running and hands the radio back. The job
can be given as its id, an unambiguous id prefix, or its row number in
'ley jobs'. A job that has already finished is left as it is.`,
		Example: `  ley jobs cancel 1               # the first row of ley jobs
  ley jobs cancel job_01J...      # by id`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			c, err := app.dial(ctx)
			if err != nil {
				return app.notRunning(err)
			}
			defer c.Close()
			jobs, err := c.ListJobs(ctx)
			if err != nil {
				return app.notRunning(err)
			}
			j, err := leyline.ResolveJob(jobs, args[0])
			if err != nil {
				if len(jobs) == 0 {
					return fmt.Errorf("the daemon has no jobs; ley scan starts one")
				}
				return fmt.Errorf("%w. Run: ley jobs", err)
			}
			final, err := c.Jobs.CancelJob(ctx, &leylinev1.JobRef{JobId: j.GetJobId()})
			if err != nil {
				return err
			}
			if app.JSON {
				return app.printJSON(final)
			}
			fmt.Fprintf(app.Stdout, "%s %s\n", final.GetJobId(), jobStateWord(final))
			return nil
		},
	}
}

// printJobTable renders the jobs table. It shows what the daemon is doing and whether it is done,
// so WHAT and STATE come first; the id is only needed to refer to a job, and a row number does
// that too, so it moves behind --wide.
func printJobTable(app *App, jobs []*leylinev1.Job, wide bool) {
	s := tableStyle(app)
	cols := []column{
		{head: "WHAT", min: 8},
		{head: "RANGE", min: 12},
		{head: "STATE"},
		{head: "AGE"},
		{head: "DETAIL", min: 12, drop: 1},
	}
	if wide {
		cols = append(cols, column{head: "ID"})
	}
	for _, j := range jobs {
		cells := []string{
			jobKind(j),
			absentIfEmpty(s, jobRange(j)),
			inkState(s, jobStateWord(j)),
			jobAge(j),
			absentIfEmpty(s, j.GetStatusDetail()),
		}
		if wide {
			cells = append(cells, s.Muted(j.GetJobId()))
		}
		for i := range cells {
			cols[i].cells = append(cols[i].cells, cells[i])
		}
	}
	// --wide requests every column, and a truncated id is what --wide exists to avoid.
	if wide {
		s.Width = 0
	}
	dropped, err := printColumns(app.Stdout, s, cols, nil)
	if err != nil {
		return
	}
	if len(jobs) == 0 {
		fmt.Fprintln(app.Stdout, s.Muted("(no jobs; ley scan starts one)"))
		return
	}
	if !wide && app.IsTTY() {
		hidden := append(dropped, "ID")
		fmt.Fprintf(app.Stdout, "%s  %s\n",
			s.Cmd("ley jobs --wide"), s.Muted("adds "+strings.Join(hidden, ", ")))
	}
}

// jobKind names the work from the config the job carries: what it was asked to do, not what the
// daemon calls it internally.
func jobKind(j *leylinev1.Job) string {
	switch j.GetConfig().(type) {
	case *leylinev1.Job_Scan:
		return "scan"
	case *leylinev1.Job_Watch:
		return "watch"
	case *leylinev1.Job_Record:
		return "record"
	case *leylinev1.Job_Decode:
		return "decode"
	}
	return "job"
}

// jobRange is the span a job was pointed at, empty when it has none.
func jobRange(j *leylinev1.Job) string {
	if sc, ok := j.GetConfig().(*leylinev1.Job_Scan); ok && sc.Scan.GetRange() != nil {
		return rangesPhrase([]*leylinev1.FrequencyRange{sc.Scan.GetRange()})
	}
	// A decode job listens on one frequency, not a range; a job on the decoder's own recipe has
	// no frequency of its own, so it shows "recipe" rather than an invented number.
	if dec, ok := j.GetConfig().(*leylinev1.Job_Decode); ok {
		if hz := dec.Decode.GetFrequencyHz(); hz > 0 {
			return units.FormatFrequency(hz)
		}
		return "recipe"
	}
	// A recording is on one frequency too, or on somebody else's channel, shown by its id.
	if rec, ok := j.GetConfig().(*leylinev1.Job_Record); ok {
		if hz := rec.Record.GetFrequencyHz(); hz > 0 {
			return units.FormatFrequency(hz)
		}
		return rec.Record.GetChannelId()
	}
	if mon, ok := j.GetConfig().(*leylinev1.Job_Monitor); ok && mon.Monitor.GetRange() != nil {
		return rangesPhrase([]*leylinev1.FrequencyRange{mon.Monitor.GetRange()})
	}
	return ""
}

// jobStateWord is the state as people say it ("running", "completed").
func jobStateWord(j *leylinev1.Job) string { return stateWord(j.GetState().String()) }

// jobAge is how long ago the job started, coarsened as it gets older: seconds while somebody is
// watching a sweep run, minutes and hours for the ones the daemon still remembers.
func jobAge(j *leylinev1.Job) string {
	if j.GetCreatedAtNs() <= 0 {
		return "-"
	}
	d := time.Since(time.Unix(0, j.GetCreatedAtNs()))
	switch {
	case d < 0:
		return "0 s"
	case d < time.Minute:
		return fmt.Sprintf("%d s", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%d m", int(d.Minutes()))
	default:
		return fmt.Sprintf("%d h", int(d.Hours()))
	}
}
