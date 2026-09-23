// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

func newDecodersCommand(app *App) *cobra.Command {
	return &cobra.Command{
		Use:   "decoders",
		Short: "List the decoders the daemon has installed",
		Long: `decoders lists the plugins the daemon found, with what each one tunes and
what it produces. A decoder is a program the daemon spawns: it reads the
audio of a channel and writes records back, so 'ley decode aprs' needs no
frequency, mode or bandwidth -- the decoder's recipe says where its protocol
lives and how to demodulate it.

The daemon reads manifests and runs nothing to build this list, so a broken
plugin is missing from it rather than breaking the verb; the directories it
looked in are printed under the table.

--json prints a ListDecodersResponse: the manifests, the search path and the
retention applied to kept records.`,
		Example: `  ley decoders                   # what can this daemon decode?
  ley decoders --json | jq -r '.decoders[].name'
  ley decode aprs                # run the first one`,
		GroupID: GroupLooking,
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runDecoders(cmd.Context(), app)
		},
	}
}

func runDecoders(ctx context.Context, app *App) error {
	c, err := app.dial(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	resp, err := c.ListDecoders(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	if app.JSON {
		return app.printJSON(resp)
	}
	printDecoderTable(app, resp)
	return nil
}

// printDecoderTable renders `ley decoders`. The name comes first: it is what `ley decode` takes.
func printDecoderTable(app *App, resp *leylinev1.ListDecodersResponse) {
	s := tableStyle(app)
	cols := []column{
		{head: "NAME"},
		{head: "FREQUENCY", min: 10},
		{head: "MODE"},
		{head: "OUTPUTS", min: 7, drop: 2},
		{head: "VERSION", drop: 1},
	}
	for _, m := range resp.GetDecoders() {
		name := m.GetName()
		// The friendly names sit beside the canonical one, so a reader learns that `ley track
		// vessels` reaches `ais` without leaving the table.
		if a := m.GetAliases(); len(a) > 0 {
			name += " " + s.Muted("("+strings.Join(a, ", ")+")")
		}
		add(cols, name, decoderFrequencies(m), decoderMode(m),
			absentIfEmpty(s, decoderOutputs(m)), absentIfEmpty(s, m.GetVersion()))
	}
	_, _ = printColumns(app.Stdout, s, cols, nil)
	if len(resp.GetDecoders()) == 0 {
		fmt.Fprintln(app.Stdout, s.Muted("(no decoders installed)"))
	}
	if path := resp.GetSearchPath(); len(path) > 0 {
		fmt.Fprintf(app.Stderr, "looked in %s\n", app.ErrStyle.Muted(strings.Join(path, ", ")))
	}
	if resp.GetStorePath() != "" {
		fmt.Fprintf(app.Stderr, "kept records in %s, %s or %d days, whichever comes first\n",
			app.ErrStyle.Muted(resp.GetStorePath()), formatBytes(resp.GetStoreCapBytes()), resp.GetStoreAgeDays())
	}
}

// decoderFrequencies is the recipe's first frequency and how many others it has, because the
// first is what `ley decode` tunes without --freq.
func decoderFrequencies(m *leylinev1.DecoderManifest) string {
	hz := m.GetRecipe().GetFrequenciesHz()
	if len(hz) == 0 {
		return "-"
	}
	out := leyline.FormatFrequency(hz[0])
	if len(hz) > 1 {
		out += fmt.Sprintf(" (+%d)", len(hz)-1)
	}
	return out
}

// decoderMode is the mode and bandwidth the recipe demodulates at, which is what makes the job
// need no tune flags.
func decoderMode(m *leylinev1.DecoderManifest) string {
	r := m.GetRecipe()
	mode := strings.ToUpper(leyline.ModeName(r.GetMode()))
	if bw := r.GetBandwidthHz(); bw > 0 {
		return mode + " " + formatBandwidth(bw)
	}
	return mode
}

// decoderOutputs names the shapes the decoder produces, in the words the design doc uses:
// records is the base stream, entities the client-side fold `ley track` renders.
func decoderOutputs(m *leylinev1.DecoderManifest) string {
	var out []string
	for _, shape := range m.GetOutputs() {
		switch shape {
		case leylinev1.OutputShape_SHAPE_RECORDS:
			out = append(out, "records")
		case leylinev1.OutputShape_SHAPE_ENTITIES:
			out = append(out, "entities")
		case leylinev1.OutputShape_SHAPE_REGISTRY:
			out = append(out, "devices")
		}
	}
	return strings.Join(out, ", ")
}

// formatBytes renders a store cap in human-readable units.
func formatBytes(n uint64) string {
	switch {
	case n == 0:
		return "no cap"
	case n >= 1<<30:
		return fmt.Sprintf("%.0f GiB", float64(n)/float64(1<<30))
	case n >= 1<<20:
		return fmt.Sprintf("%.0f MiB", float64(n)/float64(1<<20))
	default:
		return fmt.Sprintf("%d bytes", n)
	}
}

// completeDecoders offers the names the daemon has installed for a <decoder> argument, the way
// kubectl and helm complete plugin names from what is present rather than a list baked into the
// binary (docs/design/decoders.md: a decoder is data, not a compiled-in verb). Completion runs
// without a guaranteed daemon, so any failure yields no suggestions rather than an error.
func completeDecoders(app *App, toComplete string) ([]cobra.Completion, cobra.ShellCompDirective) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	c, err := app.dial(ctx)
	if err != nil {
		return nil, cobra.ShellCompDirectiveNoFileComp
	}
	defer c.Close()
	resp, err := c.ListDecoders(ctx)
	if err != nil {
		return nil, cobra.ShellCompDirectiveNoFileComp
	}
	var out []cobra.Completion
	for _, m := range resp.GetDecoders() {
		if strings.HasPrefix(m.GetName(), toComplete) {
			out = append(out, cobra.CompletionWithDesc(m.GetName(), m.GetDescription()))
		}
		// Offer the friendly names too, so `ley track ves<TAB>` completes to vessels; the verb
		// resolves it back to the canonical decoder.
		for _, a := range m.GetAliases() {
			if strings.HasPrefix(a, toComplete) {
				out = append(out, cobra.CompletionWithDesc(a, m.GetName()))
			}
		}
	}
	return out, cobra.ShellCompDirectiveNoFileComp
}
