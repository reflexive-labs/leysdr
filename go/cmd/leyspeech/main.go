// SPDX-License-Identifier: Apache-2.0

// Command leyspeech measures a speech decoder on receiver audio: it transcribes a gated recording
// with a named engine through `ley transcribe`, scores the text against a hand transcript (word
// error rate and callsign recall, go/pkg/wer), and reports what the provider counted and how fast
// it ran; or it runs the engine live and reports the delay from each over's close to its text
// (docs/dev/speech-spike.md).
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/spf13/cobra"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "leyspeech:", err)
		os.Exit(1)
	}
}

// run is main with its deferred calls, which os.Exit would skip.
func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return newRoot().ExecuteContext(ctx)
}

// globals are the flags every command takes: which ley to run and which daemon it talks to.
type globals struct {
	ley    string
	socket string
}

func (g *globals) runner() *leyRunner { return &leyRunner{bin: g.ley, socket: g.socket} }

func newRoot() *cobra.Command {
	var g globals
	root := &cobra.Command{
		Use:           "leyspeech",
		Short:         "Measure a speech decoder against a hand transcript",
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	f := root.PersistentFlags()
	f.StringVar(&g.ley, "ley", envOr("LEY_BIN", "ley"), "the ley binary (default: $LEY_BIN, else ley on PATH)")
	f.StringVar(&g.socket, "socket", "", "the daemon's socket (default: ley's own, $LEYLINE_SOCKET)")
	root.AddCommand(newRefCommand(&g))
	return root
}

func newRefCommand(g *globals) *cobra.Command {
	return &cobra.Command{
		Use:   "ref <recording>",
		Short: "Print a hand transcript to fill in, one line per over",
		Long: `ref prints a transcript template for a gated recording: one line per over,
part/over, a tab and "?", each under a comment giving when the over was heard and
how long the squelch was open. Replace each ? with the words as spoken and save
the file as transcript.txt beside recording.json; leyspeech run finds it there.

The overs are cut as the speech decoder cuts them, with its default half second
of pre-roll and hang, so two openings closer together than that are one over.

The recording is a directory holding recording.json, or an id, id prefix or
ley://recordings/ URI that 'ley recordings path' resolves on the daemon.`,
		Example: `  leyspeech ref job_01J... > "$(ley recordings path job_01J...)/transcript.txt"
  leyspeech ref ~/Recordings/job_01J...`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			dir, err := g.runner().locateRecording(cmd.Context(), args[0])
			if err != nil {
				return err
			}
			rec, err := readRecording(dir)
			if err != nil {
				return err
			}
			return writeTemplate(cmd.OutOrStdout(), rec)
		},
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
