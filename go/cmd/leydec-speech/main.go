// SPDX-License-Identifier: Apache-2.0

// Command leydec-speech is the speech decoder plugin: one over of audio in on stdin, one
// DecodeRecord with protocol speech out on stdout (docs/design/ai.md, "Speech-to-text is a
// decoder"). Its manifest asks for SEGMENTED input, so the daemon hands it one over at a time,
// and each record carries what the engine heard, the model, its confidence, the callsigns a
// pattern finds in the text, and what the call used.
//
// --engine picks the engine. `openai` sends each over to an OpenAI-compatible transcription
// endpoint on the key the daemon hands over on stdin; `scripted` replays the lines of the file
// LEYDEC_SPEECH_SCRIPT names, so that a test knows the words in advance. --model is the model
// asked for and recorded on each record; --language (default en) is the language asked for; --hint
// adds words to the vocabulary hint the openai engine sends with the audio.
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/callsign"
	"github.com/reflexive-labs/leysdr/go/pkg/plugin"
)

func main() {
	opts, err := parseArgs(os.Args[1:], os.Getenv, os.Stderr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "leydec-speech: "+err.Error())
		os.Exit(2)
	}
	plugin.MainSegmented(manifestFor(opts.engine), func(rate uint32, cred *leylinev1.SetCredentialRequest) plugin.SegmentDecoder {
		eng, err := newEngine(opts.engine, opts.config, cred)
		if err != nil {
			fmt.Fprintln(os.Stderr, "leydec-speech: "+err.Error())
			os.Exit(1)
		}
		return newDecoder(eng, float64(rate), os.Stderr, os.Exit)
	})
}

// usageText heads --help. The daemon runs this program; the text is for a person reading what it
// does with the audio and the key.
const usageText = `leydec-speech is the speech decoder plugin the daemon runs: one over of audio
in on stdin, one speech record out on stdout (docs/reference/writing-a-decoder.md).

--engine openai sends each over, as a 16-bit WAV, and the vocabulary hint to
the OpenAI-compatible endpoint of the key the daemon hands over on stdin
(https://api.openai.com unless the key names another). Each call has 60 s plus
one second per 256 KB uploaded, at most 5 minutes. A rejected key exits 1; a
rate or spend limit, an outage, or no answer in time exits 75 with the
provider's words as the last line on stderr. --engine scripted replays the lines
of the file LEYDEC_SPEECH_SCRIPT names and sends nothing anywhere.

`

// options are what the command line says: the engine and how to configure it.
type options struct {
	engine        string
	config        engineConfig
	printManifest bool
}

// parseArgs reads the flags. With --manifest it checks nothing more, and MainSegmented prints the
// manifest whatever else the line says.
func parseArgs(args []string, getenv func(string) string, stderr io.Writer) (options, error) {
	fs := flag.NewFlagSet("leydec-speech", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.Usage = func() {
		fmt.Fprint(fs.Output(), usageText)
		fs.PrintDefaults()
	}
	name := fs.String("engine", "openai", "the speech engine: openai, or scripted for tests")
	model := fs.String("model", "", "the model to ask the engine for, recorded on each record (default: the engine's own)")
	language := fs.String("language", "en", "the language spoken, as an ISO 639-1 code; empty lets the engine detect it")
	hint := fs.String("hint", "", "words to add to the vocabulary hint sent with the audio, after the built-in phonetic alphabet and net phrases; "+hintEnv+" takes its place when set")
	printManifest := fs.Bool("manifest", false, "print the manifest as proto3 JSON and exit")
	if err := fs.Parse(args); err != nil {
		return options{}, err
	}
	opts := options{
		engine: *name,
		config: engineConfig{
			model: *model, language: *language, prompt: vocabularyHint(*hint, getenv), getenv: getenv,
		},
		printManifest: *printManifest,
	}
	if opts.printManifest {
		return opts, nil
	}
	if fs.NArg() > 0 {
		return options{}, fmt.Errorf("unexpected argument %q", fs.Arg(0))
	}
	return opts, checkEngine(opts.engine)
}

// decoder turns each segment into one record.
type decoder struct {
	eng       engine
	audioRate float64
	seq       int
	stderr    io.Writer
	exit      func(int)
}

func newDecoder(eng engine, audioRate float64, stderr io.Writer, exit func(int)) *decoder {
	return &decoder{eng: eng, audioRate: audioRate, stderr: stderr, exit: exit}
}

// Segment transcribes one over. An engine that fails on one segment costs that segment's record
// and a line on stderr, and the next over is tried as usual. A failure no later segment can get
// past (a provider's limit, a rejected key) ends the plugin with its status and the reason as the
// last line on stderr, which is what the daemon reports.
func (d *decoder) Segment(samples []float32, at *leylinev1.SampleTime, emit func(*leylinev1.DecodeRecord)) {
	d.seq++
	tr, err := d.eng.transcribe(samples, d.audioRate, d.seq)
	var stop *stopError
	if errors.As(err, &stop) {
		fmt.Fprintln(d.stderr, stop.msg)
		d.exit(stop.exit)
		return
	}
	if err != nil {
		fmt.Fprintf(d.stderr, "leydec-speech: segment %d at sample %d: %v\n", d.seq, at.GetSampleIndex(), err)
		return
	}
	emit(buildRecord(tr, d.eng, at, float64(len(samples))/d.audioRate))
}

// buildRecord is the speech record: the fields docs/design/ai.md lists, the raw response, and the
// usage the daemon adds to the ledger once it has filled in the feature and the job. clip_uri and
// over are the daemon's to stamp, and so is protocol: it is the installed manifest's name, which
// this binary does not know, being both speech and speech-scripted, and the daemon fills it in
// when it is empty. The record store files a job's records under that name, so a record that
// said otherwise would not be found by the protocol it carries.
func buildRecord(tr transcript, eng engine, at *leylinev1.SampleTime, seconds float64) *leylinev1.DecodeRecord {
	fields := map[string]*leylinev1.FieldValue{
		"text":      text(tr.text),
		"language":  text(tr.language),
		"model":     text(eng.model()),
		"callsigns": text(strings.Join(callsign.Find(tr.text), ",")),
	}
	if tr.hasConfidence {
		fields["confidence"] = &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Number{Number: tr.confidence}}
	}
	return &leylinev1.DecodeRecord{
		Time:   at,
		Fields: fields,
		Raw:    tr.raw,
		Usage: &leylinev1.UsageReport{
			Provider:     eng.provider(),
			Model:        eng.model(),
			Requests:     1,
			AudioSeconds: seconds,
		},
	}
}

func text(s string) *leylinev1.FieldValue {
	return &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Text{Text: s}}
}
