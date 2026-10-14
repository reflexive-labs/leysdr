// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
)

// usageNow is the clock --since counts back from; a test freezes it.
var usageNow = time.Now

func newAIUsageCommand(app *App) *cobra.Command {
	var since, by string
	cmd := &cobra.Command{
		Use:   "usage [--since 30d] [--by day|month]",
		Short: "Print the requests and tokens the provider calls used",
		Long: `usage prints what the calls made with your keys used, in the provider's
own units: requests, input and output tokens, cache reads and writes, and
minutes of audio. One row is one provider, model and feature for one day
(or month with --by month), summed over the jobs and conversations that
made the calls, with a total row at the end.

Days are UTC, the days the providers' consoles count, so a row can be
compared with the provider's own usage page. The numbers are what the
workers reported to the daemon after each response; ley prints no prices,
and the provider's bill is the authority on what was spent. A column that
is empty in every row is left out.

--since takes a duration (30d, 12h) and counts whole UTC days, so the day it
falls in is included; --since 0 is the whole ledger. --json prints the
GetUsageResponse: the daemon's lines, one per scope and day, unsummed.`,
		Example: `  ley ai usage                         # the last 30 days, by day
  ley ai usage --since 1y --by month   # a year, by month
  ley ai usage --json | jq '[.lines[].requests | tonumber] | add'`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runAIUsage(cmd.Context(), app, since, by)
		},
	}
	cmd.Flags().StringVar(&since, "since", "30d", "how far back to count, e.g. 7d, 12h, 1y; 0 is the whole ledger")
	cmd.Flags().StringVar(&by, "by", "day", "one row per day or per month: day or month")
	return cmd
}

