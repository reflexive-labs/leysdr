// SPDX-License-Identifier: Apache-2.0

package main

import (
	"fmt"
	"strings"

	"github.com/spf13/cobra"
)

// parseEngineSpec reads "decoder" or "decoder=model".
func parseEngineSpec(s string) (engineSpec, error) {
	name, model, _ := strings.Cut(s, "=")
	if name == "" {
		return engineSpec{}, fmt.Errorf("--engine %q names no decoder; write decoder or decoder=model", s)
	}
	return engineSpec{name: name, model: model}, nil
}

func newCompareCommand(g *globals) *cobra.Command {
	var (
		o                    daemonOptions
		recordingRef, refArg string
		engines              []string
		asJSON               bool
	)
	cmd := &cobra.Command{
		Use:   "compare --recording <id> --engine <decoder[=model]>...",
		Short: "Transcribe one recording with several engines, one row each",
		Long: `compare runs what 'leyspeech run' runs once for every --engine, in the order
given, on the same recording and against the same hand transcript, and prints
one row each: the table the speech-to-text decision record holds.

--engine is a decoder name, or decoder=model for a decoder that calls a
provider; repeat it, or separate several with commas. Each run is a job of its
own, so its records and its ledger line are its own, and a model chosen for a
run is put back before the next.

A failed run stops the comparison and prints the rows that finished.`,
		Example: `  leyspeech compare --recording job_01J... --engine speech --engine <decoder>=<model>
  make speech-spike RECORDING=job_01J... ENGINES="speech <decoder>=<model>"`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			var specs []engineSpec
			for _, e := range engines {
				spec, err := parseEngineSpec(e)
				if err != nil {
					return err
				}
				specs = append(specs, spec)
			}
			if len(specs) == 0 {
				return fmt.Errorf("name at least one --engine; 'ley decoders' lists them")
			}
			results, err := measureRecording(cmd.Context(), g, o, recordingRef, refArg, specs, cmd.ErrOrStderr())
			if len(results) > 0 {
				if rerr := report(cmd.OutOrStdout(), results, asJSON); rerr != nil && err == nil {
					err = rerr
				}
			}
			return err
		},
	}
	f := cmd.Flags()
	f.StringVar(&recordingRef, "recording", "", "the recording: an id, id prefix, ley://recordings/ URI or directory")
	f.StringSliceVar(&engines, "engine", nil, "a speech decoder, or decoder=model; repeat for each engine")
	f.StringVar(&refArg, "ref", "", "the hand transcript (default: transcript.txt beside the recording)")
	f.BoolVar(&asJSON, "json", false, "print the results as a JSON array")
	addDaemonFlags(cmd, &o)
	_ = cmd.MarkFlagRequired("recording")
	return cmd
}
