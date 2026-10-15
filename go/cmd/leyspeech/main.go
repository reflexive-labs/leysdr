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
	"io"
	"os"
	"os/signal"
	"syscall"
	"time"

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
	root.AddCommand(newRefCommand(&g), newRunCommand(&g), newCompareCommand(&g), newLiveCommand(&g))
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

// addDaemonFlags adds the flags that start a hermetic daemon for the run.
func addDaemonFlags(cmd *cobra.Command, o *daemonOptions) {
	f := cmd.Flags()
	f.BoolVar(&o.hermetic, "daemon", false, "start a hermetic leylined on a copy of the recording instead of using the running daemon")
	f.StringVar(&o.leylined, "leylined", envOr("LEYLINED_BIN", "leylined"), "with --daemon: the leylined binary (default: $LEYLINED_BIN, else leylined on PATH)")
	f.StringVar(&o.decoders, "decoders", os.Getenv("LEYLINE_DECODERS"), "with --daemon: a decoder plugin directory the daemon searches first (default: $LEYLINE_DECODERS)")
	f.StringVar(&o.recordings, "recordings", "", "with --daemon: the directory of recordings to find the recording in, when it is not given as a directory")
}

// measureRecording opens the session, reads the recording and its transcript, and transcribes it
// with each engine in turn, one result each.
func measureRecording(ctx context.Context, g *globals, o daemonOptions, recordingRef, refPath string, engines []engineSpec, stderr io.Writer) ([]*result, error) {
	s, dir, err := openSession(ctx, g, o, recordingRef, stderr)
	if err != nil {
		return nil, err
	}
	defer s.close()
	rec, err := readRecording(dir)
	if err != nil {
		return nil, err
	}
	ref, refPath, err := loadRef(refPath, dir)
	if err != nil {
		return nil, err
	}
	var results []*result
	for _, e := range engines {
		r, err := s.transcribe(ctx, rec, ref, refPath, e)
		if err != nil {
			return results, err
		}
		results = append(results, r)
	}
	return results, nil
}

// report prints the results as the table and its notes, or as JSON.
func report(w io.Writer, results []*result, asJSON bool) error {
	if asJSON {
		return printJSON(w, results)
	}
	if err := writeTable(w, results); err != nil {
		return err
	}
	writeNotes(w, results)
	return nil
}

func newRunCommand(g *globals) *cobra.Command {
	var (
		o                    daemonOptions
		recordingRef, refArg string
		e                    engineSpec
		asJSON               bool
	)
	cmd := &cobra.Command{
		Use:   "run --recording <id> --engine <decoder>",
		Short: "Transcribe a recording with one engine and score it",
		Long: `run transcribes a gated recording with one speech decoder through
'ley transcribe --yes --json', scores the records against the hand transcript,
and prints one row: the overs, the word error rate with its substitutions,
deletions and insertions, the callsigns found of those spoken, the minutes of
squelch-open audio, what the provider counted for the job (from the daemon's
usage ledger, in its own units, and scaled to one hour of squelch-open audio),
and how many seconds of that audio were transcribed per second of wall clock.

The transcript is --ref, else transcript.txt beside recording.json ('leyspeech
ref' starts one). Without either nothing is scored, and the row says so.

--model is the speech model for a decoder that calls a provider. ley transcribe
leaves it chosen for later jobs; leyspeech puts the previous choice back.

Without --daemon, run uses the running daemon and the keys it holds. With
--daemon it starts a hermetic leylined (no radios, its own socket, store and
keys) on a copy of the recording, so the scripted engine and a provider key in
$LEYSPEECH_KEY can be measured without touching the user's daemon.

--json prints the results as a JSON array.`,
		Example: `  leyspeech run --recording job_01J... --engine speech
  leyspeech run --recording job_01J... --engine speech --model gpt-4o-transcribe
  LEYDEC_SPEECH_SCRIPT=script.txt leyspeech run --daemon --recording ./job_01J... --engine speech-scripted   # the keyless test engine`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			results, err := measureRecording(cmd.Context(), g, o, recordingRef, refArg, []engineSpec{e}, cmd.ErrOrStderr())
			if err != nil {
				return err
			}
			return report(cmd.OutOrStdout(), results, asJSON)
		},
	}
	f := cmd.Flags()
	f.StringVar(&recordingRef, "recording", "", "the recording: an id, id prefix, ley://recordings/ URI or directory")
	f.StringVar(&e.name, "engine", "speech", "the speech decoder ('ley decoders' lists them)")
	f.StringVar(&e.model, "model", "", "the speech model, for a decoder that calls a provider")
	f.StringVar(&refArg, "ref", "", "the hand transcript (default: transcript.txt beside the recording)")
	f.BoolVar(&asJSON, "json", false, "print the result as JSON")
	addDaemonFlags(cmd, &o)
	_ = cmd.MarkFlagRequired("recording")
	return cmd
}

func newLiveCommand(g *globals) *cobra.Command {
	var (
		freq    string
		e       engineSpec
		seconds int
		asJSON  bool
	)
	cmd := &cobra.Command{
		Use:   "live --freq <MHz> --engine <decoder>",
		Short: "Run an engine live and measure the delay from each over to its text",
		Long: `live runs 'ley decode <engine> --freq F --job --json' on the running daemon
for --seconds, stamps each record as it arrives, then cancels the job and reads,
from the recording the job kept of its overs, when each over's squelch closed.
The delay from that close to the record's arrival is reported per over, with
its median, 90th percentile and maximum.

The close is on the capture's clock, through the recording's anchor, and the
arrival on this machine's, so the two agree only on the machine the daemon runs
on. The delay includes the decoder's hang (half a second unless its manifest
says otherwise): the daemon ends a segment only that long after the close, so
no engine can answer sooner.

live takes the radio as 'ley decode' does and refuses when somebody else is
using it. --model switches the speech model for the whole window and puts the
previous choice back after. The job is cancelled on every way out, Ctrl-C
included. Its records and its recording are kept, so 'leyspeech run
--recording <job>' can score the same overs once they are transcribed by hand.`,
		Example: `  leyspeech live --freq 146.94 --engine speech --seconds 600
  leyspeech live --freq 162.55 --engine speech --model gpt-4o-transcribe --seconds 300 --json`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if seconds <= 0 {
				return fmt.Errorf("--seconds must be more than 0")
			}
			s, err := openLiveSession(cmd.Context(), g, cmd.ErrOrStderr())
			if err != nil {
				return err
			}
			defer s.close()
			r, err := s.live(cmd.Context(), freq, e, time.Duration(seconds)*time.Second)
			if err != nil {
				return err
			}
			return report(cmd.OutOrStdout(), []*result{r}, asJSON)
		},
	}
	f := cmd.Flags()
	f.StringVar(&freq, "freq", "", "where to listen, e.g. 146.94 (a bare number is MHz)")
	f.StringVar(&e.name, "engine", "speech", "the speech decoder ('ley decoders' lists them)")
	f.StringVar(&e.model, "model", "", "the speech model, for a decoder that calls a provider")
	f.IntVar(&seconds, "seconds", 120, "how long to listen")
	f.BoolVar(&asJSON, "json", false, "print the result as JSON")
	_ = cmd.MarkFlagRequired("freq")
	return cmd
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