func runAIUsage(ctx context.Context, app *App, since, by string) error {
	if by != "day" && by != "month" {
		return usageErrorf("--by must be day or month (got %q)", by)
	}
	d, err := parseUsageSince(since)
	if err != nil {
		return usageErrorf("--since %v", err)
	}
	var sinceNs int64
	if d > 0 {
		sinceNs = usageNow().Add(-d).UnixNano()
	}
	c, err := app.dial(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	resp, err := c.Usage.GetUsage(ctx, &leylinev1.GetUsageRequest{SinceNs: sinceNs})
	if err != nil {
		return app.notRunning(err)
	}
	if app.JSON {
		return app.printJSON(resp)
	}
	from := "the start of the ledger"
	if sinceNs > 0 {
		from = time.Unix(0, sinceNs).UTC().Format(time.DateOnly)
	}
	es := app.ErrStyle
	es.Width = app.Style.Width
	for _, l := range wrapWords(usageHeader(from), tableStyle(app).Width) {
		fmt.Fprintln(app.Stderr, es.Muted(l))
	}
	_, err = io.WriteString(app.Stdout, renderUsage(tableStyle(app), resp.GetLines(), by))
	return err
}

// usageHeader is the line above the table: what a day is and where the numbers came from.
func usageHeader(from string) string {
	return "Days are UTC, as the providers count them. The numbers are what the workers reported, from " + from + "."
}

// parseUsageSince is parseAge with years, since a ledger keeps 400 days.
func parseUsageSince(s string) (time.Duration, error) {
	if years, ok := strings.CutSuffix(strings.TrimSpace(s), "y"); ok {
		n, err := strconv.ParseFloat(years, 64)
		if err != nil || n < 0 {
			return 0, fmt.Errorf("%q is not a duration; try 30d, 12h or 1y", s)
		}
		return time.Duration(n * 365 * 24 * float64(time.Hour)), nil
	}
	return parseAge(s)
}

// usageRow is one row of the table: the ledger's lines summed over scope, and over the days of
// a month with --by month.
type usageRow struct {
	period, provider, model, feature string
	requests, in, out, cacheRead     uint64
	cacheWrite                       uint64
	audioSeconds                     float64
}

func (r *usageRow) addLine(l *leylinev1.UsageLine) {
	r.requests += l.GetRequests()
	r.in += l.GetInputTokens()
	r.out += l.GetOutputTokens()
	r.cacheRead += l.GetCacheReadTokens()
	r.cacheWrite += l.GetCacheWriteTokens()
	r.audioSeconds += l.GetAudioSeconds()
}

func (r *usageRow) addRow(o *usageRow) {
	r.requests += o.requests
	r.in += o.in
	r.out += o.out
	r.cacheRead += o.cacheRead
	r.cacheWrite += o.cacheWrite
	r.audioSeconds += o.audioSeconds
}

// usageRows sums lines by period, provider, model and feature, oldest period first.
func usageRows(lines []*leylinev1.UsageLine, by string) []*usageRow {
	byKey := map[string]*usageRow{}
	for _, l := range lines {
		period := l.GetDay()
		if by == "month" && len(period) >= 7 {
			period = period[:7]
		}
		k := strings.Join([]string{period, l.GetProvider(), l.GetModel(), l.GetFeature()}, "\x00")
		r := byKey[k]
		if r == nil {
			r = &usageRow{period: period, provider: l.GetProvider(), model: l.GetModel(), feature: l.GetFeature()}
			byKey[k] = r
		}
		r.addLine(l)
	}
	keys := make([]string, 0, len(byKey))
	for k := range byKey {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := make([]*usageRow, 0, len(keys))
	for _, k := range keys {
		out = append(out, byKey[k])
	}
	return out
}

// renderUsage is the `ley ai usage` table. The period, the model and the request count are what
// a narrow terminal keeps; the cache columns go first, then the feature and the provider, which
// the model name mostly implies, then the token and audio counts.
func renderUsage(s ui.Style, lines []*leylinev1.UsageLine, by string) string {
	head := "DAY"
	if by == "month" {
		head = "MONTH"
	}
	cols := []column{
		{head: head},
		{head: "PROVIDER", drop: 5},
		{head: "MODEL", min: 17},
		{head: "FEATURE", drop: 6},
		{head: "REQUESTS", right: true},
		{head: "IN", right: true, drop: 2, hideEmpty: true},
		{head: "OUT", right: true, drop: 3, hideEmpty: true},
		{head: "CACHE RD", right: true, drop: 7, hideEmpty: true},
		{head: "CACHE WR", right: true, drop: 8, hideEmpty: true},
		{head: "AUDIO (min)", right: true, drop: 4, hideEmpty: true},
	}
	rows := usageRows(lines, by)
	total := &usageRow{}
	for _, r := range rows {
		total.addRow(r)
		addUsageRow(cols, s, r.period, r.provider, r.model, r.feature, r)
	}
	var b strings.Builder
	if len(rows) == 0 {
		_, _ = printColumns(&b, s, cols, nil)
		writeWrapped(&b, s, "(no usage reported; calls made with ley ai keys are counted here)")
		return b.String()
	}
	addUsageRow(cols, s, s.Label("total"), "", "", "", total)
	_, _ = printColumns(&b, s, cols, nil)
	return b.String()
}

func addUsageRow(cols []column, s ui.Style, period, provider, model, feature string, r *usageRow) {
	absent := s.Glyphs().Absent
	count := func(n uint64) string {
		if n == 0 {
			return absent
		}
		return groupDigits(n)
	}
	audio := absent
	if r.audioSeconds > 0 {
		audio = strconv.FormatFloat(r.audioSeconds/60, 'f', 1, 64)
	}
	add(cols, period, provider, model, feature, groupDigits(r.requests), count(r.in), count(r.out),
		count(r.cacheRead), count(r.cacheWrite), audio)
}

// groupDigits writes a count with thousands separated by commas, so a token count of seven digits
// is read at a glance.
func groupDigits(n uint64) string {
	s := strconv.FormatUint(n, 10)
	for i := len(s) - 3; i > 0; i -= 3 {
		s = s[:i] + "," + s[i:]
	}
	return s
}
